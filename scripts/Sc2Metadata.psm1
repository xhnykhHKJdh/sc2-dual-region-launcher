#requires -Version 5.1
Set-StrictMode -Version 2.0

function Read-Varint {
    param([byte[]]$Data, [ref]$Position)
    [UInt64]$value = 0
    for ($shift = 0; $shift -lt 70; $shift += 7) {
        if ($Position.Value -ge $Data.Length) { throw 'Truncated protobuf integer.' }
        $octet = $Data[$Position.Value]
        $Position.Value++
        if ($shift -eq 63 -and ($octet -band 127) -gt 1) { throw 'Integer overflow.' }
        $value = $value -bor ([UInt64]($octet -band 127) -shl $shift)
        if (($octet -band 128) -eq 0) { return $value }
    }
    throw 'Invalid protobuf integer.'
}

function Get-Slice {
    param([byte[]]$Data, [int]$Start, [int]$Length)
    $slice = [byte[]]::new($Length)
    [Array]::Copy($Data, $Start, $slice, 0, $Length)
    return ,$slice
}

function Skip-Value {
    param([byte[]]$Data, [ref]$Position, [int]$Number, [int]$Wire, [int]$Depth)
    if ($Depth -gt 64) { throw 'Protobuf nesting limit exceeded.' }
    switch ($Wire) {
        0 { $null = Read-Varint $Data $Position }
        1 { $Position.Value += 8 }
        2 {
            $length = Read-Varint $Data $Position
            if ($length -gt ($Data.Length - $Position.Value)) { throw 'Invalid field length.' }
            $Position.Value += [int]$length
        }
        3 {
            $ended = $false
            while ($Position.Value -lt $Data.Length) {
                $tag = Read-Varint $Data $Position
                $childNumber = [int]($tag -shr 3)
                $childWire = [int]($tag -band 7)
                if ($childNumber -eq 0) { throw 'Invalid field number.' }
                if ($childWire -eq 4) {
                    if ($childNumber -ne $Number) { throw 'Mismatched protobuf group.' }
                    $ended = $true
                    break
                }
                Skip-Value $Data $Position $childNumber $childWire ($Depth + 1)
            }
            if (-not $ended) { throw 'Unterminated protobuf group.' }
        }
        5 { $Position.Value += 4 }
        default { throw 'Invalid protobuf wire type.' }
    }
    if ($Position.Value -gt $Data.Length) { throw 'Truncated protobuf field.' }
}

function Read-Message {
    param([byte[]]$Data)
    $position = 0
    $fields = [Collections.Generic.List[object]]::new()
    while ($position -lt $Data.Length) {
        $start = $position
        $tag = Read-Varint $Data ([ref]$position)
        $number = [int]($tag -shr 3)
        $wire = [int]($tag -band 7)
        if ($number -eq 0) { throw 'Invalid protobuf field number.' }
        $tagEnd = $position
        $payload = $null
        if ($wire -eq 2) {
            $length = Read-Varint $Data ([ref]$position)
            if ($length -gt ($Data.Length - $position)) { throw 'Invalid field length.' }
            $payload = Get-Slice $Data $position ([int]$length)
            $position += [int]$length
        }
        else {
            Skip-Value $Data ([ref]$position) $number $wire 0
        }
        $fields.Add([pscustomobject]@{
            Number = $number
            Wire = $wire
            Tag = Get-Slice $Data $start ($tagEnd - $start)
            Payload = $payload
            Raw = Get-Slice $Data $start ($position - $start)
        })
    }
    return [pscustomobject]@{ Fields = $fields.ToArray() }
}

function Get-Field {
    param($Message, [int]$Number, [switch]$Required)
    $matches = @($Message.Fields | Where-Object { $_.Number -eq $Number -and $_.Wire -eq 2 })
    if ($matches.Count -gt 1) { throw "Ambiguous repeated installation field $Number." }
    if ($matches.Count -eq 0) {
        if ($Required) { throw "Required installation field $Number is missing." }
        return $null
    }
    return $matches[0]
}

function Get-Text {
    param($Field)
    if ($null -eq $Field) { return '' }
    $text = ([Text.UTF8Encoding]::new($false, $true)).GetString($Field.Payload)
    if ($text -match '[\x00-\x1F\x7F]') { throw 'Unexpected binary installation field.' }
    return $text
}

function Get-Summary {
    param([byte[]]$InstallBytes)
    $install = Read-Message $InstallBytes
    $settingsField = Get-Field $install 3 -Required
    $settings = Read-Message $settingsField.Payload
    $version = ''
    $stateField = Get-Field $install 4
    if ($null -ne $stateField) {
        $state = Read-Message $stateField.Payload
        $buildField = Get-Field $state 1
        if ($null -ne $buildField) {
            $build = Read-Message $buildField.Payload
            $version = Get-Text (Get-Field $build 7)
        }
    }
    return [pscustomobject]@{
        ProductUid = Get-Text (Get-Field $install 1 -Required)
        ProductCode = Get-Text (Get-Field $install 2)
        Directory = Get-Text (Get-Field $settings 1 -Required)
        Region = Get-Text (Get-Field $settings 2)
        Version = $version
    }
}

function Read-Container {
    param([byte[]]$Data)
    $message = Read-Message $Data
    $rootUid = ''
    try { $rootUid = Get-Text (Get-Field $message 1) } catch { }
    $records = [Collections.Generic.List[object]]::new()
    if ($rootUid -match '^s2(?:$|_|t)') {
        $records.Add([pscustomobject]@{ Uid = $rootUid; Index = -1; Bytes = $Data })
        $format = 'direct'
    }
    else {
        $format = 'wrapper'
        for ($index = 0; $index -lt $message.Fields.Count; $index++) {
            $field = $message.Fields[$index]
            if ($field.Number -ne 1 -or $field.Wire -ne 2) { continue }
            $install = Read-Message $field.Payload
            $uid = Get-Text (Get-Field $install 1)
            $records.Add([pscustomobject]@{ Uid = $uid; Index = $index; Bytes = $field.Payload })
        }
    }
    return [pscustomobject]@{ Format = $format; Message = $message; Records = $records.ToArray() }
}

function Join-Bytes {
    param([object[]]$Segments)
    $stream = [IO.MemoryStream]::new()
    try {
        foreach ($segment in $Segments) { $stream.Write($segment, 0, $segment.Length) }
        return ,$stream.ToArray()
    }
    finally { $stream.Dispose() }
}

function Encode-Varint {
    param([UInt64]$Value)
    $bytes = [Collections.Generic.List[byte]]::new()
    do {
        $octet = [byte]($Value -band 127)
        $Value = $Value -shr 7
        if ($Value -ne 0) { $octet = $octet -bor 128 }
        $bytes.Add($octet)
    } while ($Value -ne 0)
    return ,$bytes.ToArray()
}

function Replace-Payload {
    param($Field, [byte[]]$Payload)
    return ,(Join-Bytes @($Field.Tag, (Encode-Varint $Payload.Length), $Payload))
}

function Test-BytesEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Get-Hash {
    param([byte[]]$Data)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Data))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-Database {
    param([string]$Path)
    $info = Get-Item -Force -LiteralPath $Path
    if ($info.Length -gt 16MB) { throw 'Database exceeds the 16 MiB inspection limit.' }
    return ,[IO.File]::ReadAllBytes($Path)
}

