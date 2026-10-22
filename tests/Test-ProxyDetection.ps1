$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'RemoteCodex.ps1')
function Assert-Detection($Condition, $Message) { if (-not $Condition) { throw $Message } }
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class LocalProxyFixture : IDisposable {
    private TcpListener listener;
    private Thread worker;
    private bool stopped;
    public int Port { get; private set; }
    public string LastRequest { get; private set; }
    public LocalProxyFixture(string response) {
        listener=new TcpListener(IPAddress.Loopback,0); listener.Start();
        Port=((IPEndPoint)listener.LocalEndpoint).Port;
        worker=new Thread(delegate() {
            while(!stopped) {
                try {
                    using(TcpClient client=listener.AcceptTcpClient()) {
                        client.ReceiveTimeout=3000;
                        using(NetworkStream stream=client.GetStream()) {
                            byte[] request=new byte[2048]; int count=stream.Read(request,0,request.Length);
                            LastRequest=Encoding.ASCII.GetString(request,0,count);
                            byte[] bytes=Encoding.ASCII.GetBytes(response); stream.Write(bytes,0,bytes.Length);
                        }
                    }
                } catch { if(stopped) return; }
            }
        });
        worker.IsBackground=true; worker.Start();
    }
    public void Dispose() { stopped=true; listener.Stop(); worker.Join(3000); }
}
'@
$first = [LocalProxyFixture]::new("HTTP/1.1 200 Connection established`r`n`r`n")
$second = [LocalProxyFixture]::new("HTTP/1.1 200 Connection established`r`n`r`n")
$ordinary = [LocalProxyFixture]::new("HTTP/1.1 405 Method Not Allowed`r`n`r`n")
$socksOnly = [LocalProxyFixture]::new("SOCKS5`n")
$systemEndpoints = @()
$processPorts = @()
$answers = [Collections.Generic.Queue[string]]::new()
function Get-SystemProxyEndpoints { $systemEndpoints }
function Get-EnvironmentProxyEndpoints { }
function Get-ProxyProcessPorts { $processPorts }
function Read-Host($Prompt) { if($answers.Count -eq 0) { throw 'Unexpected interactive question in test.' }; return $answers.Dequeue() }
try {
    Assert-Detection (Test-HttpProxyPort $first.Port) 'HTTP CONNECT proxy was rejected.'
    Assert-Detection (-not (Test-HttpProxyPort $ordinary.Port)) 'Ordinary HTTP server was mistaken for a proxy.'
    Assert-Detection (-not (Test-HttpProxyPort $socksOnly.Port)) 'SOCKS-only port was mistaken for HTTP.'
    Assert-Detection ($first.LastRequest.StartsWith('CONNECT example.com:443 HTTP/1.1')) 'Incorrect verification request.'
    Write-Output 'PASS HTTP proxy protocol validation'
    Assert-Detection ((Get-LoopbackProxyPort 'http://127.0.0.1:7897') -eq 7897) 'Loopback URI was not parsed.'
    Assert-Detection ($null -eq (Get-LoopbackProxyPort 'http://example.invalid:7890')) 'Remote proxy was accepted.'
    Assert-Detection ($null -eq (Get-LoopbackProxyPort 'socks5://127.0.0.1:1080')) 'SOCKS endpoint was accepted.'
    Assert-Detection ($null -eq (Get-LoopbackProxyPort 'http://name:password@127.0.0.1:7890')) 'Authenticated endpoint was accepted.'
    Write-Output 'PASS endpoint filtering'
    $config = [pscustomobject]@{ ProxyPort=$ordinary.Port; AutoDetectProxyPort=$true }
    $systemEndpoints = @('127.0.0.1:' + $first.Port)
    Assert-Detection ((Resolve-ProxyPort $config) -eq $first.Port) 'Changed system proxy was not selected.'
    Write-Output 'PASS changed proxy port detection'
    $systemEndpoints = @()
    $processPorts = @($second.Port)
    Assert-Detection ((Resolve-ProxyPort $config) -eq $second.Port) 'Proxy process fallback failed.'
    Write-Output 'PASS proxy process fallback'
    $systemEndpoints = @(('127.0.0.1:' + $first.Port), ('127.0.0.1:' + $second.Port))
    $answers.Enqueue('2')
    $expected = @($first.Port,$second.Port | Sort-Object)[1]
    Assert-Detection ((Resolve-ProxyPort $config) -eq $expected) 'Multiple proxy selection failed.'
    Assert-Detection ($answers.Count -eq 0) 'Multiple candidates did not prompt for a selection.'
    Write-Output 'PASS multiple candidate selection'
    $config.AutoDetectProxyPort=$false
    Assert-Detection ((Resolve-ProxyPort $config) -eq $ordinary.Port) 'Explicit manual mode did not preserve its port.'
    Write-Output 'PASS explicit manual port mode'
} finally { $first.Dispose(); $second.Dispose(); $ordinary.Dispose(); $socksOnly.Dispose() }
