$ErrorActionPreference = 'Stop'
$taskBase = Split-Path -Parent $PSScriptRoot
. (Join-Path $taskBase 'RemoteCodex.ps1')
$testRoot = Join-Path $taskBase ('.test-artifacts\switch-check-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$mockSsh = Join-Path $testRoot 'mockssh.exe'
$mockCode = Join-Path $testRoot 'mockcode.exe'
$testSshSource = Join-Path $testRoot 'original-ssh-config'
$testExtensions = Join-Path $testRoot 'extensions'
[IO.Directory]::CreateDirectory($testExtensions) | Out-Null
$originalSsh = "Host Example`n HostName example.invalid`n RemoteForward 7890 127.0.0.1:7890`n"
[IO.File]::WriteAllText($testSshSource, $originalSsh)
Add-Type -OutputAssembly $mockSsh -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public class MockEntry {
    public static int Main(string[] args) {
        bool ssh = Path.GetFileNameWithoutExtension(System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName) == "mockssh";
        string mode = Environment.GetEnvironmentVariable("CODEX_SWITCH_TEST_MODE");
        if (ssh) {
            if (Array.IndexOf(args, "-G") >= 0) { Console.WriteLine("hostname example.invalid"); return 0; }
            Console.WriteLine("CODEX_SWITCH_HOME=L2hvbWUvZXhhbXBsZQ==");
            Console.WriteLine("CODEX_SWITCH_WRAPPER="+Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("/home/example/.cache/remote-codex-switch/test/codex")));
            Console.WriteLine("CODEX_SWITCH_AUTH_HTTP="+(mode=="proxy-error"?"403":"200"));
            Console.WriteLine("CODEX_SWITCH_READY");
            Console.Out.Flush();
            if (mode == "ssh-drop") { Thread.Sleep(1200); return 23; }
            while (true) { Thread.Sleep(1000); Console.WriteLine("CODEX_SWITCH_ALIVE"); Console.Out.Flush(); }
        }
        if (mode == "code-error") { Thread.Sleep(700); return 42; }
        if (mode == "ssh-drop") { Thread.Sleep(15000); return 0; }
        if (mode == "user-stop") {
            Thread.Sleep(700);
            int position=Array.IndexOf(args,"--user-data-dir");
            string runtime=Directory.GetParent(args[position+1]).FullName;
            File.WriteAllText(Path.Combine(runtime,"stop.request"),"stop");
            Thread.Sleep(15000); return 0;
        }
        Thread.Sleep(1000);
        return 0;
    }
}
'@
Copy-Item -LiteralPath $mockSsh -Destination $mockCode
function Get-SshExe { return $mockSsh }
function Get-SshSource { return $testSshSource }
function Get-ExtensionDirectory { return $testExtensions }
function Find-CodeInstallation { return @{ Exe = $mockCode; Cli = (Join-Path $testRoot 'cli.js') } }
function Assert-Test($Condition, $Message) { if (-not $Condition) { throw $Message } }

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$testPort = $listener.LocalEndpoint.Port
try {
    Test-ProxyPort $testPort
    foreach ($mode in @('window-close','gui-window-close','user-stop','ssh-drop','code-error','proxy-error')) {
        $env:CODEX_SWITCH_TEST_MODE = $mode
        $script:RuntimeRoot = Join-Path $testRoot $mode
        $script:ConfigFile = Join-Path $testRoot ($mode + '.json')
        $cfg = [pscustomobject]@{ SshHost='Example'; ProxyPort=$testPort; AutoDetectProxyPort=$false; RemoteFolder='/home/example/a b' }
        Write-JsonFile $script:ConfigFile $cfg
        $caught = $false
        try { Start-CodexSession -GuiMode:($mode -eq 'gui-window-close') } catch {
            if ($mode -notin @('code-error','proxy-error')) { throw }
            $expected = if ($mode -eq 'code-error') { '*42*' } else { '*HTTP 403*' }
            Assert-Test ($_.Exception.Message -like $expected) 'Unexpected connection error.'
            $caught = $true
        }
        if ($mode -in @('code-error','proxy-error')) { Assert-Test $caught 'Connection error was not propagated.' }
        Assert-Test (-not (Test-Path -LiteralPath (Join-Path $script:RuntimeRoot 'session.json'))) 'State was not cleared.'
        if ($mode -eq 'proxy-error') {
            Assert-Test (-not (Test-Path -LiteralPath (Join-Path $script:RuntimeRoot 'vscode-data\User\settings.json'))) 'VS Code was configured despite failed proxy validation.'
            Write-Output 'PASS failed proxy validation blocks the editor'
            continue
        }
        $settings = Get-Content -LiteralPath (Join-Path $script:RuntimeRoot 'vscode-data\User\settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Test ($settings.'http.proxy' -eq '') 'Proxy setting was not reset.'
        Assert-Test ($null -eq $settings.'chatgpt.cliExecutable') 'Remote launcher setting was not reset.'
        $workspaceFiles = @(Get-ChildItem -LiteralPath $script:RuntimeRoot -Filter 'Remote-Codex-*.code-workspace')
        Assert-Test ($workspaceFiles.Count -eq 1) 'A distinct workspace was not created for this session.'
        $workspaceText = Get-Content -LiteralPath $workspaceFiles[0].FullName -Raw -Encoding UTF8
        Assert-Test ($workspaceText.Contains('a%20b')) 'Remote URI path encoding failed.'
        Assert-Test ($workspaceText.Contains('"HTTP_PROXY"') -and $workspaceText.Contains('"http_proxy"')) 'Case-sensitive environment keys were lost.'
        Assert-Test ([IO.File]::ReadAllText($testSshSource) -eq $originalSsh) 'Original SSH config was changed.'
        Assert-Test (@(Get-Process mockssh,mockcode -ErrorAction SilentlyContinue | Where-Object { $_.Path -in @($mockSsh, $mockCode) }).Count -eq 0) 'A helper process was leaked.'
        Write-Output ('PASS lifecycle: ' + $mode)
    }
    # An unrelated process or a PID reused by another executable must never be stopped.
    $selfProcess = Get-Process -Id $PID
    Write-JsonFile (Join-Path $script:RuntimeRoot 'session.json') @{
        SshPid=$PID; SshExe='C:\wrong\ssh.exe'; SshStartedUtcTicks=$selfProcess.StartTime.ToUniversalTime().Ticks.ToString()
    }
    Assert-Test ($null -eq (Get-TrackedSsh (Join-Path $script:RuntimeRoot 'session.json'))) 'Unrelated PID was accepted.'
    Write-Output 'PASS process identity protection'
    foreach ($bad in @(
        [pscustomobject]@{SshHost='-oProxyCommand=bad';ProxyPort=7890;RemoteFolder=''},
        [pscustomobject]@{SshHost='Example';ProxyPort=70000;RemoteFolder=''},
        [pscustomobject]@{SshHost='Example';ProxyPort=7890;RemoteFolder='relative/path'}
    )) {
        $rejected = $false
        try { Assert-Configuration $bad } catch { $rejected = $true }
        Assert-Test $rejected 'Invalid configuration was accepted.'
    }
    Write-Output 'PASS invalid configuration rejection'
    $script:ConfigFile = Join-Path $testRoot 'legacy-config.json'
    Write-JsonFile $script:ConfigFile @{ SshHost='Example'; ProxyPort=7890; RemoteFolder='' }
    Assert-Test ((Read-Configuration).AutoDetectProxyPort -eq $true) 'Legacy configuration did not enable automatic detection.'
    Write-Output 'PASS legacy configuration migration'
} finally {
    $listener.Stop()
    Remove-Item Env:CODEX_SWITCH_TEST_MODE -ErrorAction SilentlyContinue
}
Write-Output ('TEST_ARTIFACTS=' + $testRoot)
