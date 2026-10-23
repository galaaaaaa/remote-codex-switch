param(
    [ValidateSet('Start', 'Stop', 'Setup', 'Server', 'Detect', 'SyncLogin', 'Open')]
    [string]$Action = 'Start',
    [switch]$GuiMode
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$script:PackageRoot = $PSScriptRoot
$script:RuntimeRoot = Join-Path $PSScriptRoot 'runtime'
$script:ConfigFile = Join-Path $PSScriptRoot 'config.json'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-JsonFile($Path, $Value) {
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), $script:Utf8)
}

function Read-SharedText($Path) {
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Quote-NativeArgument([string]$Value) {
    # CommandLineToArgvW quoting, including quotes and trailing backslashes.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Get-SshExe {
    return (Get-Command ssh.exe -ErrorAction Stop).Source
}

function Get-SshSource {
    return Join-Path $env:USERPROFILE '.ssh\config'
}

function Get-ExtensionDirectory {
    return Join-Path $env:USERPROFILE '.vscode\extensions'
}

function Find-CodeInstallation {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code')
    )
    foreach ($base in $candidates) {
        $exe = Join-Path $base 'Code.exe'
        if (-not (Test-Path -LiteralPath $exe)) { continue }
        $cliPaths = @((Join-Path $base 'resources\app\out\cli.js'))
        foreach ($dir in Get-ChildItem -LiteralPath $base -Directory) {
            $cliPaths += Join-Path $dir.FullName 'resources\app\out\cli.js'
        }
        $cli = $cliPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($cli) { return @{ Exe = $exe; Cli = $cli } }
    }
    throw '找不到正式版 VS Code。请先安装 VS Code，或调整 Find-CodeInstallation 中的安装路径。'
}

function Assert-Configuration($Config) {
    if ($Config.SshHost -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw 'SSH 名称应使用 .ssh/config 中的 Host 别名，例如 my-server。'
    }
    $port = 0
    if (-not [int]::TryParse([string]$Config.ProxyPort, [ref]$port) -or $port -lt 1024 -or $port -gt 65535) {
        throw '代理端口必须是 1024 到 65535 之间的整数。'
    }
    if ($Config.PSObject.Properties['AutoDetectProxyPort'] -and $Config.AutoDetectProxyPort -isnot [bool]) {
        throw 'AutoDetectProxyPort 必须为 true 或 false。'
    }
    if ($Config.RemoteFolder -and -not ([string]$Config.RemoteFolder).StartsWith('/')) {
        throw '项目目录请填写服务器上的绝对路径，例如 /home/user/project，或者留空。'
    }
}

function Read-Configuration {
    if (-not (Test-Path -LiteralPath $script:ConfigFile)) { Set-Configuration }
    $config = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $config.PSObject.Properties['AutoDetectProxyPort']) {
        $config | Add-Member -NotePropertyName AutoDetectProxyPort -NotePropertyValue $true
    }
    Assert-Configuration $config
    return $config
}

function Select-SshHost([string]$DefaultHost = '') {
    $source = Get-SshSource
    $aliases = @()
    if (Test-Path -LiteralPath $source) {
        foreach ($sourceLine in Get-Content -LiteralPath $source) {
            $line = ($sourceLine -split '#', 2)[0]
            if ($line -match '^\s*Host\s+(.+)$') {
                foreach ($alias in ($Matches[1] -split '\s+')) {
                    if ($alias -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') { $aliases += $alias }
                }
            }
        }
    }
    $aliases = @($aliases | Select-Object -Unique)
    for ($i = 0; $i -lt $aliases.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 1), $aliases[$i]) }
    $prompt = '服务器：输入序号，或 SSH Host 别名'
    if ($DefaultHost) { $prompt += " [回车保留 $DefaultHost]" }
    $choice = (Read-Host $prompt).Trim()
    if (-not $choice) { $choice = $DefaultHost }
    $index = 0
    if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $aliases.Count) {
        $choice = $aliases[$index - 1]
    }
    return $choice
}