function Remove-S2Record {
    param([byte[]]$Data)
    $container = Read-Container $Data
    $matches = @($container.Records | Where-Object Uid -EQ 's2')
    if ($matches.Count -ne 1) { throw 'Removal requires exactly one UID=s2 record.' }
    if ($container.Format -ne 'wrapper') {
        throw 'A direct-only database cannot be repaired by removing its sole record.'
    }
    $remaining = @()
    for ($index = 0; $index -lt $container.Message.Fields.Count; $index++) {
        if ($index -ne $matches[0].Index) { $remaining += ,$container.Message.Fields[$index].Raw }
    }
    $candidate = Join-Bytes $remaining
    $parsedCandidate = Read-Container $candidate
    if (@($parsedCandidate.Records | Where-Object Uid -EQ 's2').Count -ne 0) {
        throw 'Removal verification failed.'
    }
    if ($parsedCandidate.Message.Fields.Count -ne $remaining.Count) { throw 'Field count changed unexpectedly.' }
    for ($index = 0; $index -lt $remaining.Count; $index++) {
        if (-not (Test-BytesEqual $remaining[$index] $parsedCandidate.Message.Fields[$index].Raw)) {
            throw 'An unrelated protobuf field changed.'
        }
    }
    return [pscustomobject]@{
        Bytes = $candidate
        RemovedRecord = Get-Summary $matches[0].Bytes
        RemainingSc2Uids = @($parsedCandidate.Records | Where-Object Uid -Match '^s2(?:$|_|t)' | ForEach-Object Uid)
        UnrelatedFieldsPreservedByteForByte = $true
    }
}

function Seed-S2Record {
    param([byte[]]$Data, [string]$Directory, [string]$Region)
    $container = Read-Container $Data
    $matches = @($container.Records | Where-Object Uid -EQ 's2')
    if ($matches.Count -ne 1) { throw 'Seeding requires exactly one UID=s2 record.' }
    $record = $matches[0].Bytes
    $install = Read-Message $record
    $settingsField = Get-Field $install 3 -Required
    $settings = Read-Message $settingsField.Payload
    $null = Get-Field $settings 1 -Required
    if ($Region -ne 'unchanged') { $null = Get-Field $settings 2 -Required }
    $newSettingsSegments = @()
    foreach ($field in $settings.Fields) {
        if ($field.Number -eq 1 -and $field.Wire -eq 2) {
            $newSettingsSegments += ,(Replace-Payload $field ([Text.Encoding]::UTF8.GetBytes($Directory)))
        }
        elseif ($field.Number -eq 2 -and $field.Wire -eq 2 -and $Region -ne 'unchanged') {
            $newSettingsSegments += ,(Replace-Payload $field ([Text.Encoding]::UTF8.GetBytes($Region)))
        }
        else { $newSettingsSegments += ,$field.Raw }
    }
    $newSettings = Join-Bytes $newSettingsSegments
    $newInstallSegments = @()
    foreach ($field in $install.Fields) {
        if ($field.Number -eq 3 -and $field.Wire -eq 2) {
            $newInstallSegments += ,(Replace-Payload $field $newSettings)
        }
        else { $newInstallSegments += ,$field.Raw }
    }
    $candidate = Join-Bytes $newInstallSegments
    $candidateInstall = Read-Message $candidate
    $candidateSettings = Read-Message (Get-Field $candidateInstall 3 -Required).Payload
    if ($candidateInstall.Fields.Count -ne $install.Fields.Count -or
        $candidateSettings.Fields.Count -ne $settings.Fields.Count) { throw 'Field count changed unexpectedly.' }
    for ($index = 0; $index -lt $install.Fields.Count; $index++) {
        $isSettingsField = $install.Fields[$index].Number -eq 3 -and $install.Fields[$index].Wire -eq 2
        if (-not $isSettingsField -and
            -not (Test-BytesEqual $install.Fields[$index].Raw $candidateInstall.Fields[$index].Raw)) {
            throw 'An unrelated ProductInstall field changed.'
        }
    }
    for ($index = 0; $index -lt $settings.Fields.Count; $index++) {
        $field = $settings.Fields[$index]
        $changed = ($field.Number -eq 1 -and $field.Wire -eq 2) -or
            ($field.Number -eq 2 -and $field.Wire -eq 2 -and $Region -ne 'unchanged')
        if (-not $changed -and -not (Test-BytesEqual $field.Raw $candidateSettings.Fields[$index].Raw)) {
            throw 'An unrelated installation setting changed.'
        }
    }
    $before = Get-Summary $record
    $after = Get-Summary $candidate
    if ($after.ProductUid -ne 's2' -or $after.Directory -ne $Directory -or
        $after.Version -ne $before.Version -or
        ($Region -ne 'unchanged' -and $after.Region -ne $Region)) { throw 'Seeding verification failed.' }
    return [pscustomobject]@{
        Bytes = $candidate
        Before = $before
        After = $after
        LocalDatabaseFormat = 'direct ProductInstall (same structure as the existing PTR local database)'
        UnrelatedFieldsPreservedByteForByte = $true
    }
}

function Redirect-S2Record {
    param([byte[]]$Data, [string]$Directory)
    $container = Read-Container $Data
    if ($container.Format -ne 'wrapper') { throw 'Agent redirection requires a wrapper database.' }
    $matches = @($container.Records | Where-Object Uid -EQ 's2')
    if ($matches.Count -ne 1) { throw 'Agent redirection requires exactly one UID=s2 record.' }
    $seed = Seed-S2Record $Data $Directory 'eu'
    $segments = @()
    for ($index = 0; $index -lt $container.Message.Fields.Count; $index++) {
        $field = $container.Message.Fields[$index]
        if ($index -eq $matches[0].Index) {
            $segments += ,(Replace-Payload $field $seed.Bytes)
        }
        else { $segments += ,$field.Raw }
    }
    $candidate = Join-Bytes $segments
    $parsedCandidate = Read-Container $candidate
    if ($parsedCandidate.Message.Fields.Count -ne $container.Message.Fields.Count) {
        throw 'Agent root field count changed unexpectedly.'
    }
    for ($index = 0; $index -lt $container.Message.Fields.Count; $index++) {
        if ($index -ne $matches[0].Index -and
            -not (Test-BytesEqual $container.Message.Fields[$index].Raw $parsedCandidate.Message.Fields[$index].Raw)) {
            throw 'An unrelated Agent record or root field changed.'
        }
    }
    $newMatches = @($parsedCandidate.Records | Where-Object Uid -EQ 's2')
    if ($newMatches.Count -ne 1 -or -not (Test-BytesEqual $newMatches[0].Bytes $seed.Bytes)) {
        throw 'Redirected Agent record does not match the EU local candidate.'
    }
    return [pscustomobject]@{
        Bytes = $candidate
        LocalBytes = $seed.Bytes
        Before = $seed.Before
        After = $seed.After
        UnchangedRecordsAndRootFieldsPreservedByteForByte = $true
        UnrelatedInstallAndSettingFieldsPreservedByteForByte = $seed.UnrelatedFieldsPreservedByteForByte
        AgentAndEULocalRecordBytesIdentical = $true
    }
}

