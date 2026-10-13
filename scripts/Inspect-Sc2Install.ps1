#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AgentDatabase,
    [Parameter(Mandatory)][string]$CNDirectory,
    [Parameter(Mandatory)][string]$EUDirectory
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Sc2Metadata.psm1') -Force
Get-Sc2InstallationReport -AgentDatabase $AgentDatabase -CNDirectory $CNDirectory -EUDirectory $EUDirectory | ConvertTo-Json -Depth 8
