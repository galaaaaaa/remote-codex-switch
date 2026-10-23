$ErrorActionPreference = 'Stop'
$taskBase = Split-Path -Parent $PSScriptRoot
. (Join-Path $taskBase 'RemoteCodex.ps1')
$testRoot = Join-Path $taskBase ('.test-artifacts\login-sync-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$mockSsh = Join-Path $testRoot 'mock-login-ssh.exe'
Add-Type -OutputAssembly $mockSsh -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
public class MockLoginSsh {
    public static int Main(string[] args) {
        string root=Environment.GetEnvironmentVariable("CODEX_SWITCH_LOGIN_TEST_ROOT");
        File.WriteAllLines(Path.Combine(root,"arguments.txt"),args);
        File.WriteAllText(Path.Combine(root,"received-fixture.json"),Console.In.ReadToEnd());
        Console.WriteLine("CODEX_SWITCH_LOGIN_SYNCED");
        return 0;
    }
}
'@
function Get-SshExe { return $mockSsh }
function Get-SshSource { return (Join-Path $testRoot 'ssh-config') }
function Assert-Test($Condition, $Message) { if (-not $Condition) { throw $Message } }
$script:ConfigFile = Join-Path $testRoot 'config.json'
Write-JsonFile $script:ConfigFile @{ SshHost='Example'; ProxyPort=7890; AutoDetectProxyPort=$false; RemoteFolder='' }
$oldCodexHome=$env:CODEX_HOME
$env:CODEX_HOME=Join-Path $testRoot 'fake-codex-home'
$env:CODEX_SWITCH_LOGIN_TEST_ROOT=$testRoot
[IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
$authPath=Join-Path $env:CODEX_HOME 'auth.json'
try {
    $rejected=$false
    try { Sync-CodexLogin -GuiMode } catch { $rejected=$true }
    Assert-Test $rejected 'Missing local login was not rejected.'
    Assert-Test (-not (Test-Path (Join-Path $testRoot 'received-fixture.json'))) 'SSH was called without local login.'
    [IO.File]::WriteAllText($authPath, 'invalid-json')
    $rejected=$false
    try { Sync-CodexLogin -GuiMode } catch { $rejected=$true }
    Assert-Test $rejected 'Invalid JSON was not rejected.'
    $fixture='{"tokens":{"access_token":"FAKE_TEST_TOKEN_NEVER_A_REAL_CREDENTIAL"}}'
    [IO.File]::WriteAllText($authPath,$fixture)
    foreach ($gui in @($false,$true)) {
        Sync-CodexLogin -GuiMode:$gui
        Assert-Test ([IO.File]::ReadAllText((Join-Path $testRoot 'received-fixture.json')) -eq $fixture) 'Fixture was not sent intact over stdin.'
        Assert-Test (-not [IO.File]::ReadAllText((Join-Path $testRoot 'arguments.txt')).Contains('FAKE_TEST_TOKEN')) 'Login data appeared in process arguments.'
        Assert-Test ([IO.File]::ReadAllText($authPath) -eq $fixture) 'Local login file was modified.'
    }
    $command=Get-LoginSyncCommand
    Assert-Test (-not $command.Contains('FAKE_TEST_TOKEN')) 'Login data appeared in the remote command.'
    Write-Output 'PASS missing/invalid login rejection, SSH stdin transfer, argument isolation, and local file preservation'
} finally {
    $env:CODEX_HOME=$oldCodexHome
    Remove-Item Env:CODEX_SWITCH_LOGIN_TEST_ROOT -ErrorAction SilentlyContinue
}