function Resolve-Sc2Path {
    param([string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'Use an explicit absolute path.' }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Assert-NoReparsePath {
    param([string]$Path)
    $full = Resolve-Sc2Path $Path
    $item = [IO.FileInfo]::new($full)
    if ([IO.Directory]::Exists($full)) { $item = [IO.DirectoryInfo]::new($full) }
    while ($null -ne $item) {
        if ($item.Exists -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Symlinks and junctions are refused for metadata and backup paths.'
        }
        if ($item -is [IO.FileInfo]) { $item = $item.Directory } else { $item = $item.Parent }
    }
}

function Test-PathOverlap {
    param([string]$Left, [string]$Right)
    $leftPath = (Resolve-Sc2Path $Left) + [IO.Path]::DirectorySeparatorChar
    $rightPath = (Resolve-Sc2Path $Right) + [IO.Path]::DirectorySeparatorChar
    return $leftPath.StartsWith($rightPath, [StringComparison]::OrdinalIgnoreCase) -or
        $rightPath.StartsWith($leftPath, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-Sc2Paths {
    param([string]$AgentDatabase, [string]$CNDirectory, [string]$EUDirectory, [string]$AuxiliaryDirectory)
    foreach ($path in @($AgentDatabase, $CNDirectory, $EUDirectory)) { Assert-NoReparsePath $path }
    if ((Split-Path -Leaf $AgentDatabase) -ne 'product.db') { throw 'The AgentDatabase filename must be product.db.' }
    if (Test-PathOverlap $CNDirectory $EUDirectory) { throw 'CN and EU directories must be separate and cannot be nested.' }
    $agentDirectory = Split-Path -Parent (Resolve-Sc2Path $AgentDatabase)
    if ((Test-PathOverlap $agentDirectory $CNDirectory) -or (Test-PathOverlap $agentDirectory $EUDirectory)) {
        throw 'The Agent database directory must be separate from both game directories.'
    }
    if ($AuxiliaryDirectory) {
        Assert-NoReparsePath $AuxiliaryDirectory
        foreach ($directory in @($agentDirectory, $CNDirectory, $EUDirectory)) {
            if (Test-PathOverlap $directory $AuxiliaryDirectory) { throw 'Backups/candidates must be outside the game and Agent directories.' }
        }
    }
}

function Assert-Sc2Offline {
    $blockedNames = @('Battle.net', 'Battle.net Launcher', 'Agent', 'AgentHelper', 'SC2', 'SC2_x64', 'SC2Switcher', 'SC2Switcher_x64')
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in $blockedNames })
    if ($running.Count) { throw 'Exit Battle.net, its Agent, and StarCraft II before writing or moving metadata.' }
}

function Get-InstallRecord {
    param([byte[]]$Data, [string]$Uid)
    $container = Read-Container $Data
    $matches = @($container.Records | Where-Object Uid -EQ $Uid)
    if ($matches.Count -ne 1) { throw "Exactly one installation record is required for $Uid." }
    return $matches[0]
}

function Get-ValidatedCNLocalContainer {
    param([byte[]]$Data)
    $container = Read-Container $Data
    if (@($container.Records | Where-Object { $_.Uid -notin @('s2_cn', 's2') }).Count) {
        throw 'The CN local database contains an unexpected product; manual review is required.'
    }
    if (@($container.Records | Where-Object Uid -EQ 's2_cn').Count -ne 1 -or
        @($container.Records | Where-Object Uid -EQ 's2').Count -gt 1) {
        throw 'CN local metadata requires one s2_cn record and no duplicate s2 records.'
    }
    return $container
}

function Get-StateHexStrings {
    param($Message, [int]$Depth = 0)
    if ($Depth -gt 8) { throw 'Installation state nesting exceeds the inspection limit.' }
    foreach ($field in $Message.Fields) {
        if ($field.Wire -ne 2) { continue }
        $value = ''
        try { $value = Get-Text $field } catch { }
        if ($value -match '^[0-9a-fA-F]{32}$') { $value.ToLowerInvariant(); continue }
        # A printable scalar is not a nested protobuf message.
        if ($value) { continue }
        try { $child = Read-Message $field.Payload } catch { continue }
        Get-StateHexStrings $child ($Depth + 1)
    }
}

function Read-BuildInfo {
    param([byte[]]$Data)
    $hasBom = $Data.Length -ge 3 -and $Data[0] -eq 239 -and $Data[1] -eq 187 -and $Data[2] -eq 191
    $text = ([Text.UTF8Encoding]::new($false, $true)).GetString($Data).TrimStart([char]65279)
    $newlineMatch = [regex]::Match($text, '\r\n|\n|\r')
    $newline = if ($newlineMatch.Success) { $newlineMatch.Value } else { [Environment]::NewLine }
    $lines = [regex]::Split($text, '\r\n|\n|\r')
    if ($lines.Count -lt 2) { throw 'build.info needs a header and at least one build row.' }
    $columns = @($lines[0].Split('|') | ForEach-Object { ($_ -split '!', 2)[0] })
    if ($columns -notcontains 'Build Key' -or $columns -notcontains 'Version') { throw 'Required build.info columns are missing.' }
    $rows = @()
    foreach ($line in $lines[1..($lines.Count - 1)]) {
        if (-not $line) { continue }
        $values = $line.Split('|')
        if ($values.Count -ne $columns.Count) { throw 'Malformed build.info row.' }
        $map = @{}
        for ($index = 0; $index -lt $columns.Count; $index++) {
            if ($map.ContainsKey($columns[$index])) { throw 'Repeated build.info column.' }
            $map[$columns[$index]] = $values[$index]
        }
        $rows += [pscustomobject]@{ Raw = $line; Values = $map }
    }
    return [pscustomobject]@{ Header = $lines[0]; Newline = $newline; HasBom = $hasBom; Rows = $rows }
}

function Select-BuildRow {
    param([byte[]]$InstallBytes, $Table)
    $install = Read-Message $InstallBytes
    $state = Read-Message (Get-Field $install 4 -Required).Payload
    $build = Read-Message (Get-Field $state 1 -Required).Payload
    $keys = @(Get-StateHexStrings $build | Select-Object -Unique)
    $matches = @($Table.Rows | Where-Object { $_.Values['Build Key'].ToLowerInvariant() -in $keys })
    if ($matches.Count -ne 1) { throw 'Installation state and build.info must have exactly one matching Build Key row.' }
    $version = Get-Text (Get-Field $build 7 -Required)
    if ($matches[0].Values['Version'] -ne $version) { throw 'The selected build.info version does not match installation state.' }
    return $matches[0]
}

function Encode-SelectedBuildInfo {
    param($Table, $Row)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Table.Header + $Table.Newline + $Row.Raw + $Table.Newline)
    if ($Table.HasBom) { return ,(Join-Bytes @([byte[]]@(239, 187, 191), $bytes)) }
    return ,$bytes
}

function Get-Sc2InstallationReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AgentDatabase, [Parameter(Mandatory)][string]$CNDirectory, [Parameter(Mandatory)][string]$EUDirectory)
    Assert-Sc2Paths $AgentDatabase $CNDirectory $EUDirectory
    $paths = @($AgentDatabase, (Join-Path $CNDirectory '.product.db'), (Join-Path $EUDirectory '.product.db'))
    $records = @(foreach ($path in $paths) {
        if (-not [IO.File]::Exists($path)) { [pscustomobject]@{ Source = $path; Status = 'missing'; Installations = @() }; continue }
        Assert-NoReparsePath $path
        $bytes = Read-Database $path
        $container = Read-Container $bytes
        $summaries = @($container.Records | Where-Object Uid -Match '^s2(?:$|_|t)' | ForEach-Object { Get-Summary $_.Bytes })
        [pscustomobject]@{ Source = $path; Status = 'present'; Sha256 = Get-Hash $bytes; Installations = $summaries }
    })
    return [pscustomobject]@{ Installations = $records }
}

function Assert-EUGameCopy {
    param([string]$Directory)
    $launcher = Join-Path $Directory 'StarCraft II.exe'
    $data = Join-Path $Directory 'SC2Data'
    $versions = Join-Path $Directory 'Versions'
    foreach ($path in @($launcher, $data, $versions)) { Assert-NoReparsePath $path }
    if (-not [IO.File]::Exists($launcher) -or ([IO.FileInfo]::new($launcher)).Length -eq 0 -or
        -not [IO.Directory]::Exists($data) -or -not [IO.Directory]::Exists($versions)) {
        throw 'The EU copy needs a nonempty StarCraft II.exe, SC2Data, and Versions before metadata can be redirected.'
    }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($data)
    $found = $false
    while ($pending.Count -and -not $found) {
        foreach ($item in Get-ChildItem -Force -LiteralPath $pending.Pop()) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The EU game data contains a symlink or junction.' }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            elseif ($item.Length -gt 0) { $found = $true }
        }
    }
    if (-not $found) { throw 'SC2Data has no nonempty data file; copy the game before redirecting metadata.' }
}

