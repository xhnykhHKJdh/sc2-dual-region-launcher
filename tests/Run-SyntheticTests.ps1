[CmdletBinding()]
param(
    [string]$ModulePath,
    [switch]$KeepFixtures
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $ModulePath) { $ModulePath = Join-Path $PSScriptRoot '..\scripts\Sc2Metadata.psm1' }
. (Join-Path $PSScriptRoot 'SyntheticFixtures.ps1')

if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) { throw "Module not found: $ModulePath" }
$testModule = Import-Module $ModulePath -Force -PassThru
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('sc2-dual-region-synthetic-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$script:results = [Collections.Generic.List[object]]::new()
$script:caseNumber = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message (expected=$Expected; actual=$Actual)" }
}

function Assert-BytesEqual {
    param([byte[]]$Actual, [byte[]]$Expected, [string]$Message)
    Assert-Equal ([Convert]::ToBase64String($Actual)) ([Convert]::ToBase64String($Expected)) $Message
}

function Assert-ContainsBytes {
    param([byte[]]$Bytes, [byte[]]$Needle, [string]$Message)
    $found = $false
    for ($i = 0; $i -le $Bytes.Length - $Needle.Length; $i++) {
        $matches = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Bytes[$i + $j] -ne $Needle[$j]) { $matches = $false; break }
        }
        if ($matches) { $found = $true; break }
    }
    Assert-True $found $Message
}

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Message)
    $rejected = $false
    try { & $Action 2>$null | Out-Null } catch { $rejected = $true }
    Assert-True $rejected $Message
}

function Set-SyntheticProcessState {
    param([string]$ProcessName)
    & $testModule {
        param($SyntheticProcessName)
        $script:SyntheticProcessName = $SyntheticProcessName
        function script:Get-Process {
            if ($script:SyntheticProcessName) {
                [pscustomobject]@{ ProcessName = $script:SyntheticProcessName; Id = 987654 }
            }
        }
    } $ProcessName
}

function New-CaseFixture {
    param([switch]$Reordered, [switch]$Hidden, [switch]$Separated, [switch]$Versions)
    $script:caseNumber++
    $root = Join-Path $fixtureRoot ('case-' + $script:caseNumber)
    if ($Versions) { return New-SyntheticVersions $root }
    return New-SyntheticInstallation $root -Reordered:$Reordered -Hidden:$Hidden -Separated:$Separated
}

function New-CasePlan {
    param($Fixture)
    return New-Sc2RepairPlan -AgentDatabase $Fixture.AgentDatabase -CNDirectory $Fixture.CNDirectory -EUDirectory $Fixture.EUDirectory
}

function New-PreUpdateArchiveFixture {
    $fixture = New-CaseFixture -Versions
    $archive = Join-Path $fixture.Root 'pre-update synthetic archive'
    [IO.Directory]::CreateDirectory($archive) | Out-Null
    $moves = @(foreach ($name in @('Base51029', 'Base50807')) {
        $original = Join-Path (Join-Path $fixture.EUDirectory 'Versions') $name
        $destination = Join-Path $archive $name
        $fingerprint = & $testModule { param($Path) Get-DirectoryFingerprint $Path } $original
        [IO.Directory]::Move($original, $destination)
        [pscustomobject]@{ OriginalPath = $original; ArchivePath = $destination; Fingerprint = $fingerprint }
    })
    $manifest = [pscustomobject]@{
        SchemaVersion = 1; Mode = 'NewEUCopyBeforeOfficialUpdate'
        Inputs = [pscustomobject]@{ AgentDatabase = $fixture.AgentDatabase; CNDirectory = $fixture.CNDirectory; EUDirectory = $fixture.EUDirectory }
        OfficialEU = $null; Moves = $moves
    }
    Write-FixtureText (Join-Path $archive 'archive.json') ($manifest | ConvertTo-Json -Depth 8)
    return [pscustomobject]@{ Fixture = $fixture; ArchiveDirectory = $archive; Manifest = $manifest }
}