function Set-Configuration {
    Write-Host '首次设置 / 修改设置' -ForegroundColor Cyan
    $choice = Select-SshHost
    $portText = (Read-Host '代理端口 [回车自动检测；输入数字则固定使用该端口]').Trim()
    $autoDetect = -not $portText
    if ($autoDetect) { $portText = '7890' }
    $folder = (Read-Host '服务器项目目录 [留空打开远程主目录]').Trim()
    $config = [pscustomobject]@{ SshHost = $choice; ProxyPort = $portText; AutoDetectProxyPort = $autoDetect; RemoteFolder = $folder }
    Assert-Configuration $config
    Write-JsonFile $script:ConfigFile $config
    Write-Host '设置已保存。自动模式会在每次开启时重新检查代理端口。' -ForegroundColor Green
}

function Set-Server {
    if (-not (Test-Path -LiteralPath $script:ConfigFile)) { Set-Configuration; return }
    $config = Read-Configuration
    $config.SshHost = Select-SshHost $config.SshHost
    $config.RemoteFolder = (Read-Host '该服务器的项目目录 [留空打开远程主目录]').Trim()
    Assert-Configuration $config
    Write-JsonFile $script:ConfigFile $config
    Write-Host ('已选择服务器：' + $config.SshHost) -ForegroundColor Green
}

function Test-ProxyPort([int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(2500)) { throw 'timeout' }
        $client.EndConnect($pending)
    } catch {
        throw "本机 127.0.0.1:$Port 没有可连接的代理端口。请先打开梯子，核对 HTTP / Mixed 端口。"
    } finally { $client.Close() }
}

function Get-LoopbackProxyPort([string]$Endpoint) {
    if (-not $Endpoint) { return }
    $address = $Endpoint.Trim()
    if ($address -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $address = 'http://' + $address }
    $uri = $null
    if (-not [Uri]::TryCreate($address, [UriKind]::Absolute, [ref]$uri)) { return }
    if ($uri.Scheme -ne 'http' -or $uri.Host -notin @('127.0.0.1', 'localhost') -or $uri.UserInfo) { return }
    if ($uri.Port -ge 1024 -and $uri.Port -le 65535) { return [int]$uri.Port }
}

function Get-SystemProxyEndpoints {
    try {
        $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable,ProxyServer -ErrorAction Stop
        if ($settings.ProxyEnable -ne 1) { return }
        foreach ($entry in ([string]$settings.ProxyServer -split ';')) {
            if ($entry -match '^(?i:https?)=(.+)$') { $Matches[1] }
            elseif ($entry -notmatch '=') { $entry }
        }
    } catch { return }
}

function Get-EnvironmentProxyEndpoints {
    foreach ($key in @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy')) {
        $value = [Environment]::GetEnvironmentVariable($key)
        if ($value) { $value }
    }
}

function Get-ProxyProcessPorts {
    try {
        $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -match '(?i)(mihomo|clash|v2ray|xray|sing-box|hiddify|nekoray|nekobox)'
        })
        if ($processes.Count -eq 0) { return }
        Get-NetTCPConnection -State Listen -OwningProcess @($processes.Id) -ErrorAction Stop |
            Where-Object { $_.LocalAddress -in @('127.0.0.1', '0.0.0.0', '::') -and $_.LocalPort -ge 1024 } |
            Select-Object -ExpandProperty LocalPort -Unique
    } catch { return }
}

function Get-ProxyCandidates([int]$SavedPort) {
    $items = [Collections.Generic.List[object]]::new()
    foreach ($endpoint in @(Get-SystemProxyEndpoints)) {
        $port = Get-LoopbackProxyPort $endpoint
        if ($port) { $items.Add([pscustomobject]@{ Port=$port; Priority=0; Source='Windows 系统代理' }) }
    }
    foreach ($endpoint in @(Get-EnvironmentProxyEndpoints)) {
        $port = Get-LoopbackProxyPort $endpoint
        if ($port) { $items.Add([pscustomobject]@{ Port=$port; Priority=1; Source='本机代理环境变量' }) }
    }
    $items.Add([pscustomobject]@{ Port=$SavedPort; Priority=2; Source='上次保存的端口' })
    foreach ($port in @(Get-ProxyProcessPorts)) {
        $items.Add([pscustomobject]@{ Port=[int]$port; Priority=3; Source='运行中的代理程序' })
    }
    foreach ($port in @(7890, 7897, 10809, 10808, 1080, 1087, 2080)) {
        $items.Add([pscustomobject]@{ Port=$port; Priority=4; Source='常见代理端口' })
    }
    $seen = @{}
    foreach ($item in ($items | Sort-Object Priority,Port)) {
        if (-not $seen.ContainsKey($item.Port)) { $seen[$item.Port] = $true; $item }
    }
}