function New-Sc2RepairPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AgentDatabase, [Parameter(Mandatory)][string]$CNDirectory, [Parameter(Mandatory)][string]$EUDirectory)
    Assert-Sc2Paths $AgentDatabase $CNDirectory $EUDirectory
    $inputs = [pscustomobject]@{ AgentDatabase = Resolve-Sc2Path $AgentDatabase; CNDirectory = Resolve-Sc2Path $CNDirectory; EUDirectory = Resolve-Sc2Path $EUDirectory }
    if (-not [IO.Directory]::Exists($inputs.CNDirectory) -or -not [IO.Directory]::Exists($inputs.EUDirectory)) {
        throw 'Both game directories must exist; first copy the game files to a separate EU directory.'
    }
    Assert-EUGameCopy $inputs.EUDirectory
    $agentBytes = Read-Database $inputs.AgentDatabase
    $cnPath = Join-Path $inputs.CNDirectory '.product.db'
    Assert-NoReparsePath $cnPath
    $cnBytes = Read-Database $cnPath
    $cnContainer = Get-ValidatedCNLocalContainer $cnBytes
    $cnRecord = Get-InstallRecord $cnBytes 's2_cn'
    $agentCn = Get-InstallRecord $agentBytes 's2_cn'
    $agentEu = Get-InstallRecord $agentBytes 's2'
    $cnSummary = Get-Summary $cnRecord.Bytes
    $agentCnSummary = Get-Summary $agentCn.Bytes
    if ((Resolve-Sc2Path $agentCnSummary.Directory) -ne $inputs.CNDirectory -or
        (Resolve-Sc2Path $cnSummary.Directory) -ne $inputs.CNDirectory -or
        $agentCnSummary.Version -ne $cnSummary.Version -or $cnSummary.Region -ne 'cn' -or $agentCnSummary.Region -ne 'cn') {
        throw 'CN directory/region/version must already agree in Agent and CN local metadata.'
    }
    $euSummary = Get-Summary $agentEu.Bytes
    if ((Resolve-Sc2Path $euSummary.Directory) -notin @($inputs.CNDirectory, $inputs.EUDirectory)) {
        throw 'International metadata points to a third directory; refusing to redirect it.'
    }
    $redirect = Redirect-S2Record $agentBytes ($inputs.EUDirectory.Replace('\', '/'))
    $euProductPath = Join-Path $inputs.EUDirectory '.product.db'
    Assert-NoReparsePath $euProductPath
    $euProductBytes = if ([IO.File]::Exists($euProductPath)) { Read-Database $euProductPath } else { $null }
    if ($null -ne $euProductBytes -and -not (Test-BytesEqual $euProductBytes $cnBytes)) {
        $euContainer = Read-Container $euProductBytes
        if ($euContainer.Records.Count -ne 1 -or $euContainer.Records[0].Uid -ne 's2' -or
            ($euContainer.Format -eq 'wrapper' -and $euContainer.Message.Fields.Count -ne 1)) {
            throw 'Existing EU metadata is not a verified CN copy or a single international install; refusing to overwrite it.'
        }
        $recordBytes = $euContainer.Records[0].Bytes
        if (-not (Test-BytesEqual $recordBytes $agentEu.Bytes) -and
            -not (Test-BytesEqual $recordBytes $redirect.LocalBytes)) {
            throw 'Existing EU install state differs from the Agent record; manual review is required.'
        }
    }
    $cnInternational = @($cnContainer.Records | Where-Object Uid -EQ 's2')
    if ($cnInternational.Count -gt 1) { throw 'Ambiguous international CN-local record.' }
    $cleanCn = if ($cnInternational.Count -eq 1) { (Remove-S2Record $cnBytes).Bytes } else { $cnBytes }
    $cnBuildPath = Join-Path $inputs.CNDirectory '.build.info'
    $euBuildPath = Join-Path $inputs.EUDirectory '.build.info'
    Assert-NoReparsePath $cnBuildPath
    Assert-NoReparsePath $euBuildPath
    $cnBuildBytes = Read-Database $cnBuildPath
    $euBuildBytes = if ([IO.File]::Exists($euBuildPath)) { Read-Database $euBuildPath } else { $null }
    $cnTable = Read-BuildInfo $cnBuildBytes
    $euTable = if ($null -ne $euBuildBytes) { Read-BuildInfo $euBuildBytes } else { $cnTable }
    $cnRow = Select-BuildRow $cnRecord.Bytes $cnTable
    if ($cnRow.Values['Branch'] -ne 'cn' -or $cnRow.Values['Active'] -ne '1') { throw 'The selected CN build must be active and belong to the cn branch.' }
    $agentCnRow = Select-BuildRow $agentCn.Bytes $cnTable
    if ($agentCnRow.Values['Build Key'] -ne $cnRow.Values['Build Key']) { throw 'Agent and CN-local state select different CN builds.' }
    $euRow = Select-BuildRow $agentEu.Bytes $euTable
    $specs = @(
        [pscustomobject]@{ Role = 'Agent'; Path = $inputs.AgentDatabase; Bytes = $redirect.Bytes },
        [pscustomobject]@{ Role = 'CNProduct'; Path = $cnPath; Bytes = [byte[]]$cleanCn },
        [pscustomobject]@{ Role = 'EUProduct'; Path = Join-Path $inputs.EUDirectory '.product.db'; Bytes = $redirect.LocalBytes },
        [pscustomobject]@{ Role = 'CNBuild'; Path = $cnBuildPath; Bytes = Encode-SelectedBuildInfo $cnTable $cnRow },
        [pscustomobject]@{ Role = 'EUBuild'; Path = $euBuildPath; Bytes = Encode-SelectedBuildInfo $euTable $euRow }
    )
    $targets = @(foreach ($spec in $specs) {
        Assert-NoReparsePath $spec.Path
        $exists = [IO.File]::Exists($spec.Path)
        $beforeHash = if ($exists) { Get-Hash (Read-Database $spec.Path) } else { $null }
        $attributes = if ($exists) { [int][IO.File]::GetAttributes($spec.Path) } else { 0 }
        [pscustomobject]@{ Role = $spec.Role; Path = $spec.Path; BeforeExists = $exists; BeforeSha256 = $beforeHash; BeforeAttributes = $attributes; CandidateBytes = [byte[]]$spec.Bytes; CandidateSha256 = Get-Hash $spec.Bytes }
    })
    $snapshots = @{ Agent = $agentBytes; CNProduct = $cnBytes; CNBuild = $cnBuildBytes }
    if ($null -ne $euProductBytes) { $snapshots.EUProduct = $euProductBytes }
    if ($null -ne $euBuildBytes) { $snapshots.EUBuild = $euBuildBytes }
    foreach ($target in $targets) {
        if ($snapshots.ContainsKey($target.Role) -and (Get-Hash $snapshots[$target.Role]) -ne $target.BeforeSha256) {
            throw 'Metadata changed during plan generation; retry after exiting Battle.net and its Agent.'
        }
    }
    return [pscustomobject]@{
        Inputs = $inputs
        Targets = $targets
        Summary = [pscustomobject]@{
            CN = $cnSummary; EU = $redirect.After
            CNBuildKey = $cnRow.Values['Build Key']; EUBuildKey = $euRow.Values['Build Key']
            EUBuildBranchPreserved = $euRow.Values['Branch']
            UnchangedAgentRecordsPreservedByteForByte = $redirect.UnchangedRecordsAndRootFieldsPreservedByteForByte
            UnchangedInstallFieldsPreservedByteForByte = $redirect.UnrelatedInstallAndSettingFieldsPreservedByteForByte
            Note = 'EU build.info retains the real copied build row; the official Agent must revalidate and update the EU copy.'
        }
    }
}

function New-ArtifactDirectory {
    param([string]$Root, [string]$Prefix)
    Assert-NoReparsePath $Root
    $fullRoot = Resolve-Sc2Path $Root
    $null = [IO.Directory]::CreateDirectory($fullRoot)
    $path = Join-Path $fullRoot ($Prefix + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = [IO.Directory]::CreateDirectory($path)
    return $path
}

function Get-PublicPlan {
    param($Plan)
    return [pscustomobject]@{ Inputs = $Plan.Inputs; Summary = $Plan.Summary; Targets = @($Plan.Targets | Select-Object Role, Path, BeforeExists, BeforeSha256, BeforeAttributes, CandidateSha256) }
}

function Save-Sc2RepairCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$CandidateDirectory)
    Assert-Sc2Paths $Plan.Inputs.AgentDatabase $Plan.Inputs.CNDirectory $Plan.Inputs.EUDirectory $CandidateDirectory
    $directory = New-ArtifactDirectory $CandidateDirectory 'sc2-candidates'
    foreach ($target in $Plan.Targets) {
        if ($target.Role -notin @('Agent', 'CNProduct', 'EUProduct', 'CNBuild', 'EUBuild')) { throw 'Unexpected candidate role.' }
        [IO.File]::WriteAllBytes((Join-Path $directory ($target.Role + '.candidate')), $target.CandidateBytes)
    }
    [IO.File]::WriteAllText((Join-Path $directory 'plan.json'), ((Get-PublicPlan $Plan) | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ CandidateDirectory = $directory }
}

function Write-MetadataBytes {
    param([string]$Path, [byte[]]$Bytes, [int]$Attributes)
    Assert-NoReparsePath $Path
    $temporary = Join-Path (Split-Path -Parent $Path) ('.sc2-metadata-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if ([IO.File]::Exists($Path)) {
            $currentAttributes = [IO.File]::GetAttributes($Path)
            $writableAttributes = $currentAttributes -band (-bnot ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::ReadOnly))
            [IO.File]::SetAttributes($Path, $writableAttributes)
            try { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
            catch { [IO.File]::SetAttributes($Path, $currentAttributes); throw }
        }
        else { [IO.File]::Move($temporary, $Path) }
        $finalAttributes = if ($Attributes -eq 0) { [IO.FileAttributes]::Hidden } else { [IO.FileAttributes]$Attributes }
        [IO.File]::SetAttributes($Path, $finalAttributes)
        if ((Get-Hash (Read-Database $Path)) -ne (Get-Hash $Bytes)) { throw 'Metadata write hash verification failed.' }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Assert-BackupManifest {
    param($Manifest, [string]$Directory)
    if ($Manifest.SchemaVersion -ne 1) { throw 'Unknown backup manifest version.' }
    Assert-Sc2Paths $Manifest.Inputs.AgentDatabase $Manifest.Inputs.CNDirectory $Manifest.Inputs.EUDirectory $Directory
    $expected = @{
        Agent = Resolve-Sc2Path $Manifest.Inputs.AgentDatabase
        CNProduct = Join-Path $Manifest.Inputs.CNDirectory '.product.db'
        EUProduct = Join-Path $Manifest.Inputs.EUDirectory '.product.db'
        CNBuild = Join-Path $Manifest.Inputs.CNDirectory '.build.info'
        EUBuild = Join-Path $Manifest.Inputs.EUDirectory '.build.info'
    }
    if ($Manifest.Targets.Count -ne 5) { throw 'Backup requires exactly five metadata targets.' }
    $seen = @{}
    foreach ($target in $Manifest.Targets) {
        if (-not $expected.ContainsKey($target.Role) -or $seen.ContainsKey($target.Role) -or
            (Resolve-Sc2Path $target.Path) -ne (Resolve-Sc2Path $expected[$target.Role])) { throw 'Invalid backup target path or role.' }
        $seen[$target.Role] = $true
        Assert-NoReparsePath $target.Path
        if ($target.BeforeExists) {
            $backupPath = Join-Path $Directory ($target.Role + '.original')
            Assert-NoReparsePath $backupPath
            if ((Get-Hash (Read-Database $backupPath)) -ne $target.BeforeSha256) { throw 'Original backup hash verification failed.' }
        }
        $exists = [IO.File]::Exists($target.Path)
        if ($exists) {
            $hash = Get-Hash (Read-Database $target.Path)
            if ($hash -ne $target.CandidateSha256 -and $hash -ne $target.BeforeSha256) {
                throw 'Metadata changed after repair (possibly an official update); refusing to overwrite it during rollback.'
            }
        }
        elseif ($target.BeforeExists) { throw 'An original metadata target is unexpectedly missing.' }
    }
}

function Restore-Sc2RepairBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupDirectory)
    Assert-Sc2Offline
    Assert-NoReparsePath $BackupDirectory
    $manifestPath = Join-Path $BackupDirectory 'manifest.json'
    Assert-NoReparsePath $manifestPath
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    Assert-BackupManifest $manifest $BackupDirectory
    foreach ($target in $manifest.Targets) {
        Assert-Sc2Offline
        if ($target.BeforeExists) {
            Write-MetadataBytes $target.Path (Read-Database (Join-Path $BackupDirectory ($target.Role + '.original'))) $target.BeforeAttributes
        }
        elseif ([IO.File]::Exists($target.Path)) {
            # Delete only the single metadata file created by this repair.
            [IO.File]::SetAttributes($target.Path, [IO.FileAttributes]::Normal)
            [IO.File]::Delete($target.Path)
        }
    }
    return [pscustomobject]@{ Restored = $true; BackupDirectory = Resolve-Sc2Path $BackupDirectory }
}

