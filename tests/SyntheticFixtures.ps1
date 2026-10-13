Set-StrictMode -Version Latest

function Join-FixtureBytes {
    param([object[]]$Chunks)
    $stream = [IO.MemoryStream]::new()
    try {
        foreach ($chunk in $Chunks) {
            if ($null -ne $chunk) {
                $data = [byte[]]$chunk
                $stream.Write($data, 0, $data.Length)
            }
        }
        return ,$stream.ToArray()
    } finally { $stream.Dispose() }
}

function ConvertTo-FixtureVarint {
    param([UInt64]$Value)
    $result = [Collections.Generic.List[byte]]::new()
    do {
        $part = [byte]($Value -band 127)
        $Value = $Value -shr 7
        if ($Value -gt 0) { $part = [byte]($part -bor 128) }
        $result.Add($part)
    } while ($Value -gt 0)
    return ,$result.ToArray()
}

function New-FixtureField {
    param([int]$Number, [byte[]]$Bytes, [int]$Wire = 2)
    $tag = ConvertTo-FixtureVarint ([UInt64](($Number -shl 3) -bor $Wire))
    if ($Wire -eq 2) {
        return ,(Join-FixtureBytes @($tag, (ConvertTo-FixtureVarint $Bytes.Length), $Bytes))
    }
    return ,(Join-FixtureBytes @($tag, $Bytes))
}

function New-FixtureTextField {
    param([int]$Number, [string]$Text)
    return ,(New-FixtureField $Number ([Text.Encoding]::UTF8.GetBytes($Text)))
}

function New-FixtureUnknownBytes {
    param([int]$Base = 30)
    # 81 00 encodes 1 using a noncanonical, valid varint. It must remain byte-identical.
    return ,(Join-FixtureBytes @(
        (New-FixtureField $Base ([byte[]]@(0x81, 0x00)) 0),
        (New-FixtureField ($Base + 1) ([byte[]]@(17, 29, 43, 59, 71, 83, 97, 109)) 1),
        (New-FixtureTextField ($Base + 2) "synthetic-unknown-$Base"),
        (New-FixtureField ($Base + 3) ([byte[]]@(113, 127, 131, 137)) 5)
    ))
}

function New-FixtureProduct {
    param(
        [string]$Uid,
        [string]$Directory,
        [string]$Region,
        [string]$Version,
        [string]$BuildKey,
        [string]$CdnKey,
        [string]$Code = $Uid
    )
    $settingsUnknown = New-FixtureUnknownBytes 40
    $stateUnknown = New-FixtureUnknownBytes 50
    $productUnknown = New-FixtureUnknownBytes 60
    $settings = Join-FixtureBytes @(
        $settingsUnknown,
        (New-FixtureTextField 1 $Directory),
        (New-FixtureTextField 2 $Region)
    )
    $state = Join-FixtureBytes @(
        (New-FixtureTextField 7 $Version),
        (New-FixtureTextField 12 $BuildKey),
        $stateUnknown,
        (New-FixtureTextField 14 $CdnKey)
    )
    $record = Join-FixtureBytes @(
        (New-FixtureTextField 1 $Uid),
        $productUnknown,
        (New-FixtureTextField 2 $Code),
        (New-FixtureField 3 $settings),
        (New-FixtureField 4 (New-FixtureField 1 $state)),
        (New-FixtureTextField 6 's2')
    )
    return ,$record
}

function New-FixtureDatabase {
    param([object[]]$Records)
    $chunks = [Collections.Generic.List[object]]::new()
    $chunks.Add((New-FixtureUnknownBytes 20))
    foreach ($record in $Records) { $chunks.Add((New-FixtureField 1 ([byte[]]$record))) }
    $chunks.Add((New-FixtureTextField 29 'synthetic-wrapper-tail'))
    return ,(Join-FixtureBytes $chunks.ToArray())
}

function New-FixtureKey { return [Guid]::NewGuid().ToString('N') }

function Write-FixtureBytes {
    param([string]$Path, [byte[]]$Bytes)
    $parent = [IO.Path]::GetDirectoryName($Path)
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $beforeAttributes = $null
    if ([IO.File]::Exists($Path)) {
        $beforeAttributes = [IO.File]::GetAttributes($Path)
        [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal)
    }
    try { [IO.File]::WriteAllBytes($Path, $Bytes) }
    finally {
        if ($null -ne $beforeAttributes -and [IO.File]::Exists($Path)) { [IO.File]::SetAttributes($Path, $beforeAttributes) }
    }
}

