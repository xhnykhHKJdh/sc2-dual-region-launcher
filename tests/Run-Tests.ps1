[CmdletBinding()]
param([switch]$KeepFixtures)

$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0
& (Join-Path $PSScriptRoot 'Run-SyntheticTests.ps1') -KeepFixtures:$KeepFixtures
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& (Join-Path $PSScriptRoot 'Test-OneClick.ps1') -KeepFixtures:$KeepFixtures
exit $LASTEXITCODE