function Get-TargetByPath {
    param($Plan, [string]$Path)
    $target = @($Plan.Targets | Where-Object { [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($Path) })
    Assert-Equal $target.Count 1 "Exactly one plan target expected for $Path"
    return $target[0]
}

function Get-FixtureSnapshot {
    param([string[]]$Paths)
    return @($Paths | ForEach-Object {
        $exists = [IO.File]::Exists($_)
        [pscustomobject]@{
            Path = $_; Exists = $exists
            Hash = if ($exists) { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash } else { $null }
            Bytes = if ($exists) { [IO.File]::ReadAllBytes($_) } else { $null }
            Attributes = if ($exists) { [int][IO.File]::GetAttributes($_) } else { $null }
        }
    })
}

function Assert-SnapshotUnchanged {
    param([object[]]$Snapshot, [switch]$Attributes)
    foreach ($file in $Snapshot) {
        Assert-Equal ([IO.File]::Exists($file.Path)) $file.Exists "Existence changed: $($file.Path)"
        if ($file.Exists) {
            Assert-BytesEqual ([IO.File]::ReadAllBytes($file.Path)) $file.Bytes "Bytes changed: $($file.Path)"
            if ($Attributes) { Assert-Equal ([int][IO.File]::GetAttributes($file.Path)) $file.Attributes "Attributes changed: $($file.Path)" }
        }
    }
}

function Get-SyntheticActiveBuild {
    param([byte[]]$Bytes)
    $lines = @(([Text.Encoding]::UTF8.GetString($Bytes) -split '\r?\n') | Where-Object { $_.Length -gt 0 })
    $names = @($lines[0] -split '\|' | ForEach-Object { ($_ -split '!')[0] })
    $activeIndex = [Array]::IndexOf($names, 'Active')
    $buildIndex = [Array]::IndexOf($names, 'Build Key')
    $branchIndex = [Array]::IndexOf($names, 'Branch')
    $versionIndex = [Array]::IndexOf($names, 'Version')
    $active = @($lines | Select-Object -Skip 1 | ForEach-Object {
        $cells = $_ -split '\|'
        if ($cells[$activeIndex] -eq '1') {
            [pscustomobject]@{ Key = $cells[$buildIndex]; Branch = $cells[$branchIndex]; Version = $cells[$versionIndex] }
        }
    })
    Assert-Equal $active.Count 1 'Exactly one active build expected in each regional candidate'
    return $active[0]
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    Set-SyntheticProcessState ''
    try {
        & $Body | Out-Null
        $script:results.Add([pscustomobject]@{ Name = $Name; Status = 'PASS'; Error = $null })
        Write-Host "PASS  $Name"
    } catch {
        $script:results.Add([pscustomobject]@{ Name = $Name; Status = 'FAIL'; Error = $_.Exception.Message })
        Write-Host "FAIL  $Name -- $($_.Exception.Message)" -ForegroundColor Red
    } finally { Set-SyntheticProcessState '' }
}

try {
    Test-Case 'prepare is read-only and has exactly five explicit metadata targets' {
        $fixture = New-CaseFixture
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        $plan = New-CasePlan $fixture
        Assert-Equal @($plan.Targets).Count 5 'Five metadata targets expected'
        foreach ($path in $fixture.Paths) {
            $target = Get-TargetByPath $plan $path
            Assert-True ($target.CandidateBytes -is [byte[]]) 'CandidateBytes must be byte[]'
            Assert-True ($target.CandidateSha256 -match '^[a-fA-F0-9]{64}$') 'Candidate SHA256 must be present'
        }
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'protobuf preserves other products and all synthetic unknown wire bytes' {
        $fixture = New-CaseFixture
        $plan = New-CasePlan $fixture
        $agent = (Get-TargetByPath $plan $fixture.AgentDatabase).CandidateBytes
        $cn = (Get-TargetByPath $plan (Join-Path $fixture.CNDirectory '.product.db')).CandidateBytes
        $eu = (Get-TargetByPath $plan (Join-Path $fixture.EUDirectory '.product.db')).CandidateBytes
        $expectedEURecord = New-FixtureProduct 's2' ($fixture.EUDirectory -replace '\\', '/') 'eu' $fixture.EUVersion $fixture.EUKey $fixture.EUCDNKey
        Assert-BytesEqual $eu $expectedEURecord 'EU record must differ only in the intended path and region fields'
        Assert-BytesEqual $agent (New-FixtureDatabase @($fixture.CNRecord, $expectedEURecord, $fixture.PTRRecord, $fixture.OtherRecord)) 'Agent database must differ only in its intended s2 path and region fields'
        Assert-BytesEqual $cn (New-FixtureDatabase -Records (,$fixture.CNRecord)) 'CN database must differ only by removing the shared s2 record'
        Assert-ContainsBytes $agent $fixture.CNRecord 'Agent CN record must remain byte-identical'
        Assert-ContainsBytes $agent $fixture.PTRRecord 'Agent PTR record must remain byte-identical'
        Assert-ContainsBytes $agent $fixture.OtherRecord 'Agent unrelated product must remain byte-identical'
        Assert-ContainsBytes $cn $fixture.CNRecord 'CN local CN record must remain byte-identical'
        foreach ($base in @(20, 40, 50, 60)) {
            Assert-ContainsBytes $agent (New-FixtureUnknownBytes $base) "Agent unknown bytes $base must survive"
            if ($base -ne 20) { Assert-ContainsBytes $eu (New-FixtureUnknownBytes $base) "EU installed-record unknown bytes $base must survive" }
        }
        Assert-ContainsBytes $cn (New-FixtureTextField 29 'synthetic-wrapper-tail') 'CN wrapper tail must survive'
    }

    Test-Case 'dynamic build keys match product state and reordered build-info headers' {
        $fixture = New-CaseFixture -Reordered
        $plan = New-CasePlan $fixture
        $cnBuild = Get-SyntheticActiveBuild (Get-TargetByPath $plan (Join-Path $fixture.CNDirectory '.build.info')).CandidateBytes
        $euBuild = Get-SyntheticActiveBuild (Get-TargetByPath $plan (Join-Path $fixture.EUDirectory '.build.info')).CandidateBytes
        Assert-Equal $cnBuild.Key $fixture.CNKey 'CN active key must match synthetic CN product state'
        Assert-Equal $euBuild.Key $fixture.EUKey 'EU active key must match synthetic EU product state'
        Assert-Equal $cnBuild.Version $fixture.CNVersion 'CN build version must match its product'
        Assert-Equal $euBuild.Version $fixture.EUVersion 'EU build version must match its product'
        Assert-Equal $cnBuild.Branch 'cn' 'CN branch must be cn'
        Assert-Equal $euBuild.Branch 'cn' 'Copied EU build candidate must preserve its factual source branch for the official updater'
    }

    Test-Case 'existing separated CN and EU metadata remains supported' {
        $fixture = New-CaseFixture -Separated
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        $plan = New-CasePlan $fixture
        Assert-Equal @($plan.Targets).Count 5 'Separated fixture must produce a complete plan'
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'EU database copied exactly from CN is safely recognized' {
        $fixture = New-CaseFixture
        Write-FixtureBytes (Join-Path $fixture.EUDirectory '.product.db') ([IO.File]::ReadAllBytes((Join-Path $fixture.CNDirectory '.product.db')))
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        $plan = New-CasePlan $fixture
        Assert-Equal @($plan.Targets).Count 5 'An exact copied CN database must support separation'
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'unproven existing EU product metadata rejects before writes' {
        $fixture = New-CaseFixture
        $euPath = Join-Path $fixture.EUDirectory '.product.db'
        Write-FixtureBytes $euPath (New-FixtureDatabase @($fixture.EURecord, $fixture.OtherRecord))
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        Assert-Rejected { New-CasePlan $fixture } 'Another installed EU product must not be silently replaced'
        Assert-SnapshotUnchanged $snapshot -Attributes
        Write-FixtureBytes $euPath (New-FixtureDatabase -Records (,$fixture.EURecord))
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        Assert-Rejected { New-CasePlan $fixture } 'Unknown EU wrapper bytes cannot be silently discarded unless the database is an exact proven CN copy'
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'candidate export leaves source metadata unchanged' {
        $fixture = New-CaseFixture
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        $plan = New-CasePlan $fixture
        $candidateRoot = Join-Path $fixture.Root 'candidate export'
        Save-Sc2RepairCandidates -Plan $plan -CandidateDirectory $candidateRoot | Out-Null
        $candidateHashes = @(Get-ChildItem -LiteralPath $candidateRoot -File -Force -Recurse | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
        foreach ($target in $plan.Targets) { Assert-True ($target.CandidateSha256 -in $candidateHashes) "Exported candidate missing for $($target.Role)" }
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'hidden System metadata writes, verifies backups, and rolls back exactly' {
        $fixture = New-CaseFixture -Hidden
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        $plan = New-CasePlan $fixture
        $backup = Join-Path $fixture.Root 'backup'
        $applied = Invoke-Sc2RepairPlan -Plan $plan -BackupDirectory $backup
        Assert-True ([IO.Path]::GetFullPath($applied.BackupDirectory).StartsWith([IO.Path]::GetFullPath($backup) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'Application must identify a unique backup beneath the explicit backup directory'
        $backup = $applied.BackupDirectory
        foreach ($target in $plan.Targets) {
            Assert-BytesEqual ([IO.File]::ReadAllBytes($target.Path)) $target.CandidateBytes "Applied candidate mismatch: $($target.Role)"
            if ($target.BeforeExists) { Assert-Equal ([int][IO.File]::GetAttributes($target.Path)) ([int]$target.BeforeAttributes) "Source attributes must be retained: $($target.Role)" }
        }
        $backupHashes = @(Get-ChildItem -LiteralPath $backup -File -Force -Recurse | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
        foreach ($original in $snapshot | Where-Object Exists) { Assert-True ($original.Hash -in $backupHashes) 'An original source must have an exact backup' }
        Restore-Sc2RepairBackup -BackupDirectory $backup | Out-Null
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    foreach ($processName in @('Agent', 'Battle.net', 'Battle.net Launcher')) {
        Test-Case "running $processName blocks apply before writes" {
            $fixture = New-CaseFixture
            $plan = New-CasePlan $fixture
            $snapshot = Get-FixtureSnapshot $fixture.Paths
            Set-SyntheticProcessState $processName
            Assert-Rejected { Invoke-Sc2RepairPlan -Plan $plan -BackupDirectory (Join-Path $fixture.Root 'backup') } 'An active launcher or Agent must block applying'
            Assert-SnapshotUnchanged $snapshot -Attributes
        }
    }

    Test-Case 'running Agent blocks rollback before writes' {
        $fixture = New-CaseFixture
        $plan = New-CasePlan $fixture
        $backup = Join-Path $fixture.Root 'backup'
        $backup = (Invoke-Sc2RepairPlan -Plan $plan -BackupDirectory $backup).BackupDirectory
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        Set-SyntheticProcessState 'Agent'
        Assert-Rejected { Restore-Sc2RepairBackup -BackupDirectory $backup } 'Agent must block rollback'
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'source changed since preparation blocks apply atomically' {
        $fixture = New-CaseFixture
        $plan = New-CasePlan $fixture
        Write-FixtureText (Join-Path $fixture.CNDirectory '.build.info') 'synthetic external change'
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        Assert-Rejected { Invoke-Sc2RepairPlan -Plan $plan -BackupDirectory (Join-Path $fixture.Root 'backup') } 'A stale source hash must reject apply'
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'candidate changed after preparation blocks apply atomically' {
        $fixture = New-CaseFixture
        $plan = New-CasePlan $fixture
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        $plan.Targets[0].CandidateBytes[0] = $plan.Targets[0].CandidateBytes[0] -bxor 1
        Assert-Rejected { Invoke-Sc2RepairPlan -Plan $plan -BackupDirectory (Join-Path $fixture.Root 'backup') } 'A stale candidate hash must reject apply'
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'backup corruption blocks rollback atomically' {
        $fixture = New-CaseFixture
        $plan = New-CasePlan $fixture
        $beforeHash = (Get-FileHash -LiteralPath $fixture.AgentDatabase -Algorithm SHA256).Hash
        $backup = Join-Path $fixture.Root 'backup'
        $backup = (Invoke-Sc2RepairPlan -Plan $plan -BackupDirectory $backup).BackupDirectory
        $backupFile = @(Get-ChildItem -LiteralPath $backup -File -Force -Recurse | Where-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -eq $beforeHash })
        Assert-Equal $backupFile.Count 1 'Agent original must have one backup copy'
        Write-FixtureText $backupFile[0].FullName 'synthetic corrupted backup'
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        Assert-Rejected { Restore-Sc2RepairBackup -BackupDirectory $backup } 'A corrupted backup must block rollback'
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'metadata modified after apply blocks rollback atomically' {
        $fixture = New-CaseFixture
        $plan = New-CasePlan $fixture
        $backup = Join-Path $fixture.Root 'backup'
        $backup = (Invoke-Sc2RepairPlan -Plan $plan -BackupDirectory $backup).BackupDirectory
        Write-FixtureText (Join-Path $fixture.EUDirectory '.build.info') 'synthetic official updater change'
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        Assert-Rejected { Restore-Sc2RepairBackup -BackupDirectory $backup } 'Rollback must not overwrite a subsequent change'
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'invalid backup manifest target refuses before any rollback write' {
        $fixture = New-CaseFixture
        $plan = New-CasePlan $fixture
        $backup = (Invoke-Sc2RepairPlan -Plan $plan -BackupDirectory (Join-Path $fixture.Root 'backup')).BackupDirectory
        $manifestPath = Join-Path $backup 'manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.Targets[0].Path = Join-Path $fixture.Root 'unrelated.synthetic'
        Write-FixtureText $manifestPath ($manifest | ConvertTo-Json -Depth 8)
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        Assert-Rejected { Restore-Sc2RepairBackup -BackupDirectory $backup } 'A manifest cannot redirect restoration to another path'
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'failure after first commit restores all original bytes and attributes' {
        $fixture = New-CaseFixture -Hidden
        $plan = New-CasePlan $fixture
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        & $testModule {
            $script:SyntheticOriginalWrite = (Get-Item Function:Write-MetadataBytes).ScriptBlock
            $script:SyntheticWriteCount = 0
            function script:Write-MetadataBytes {
                param([string]$Path, [byte[]]$Bytes, [int]$Attributes)
                $script:SyntheticWriteCount++
                if ($script:SyntheticWriteCount -eq 2) { throw 'Injected synthetic commit failure.' }
                & $script:SyntheticOriginalWrite -Path $Path -Bytes $Bytes -Attributes $Attributes
            }
        }
        try {
            Assert-Rejected { Invoke-Sc2RepairPlan -Plan $plan -BackupDirectory (Join-Path $fixture.Root 'backup') } 'Injected commit failure must be reported'
            Assert-SnapshotUnchanged $snapshot -Attributes
        } finally {
            & $testModule {
                Set-Item -Path Function:script:Write-MetadataBytes -Value $script:SyntheticOriginalWrite
                Remove-Variable -Scope Script -Name SyntheticOriginalWrite, SyntheticWriteCount
            }
        }
    }

    Test-Case 'existing backup directory is never overwritten by repeat apply' {
        $fixture = New-CaseFixture
        $plan = New-CasePlan $fixture
        $backup = Join-Path $fixture.Root 'backup'
        $backup = (Invoke-Sc2RepairPlan -Plan $plan -BackupDirectory $backup).BackupDirectory
        $backupFiles = @(Get-ChildItem -LiteralPath $backup -File -Force -Recurse | Select-Object -ExpandProperty FullName)
        $snapshot = Get-FixtureSnapshot $backupFiles
        Assert-Rejected { Invoke-Sc2RepairPlan -Plan $plan -BackupDirectory $backup } 'A repeat application cannot overwrite its original backup'
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'same, case-equivalent, and nested CN/EU roots reject' {
        $fixture = New-CaseFixture
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        $badPaths = @($fixture.CNDirectory, ($fixture.CNDirectory + [IO.Path]::DirectorySeparatorChar), (Join-Path $fixture.CNDirectory 'nested'))
        if ($env:OS -eq 'Windows_NT') { $badPaths += $fixture.CNDirectory.ToUpperInvariant() }
        foreach ($badPath in $badPaths) {
            Assert-Rejected { New-Sc2RepairPlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $badPath } 'Equivalent or nested roots must reject'
        }
        Assert-Rejected { New-Sc2RepairPlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.Root -EUDirectory $fixture.CNDirectory } 'A CN root containing the EU root must reject'
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'repair requires a complete synthetic EU game skeleton' {
        $fixture = New-CaseFixture
        $exePath = Join-Path $fixture.EUDirectory 'StarCraft II.exe'
        Write-FixtureBytes $exePath ([byte[]]@())
        Assert-Rejected { New-CasePlan $fixture } 'An empty executable marker must reject repair'
        Write-FixtureText $exePath 'synthetic marker; never execute'
        [IO.File]::Delete((Join-Path $fixture.EUDirectory 'SC2Data\synthetic.data'))
        Assert-Rejected { New-CasePlan $fixture } 'Empty SC2Data must reject repair'
        Write-FixtureText (Join-Path $fixture.EUDirectory 'SC2Data\synthetic.data') 'synthetic installed data marker'
        [IO.Directory]::Delete((Join-Path $fixture.EUDirectory 'Versions'))
        Assert-Rejected { New-CasePlan $fixture } 'Missing Versions must reject repair'
    }

    Test-Case 'directory reparse point CN/EU root rejects' {
        $fixture = New-CaseFixture
        $link = Join-Path $fixture.Root 'EU linked'
        $linkCreated = $false
        try {
            try {
                New-Item -ItemType SymbolicLink -Path $link -Target $fixture.EUDirectory | Out-Null
                $linkCreated = $true
            } catch {
                if ($env:OS -eq 'Windows_NT') {
                    New-Item -ItemType Junction -Path $link -Target $fixture.EUDirectory | Out-Null
                    $linkCreated = $true
                } else { throw }
            }
            Assert-Rejected { New-Sc2RepairPlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $link } 'A symlink or junction root must reject'
        } finally {
            if ($linkCreated) {
                Assert-Equal ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($link))) ([IO.Path]::GetFullPath($fixture.Root)) 'Link removal must remain inside its fixture'
                Assert-True (([IO.File]::GetAttributes($link) -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'Only the generated reparse point may be removed'
                [IO.Directory]::Delete($link)
            }
        }
    }

    Test-Case 'truncated protobuf refuses before writes' {
        $fixture = New-CaseFixture
        $bytes = [IO.File]::ReadAllBytes($fixture.AgentDatabase)
        Write-FixtureBytes $fixture.AgentDatabase $bytes[0..($bytes.Length - 2)]
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        Assert-Rejected { New-CasePlan $fixture } 'Truncated protobuf must reject'
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'ambiguous s2 records and unknown local product refuse before writes' {
        $fixture = New-CaseFixture
        Write-FixtureBytes $fixture.AgentDatabase (New-FixtureDatabase @($fixture.CNRecord, $fixture.EURecord, $fixture.EURecord))
        Assert-Rejected { New-CasePlan $fixture } 'Duplicate s2 records must reject'
        Write-FixtureBytes $fixture.AgentDatabase (New-FixtureDatabase @($fixture.CNRecord, $fixture.EURecord, $fixture.PTRRecord))
        Write-FixtureBytes (Join-Path $fixture.CNDirectory '.product.db') (New-FixtureDatabase @($fixture.CNRecord, $fixture.EURecord, $fixture.OtherRecord))
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        Assert-Rejected { New-CasePlan $fixture } 'Unknown local installed product must reject rather than remove it'
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'missing and ambiguous dynamic Build Key matches reject' {
        $fixture = New-CaseFixture
        $buildPath = Join-Path $fixture.CNDirectory '.build.info'
        $original = [IO.File]::ReadAllText($buildPath)
        Write-FixtureText $buildPath ($original.Replace($fixture.EUKey, (New-FixtureKey)))
        Assert-Rejected { New-CasePlan $fixture } 'Missing build key intersection must reject'
        $lines = @($original -split '\r?\n' | Where-Object { $_ })
        Write-FixtureText $buildPath ($original + $lines[2] + "`r`n")
        $snapshot = Get-FixtureSnapshot $fixture.Paths
        Assert-Rejected { New-CasePlan $fixture } 'Duplicate matching active build rows must reject'
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'Versions moves only proven copied CN newer than confirmed EU and restores it' {
        $fixture = New-CaseFixture -Versions
        $versions = Join-Path $fixture.EUDirectory 'Versions'
        $originalNames = @(Get-ChildItem -LiteralPath $versions -Directory | Select-Object -ExpandProperty Name | Sort-Object)
        $plan = Get-Sc2VersionMaintenancePlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $fixture.EUDirectory
        $archive = Move-Sc2CopiedCNVersions -Plan $plan -BackupDirectory (Join-Path $fixture.Root 'version archive')
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $versions 'Base51029'))) 'Proven copied newer CN build should move'
        foreach ($name in @('Base50913', 'Base50807', 'Base51999', 'BasePreview')) { Assert-True (Test-Path -LiteralPath (Join-Path $versions $name)) "Unproven or necessary directory must remain: $name" }
        Assert-True ([IO.Directory]::Exists($archive.ArchiveDirectory)) 'Versions archive must be recoverable'
        Restore-Sc2VersionsArchive -ArchiveDirectory $archive.ArchiveDirectory | Out-Null
        $restoredNames = @(Get-ChildItem -LiteralPath $versions -Directory | Select-Object -ExpandProperty Name | Sort-Object)
        Assert-Equal ($restoredNames -join '|') ($originalNames -join '|') 'Archive restore must recover all original Version directories'
    }

    Test-Case 'Versions cannot move a high CN directory whose fingerprint differs' {
        $fixture = New-CaseFixture -Versions
        Write-FixtureText (Join-Path $fixture.EUDirectory 'Versions\Base51029\nested\SC2.synthetic') 'different synthetic file'
        $plan = Get-Sc2VersionMaintenancePlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $fixture.EUDirectory
        Move-Sc2CopiedCNVersions -Plan $plan -BackupDirectory (Join-Path $fixture.Root 'version archive') | Out-Null
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.EUDirectory 'Versions\Base51029')) 'Fingerprint mismatch must retain the high directory'
    }

    Test-Case 'Versions rejects a stale fingerprint after planning without moving files' {
        $fixture = New-CaseFixture -Versions
        $plan = Get-Sc2VersionMaintenancePlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $fixture.EUDirectory
        Write-FixtureText (Join-Path $fixture.EUDirectory 'Versions\Base51029\nested\SC2.synthetic') 'synthetic change after planning'
        Assert-Rejected { Move-Sc2CopiedCNVersions -Plan $plan -BackupDirectory (Join-Path $fixture.Root 'version archive') } 'A stale version fingerprint must reject movement'
        foreach ($name in @('Base51029', 'Base50913', 'Base50807', 'Base51999', 'BasePreview')) { Assert-True (Test-Path -LiteralPath (Join-Path (Join-Path $fixture.EUDirectory 'Versions') $name)) "Stale plan must leave $name in place" }
    }

    Test-Case 'Versions restore refuses a new directory at the original path' {
        $fixture = New-CaseFixture -Versions
        $plan = Get-Sc2VersionMaintenancePlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $fixture.EUDirectory
        $archive = Move-Sc2CopiedCNVersions -Plan $plan -BackupDirectory (Join-Path $fixture.Root 'version archive')
        New-FixtureVersion $fixture.EUDirectory 'Base51029' 'synthetic newly installed content' | Out-Null
        Assert-Rejected { Restore-Sc2VersionsArchive -ArchiveDirectory $archive.ArchiveDirectory } 'Version restore must refuse an original-path collision'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $fixture.EUDirectory 'Versions\Base51029\nested\SC2.synthetic'))) 'synthetic newly installed content' 'Newly installed content must remain intact'
        Assert-True (Test-Path -LiteralPath (Join-Path $archive.ArchiveDirectory 'Base51029')) 'Archive must remain recoverable after collision refusal'
    }

    Test-Case 'Versions restore refuses corrupted archive bytes without moving them' {
        $fixture = New-CaseFixture -Versions
        $plan = Get-Sc2VersionMaintenancePlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $fixture.EUDirectory
        $archive = Move-Sc2CopiedCNVersions -Plan $plan -BackupDirectory (Join-Path $fixture.Root 'version archive')
        Write-FixtureText (Join-Path $archive.ArchiveDirectory 'Base51029\nested\SC2.synthetic') 'synthetic corrupted archive'
        Assert-Rejected { Restore-Sc2VersionsArchive -ArchiveDirectory $archive.ArchiveDirectory } 'Corrupted archive fingerprints must reject restore'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.EUDirectory 'Versions\Base51029'))) 'Rejected restore must not create the original directory'
        Assert-True (Test-Path -LiteralPath (Join-Path $archive.ArchiveDirectory 'Base51029')) 'Rejected restore must retain archived bytes for review'
    }

    Test-Case 'Versions refuses when config build-name contradicts EU state' {
        $fixture = New-CaseFixture -Versions
        Write-FixtureBuildConfig $fixture.EUDirectory $fixture.EUKey '5.0.17.51029' | Out-Null
        $original = @(Get-ChildItem -LiteralPath (Join-Path $fixture.EUDirectory 'Versions') -File -Recurse | Select-Object -ExpandProperty FullName)
        $snapshot = Get-FixtureSnapshot $original
        Assert-Rejected {
            $plan = Get-Sc2VersionMaintenancePlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $fixture.EUDirectory
            Move-Sc2CopiedCNVersions -Plan $plan -BackupDirectory (Join-Path $fixture.Root 'version archive')
        } 'Contradictory EU evidence must not permit Versions moving'
        Assert-SnapshotUnchanged $snapshot -Attributes
    }

    Test-Case 'Versions requires the exact EU build config and matching local EU region' {
        $fixture = New-CaseFixture -Versions
        $configPath = Join-Path $fixture.EUDirectory ("SC2Data/config/{0}/{1}/{2}" -f $fixture.EUKey.Substring(0, 2), $fixture.EUKey.Substring(2, 2), $fixture.EUKey)
        [IO.File]::Delete($configPath)
        Assert-Rejected { Get-Sc2VersionMaintenancePlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $fixture.EUDirectory } 'Missing exact EU build config must reject maintenance'
        Write-FixtureBuildConfig $fixture.EUDirectory $fixture.EUKey $fixture.EUVersion | Out-Null
        $wrongLocal = New-FixtureProduct 's2' ($fixture.EUDirectory -replace '\\', '/') 'cn' $fixture.EUVersion $fixture.EUKey $fixture.EUCDNKey
        Write-FixtureBytes (Join-Path $fixture.EUDirectory '.product.db') (New-FixtureDatabase -Records (,$wrongLocal))
        Assert-Rejected { Get-Sc2VersionMaintenancePlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $fixture.EUDirectory } 'EU local cn region must reject maintenance'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.EUDirectory 'Versions\Base51029')) 'Insufficient EU evidence must leave copied CN version untouched'
    }

    Test-Case 'Versions requires EU local Build Key to agree with Agent and selected row' {
        $fixture = New-CaseFixture -Versions
        $wrongKeyRecord = New-FixtureProduct 's2' ($fixture.EUDirectory -replace '\\', '/') 'eu' $fixture.EUVersion (New-FixtureKey) $fixture.EUCDNKey
        Write-FixtureBytes (Join-Path $fixture.EUDirectory '.product.db') $wrongKeyRecord
        Assert-Rejected { Get-Sc2VersionMaintenancePlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $fixture.EUDirectory } 'A different EU local Build Key must reject maintenance'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.EUDirectory 'Versions\Base51029')) 'Mismatched build evidence must leave the copied CN Base'
    }

    Test-Case 'Versions requires a nonempty confirmed EU Base directory' {
        $fixture = New-CaseFixture -Versions
        $officialBase = Join-Path $fixture.EUDirectory 'Versions\Base50913'
        [IO.File]::Delete((Join-Path $officialBase 'nested\SC2.synthetic'))
        [IO.File]::Delete((Join-Path $officialBase 'client.synthetic'))
        [IO.File]::Delete((Join-Path $officialBase 'SC2_x64.exe'))
        [IO.Directory]::Delete((Join-Path $officialBase 'nested'))
        Assert-Rejected { Get-Sc2VersionMaintenancePlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $fixture.EUDirectory } 'An empty official EU Base must reject maintenance'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.EUDirectory 'Versions\Base51029')) 'An empty EU Base must leave the copied CN Base'
    }

    Test-Case 'Versions detects a hidden proven copied CN Base' {
        $fixture = New-CaseFixture -Versions
        $copiedBase = Join-Path $fixture.EUDirectory 'Versions\Base51029'
        [IO.File]::SetAttributes($copiedBase, ([IO.File]::GetAttributes($copiedBase) -bor [IO.FileAttributes]::Hidden))
        $plan = Get-Sc2VersionMaintenancePlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $fixture.EUDirectory
        Assert-Equal @($plan.MoveCandidates).Count 1 'Hidden copied Base must be included in the plan'
        Assert-Equal $plan.MoveCandidates[0].Name 'Base51029' 'Only the proven copied CN Base may be eligible'
    }

    Test-Case 'Versions requires a nonempty actual-client marker in the confirmed EU Base' {
        $fixture = New-CaseFixture -Versions
        $clientPath = Join-Path $fixture.EUDirectory 'Versions\Base50913\SC2_x64.exe'
        [IO.File]::Delete($clientPath)
        Assert-Rejected { Get-Sc2VersionMaintenancePlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $fixture.EUDirectory } 'A missing SC2.exe or SC2_x64.exe must reject maintenance'
        Write-FixtureBytes $clientPath ([byte[]]@())
        Assert-Rejected { Get-Sc2VersionMaintenancePlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $fixture.EUDirectory } 'An empty client marker must reject maintenance'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.EUDirectory 'Versions\Base51029')) 'Unproven official client must leave the copied CN Base'
    }

    Test-Case 'known pre-update EU-copy archive restores multiple synthetic Base directories' {
        $case = New-PreUpdateArchiveFixture
        $sourceSnapshot = Get-FixtureSnapshot @(Get-ChildItem -Force -File -Recurse -LiteralPath (Join-Path $case.Fixture.CNDirectory 'Versions') | Select-Object -ExpandProperty FullName)
        $result = Restore-Sc2VersionsArchive -ArchiveDirectory $case.ArchiveDirectory
        Assert-Equal $result.Restored 2 'The known pre-update mode must restore both recorded Base directories'
        foreach ($move in $case.Manifest.Moves) {
            Assert-True ([IO.Directory]::Exists($move.OriginalPath)) 'Every original Base must be restored'
            Assert-True (-not [IO.Directory]::Exists($move.ArchivePath)) 'Restored Base must no longer remain at its archive path'
            $fingerprint = & $testModule { param($Path) Get-DirectoryFingerprint $Path } $move.OriginalPath
            Assert-Equal $fingerprint $move.Fingerprint 'Restored content must retain the verified fingerprint'
        }
        Assert-SnapshotUnchanged $sourceSnapshot -Attributes
    }

    Test-Case 'unknown or ordinary multi-Base archive mode rejects before moving anything' {
        $case = New-PreUpdateArchiveFixture
        foreach ($mode in @('UnrecognizedMode', 'VerifiedCopiedCNAfterOfficialUpdate', $null)) {
            if ($null -eq $mode) { $case.Manifest.PSObject.Properties.Remove('Mode') }
            else { $case.Manifest.Mode = $mode }
            Write-FixtureText (Join-Path $case.ArchiveDirectory 'archive.json') ($case.Manifest | ConvertTo-Json -Depth 8)
            Assert-Rejected { Restore-Sc2VersionsArchive -ArchiveDirectory $case.ArchiveDirectory } 'Only the known pre-update mode may restore multiple Base directories'
            foreach ($move in $case.Manifest.Moves) {
                Assert-True ([IO.Directory]::Exists($move.ArchivePath)) 'Rejected restoration must retain every archived Base'
                Assert-True (-not [IO.Directory]::Exists($move.OriginalPath)) 'Rejected restoration must not create any original Base'
            }
        }
    }

    Test-Case 'multi-Base archive duplicate original or archive targets reject atomically' {
        $case = New-PreUpdateArchiveFixture
        $originalMoves = @($case.Manifest.Moves)
        $case.Manifest.Moves = @($originalMoves[0], $originalMoves[0])
        Write-FixtureText (Join-Path $case.ArchiveDirectory 'archive.json') ($case.Manifest | ConvertTo-Json -Depth 8)
        Assert-Rejected { Restore-Sc2VersionsArchive -ArchiveDirectory $case.ArchiveDirectory } 'Duplicate original and archive paths must reject'
        $badSecond = [pscustomobject]@{ OriginalPath = $originalMoves[1].OriginalPath; ArchivePath = $originalMoves[0].ArchivePath; Fingerprint = $originalMoves[1].Fingerprint }
        $case.Manifest.Moves = @($originalMoves[0], $badSecond)
        Write-FixtureText (Join-Path $case.ArchiveDirectory 'archive.json') ($case.Manifest | ConvertTo-Json -Depth 8)
        Assert-Rejected { Restore-Sc2VersionsArchive -ArchiveDirectory $case.ArchiveDirectory } 'An archive path reused for another Base must reject'
        foreach ($move in $originalMoves) {
            Assert-True ([IO.Directory]::Exists($move.ArchivePath)) 'Duplicate targets must leave all archived content in place'
            Assert-True (-not [IO.Directory]::Exists($move.OriginalPath)) 'Duplicate targets must not move even the first valid Base'
        }
    }

    Test-Case 'regional Windows B-number WIN suffix matches the actual build number' {
        $fixture = New-CaseFixture -Versions
        $configPath = Write-FixtureBuildConfig $fixture.CNDirectory $fixture.CNKey $fixture.CNVersion -WinSuffix
        $actual = & $testModule {
            param($Path, $Version)
            Read-RealBuildName $Path $Version
        } $configPath $fixture.CNVersion
        Assert-Equal $actual 'B51029-WIN' 'The exact observed WIN suffix must be accepted for the matching regional build'
    }

    Test-Case 'regional Windows WIN suffix with a wrong number rejects' {
        $fixture = New-CaseFixture -Versions
        $configPath = Write-FixtureBuildConfig $fixture.CNDirectory $fixture.CNKey $fixture.EUVersion -WinSuffix
        Assert-Rejected {
            & $testModule {
                param($Path, $Version)
                Read-RealBuildName $Path $Version
            } $configPath $fixture.CNVersion
        } 'A WIN suffix must not bypass the regional build-number equality check'
    }

    Test-Case 'regional build-name rejects unknown platform suffixes' {
        $fixture = New-CaseFixture -Versions
        $configPath = Write-FixtureBuildConfig $fixture.CNDirectory $fixture.CNKey $fixture.CNVersion
        foreach ($suffix in @('-MAC', '-WIN-EXTRA', '-win', '-OTHER')) {
            Write-FixtureText $configPath ("build-name = B51029" + $suffix + "`r`n")
            Assert-Rejected {
                & $testModule {
                    param($Path, $Version)
                    Read-RealBuildName $Path $Version
                } $configPath $fixture.CNVersion
            } 'Only the exact WIN suffix may be accepted; unknown trailing text must reject'
        }
    }

    Test-Case 'Versions also accepts an exact full-version build-name' {
        $fixture = New-CaseFixture -Versions
        Write-FixtureBuildConfig $fixture.EUDirectory $fixture.EUKey $fixture.EUVersion -FullVersion | Out-Null
        $plan = Get-Sc2VersionMaintenancePlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $fixture.EUDirectory
        Assert-Equal $plan.OfficialEU.Version $fixture.EUVersion 'Full version build-name must resolve the same EU version'
        Assert-Equal @($plan.MoveCandidates).Count 1 'Full version config must preserve the one proven CN candidate'
    }

    Test-Case 'running Agent blocks Versions movement and restoration' {
        $fixture = New-CaseFixture -Versions
        $plan = Get-Sc2VersionMaintenancePlan -AgentDatabase $fixture.AgentDatabase -CNDirectory $fixture.CNDirectory -EUDirectory $fixture.EUDirectory
        Set-SyntheticProcessState 'Agent'
        Assert-Rejected { Move-Sc2CopiedCNVersions -Plan $plan -BackupDirectory (Join-Path $fixture.Root 'blocked archive') } 'Agent must block moving Versions'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.EUDirectory 'Versions\Base51029')) 'Blocked move must leave the source'
        Set-SyntheticProcessState ''
        $archive = Move-Sc2CopiedCNVersions -Plan $plan -BackupDirectory (Join-Path $fixture.Root 'version archive')
        Set-SyntheticProcessState 'Agent'
        Assert-Rejected { Restore-Sc2VersionsArchive -ArchiveDirectory $archive.ArchiveDirectory } 'Agent must block restoring Versions'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.EUDirectory 'Versions\Base51029'))) 'Blocked restore must leave the archive unchanged'
    }
} finally {
    & $testModule {
        Remove-Item -LiteralPath Function:script:Get-Process -ErrorAction SilentlyContinue
        Remove-Variable -Name SyntheticProcessName -Scope Script -ErrorAction SilentlyContinue
    }
}

$failed = @($results | Where-Object Status -eq 'FAIL')
$passed = @($results | Where-Object Status -eq 'PASS')
Write-Host "`nSynthetic result: $($passed.Count) passed; $($failed.Count) failed."
if ($failed.Count -gt 0 -or $KeepFixtures) {
    Write-Host "Synthetic fixtures preserved: $fixtureRoot"
} else {
    $fullRoot = [IO.Path]::GetFullPath($fixtureRoot)
    $fullTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    Assert-True ($fullRoot.StartsWith($fullTemp, [StringComparison]::OrdinalIgnoreCase)) 'Cleanup path must remain in the temp directory'
    Assert-True ([IO.Path]::GetFileName($fullRoot) -match '^sc2-dual-region-synthetic-[a-f0-9]{32}$') 'Cleanup root must have the exact generated test prefix'
    Assert-True (([IO.File]::GetAttributes($fullRoot) -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Cleanup root must not be a reparse point'
    Remove-Item -LiteralPath $fullRoot -Recurse -Force
}
if ($failed.Count -gt 0) { exit 1 }
