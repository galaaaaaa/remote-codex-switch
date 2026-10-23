param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'))
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $compiler)) { throw '需要 Windows .NET Framework 4.x 编译器。' }
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$executable = Join-Path $OutputDirectory 'RemoteCodex.exe'
& $compiler /nologo /target:winexe /optimize+ /codepage:65001 "/out:$executable" "/win32manifest:$(Join-Path $PSScriptRoot 'src\app.manifest')" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll "/resource:$(Join-Path $PSScriptRoot 'RemoteCodex.ps1'),RemoteCodex.ps1" "/resource:$(Join-Path $PSScriptRoot 'GuiBridge.ps1'),GuiBridge.ps1" "/resource:$(Join-Path $PSScriptRoot 'RemoteSession.py'),RemoteSession.py" (Join-Path $PSScriptRoot 'src\RemoteCodexApp.cs')
if ($LASTEXITCODE -ne 0) { throw '应用编译失败。' }
Write-Output $executable
