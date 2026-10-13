[CmdletBinding()]
param([switch]$KeepFixtures)

$ErrorActionPreference = 'Stop'
foreach ($test in @('Run-SyntheticTests.ps1','Test-OneClick.ps1','Test-Launcher.ps1','Test-LauncherWindow.ps1')) {
    $global:LASTEXITCODE = 0
    & (Join-Path $PSScriptRoot $test) -KeepFixtures:$KeepFixtures
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
exit 0