function Test-HttpProxyPort([int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    $reader = $null
    $waitHandle = $null
    try {
        $pending = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $waitHandle = $pending.AsyncWaitHandle
        if (-not $waitHandle.WaitOne(400)) { return $false }
        $client.EndConnect($pending)
        $client.ReceiveTimeout = 1500
        $client.SendTimeout = 1500
        $stream = $client.GetStream()
        # A CONNECT handshake distinguishes HTTP/Mixed proxies from SOCKS-only ports.
        # No application payload or account data is sent through the test tunnel.
        $request = [Text.Encoding]::ASCII.GetBytes("CONNECT example.com:443 HTTP/1.1`r`nHost: example.com:443`r`n`r`n")
        $stream.Write($request, 0, $request.Length)
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII)
        $status = $reader.ReadLine()
        return $null -ne $status -and $status -match '^HTTP/1\.[01] 200\b'
    } catch { return $false }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($waitHandle) { $waitHandle.Dispose() }
        $client.Close()
    }
}

function Resolve-ProxyPort($Config, [switch]$ForceDetection) {
    if (-not $ForceDetection -and -not $Config.AutoDetectProxyPort) {
        Test-ProxyPort ([int]$Config.ProxyPort)
        return [int]$Config.ProxyPort
    }
    Write-Host '正在检测本机 HTTP / Mixed 代理端口……' -ForegroundColor Cyan
    foreach ($group in @(Get-ProxyCandidates ([int]$Config.ProxyPort) | Group-Object Priority | Sort-Object { [int]$_.Name })) {
        $valid = @($group.Group | Where-Object { Test-HttpProxyPort $_.Port })
        if ($valid.Count -eq 0) { continue }
        if ($valid.Count -eq 1) {
            Write-Host ('检测到端口 {0}（{1}）' -f $valid[0].Port,$valid[0].Source) -ForegroundColor Green
            return [int]$valid[0].Port
        }
        Write-Host '发现多个可用代理端口，请选择：'
        for ($i = 0; $i -lt $valid.Count; $i++) { Write-Host ('  {0}. {1}（{2}）' -f ($i + 1),$valid[$i].Port,$valid[$i].Source) }
        $selection = 0
        $choice = Read-Host '输入序号'
        if (-not [int]::TryParse($choice, [ref]$selection) -or $selection -lt 1 -or $selection -gt $valid.Count) {
            throw '未选择有效的代理端口，请重新开启。'
        }
        return [int]$valid[$selection - 1].Port
    }
    Write-Warning '未能自动确认可用 HTTP 代理。请先打开代理软件，也可以手动指定端口。'
    $manualText = (Read-Host '手动输入 HTTP / Mixed 端口 [回车取消]').Trim()
    $manualPort = 0
    if (-not [int]::TryParse($manualText, [ref]$manualPort) -or $manualPort -lt 1024 -or $manualPort -gt 65535) {
        throw '未设置有效代理端口。打开代理软件后再试，或通过“修改设置.cmd”填写端口。'
    }
    Test-ProxyPort $manualPort
    Write-Warning '手动端口仅确认了 TCP 可连接，请确认它是无需认证的 HTTP / Mixed 端口。'
    return $manualPort
}

function Detect-ProxyPort {
    $hasConfig = Test-Path -LiteralPath $script:ConfigFile
    if ($hasConfig) { $config = Read-Configuration }
    else { $config = [pscustomobject]@{ ProxyPort=7890; AutoDetectProxyPort=$true } }
    $config.ProxyPort = Resolve-ProxyPort $config -ForceDetection
    $config.AutoDetectProxyPort = $true
    if ($hasConfig) { Write-JsonFile $script:ConfigFile $config }
    Write-Host ('当前代理端口：{0}。下次开启时仍会自动检测。' -f $config.ProxyPort) -ForegroundColor Green
}