function Invoke-Sc2RepairPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$BackupDirectory)
    Assert-Sc2Offline
    Assert-Sc2Paths $Plan.Inputs.AgentDatabase $Plan.Inputs.CNDirectory $Plan.Inputs.EUDirectory $BackupDirectory
    # Rebuild from the current files to reject stale or edited plans.
    $freshParameters = @{
        AgentDatabase = $Plan.Inputs.AgentDatabase; CNDirectory = $Plan.Inputs.CNDirectory; EUDirectory = $Plan.Inputs.EUDirectory
    }
    $fresh = New-Sc2RepairPlan @freshParameters
    if ($Plan.Targets.Count -ne 5) { throw 'Repair requires exactly five metadata targets.' }
    for ($index = 0; $index -lt 5; $index++) {
        $old = $Plan.Targets[$index]; $new = $fresh.Targets[$index]
        if ($old.Role -ne $new.Role -or $old.Path -ne $new.Path -or
            $old.BeforeExists -ne $new.BeforeExists -or $old.BeforeSha256 -ne $new.BeforeSha256 -or
            -not (Test-BytesEqual $old.CandidateBytes $new.CandidateBytes)) { throw 'Plan is stale or modified; generate it again.' }
    }
    $directory = New-ArtifactDirectory $BackupDirectory 'sc2-backup'
    $manifest = [pscustomobject]@{ SchemaVersion = 1; Inputs = $fresh.Inputs; Targets = (Get-PublicPlan $fresh).Targets }
    foreach ($target in $fresh.Targets) {
        if ($target.BeforeExists) {
            $bytes = Read-Database $target.Path
            if ((Get-Hash $bytes) -ne $target.BeforeSha256) { throw 'Source changed while taking backups.' }
            $path = Join-Path $directory ($target.Role + '.original')
            [IO.File]::WriteAllBytes($path, $bytes)
            if ((Get-Hash (Read-Database $path)) -ne $target.BeforeSha256) { throw 'Backup hash verification failed.' }
        }
    }
    [IO.File]::WriteAllText((Join-Path $directory 'manifest.json'), ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Assert-BackupManifest $manifest $directory
    try {
        foreach ($target in $fresh.Targets) {
            Assert-Sc2Offline
            $existsNow = [IO.File]::Exists($target.Path)
            if ($existsNow -ne $target.BeforeExists -or
                ($existsNow -and (Get-Hash (Read-Database $target.Path)) -ne $target.BeforeSha256)) {
                throw 'A metadata source changed immediately before replacement.'
            }
            Write-MetadataBytes $target.Path $target.CandidateBytes $target.BeforeAttributes
        }
    }
    catch {
        try { $null = Restore-Sc2RepairBackup $directory }
        catch { throw "Repair failed and automatic rollback could not complete. Keep backup directory: $directory" }
        throw "Repair failed; original metadata was restored. Backup directory: $directory"
    }
    return [pscustomobject]@{ Applied = $true; BackupDirectory = $directory; Summary = $fresh.Summary }
}

