#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Inspect')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Inspect')]
    [Parameter(Mandatory, ParameterSetName = 'Move')]
    [string]$AgentDatabase,
    [Parameter(Mandatory, ParameterSetName = 'Inspect')]
    [Parameter(Mandatory, ParameterSetName = 'Move')]
    [string]$CNDirectory,
    [Parameter(Mandatory, ParameterSetName = 'Inspect')]
    [Parameter(Mandatory, ParameterSetName = 'Move')]
    [string]$EUDirectory,
    [Parameter(Mandatory, ParameterSetName = 'Move')]
    [switch]$MoveCopiedCNBuilds,
    [Parameter(Mandatory, ParameterSetName = 'Move')]
    [string]$BackupDirectory,
    [Parameter(Mandatory, ParameterSetName = 'Restore')]
    [switch]$RestoreArchive,
    [Parameter(Mandatory, ParameterSetName = 'Restore')]
    [string]$ArchiveDirectory
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Sc2Metadata.psm1') -Force
if ($PSCmdlet.ParameterSetName -eq 'Restore') {
    Restore-Sc2VersionsArchive -ArchiveDirectory $ArchiveDirectory | ConvertTo-Json -Depth 8
}
else {
    $plan = Get-Sc2VersionMaintenancePlan -AgentDatabase $AgentDatabase -CNDirectory $CNDirectory -EUDirectory $EUDirectory
    if ($MoveCopiedCNBuilds) { Move-Sc2CopiedCNVersions -Plan $plan -BackupDirectory $BackupDirectory | ConvertTo-Json -Depth 8 }
    else { $plan | ConvertTo-Json -Depth 8 }
}