function Write-IsolatedSshConfig($Destination) {
    $source = Get-SshSource
    if (-not (Test-Path -LiteralPath $source)) { throw '未找到 .ssh/config，请先在 VS Code 中配置服务器连接。' }
    $original = [IO.File]::ReadAllText($source)
    # The editor must not create a second copy of the launcher's reverse tunnel.
    # Work on a copy; never edit the user's SSH configuration.
    $copy = [regex]::Replace($original, '(?im)^[ \t]*(RemoteForward|LocalForward|DynamicForward|ClearAllForwardings)[ \t=].*$', '# Forwarding omitted in this isolated copy.')
    $copy = "Host *`n  ClearAllForwardings no`n" + $copy
    [IO.File]::WriteAllText($Destination, $copy, $script:Utf8)
}

function Get-RemoteCommand([int]$ProxyPort, [string]$SessionId) {
    if ($ProxyPort -lt 1024 -or $ProxyPort -gt 65535 -or $SessionId -notmatch '^[a-f0-9]{32}$') { throw '代理会话参数无效。' }
    $source = [IO.File]::ReadAllText((Join-Path $script:PackageRoot 'RemoteSession.py'))
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))
    return ('exec python3 -u -c "import base64;exec(base64.b64decode(''{0}''))" {1} {2}' -f $payload,$ProxyPort,$SessionId)
}

function Start-SshChannel($Executable, $Arguments, $Log, $ErrorLog, [switch]$Batch) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = ($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = [bool]$Batch
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = [bool]$Batch
    $output = [IO.FileStream]::new($Log,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,1,$true)
    $errors = $null
    try {
        if ($Batch) { $errors = [IO.FileStream]::new($ErrorLog,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,1,$true) }
        $process = [Diagnostics.Process]::Start($info)
        $copy = $process.StandardOutput.BaseStream.CopyToAsync($output)
        $errorCopy = $null
        if ($errors) { $errorCopy = $process.StandardError.BaseStream.CopyToAsync($errors) }
        return [pscustomobject]@{ Process=$process; Output=$output; Errors=$errors; Copy=$copy; ErrorCopy=$errorCopy }
    } catch { $output.Dispose(); if($errors){$errors.Dispose()}; throw }
}

function Send-SshHeartbeat($Channel) {
    if ($Channel -and -not $Channel.Process.HasExited) {
        try { $Channel.Process.StandardInput.WriteLine('PING'); $Channel.Process.StandardInput.Flush() } catch { }
    }
}

function Close-SshChannel($Channel) {
    if (-not $Channel) { return }
    $process = $Channel.Process
    try {
        if (-not $process.HasExited) {
            try { $process.StandardInput.WriteLine('STOP'); $process.StandardInput.Close() } catch { }
            if (-not $process.WaitForExit(5000)) { $process.Kill(); $process.WaitForExit(2000) | Out-Null }
        }
        try { $Channel.Copy.Wait(2000) | Out-Null } catch { }
        if ($Channel.ErrorCopy) { try { $Channel.ErrorCopy.Wait(2000) | Out-Null } catch { } }
    } finally {
        $Channel.Output.Dispose()
        if ($Channel.Errors) { $Channel.Errors.Dispose() }
        $process.Dispose()
    }
}

function Open-RemoteProject {
    $config = Read-Configuration
    $install = Find-CodeInstallation
    $arguments = @($install.Cli,'--new-window','--remote',('ssh-remote+' + $config.SshHost))
    if ($config.RemoteFolder) { $arguments += [string]$config.RemoteFolder }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $install.Exe
    $info.Arguments = ($arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1'
    $info.EnvironmentVariables.Remove('VSCODE_IPC_HOOK_CLI')
    [Diagnostics.Process]::Start($info) | Out-Null
    Write-Host '已请求打开普通 VS Code 远程窗口。关闭该窗口不会停止共享连接。'
}

function Get-TrackedSsh($StateFile) {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try {
        $state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $process = Get-Process -Id ([int]$state.SshPid) -ErrorAction Stop
        if ($process.Path -ne $state.SshExe) { return $null }
        if ($process.StartTime.ToUniversalTime().Ticks.ToString() -ne $state.SshStartedUtcTicks) { return $null }
        return $process
    } catch { return $null }
}

function Stop-CodexTunnel {
    [IO.Directory]::CreateDirectory($script:RuntimeRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:RuntimeRoot 'stop.request'), 'stop', $script:Utf8)
    $stateFile = Join-Path $script:RuntimeRoot 'session.json'
    $process = Get-TrackedSsh $stateFile
    if ($process) {
        if (-not $process.WaitForExit(8000)) { Stop-Process -Id $process.Id -ErrorAction Stop }
        Write-Host '共享连接已停止。远端代理设置会恢复，已启动的 Codex 如需继续使用请重新加载窗口。' -ForegroundColor Green
    } else {
        Write-Host '当前没有本工具建立的活动隧道。'
    }
}