function Write-FixtureText {
    param([string]$Path, [string]$Text)
    Write-FixtureBytes $Path ([Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function New-FixtureBuildInfo {
    param(
        [string]$CNKey,
        [string]$CNCDNKey,
        [string]$EUKey,
        [string]$EUCDNKey,
        [string]$CNVersion = '5.0.17.51029',
        [string]$EUVersion = '5.0.14.50913',
        [switch]$Reordered
    )
    $columns = @('Branch', 'Active', 'Build Key', 'CDN Key', 'Version', 'CDN Hosts', 'Extra')
    if ($Reordered) { $columns = @('Extra', 'Version', 'CDN Key', 'Active', 'Branch', 'CDN Hosts', 'Build Key') }
    $types = @{ Branch = 'STRING:0'; Active = 'DEC:1'; 'Build Key' = 'HEX:16'; 'CDN Key' = 'HEX:16'; Version = 'STRING:0'; 'CDN Hosts' = 'STRING:0'; Extra = 'STRING:0' }
    $rows = @(
        @{ Branch = 'cn'; Active = '1'; 'Build Key' = $CNKey; 'CDN Key' = $CNCDNKey; Version = $CNVersion; 'CDN Hosts' = 'synthetic-cn.invalid'; Extra = 'keep CN extra' },
        @{ Branch = 'cn'; Active = '1'; 'Build Key' = $EUKey; 'CDN Key' = $EUCDNKey; Version = $EUVersion; 'CDN Hosts' = 'synthetic-eu.invalid'; Extra = 'keep EU extra' },
        @{ Branch = 'eu'; Active = '0'; 'Build Key' = (New-FixtureKey); 'CDN Key' = (New-FixtureKey); Version = '5.0.12.50807'; 'CDN Hosts' = 'inactive.invalid'; Extra = 'inactive extra' }
    )
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add((($columns | ForEach-Object { "$_!$($types[$_])" }) -join '|'))
    foreach ($row in $rows) { $lines.Add((($columns | ForEach-Object { $row[$_] }) -join '|')) }
    return ($lines -join "`r`n") + "`r`n"
}

function New-SyntheticInstallation {
    param([string]$Root, [switch]$Reordered, [switch]$Hidden, [switch]$Separated)
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    $unicodeSuffix = ([char]0x6E38).ToString() + ([char]0x620F).ToString()
    $cn = Join-Path $Root ('CN ' + $unicodeSuffix)
    $eu = Join-Path $Root ('EU ' + $unicodeSuffix)
    [IO.Directory]::CreateDirectory($cn) | Out-Null
    [IO.Directory]::CreateDirectory($eu) | Out-Null
    foreach ($gameDirectory in @($cn, $eu)) {
        Write-FixtureText (Join-Path $gameDirectory 'StarCraft II.exe') 'synthetic marker only; never execute this file'
        Write-FixtureText (Join-Path $gameDirectory 'SC2Data\synthetic.data') 'synthetic installed data marker'
        [IO.Directory]::CreateDirectory((Join-Path $gameDirectory 'Versions')) | Out-Null
    }
    $agent = Join-Path $Root 'Agent synthetic\product.db'
    $cnkey = New-FixtureKey
    $eukey = New-FixtureKey
    $cncdn = New-FixtureKey
    $eucdn = New-FixtureKey
    $cnVersion = '5.0.17.51029'
    $euVersion = '5.0.14.50913'
    $cnRecord = New-FixtureProduct 's2_cn' ($cn -replace '\\', '/') 'cn' $cnVersion $cnkey $cncdn
    $euOriginalDirectory = $cn
    $euOriginalRegion = 'cn'
    if ($Separated) { $euOriginalDirectory = $eu; $euOriginalRegion = 'eu' }
    $euRecord = New-FixtureProduct 's2' ($euOriginalDirectory -replace '\\', '/') $euOriginalRegion $euVersion $eukey $eucdn
    $ptrRecord = New-FixtureProduct 's2t' ((Join-Path $Root 'PTR') -replace '\\', '/') 'eu' '5.0.17.51007' (New-FixtureKey) (New-FixtureKey)
    $otherRecord = New-FixtureProduct 'synthetic_other' ((Join-Path $Root 'Other') -replace '\\', '/') 'eu' '1.2.3' (New-FixtureKey) (New-FixtureKey) 'other'
    Write-FixtureBytes $agent (New-FixtureDatabase @($cnRecord, $euRecord, $ptrRecord, $otherRecord))
    $cnRecords = @($cnRecord, $euRecord)
    if ($Separated) { $cnRecords = ,$cnRecord }
    Write-FixtureBytes (Join-Path $cn '.product.db') (New-FixtureDatabase $cnRecords)
    $buildInfo = New-FixtureBuildInfo $cnkey $cncdn $eukey $eucdn -Reordered:$Reordered
    Write-FixtureText (Join-Path $cn '.build.info') $buildInfo
    if ($Separated) {
        Write-FixtureBytes (Join-Path $eu '.product.db') $euRecord
        # Retain only the EU active row and mark its selected branch eu.
        $lines = $buildInfo -split '\r?\n'
        $columns = ($lines[0] -split '\|') | ForEach-Object { ($_ -split '!')[0] }
        $branchIndex = [Array]::IndexOf($columns, 'Branch')
        $euCells = $lines[2] -split '\|'
        $euCells[$branchIndex] = 'eu'
        Write-FixtureText (Join-Path $eu '.build.info') ($lines[0] + "`r`n" + ($euCells -join '|') + "`r`n")
    }
    if ($Hidden) {
        foreach ($path in @((Join-Path $cn '.product.db'), (Join-Path $cn '.build.info'))) {
            [IO.File]::SetAttributes($path, [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)
        }
    }
    return [pscustomobject]@{
        Root = $Root; CNDirectory = $cn; EUDirectory = $eu; AgentDatabase = $agent
        CNRecord = $cnRecord; EURecord = $euRecord; PTRRecord = $ptrRecord; OtherRecord = $otherRecord
        CNKey = $cnkey; EUKey = $eukey; CNCDNKey = $cncdn; EUCDNKey = $eucdn
        CNVersion = $cnVersion; EUVersion = $euVersion
        Paths = @($agent, (Join-Path $cn '.product.db'), (Join-Path $eu '.product.db'), (Join-Path $cn '.build.info'), (Join-Path $eu '.build.info'))
    }
}

function New-FixtureVersion {
    param([string]$Directory, [string]$Name, [string]$Marker)
    $base = Join-Path (Join-Path $Directory 'Versions') $Name
    Write-FixtureText (Join-Path $base 'nested\SC2.synthetic') $Marker
    Write-FixtureText (Join-Path $base 'client.synthetic') "synthetic executable $Marker"
    Write-FixtureText (Join-Path $base 'SC2_x64.exe') "synthetic marker only; never execute $Marker"
    return $base
}

function Write-FixtureBuildConfig {
    param([string]$Directory, [string]$Key, [string]$Version, [switch]$FullVersion, [switch]$WinSuffix)
    $configPath = Join-Path $Directory ("SC2Data/config/{0}/{1}/{2}" -f $Key.Substring(0, 2), $Key.Substring(2, 2), $Key)
    $buildName = 'B' + $Version.Split('.')[-1]
    if ($FullVersion) { $buildName = $Version }
    if ($WinSuffix) {
        if ($FullVersion) { throw 'The WIN fixture suffix belongs only to B-number names.' }
        $buildName += '-WIN'
    }
    Write-FixtureText $configPath ("# Synthetic fixture; never a real game file.`r`nbuild-name = $buildName`r`n")
    return $configPath
}

function New-SyntheticVersions {
    param([string]$Root)
    $fixture = New-SyntheticInstallation $Root -Separated
    Write-FixtureBuildConfig $fixture.EUDirectory $fixture.EUKey $fixture.EUVersion | Out-Null
    Write-FixtureBuildConfig $fixture.CNDirectory $fixture.CNKey $fixture.CNVersion -WinSuffix | Out-Null
    New-FixtureVersion $fixture.CNDirectory 'Base51029' 'identical CN copied content' | Out-Null
    New-FixtureVersion $fixture.EUDirectory 'Base51029' 'identical CN copied content' | Out-Null
    New-FixtureVersion $fixture.EUDirectory 'Base50913' 'current EU content' | Out-Null
    New-FixtureVersion $fixture.CNDirectory 'Base50807' 'older CN content' | Out-Null
    New-FixtureVersion $fixture.EUDirectory 'Base50807' 'older CN content' | Out-Null
    New-FixtureVersion $fixture.EUDirectory 'Base51999' 'unrelated high content' | Out-Null
    New-FixtureVersion $fixture.EUDirectory 'BasePreview' 'nonnumeric content' | Out-Null
    return $fixture
}