function Test-Sc2RepairBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupDirectory)
    Assert-NoReparsePath $BackupDirectory
    $path = Join-Path $BackupDirectory 'manifest.json'
    Assert-NoReparsePath $path
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
    Assert-BackupManifest $manifest $BackupDirectory
    return [pscustomobject]@{ DryRun = $true; Restorable = $true; BackupDirectory = Resolve-Sc2Path $BackupDirectory; Targets = $manifest.Targets }
}

function Get-DirectoryFingerprint {
    param([string]$Directory)
    Assert-NoReparsePath $Directory
    if (-not [IO.Directory]::Exists($Directory)) { throw 'Version directory does not exist.' }
    $root = Resolve-Sc2Path $Directory
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($root)
    $files = @()
    while ($pending.Count) {
        $current = $pending.Pop()
        foreach ($item in Get-ChildItem -Force -LiteralPath $current) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A Versions directory contains a symlink or junction.' }
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            $relative = $item.FullName.Substring($root.Length + 1).Replace('\', '/').ToLowerInvariant()
            $files += [pscustomobject]@{ Relative = $relative; Length = $item.Length; Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant() }
        }
    }
    if ($files.Count -eq 0) { throw 'An empty Base directory cannot confirm copied game files.' }
    $lines = @($files | Sort-Object Relative | ForEach-Object { $_.Relative + '|' + $_.Length + '|' + $_.Hash })
    return Get-Hash ([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))
}