function Get-LoginSyncCommand {
    $remoteScript = @'
set -eu
umask 077
auth_dir=${CODEX_HOME:-"$HOME/.codex"}
if [ -f "$auth_dir/config.toml" ] && grep -E '^[[:space:]]*cli_auth_credentials_store[[:space:]]*=' "$auth_dir/config.toml" | grep -Eq '(keyring|auto|ephemeral)'; then
  printf '%s\n' 'Remote Codex: login sync currently requires file credential storage on the server.' >&2
  exit 1
fi
mkdir -p "$auth_dir"
if [ -L "$auth_dir/auth.json" ]; then printf '%s\n' 'Remote Codex: refusing to replace a symlinked auth.json.' >&2; exit 1; fi
temporary=$(mktemp "$auth_dir/.remote-codex-login.XXXXXXXXXX")
trap 'rm -f "$temporary"' EXIT
cat > "$temporary"
if [ ! -s "$temporary" ]; then printf '%s\n' 'Remote Codex: no login data received.' >&2; exit 1; fi
chmod 600 "$temporary"
if [ -f "$auth_dir/auth.json" ]; then
  backup="$auth_dir/auth.json.remote-codex-switch-backup-$(date +%Y%m%d%H%M%S)-$$"
  cp -p "$auth_dir/auth.json" "$backup"
  chmod 600 "$backup"
fi
mv "$temporary" "$auth_dir/auth.json"
printf 'CODEX_SWITCH_LOGIN_SYNCED\n'
'@
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($remoteScript -replace "`r`n", "`n")))
    return 'exec sh -c "$(printf %s ' + $payload + ' | base64 -d)"'
}

