$ErrorActionPreference='Stop'
$taskBase=Split-Path -Parent $PSScriptRoot
. (Join-Path $taskBase 'RemoteCodex.ps1')
$testRoot=Join-Path $taskBase ('.test-artifacts\shared-check-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot)|Out-Null
$mockSsh=Join-Path $testRoot 'mockssh.exe'
$testSshSource=Join-Path $testRoot 'ssh-config'
$originalSsh="Host Example`n HostName example.invalid`n RemoteForward 7890 127.0.0.1:7890`n"
[IO.File]::WriteAllText($testSshSource,$originalSsh)
Add-Type -OutputAssembly $mockSsh -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public class MockSharedSsh {
 public static int Main(string[] args) {
  if(Array.IndexOf(args,"-G")>=0){Console.WriteLine("hostname example.invalid");return 0;}
  string mode=Environment.GetEnvironmentVariable("CODEX_SWITCH_TEST_MODE");
  string root=Environment.GetEnvironmentVariable("CODEX_SWITCH_TEST_RUNTIME");
  if(mode=="proxy-error"){Console.Error.WriteLine("OpenAI login service proxy check failed: HTTP 403");return 9;}
  Console.WriteLine("CODEX_SWITCH_AUTH_HTTP=200");
  Console.WriteLine("CODEX_SWITCH_SHARED=1");
  Console.WriteLine("CODEX_SWITCH_READY");Console.Out.Flush();
  var worker=new Thread(delegate(){
   Thread.Sleep(1700);
   if(mode=="ssh-drop") Environment.Exit(23);
   else File.WriteAllText(Path.Combine(root,"stop.request"),"stop");
  });worker.IsBackground=true;worker.Start();
  string line;
  while((line=Console.In.ReadLine())!=null){
   if(line=="STOP"){File.WriteAllText(Path.Combine(root,"graceful-stop.txt"),"restored");Console.WriteLine("CODEX_SWITCH_RESTORED");return 0;}
  }
  return 0;
 }
}
'@
function Get-SshExe {return $mockSsh}
function Get-SshSource {return $testSshSource}
function Find-CodeInstallation {throw 'Starting a shared connection must not launch VS Code.'}
function Assert-Test($Condition,$Message){if(-not $Condition){throw $Message}}
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start()
try {
 foreach($mode in @('gui-background','console-background','ssh-drop','proxy-error')){
  $script:RuntimeRoot=Join-Path $testRoot $mode
  $script:ConfigFile=Join-Path $testRoot ($mode+'.json')
  $env:CODEX_SWITCH_TEST_MODE=$mode;$env:CODEX_SWITCH_TEST_RUNTIME=$script:RuntimeRoot
  Write-JsonFile $script:ConfigFile @{SshHost='Example';ProxyPort=$listener.LocalEndpoint.Port;AutoDetectProxyPort=$false;RemoteFolder=''}
  $caught=$false;$elapsed=[Diagnostics.Stopwatch]::StartNew()
  try{Start-CodexSession -GuiMode:($mode -ne 'console-background')}catch{
   if($mode -notin @('ssh-drop','proxy-error')){throw}
   $caught=$true
  }
  if($mode -in @('ssh-drop','proxy-error')){Assert-Test $caught 'Connection failure was not reported.'}
  else{
   Assert-Test ($elapsed.Elapsed.TotalSeconds -ge 1.5) 'Connection ended with an unrelated editor lifetime.'
   Assert-Test (Test-Path (Join-Path $script:RuntimeRoot 'graceful-stop.txt')) 'STOP was not delivered before disconnect.'
  }
  Assert-Test (-not (Test-Path (Join-Path $script:RuntimeRoot 'session.json'))) 'Session state was not cleared.'
  Assert-Test ([IO.File]::ReadAllText($testSshSource) -eq $originalSsh) 'Original SSH config changed.'
  Assert-Test (-not (Test-Path (Join-Path $script:RuntimeRoot 'vscode-data'))) 'An isolated editor profile was created.'
  Write-Output ('PASS shared lifecycle: '+$mode)
 }
 $selfProcess=Get-Process -Id $PID
 Write-JsonFile (Join-Path $script:RuntimeRoot 'session.json') @{SshPid=$PID;SshExe='C:\wrong\ssh.exe';SshStartedUtcTicks=$selfProcess.StartTime.ToUniversalTime().Ticks.ToString()}
 Assert-Test ($null -eq (Get-TrackedSsh (Join-Path $script:RuntimeRoot 'session.json'))) 'An unrelated process was accepted.'
 Write-Output 'PASS process identity protection and editor independence'
}finally{
 $listener.Stop()
 Remove-Item Env:CODEX_SWITCH_TEST_MODE,Env:CODEX_SWITCH_TEST_RUNTIME -ErrorAction SilentlyContinue
}
