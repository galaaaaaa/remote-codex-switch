param(
    [ValidateSet('Start', 'Stop', 'Setup')]
    [string]$Action = 'Start'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
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
    if ($Config.RemoteFolder -and -not ([string]$Config.RemoteFolder).StartsWith('/')) {
        throw '项目目录请填写服务器上的绝对路径，例如 /home/user/project，或者留空。'
    }
}

function Read-Configuration {
    if (-not (Test-Path -LiteralPath $script:ConfigFile)) { Set-Configuration }
    $config = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Configuration $config
    return $config
}

function Set-Configuration {
    Write-Host '首次设置 / 修改设置' -ForegroundColor Cyan
    $source = Get-SshSource
    $aliases = @()
    if (Test-Path -LiteralPath $source) {
        foreach ($line in Get-Content -LiteralPath $source) {
            if ($line -match '^\s*Host\s+(.+)$') {
                foreach ($alias in ($Matches[1] -split '\s+')) {
                    if ($alias -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') { $aliases += $alias }
                }
            }
        }
    }
    $aliases = @($aliases | Select-Object -Unique)
    for ($i = 0; $i -lt $aliases.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 1), $aliases[$i]) }
    $choice = (Read-Host '服务器：输入序号，或 SSH Host 别名').Trim()
    $index = 0
    if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $aliases.Count) {
        $choice = $aliases[$index - 1]
    }
    $portText = (Read-Host '本机代理的 HTTP / Mixed 端口 [默认 7890]').Trim()
    if (-not $portText) { $portText = '7890' }
    $folder = (Read-Host '服务器项目目录 [留空打开远程主目录]').Trim()
    $config = [pscustomobject]@{ SshHost = $choice; ProxyPort = $portText; RemoteFolder = $folder }
    Assert-Configuration $config
    Write-JsonFile $script:ConfigFile $config
    Write-Host '设置已保存。端口要与代理软件中的 HTTP / Mixed 端口一致。' -ForegroundColor Green
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

function Get-RemoteCommand {
    # This remote command only reads configuration. It writes no remote files.
    $remoteScript = @'
set -eu
printf 'CODEX_SWITCH_HOME=%s\n' "$(printf %s "$HOME" | base64 | tr -d '\n')"
old_proxy=0
if [ -n "${HTTP_PROXY-}${HTTPS_PROXY-}${http_proxy-}${https_proxy-}${ALL_PROXY-}${all_proxy-}" ]; then old_proxy=1; fi
for file in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile"; do
  if [ -f "$file" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy|ALL_PROXY|all_proxy)[[:space:]]*=' "$file"; then old_proxy=1; fi
done
if [ "$old_proxy" = 1 ]; then printf 'CODEX_SWITCH_OLD_PROXY=1\n'; fi
machine="$HOME/.vscode-server/data/Machine/settings.json"
if [ -f "$machine" ] && grep -Eq '"(http\.proxy|terminal\.integrated\.env\.linux)"[[:space:]]*:' "$machine"; then printf 'CODEX_SWITCH_OLD_SETTINGS=1\n'; fi
printf 'CODEX_SWITCH_READY\n'
while sleep 3; do printf 'CODEX_SWITCH_ALIVE\n' || exit; done
'@
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($remoteScript -replace "`r`n", "`n")))
    return 'exec sh -c "$(printf %s ' + $payload + ' | base64 -d)"'
}

function New-CodeSettings($Config, $SshCopy) {
    return [ordered]@{
        'http.proxy' = ('http://127.0.0.1:{0}' -f $Config.ProxyPort)
        'http.proxySupport' = 'on'
        'http.useLocalProxyConfiguration' = $true
        'remote.SSH.configFile' = $SshCopy
        'remote.SSH.remotePlatform' = @{ $Config.SshHost = 'linux' }
        'chatgpt.openOnStartup' = $true
        'window.title' = ('远程 Codex · ' + $Config.SshHost + ' · ${dirty}${activeEditorShort}')
        'extensions.autoUpdate' = $false
    }
}