function Get-OfficialEUVersion {
    param($Inputs, [byte[]]$AgentBytes)
    $euRecord = Get-InstallRecord $AgentBytes 's2'
    $eu = Get-Summary $euRecord.Bytes
    if ($eu.Region -ne 'eu' -or (Resolve-Sc2Path $eu.Directory) -ne $Inputs.EUDirectory) { throw 'International Agent metadata must point to the EU directory and eu region.' }
    $euLocalPath = Join-Path $Inputs.EUDirectory '.product.db'
    Assert-NoReparsePath $euLocalPath
    $euLocalRecord = Get-InstallRecord (Read-Database $euLocalPath) 's2'
    $euLocal = Get-Summary $euLocalRecord.Bytes
    if ($euLocal.Region -ne 'eu' -or $euLocal.Version -ne $eu.Version -or (Resolve-Sc2Path $euLocal.Directory) -ne $Inputs.EUDirectory) {
        throw 'EU local and Agent metadata must agree after the official update.'
    }
    $buildInfoPath = Join-Path $Inputs.EUDirectory '.build.info'
    Assert-NoReparsePath $buildInfoPath
    $table = Read-BuildInfo (Read-Database $buildInfoPath)
    $row = Select-BuildRow $euRecord.Bytes $table
    $localRow = Select-BuildRow $euLocalRecord.Bytes $table
    if ($localRow.Values['Build Key'] -ne $row.Values['Build Key']) { throw 'EU local and Agent state select different real EU builds.' }
    if ($row.Values['Branch'] -ne 'eu' -or $row.Values['Active'] -ne '1') { throw 'Official EU build.info must contain the active eu build row.' }
    $key = $row.Values['Build Key'].ToLowerInvariant()
    $configPath = Join-Path $Inputs.EUDirectory ('SC2Data\config\' + $key.Substring(0, 2) + '\' + $key.Substring(2, 2) + '\' + $key)
    Assert-NoReparsePath $configPath
    $buildName = Read-RealBuildName $configPath $eu.Version
    $versionParts = $eu.Version.Split('.')
    return [pscustomobject]@{ Version = $eu.Version; BuildNumber = [long]$versionParts[-1]; BuildKey = $key; BuildConfigPath = $configPath; BuildName = $buildName }
}

function Read-RealBuildName {
    param([string]$ConfigPath, [string]$Version)
    Assert-NoReparsePath $ConfigPath
    $config = ([Text.UTF8Encoding]::new($false, $true)).GetString((Read-Database $ConfigPath))
    $versionParts = $Version.Split('.')
    if ($Version -notmatch '^\d+(?:\.\d+){3}$') { throw 'Installation state has an unsupported version format.' }
    # Regional Windows builds can use B<number>-WIN. Only that observed
    # suffix is accepted; arbitrary text after the build number is refused.
    $names = [regex]::Matches($config, '(?m)^build-name\s*=\s*(B(\d+)(?:-WIN)?|(\d+(?:\.\d+){3}))\s*\r?$')
    if ($names.Count -ne 1) { throw 'The real regional build config needs exactly one supported build-name.' }
    $buildName = $names[0]
    if (($buildName.Groups[2].Success -and [long]$buildName.Groups[2].Value -ne [long]$versionParts[-1]) -or
        ($buildName.Groups[3].Success -and $buildName.Groups[3].Value -ne $Version)) {
        throw 'Real build-name must match the build number in Agent state and build.info.'
    }
    return $buildName.Groups[1].Value
}

function Assert-BaseClient {
    param([string]$BaseDirectory)
    Assert-NoReparsePath $BaseDirectory
    $clients = @('SC2_x64.exe', 'SC2.exe')
    $found = $false
    foreach ($name in $clients) {
        $path = Join-Path $BaseDirectory $name
        Assert-NoReparsePath $path
        if ([IO.File]::Exists($path) -and ([IO.FileInfo]::new($path)).Length -gt 0) { $found = $true }
    }
    if (-not $found) { throw 'The real Base directory needs a nonempty SC2_x64.exe or SC2.exe before version archival or automatic discovery.' }
    return Get-DirectoryFingerprint $BaseDirectory
}

function Get-VerifiedLocalBuild {
    param($AgentRecord, [string]$Directory, [string]$Uid, [string]$Region)
    $summary = Get-Summary $AgentRecord.Bytes
    $localPath = Join-Path $Directory '.product.db'
    Assert-NoReparsePath $localPath
    $localRecord = Get-InstallRecord (Read-Database $localPath) $Uid
    $local = Get-Summary $localRecord.Bytes
    if ($summary.Region -ne $Region -or $local.Region -ne $Region -or $summary.Version -ne $local.Version -or
        (Resolve-Sc2Path $summary.Directory) -ne (Resolve-Sc2Path $Directory) -or
        (Resolve-Sc2Path $local.Directory) -ne (Resolve-Sc2Path $Directory)) { throw 'Local and Agent installation directory/region/version do not agree.' }
    $tablePath = Join-Path $Directory '.build.info'
    Assert-NoReparsePath $tablePath
    $table = Read-BuildInfo (Read-Database $tablePath)
    $row = Select-BuildRow $AgentRecord.Bytes $table
    $localRow = Select-BuildRow $localRecord.Bytes $table
    if ($row.Values['Build Key'] -ne $localRow.Values['Build Key'] -or $row.Values['Branch'] -ne $Region -or $row.Values['Active'] -ne '1') {
        throw 'Local and Agent state must select the same active regional build.'
    }
    $key = $row.Values['Build Key'].ToLowerInvariant()
    $configPath = Join-Path $Directory ('SC2Data\config\' + $key.Substring(0, 2) + '\' + $key.Substring(2, 2) + '\' + $key)
    $name = Read-RealBuildName $configPath $summary.Version
    $number = [long]$summary.Version.Split('.')[-1]
    $null = Assert-BaseClient (Join-Path (Join-Path $Directory 'Versions') ('Base' + $number))
    return [pscustomobject]@{ Version = $summary.Version; BuildKey = $key; BuildName = $name }
}

function Get-Sc2AutoDiscovery {
    [CmdletBinding()]
    param([string]$AgentDatabase = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Battle.net\Agent\product.db'))
    $result = [ordered]@{
        AgentDatabase = $AgentDatabase; CNDirectory = $null; EUDirectory = $null; LauncherPath = $null
        Status = 'Unsupported'; Reason = ''; CNVersion = $null; EUVersion = $null; CNBuildKey = $null; EUBuildKey = $null
    }
    try {
        $result.AgentDatabase = Resolve-Sc2Path $AgentDatabase
        Assert-NoReparsePath $result.AgentDatabase
        if ((Split-Path -Leaf $result.AgentDatabase) -ne 'product.db') { throw 'AgentDatabase must be product.db.' }
        $agentBytes = Read-Database $result.AgentDatabase
        $cnRecord = Get-InstallRecord $agentBytes 's2_cn'
        $euRecord = Get-InstallRecord $agentBytes 's2'
        $launcherRecord = Get-InstallRecord $agentBytes 'battle.net'
        $launcherMessage = Read-Message $launcherRecord.Bytes
        $launcherSettings = Read-Message (Get-Field $launcherMessage 3 -Required).Payload
        $launcherDirectory = Resolve-Sc2Path (Get-Text (Get-Field $launcherSettings 1 -Required))
        Assert-NoReparsePath $launcherDirectory
        foreach ($name in @('Battle.net Launcher.exe', 'Battle.net.exe')) {
            $path = Join-Path $launcherDirectory $name
            Assert-NoReparsePath $path
            if ([IO.File]::Exists($path) -and ([IO.FileInfo]::new($path)).Length -gt 0) { $result.LauncherPath = $path; break }
        }
        if (-not $result.LauncherPath) { throw 'No Battle.net launcher executable found in the registered launcher directory.' }
        $cn = Get-Summary $cnRecord.Bytes; $eu = Get-Summary $euRecord.Bytes
        $result.CNDirectory = Resolve-Sc2Path $cn.Directory
        $registeredEU = Resolve-Sc2Path $eu.Directory
        $result.CNVersion = $cn.Version; $result.EUVersion = $eu.Version
        if ($cn.Region -ne 'cn') { throw 'The CN Agent installation must use cn region.' }
        Assert-EUGameCopy $result.CNDirectory
        $verifiedCN = Get-VerifiedLocalBuild $cnRecord $result.CNDirectory 's2_cn' 'cn'
        $result.CNBuildKey = $verifiedCN.BuildKey
        if ($registeredEU -eq $result.CNDirectory -and $eu.Region -eq 'cn') {
            # Refuse ambiguous/foreign local registrations before an automatic
            # caller can create or copy the large game directory.
            $null = Get-ValidatedCNLocalContainer (Read-Database (Join-Path $result.CNDirectory '.product.db'))
            $result.EUDirectory = Join-Path (Split-Path -Parent $result.CNDirectory) ((Split-Path -Leaf $result.CNDirectory) + ' EU')
            Assert-Sc2Paths $result.AgentDatabase $result.CNDirectory $result.EUDirectory
            if ([IO.File]::Exists($result.EUDirectory) -or [IO.Directory]::Exists($result.EUDirectory)) {
                throw 'The proposed unregistered EU path already exists; automatic copying requires a new destination owned by this run.'
            }
            # Confirm that the old international state has one truthful source
            # build row before copying; the row is not relabeled as eu.
            $sourceTable = Read-BuildInfo (Read-Database (Join-Path $result.CNDirectory '.build.info'))
            $oldEuRow = Select-BuildRow $euRecord.Bytes $sourceTable
            $result.EUBuildKey = $oldEuRow.Values['Build Key']
            $result.Status = 'Conflict'; $result.Reason = 'Both formal products share the CN directory and the international record is still cn.'
        }
        elseif ($registeredEU -ne $result.CNDirectory -and $eu.Region -eq 'eu') {
            $result.EUDirectory = $registeredEU
            Assert-Sc2Paths $result.AgentDatabase $result.CNDirectory $result.EUDirectory
            Assert-EUGameCopy $result.EUDirectory
            $verifiedEU = Get-VerifiedLocalBuild $euRecord $result.EUDirectory 's2' 'eu'
            $result.EUBuildKey = $verifiedEU.BuildKey
            $result.Status = 'Separated'; $result.Reason = 'Separate CN and EU directories agree with their local metadata, active build rows, real build-name, and Base client.'
        }
        else { throw 'Only a shared cn conflict or a verified separate cn/eu pair can be handled automatically.' }
    }
    catch { $result.Status = 'Unsupported'; $result.Reason = $_.Exception.Message }
    return [pscustomobject]$result
}

function Get-Sc2VersionMaintenancePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AgentDatabase, [Parameter(Mandatory)][string]$CNDirectory, [Parameter(Mandatory)][string]$EUDirectory)
    Assert-Sc2Paths $AgentDatabase $CNDirectory $EUDirectory
    $inputs = [pscustomobject]@{ AgentDatabase = Resolve-Sc2Path $AgentDatabase; CNDirectory = Resolve-Sc2Path $CNDirectory; EUDirectory = Resolve-Sc2Path $EUDirectory }
    $agentBytes = Read-Database $inputs.AgentDatabase
    $official = Get-OfficialEUVersion $inputs $agentBytes
    $cn = Get-Summary (Get-InstallRecord $agentBytes 's2_cn').Bytes
    $cnLocalPath = Join-Path $inputs.CNDirectory '.product.db'
    Assert-NoReparsePath $cnLocalPath
    $cnLocal = Get-Summary (Get-InstallRecord (Read-Database $cnLocalPath) 's2_cn').Bytes
    if ($cn.Region -ne 'cn' -or $cnLocal.Region -ne 'cn' -or $cn.Version -ne $cnLocal.Version -or
        (Resolve-Sc2Path $cn.Directory) -ne $inputs.CNDirectory -or (Resolve-Sc2Path $cnLocal.Directory) -ne $inputs.CNDirectory -or
        $cn.Version -notmatch '^\d+(?:\.\d+){3}$') { throw 'CN local and Agent metadata must agree before confirming a copied CN version.' }
    $cnNumber = [long]$cn.Version.Split('.')[-1]
    $euVersions = Join-Path $inputs.EUDirectory 'Versions'
    $cnVersions = Join-Path $inputs.CNDirectory 'Versions'
    Assert-NoReparsePath $euVersions
    Assert-NoReparsePath $cnVersions
    $officialBase = Join-Path $euVersions ('Base' + $official.BuildNumber)
    if (-not [IO.Directory]::Exists($officialBase)) { throw 'The real EU Base directory must exist before archiving any other version.' }
    $official | Add-Member -MemberType NoteProperty -Name BaseFingerprint -Value (Assert-BaseClient $officialBase)
    $candidates = @(foreach ($directory in Get-ChildItem -Force -Directory -LiteralPath $euVersions) {
        if ($directory.Name -notmatch '^Base(\d+)$') { continue }
        Assert-NoReparsePath $directory.FullName
        $number = [long]$Matches[1]
        if ($number -le $official.BuildNumber) { continue }
        $source = Join-Path $cnVersions $directory.Name
        $eligible = $false; $fingerprint = $null
        $reason = 'This higher version is not confirmed as the CN installation build.'
        if ($number -eq $cnNumber -and [IO.Directory]::Exists($source)) {
            $cnFingerprint = Get-DirectoryFingerprint $source
            $euFingerprint = Get-DirectoryFingerprint $directory.FullName
            if ($cnFingerprint -eq $euFingerprint) { $eligible = $true; $fingerprint = $euFingerprint; $reason = 'Same build number as CN installation state and identical relative files/content to CN Base.' }
            else { $reason = 'CN and EU Base contents differ; manual review is required.' }
        }
        [pscustomobject]@{ Name = $directory.Name; BuildNumber = $number; Path = $directory.FullName; CNSourcePath = $source; Eligible = $eligible; Fingerprint = $fingerprint; Reason = $reason }
    })
    return [pscustomobject]@{ Inputs = $inputs; OfficialEU = $official; CNVersion = $cn.Version; Candidates = $candidates; MoveCandidates = @($candidates | Where-Object Eligible); NoAutomaticDeletion = $true }
}

function Move-Sc2CopiedCNVersions {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$BackupDirectory)
    Assert-Sc2Offline
    Assert-Sc2Paths $Plan.Inputs.AgentDatabase $Plan.Inputs.CNDirectory $Plan.Inputs.EUDirectory $BackupDirectory
    $freshParameters = @{
        AgentDatabase = $Plan.Inputs.AgentDatabase; CNDirectory = $Plan.Inputs.CNDirectory; EUDirectory = $Plan.Inputs.EUDirectory
    }
    $fresh = Get-Sc2VersionMaintenancePlan @freshParameters
    if (($fresh | ConvertTo-Json -Depth 8 -Compress) -ne ($Plan | ConvertTo-Json -Depth 8 -Compress)) { throw 'Version maintenance plan is stale or modified.' }
    if (-not $fresh.MoveCandidates.Count) { return [pscustomobject]@{ Moved = 0; ArchiveDirectory = $null } }
    if ([IO.Path]::GetPathRoot((Resolve-Sc2Path $BackupDirectory)) -ne [IO.Path]::GetPathRoot($Plan.Inputs.EUDirectory)) {
        throw 'Choose an archive directory on the EU drive so directory moves do not become copy-and-delete operations.'
    }
    $archive = New-ArtifactDirectory $BackupDirectory 'sc2-versions-archive'
    $moves = @($fresh.MoveCandidates | ForEach-Object { [pscustomobject]@{ OriginalPath = $_.Path; ArchivePath = Join-Path $archive $_.Name; Fingerprint = $_.Fingerprint } })
    $manifest = [pscustomobject]@{ SchemaVersion = 1; Mode = 'VerifiedCopiedCNAfterOfficialUpdate'; Inputs = $fresh.Inputs; OfficialEU = $fresh.OfficialEU; Moves = $moves }
    [IO.File]::WriteAllText((Join-Path $archive 'archive.json'), ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    foreach ($move in $moves) {
        Assert-Sc2Offline
        if ((Get-DirectoryFingerprint $move.OriginalPath) -ne $move.Fingerprint) { throw 'Version files changed immediately before archival.' }
        [IO.Directory]::Move($move.OriginalPath, $move.ArchivePath)
        if ((Get-DirectoryFingerprint $move.ArchivePath) -ne $move.Fingerprint) { throw 'Archived directory fingerprint mismatch; preserve the archive for review.' }
    }
    return [pscustomobject]@{ Moved = $moves.Count; ArchiveDirectory = $archive }
}

function Restore-Sc2VersionsArchive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchiveDirectory)
    Assert-Sc2Offline
    Assert-NoReparsePath $ArchiveDirectory
    $manifestPath = Join-Path $ArchiveDirectory 'archive.json'
    Assert-NoReparsePath $manifestPath
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    if ($manifest.SchemaVersion -ne 1) { throw 'Unknown archive manifest version.' }
    $modeProperty = $manifest.PSObject.Properties['Mode']
    $mode = if ($null -ne $modeProperty) { [string]$modeProperty.Value } else { $null }
    $moveCount = @($manifest.Moves).Count
    if ($null -ne $modeProperty -and $mode -notin @('NewEUCopyBeforeOfficialUpdate', 'VerifiedCopiedCNAfterOfficialUpdate')) {
        throw 'Unknown version archive mode.'
    }
    if ($moveCount -lt 1 -or ($mode -eq 'NewEUCopyBeforeOfficialUpdate' -and $moveCount -gt 128) -or
        ($mode -ne 'NewEUCopyBeforeOfficialUpdate' -and $moveCount -gt 1)) {
        throw 'Only the known pre-update EU-copy mode permits multiple Base directories (maximum 128).'
    }
    Assert-Sc2Paths $manifest.Inputs.AgentDatabase $manifest.Inputs.CNDirectory $manifest.Inputs.EUDirectory $ArchiveDirectory
    $versionsPath = Resolve-Sc2Path (Join-Path $manifest.Inputs.EUDirectory 'Versions')
    $originalPaths = @{}; $archivePaths = @{}
    foreach ($move in $manifest.Moves) {
        Assert-NoReparsePath $move.OriginalPath; Assert-NoReparsePath $move.ArchivePath
        $name = Split-Path -Leaf $move.OriginalPath
        if ($name -notmatch '^Base\d+$' -or (Resolve-Sc2Path (Split-Path -Parent $move.OriginalPath)) -ne $versionsPath -or
            (Resolve-Sc2Path $move.ArchivePath) -ne (Resolve-Sc2Path (Join-Path $ArchiveDirectory $name))) { throw 'Invalid archive target path.' }
        $originalFullPath = Resolve-Sc2Path $move.OriginalPath
        $archiveFullPath = Resolve-Sc2Path $move.ArchivePath
        if ($originalPaths.ContainsKey($originalFullPath) -or $archivePaths.ContainsKey($archiveFullPath)) { throw 'Duplicate version archive target path.' }
        $originalPaths[$originalFullPath] = $true; $archivePaths[$archiveFullPath] = $true
        if ([IO.Directory]::Exists($move.OriginalPath) -or [IO.File]::Exists($move.OriginalPath)) { throw 'A version exists at the restore path; refusing to overwrite it.' }
        if ((Get-DirectoryFingerprint $move.ArchivePath) -ne $move.Fingerprint) { throw 'Archive content changed; refusing to restore it.' }
    }
    foreach ($move in $manifest.Moves) { Assert-Sc2Offline; [IO.Directory]::Move($move.ArchivePath, $move.OriginalPath) }
    return [pscustomobject]@{ Restored = $manifest.Moves.Count; ArchiveDirectory = Resolve-Sc2Path $ArchiveDirectory }
}

Export-ModuleMember -Function Get-Sc2InstallationReport, New-Sc2RepairPlan, Save-Sc2RepairCandidates, Invoke-Sc2RepairPlan, Restore-Sc2RepairBackup, Test-Sc2RepairBackup, Get-Sc2VersionMaintenancePlan, Move-Sc2CopiedCNVersions, Restore-Sc2VersionsArchive, Get-Sc2AutoDiscovery
