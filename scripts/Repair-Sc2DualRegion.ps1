#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AgentDatabase,
    [Parameter(Mandatory)][string]$CNDirectory,
    [Parameter(Mandatory)][string]$EUDirectory,
    [string]$CandidateDirectory,
    [switch]$Apply,
    [string]$BackupDirectory
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Sc2Metadata.psm1') -Force
if ($Apply -and -not $BackupDirectory) { throw '-Apply requires an explicit -BackupDirectory outside both game and Agent directories.' }
$plan = New-Sc2RepairPlan -AgentDatabase $AgentDatabase -CNDirectory $CNDirectory -EUDirectory $EUDirectory
$saved = if ($CandidateDirectory) { Save-Sc2RepairCandidates -Plan $plan -CandidateDirectory $CandidateDirectory } else { $null }
$applied = if ($Apply) { Invoke-Sc2RepairPlan -Plan $plan -BackupDirectory $BackupDirectory } else { $null }
[pscustomobject]@{
    DryRun = -not $Apply.IsPresent
    Summary = $plan.Summary
    Targets = @($plan.Targets | Select-Object Role, Path, BeforeExists, BeforeSha256, CandidateSha256)
    SavedCandidates = $saved
    Application = $applied
} | ConvertTo-Json -Depth 8