function Sync-CodexLogin([switch]$GuiMode) {
    $config = Read-Configuration
    $authRoot = $env:CODEX_HOME
    if (-not $authRoot) { $authRoot = Join-Path $env:USERPROFILE '.codex' }
    $authPath = Join-Path $authRoot 'auth.json'
    if (-not (Test-Path -LiteralPath $authPath) -or (Get-Item -LiteralPath $authPath).Length -gt 1MB) {
        throw '找不到可同步的本机 Codex 登录文件。请先在本机 Codex 登录；系统凭据库中的登录暂不支持此方式。'
    }
    # Credentials travel only over SSH stdin, never in arguments, logs or Git.
    $authText = [IO.File]::ReadAllText($authPath, [Text.Encoding]::UTF8)
    try { $auth = $authText | ConvertFrom-Json } catch { throw '本机 Codex 登录文件不是有效 JSON，请重新登录。' }
    $hasTokens = $false
    $hasApiKey = $false
    if ($auth -and $auth.PSObject.Properties['tokens'] -and $auth.tokens) {
        foreach ($key in @('access_token','refresh_token')) {
            if ($auth.tokens.PSObject.Properties[$key] -and -not [string]::IsNullOrWhiteSpace([string]$auth.tokens.$key)) { $hasTokens = $true }
        }
    }
    if ($auth -and $auth.PSObject.Properties['OPENAI_API_KEY']) { $hasApiKey = -not [string]::IsNullOrWhiteSpace([string]$auth.OPENAI_API_KEY) }
    if (-not $hasTokens -and -not $hasApiKey) {
        throw '本机文件不包含可识别的 Codex 登录数据，请重新登录。'
    }
    $sshExe = Get-SshExe
    $arguments = @('-T', '-F', (Get-SshSource), '-o', 'ClearAllForwardings=yes', '-o', 'ConnectTimeout=15')
    if ($GuiMode) { $arguments += @('-o', 'BatchMode=yes') }
    $arguments += @($config.SshHost, (Get-LoginSyncCommand))
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $sshExe
        $info.Arguments = ($arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
        $info.UseShellExecute = $false
        $info.CreateNoWindow = [bool]$GuiMode
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = [bool]$GuiMode
        $process = [Diagnostics.Process]::Start($info)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $null
            if ($GuiMode) { $stderr = $process.StandardError.ReadToEndAsync() }
            $timeout = if ($GuiMode) { 30000 } else { 180000 }
            $write = $process.StandardInput.WriteAsync($authText)
            if (-not $write.Wait($timeout)) { $process.Kill(); throw '同步登录超时，请检查服务器连接。' }
            $process.StandardInput.Close()
            if (-not $process.WaitForExit($timeout)) { $process.Kill(); throw '同步登录超时，请检查服务器连接。' }
            $errorText = ''
            if ($stderr) { $errorText = $stderr.Result }
            if ($GuiMode -and $process.ExitCode -ne 0 -and $errorText -match '(?i)(permission denied|host key verification failed|sign_and_send_pubkey|authentication failed)') {
                Write-Host '同步需要 SSH 登录，请在弹出的窗口输入密码或确认主机。'
                $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $syncArgs = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $script:PackageRoot 'RemoteCodex.ps1'),'-Action','SyncLogin')
                $interactive = Start-Process -FilePath $shell -ArgumentList (($syncArgs | ForEach-Object { Quote-NativeArgument $_ }) -join ' ') -WindowStyle Normal -Wait -PassThru
                if ($interactive.ExitCode -ne 0) { throw '同步登录未完成，请查看 SSH 登录窗口的提示。' }
                Write-Host '同步窗口已完成。请重新加载远端 Codex；联网仍需保持代理连接。'
                return
            }
            if ($process.ExitCode -ne 0 -or -not $stdout.Result.Contains('CODEX_SWITCH_LOGIN_SYNCED')) {
                throw '同步登录失败，请检查 SSH 权限，以及远端是否使用文件方式保存 Codex 登录。'
            }
        } finally {
            if (-not $process.HasExited) { $process.Kill() }
            $process.Dispose()
        }
    Write-Host '本机登录已通过 SSH 同步到所选服务器。旧文件（如有）已在远端备份。' -ForegroundColor Green
    Write-Host '请重新加载远端 Codex。登录同步不会修复网络；使用和刷新登录仍需要代理连接。'
}

