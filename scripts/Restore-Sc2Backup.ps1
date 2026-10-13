#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BackupDirectory,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Sc2Metadata.psm1') -Force
if ($Apply) { Restore-Sc2RepairBackup -BackupDirectory $BackupDirectory | ConvertTo-Json -Depth 8 }
else { Test-Sc2RepairBackup -BackupDirectory $BackupDirectory | ConvertTo-Json -Depth 8 }
