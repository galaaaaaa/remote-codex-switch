param(
    [Parameter(Mandatory=$true)][int]$SavedPort,
    [Parameter(Mandatory=$true)][string]$ResultPath
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'RemoteCodex.ps1')
try {
    $valid = @()
    foreach ($group in @(Get-ProxyCandidates $SavedPort | Group-Object Priority | Sort-Object { [int]$_.Name })) {
        $valid = @($group.Group | Where-Object { Test-HttpProxyPort $_.Port })
        if ($valid.Count -gt 0) { break }
    }
    Write-JsonFile $ResultPath @{ Candidates=@($valid | ForEach-Object { @{ Port=[int]$_.Port; Source=$_.Source } }); Error=$null }
} catch {
    Write-JsonFile $ResultPath @{ Candidates=@(); Error=$_.Exception.Message }
    exit 1
}