function Start-CodexSession([switch]$GuiMode) {
    [IO.Directory]::CreateDirectory($script:RuntimeRoot) | Out-Null
    $lockPath = Join-Path $script:RuntimeRoot 'session.lock'
    $lock = $null
    $channel = $null
    $ownsState = $false
    $stateFile = Join-Path $script:RuntimeRoot 'session.json'
    $stopFile = Join-Path $script:RuntimeRoot 'stop.request'
    try {
        try { $lock = [IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None') }
        catch { throw '共享连接已经在运行，请使用已有应用或先关闭连接。' }
        if (Get-TrackedSsh $stateFile) { throw '上一次连接仍在运行，请先关闭连接。' }
        if (Test-Path -LiteralPath $stopFile) { Remove-Item -LiteralPath $stopFile -Force }
        $config = Read-Configuration
        if ($GuiMode) { Test-ProxyPort ([int]$config.ProxyPort) }
        else { $config.ProxyPort = Resolve-ProxyPort $config }
        Write-JsonFile $script:ConfigFile $config
        $sshExe = Get-SshExe
        $sshCopy = Join-Path $script:RuntimeRoot 'ssh-config'
        Write-IsolatedSshConfig $sshCopy
        $effective = & $sshExe -G -F $sshCopy $config.SshHost 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'SSH 配置检查失败。' }
        if ($effective -match '^(remoteforward|localforward|dynamicforward)\s') { throw 'SSH Include 文件仍有常驻端口转发，请先处理重复转发。' }
        $log = Join-Path $script:RuntimeRoot 'connection.log'
        $errorLog = Join-Path $script:RuntimeRoot 'ssh-error.log'
        $sessionId = [Guid]::NewGuid().ToString('N')
        $forward = '127.0.0.1:{0}:127.0.0.1:{0}' -f $config.ProxyPort
        $arguments = @('-T','-F',$sshCopy,'-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2','-o','ConnectTimeout=15','-R',$forward,$config.SshHost,(Get-RemoteCommand $config.ProxyPort $sessionId))
        if ($GuiMode) { $arguments = @('-o','BatchMode=yes') + $arguments }
        Write-Host ('正在为 ' + $config.SshHost + ' 开启共享连接……') -ForegroundColor Cyan
        $channel = Start-SshChannel $sshExe $arguments $log $errorLog -Batch:$GuiMode
        $ssh = $channel.Process
        Write-JsonFile $stateFile @{ SshPid=$ssh.Id; SshExe=$sshExe; SshStartedUtcTicks=$ssh.StartTime.ToUniversalTime().Ticks.ToString(); SshHost=$config.SshHost; SessionId=$sessionId }
        $ownsState = $true
        $deadline = [DateTime]::UtcNow.AddMinutes(3)
        $received = ''
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath $stopFile) { return }
            Send-SshHeartbeat $channel
            if ($ssh.HasExited) {
                try { $channel.Copy.Wait(1000) | Out-Null; if($channel.ErrorCopy){$channel.ErrorCopy.Wait(1000) | Out-Null} } catch { }
                $details = if($GuiMode) { Read-SharedText $errorLog } else { '' }
                if ($GuiMode -and $details -match '(?i)(permission denied|host key verification failed|sign_and_send_pubkey|authentication failed)') {
                    Close-SshChannel $channel
                    $channel=$null
                    Remove-Item -LiteralPath $stateFile -Force
                    $ownsState=$false
                    $lock.Dispose(); $lock=$null
                    Write-Host '请在弹出的 SSH 窗口输入密码或确认主机。'
                    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    $childArgs=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $script:PackageRoot 'RemoteCodex.ps1'),'-Action','Start')
                    $child=Start-Process -FilePath $shell -ArgumentList (($childArgs|ForEach-Object{Quote-NativeArgument $_}) -join ' ') -WindowStyle Normal -PassThru
                    $child.WaitForExit()
                    if($child.ExitCode -ne 0){throw 'SSH 登录窗口中的共享连接未完成。'}
                    return
                }
                throw ('共享连接未完成。请确认服务器有 Python 3、curl，端口未占用。' + $details.Trim())
            }
            if (Test-Path -LiteralPath $log) { $received=Read-SharedText $log }
            if ($received.Contains('CODEX_SWITCH_READY')) { break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $received.Contains('CODEX_SWITCH_READY') -or -not $received.Contains('CODEX_SWITCH_SHARED=1')) { throw '等待共享连接超时。' }
        Write-Host '共享连接已开启。请在该服务器当前用户的 VS Code 窗口重新加载一次，再使用 Codex。' -ForegroundColor Green
        Write-Host '无需保留某个 VS Code 窗口。应用可收进托盘；关闭连接或退出应用时恢复远端代理设置。'
        while (-not $ssh.HasExited -and -not (Test-Path -LiteralPath $stopFile)) {
            Send-SshHeartbeat $channel
            Start-Sleep -Milliseconds 500
        }
        if (-not (Test-Path -LiteralPath $stopFile)) { throw '共享连接已断开，请检查本机代理或 SSH 后重新开启。' }
    } finally {
        Close-SshChannel $channel
        if ($lock) {
            if ($ownsState -and (Test-Path -LiteralPath $stateFile)) { Remove-Item -LiteralPath $stateFile -Force }
            $lock.Dispose()
        }
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }
try {
    switch ($Action) {
        'Start' { Start-CodexSession -GuiMode:$GuiMode }
        'Stop' { Stop-CodexTunnel }
        'Setup' { Set-Configuration }
        'Server' { Set-Server }
        'Detect' { Detect-ProxyPort }
        'SyncLogin' { Sync-CodexLogin -GuiMode:$GuiMode }
        'Open' { Open-RemoteProject }
    }
} catch {
    Write-Host ("操作未完成：" + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