function New-Workspace($Config, [string]$RemoteHome) {
    $folder = [string]$Config.RemoteFolder
    if (-not $folder) { $folder = $RemoteHome }
    $escapedPath = (($folder -split '/', 0, 'SimpleMatch' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
    # Linux environment variable names are case-sensitive; PowerShell hashtables are not.
    $terminalEnv = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($key in @('HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy','ALL_PROXY','all_proxy','NO_PROXY','no_proxy')) {
        $terminalEnv[$key] = $null
    }
    return [ordered]@{
        folders = @(@{ uri = ('vscode-remote://ssh-remote+' + $Config.SshHost + $escapedPath) })
        settings = @{
            'terminal.integrated.env.linux' = $terminalEnv
        }
    }
}

function Start-CodeClient($Install, $Workspace, $UserData, $Extensions) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Install.Exe
    $argsForCode = @($Install.Cli, '--new-window', '--wait', '--user-data-dir', $UserData, '--extensions-dir', $Extensions, $Workspace)
    $info.Arguments = ($argsForCode | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1'
    $info.EnvironmentVariables.Remove('VSCODE_DEV')
    $info.EnvironmentVariables.Remove('VSCODE_IPC_HOOK_CLI')
    return [Diagnostics.Process]::Start($info)
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
    $stateFile = Join-Path $script:RuntimeRoot 'session.json'
    $process = Get-TrackedSsh $stateFile
    if ($process) {
        Stop-Process -Id $process.Id -ErrorAction Stop
        Write-Host '已停止本工具建立的代理隧道。专用 VS Code 窗口可以关闭。' -ForegroundColor Green
    } else {
        Write-Host '当前没有本工具建立的活动隧道。'
    }
}

function Start-CodexSession {
    [IO.Directory]::CreateDirectory($script:RuntimeRoot) | Out-Null
    $lockPath = Join-Path $script:RuntimeRoot 'session.lock'
    $lock = $null
    $ssh = $null
    $code = $null
    $settingsFile = $null
    $ownsState = $false
    $stateFile = Join-Path $script:RuntimeRoot 'session.json'
    try {
        try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { throw '启动器已经在运行。请先关闭专用窗口，或双击“关闭远程Codex.cmd”。' }
        if (Get-TrackedSsh $stateFile) { throw '检测到上一次的隧道仍在运行，请先双击“关闭远程Codex.cmd”。' }
        $config = Read-Configuration
        $install = Find-CodeInstallation
        $sshExe = Get-SshExe
        $extensions = Get-ExtensionDirectory
        if (-not (Test-Path -LiteralPath $extensions)) { throw '找不到 VS Code 扩展目录。请先安装 Remote - SSH 和 Codex 扩展。' }
        Test-ProxyPort ([int]$config.ProxyPort)
        $sshCopy = Join-Path $script:RuntimeRoot 'ssh-config'
        Write-IsolatedSshConfig $sshCopy
        $effective = & $sshExe -G -F $sshCopy $config.SshHost 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'SSH 配置检查失败，请检查 SSH Host 名称及配置文件。' }
        if ($effective -match '^(remoteforward|localforward|dynamicforward)\s') {
            throw 'SSH 的 Include 文件仍包含端口转发。请先为该连接移除常驻转发；原配置未被本工具修改。'
        }
        $userData = Join-Path $script:RuntimeRoot 'vscode-data'
        $settingsFile = Join-Path $userData 'User\settings.json'
        Write-JsonFile $settingsFile (New-CodeSettings $config $sshCopy)
        $log = Join-Path $script:RuntimeRoot 'connection.log'
        $forward = '127.0.0.1:{0}:127.0.0.1:{0}' -f $config.ProxyPort
        $sshArguments = @('-n', '-T', '-F', $sshCopy, '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2', '-o', 'ConnectTimeout=15', '-R', $forward, $config.SshHost, (Get-RemoteCommand))
        Write-Host '正在建立连接。如提示密码或首次确认主机，请在此窗口完成。' -ForegroundColor Cyan
        $ssh = Start-Process -FilePath $sshExe -ArgumentList (($sshArguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' ') -NoNewWindow -RedirectStandardOutput $log -PassThru
        Write-JsonFile $stateFile @{
            SshPid = $ssh.Id
            SshExe = $sshExe
            SshStartedUtcTicks = $ssh.StartTime.ToUniversalTime().Ticks.ToString()
        }
        $ownsState = $true
        $deadline = [DateTime]::UtcNow.AddMinutes(3)
        $received = ''
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($ssh.HasExited) { throw 'SSH 连接已退出。请查看上方错误；可能是登录失败，或服务器上的同名端口已占用。' }
            if (Test-Path -LiteralPath $log) { $received = Read-SharedText $log }
            if ($received.Contains('CODEX_SWITCH_READY')) { break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $received.Contains('CODEX_SWITCH_READY')) { throw '等待 SSH 登录超时，请重新启动。' }
        if ($received -notmatch 'CODEX_SWITCH_HOME=([A-Za-z0-9+/=]+)') { throw '无法读取远程主目录。' }
        $remoteHome = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
        if ($received.Contains('CODEX_SWITCH_OLD_PROXY=1') -or $received.Contains('CODEX_SWITCH_OLD_SETTINGS=1')) {
            Write-Warning '检测到服务器可能留有旧代理设置。本开关不会清理它们，普通终端可能仍受影响。请查看“README.md”的旧配置部分。'
        }
        $workspace = Join-Path $script:RuntimeRoot 'Remote-Codex.code-workspace'
        Write-JsonFile $workspace (New-Workspace $config $remoteHome)
        $code = Start-CodeClient $install $workspace $userData $extensions
        Write-Host ''
        Write-Host '隧道已建立，正在打开远程 Codex 专用窗口。' -ForegroundColor Green
        Write-Host '用完关闭该 VS Code 窗口，隧道会自动停止；也可双击“关闭远程Codex.cmd”。'
        Write-Host '此窗口请保持打开。首次使用可能需要在远端安装 Codex 扩展并登录。'
        while (-not $code.HasExited -and -not $ssh.HasExited) { Start-Sleep -Milliseconds 500 }
        if ($ssh.HasExited -and -not $code.HasExited) {
            Write-Warning '代理隧道已停止或断开。服务器继续运行，专用窗口中的 Codex 将无法通过该隧道联网。'
        } elseif ($code.ExitCode -ne 0) {
            throw ('VS Code 启动失败，退出码：' + $code.ExitCode)
        }
    } finally {
        if ($ssh -and -not $ssh.HasExited) {
            Stop-Process -Id $ssh.Id -ErrorAction SilentlyContinue
            $ssh.WaitForExit(3000) | Out-Null
        }
        if ($code -and -not $code.HasExited) {
            # This is the waiting CLI helper, not the editor or the user's other windows.
            Stop-Process -Id $code.Id -ErrorAction SilentlyContinue
            $code.WaitForExit(3000) | Out-Null
        }
        if ($settingsFile -and (Test-Path -LiteralPath $settingsFile)) {
            $settings = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $settings.'http.proxy' = ''
            Write-JsonFile $settingsFile $settings
        }
        if ($lock) {
            if ($ownsState -and (Test-Path -LiteralPath $stateFile)) { Remove-Item -LiteralPath $stateFile -Force }
            $lock.Dispose()
        }
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }
try {
    switch ($Action) {
        'Start' { Start-CodexSession }
        'Stop' { Stop-CodexTunnel }
        'Setup' { Set-Configuration }
    }
} catch {
    Write-Host ("操作未完成：" + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
