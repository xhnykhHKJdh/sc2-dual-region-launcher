[CmdletBinding()]
param([switch]$KeepFixtures)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\Start-SC2DualRegion.ps1')
. (Join-Path $PSScriptRoot 'SyntheticFixtures.ps1')
$testCore = Get-Module Sc2Metadata
& $testCore { function script:Get-Process { } }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sc2-oneclick-tests-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($testRoot)
$script:results = [Collections.Generic.List[object]]::new()
$script:caseIndex = 0
$script:originalFunctions = @{}
foreach ($name in @('Get-OneClickDiscovery','Get-OneClickProcesses','Get-OneClickAvailableSpace','Invoke-OneClickRobocopy','Ensure-OneClickShortcuts','Start-OneClickEU','Get-OneClickDesktop','Read-OneClickShortcut','Get-OneClickConfigPath','Move-OneClickDirectory')) {
    $script:originalFunctions[$name] = (Get-Item ('Function:' + $name)).ScriptBlock
}

function Assert-OC([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-OCRejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-OC $rejected $Message
}
function Reset-OCMocks {
    foreach ($name in $script:originalFunctions.Keys) { Set-Item -Path ('Function:script:' + $name) -Value $script:originalFunctions[$name] }
    function script:Get-OneClickProcesses { }
    function script:Get-OneClickAvailableSpace { return [long]10TB }
    $script:shortcutCalls = 0; $script:launchCalls = 0
}
function New-OCFixture([switch]$Separated, [switch]$SameBuild) {
    $script:caseIndex++
    $root = Join-Path $testRoot ('case-' + $script:caseIndex)
    $fixture = New-SyntheticInstallation $root -Separated:$Separated
    if ($SameBuild) {
        $fixture.EURecord = New-FixtureProduct 's2' $fixture.CNDirectory 'cn' $fixture.CNVersion $fixture.CNKey $fixture.CNCDNKey
        $fixture.EUVersion = $fixture.CNVersion
        Write-FixtureBytes (Join-Path $fixture.CNDirectory '.product.db') (New-FixtureDatabase @($fixture.CNRecord,$fixture.EURecord))
    }
    Write-FixtureBuildConfig $fixture.CNDirectory $fixture.CNKey $fixture.CNVersion | Out-Null
    New-FixtureVersion $fixture.CNDirectory ('Base' + $fixture.CNVersion.Split('.')[-1]) 'synthetic current CN' | Out-Null
    if ($Separated) {
        Write-FixtureBuildConfig $fixture.EUDirectory $fixture.EUKey $fixture.EUVersion | Out-Null
        New-FixtureVersion $fixture.EUDirectory ('Base' + $fixture.EUVersion.Split('.')[-1]) 'synthetic current EU' | Out-Null
    }
    $launcherDirectory = Join-Path $root 'Official launcher synthetic'
    Write-FixtureText (Join-Path $launcherDirectory 'Battle.net Launcher.exe') 'synthetic launcher; never execute'
    $launcherRecord = New-FixtureProduct 'battle.net' $launcherDirectory 'eu' '2.0.0.12345' (New-FixtureKey) (New-FixtureKey)
    Write-FixtureBytes $fixture.AgentDatabase (New-FixtureDatabase @($fixture.CNRecord,$fixture.EURecord,$fixture.PTRRecord,$fixture.OtherRecord,$launcherRecord))
    $fixture | Add-Member -MemberType NoteProperty -Name LauncherRecord -Value $launcherRecord
    return $fixture
}
function Set-OCInternationalRegions($Fixture,[string]$AgentRegion,[string]$LocalRegion,[string]$BuildBranch) {
    $agentRecord=New-FixtureProduct 's2' $Fixture.EUDirectory $AgentRegion $Fixture.EUVersion $Fixture.EUKey $Fixture.EUCDNKey
    $localRecord=New-FixtureProduct 's2' $Fixture.EUDirectory $LocalRegion $Fixture.EUVersion $Fixture.EUKey $Fixture.EUCDNKey
    Write-FixtureBytes $Fixture.AgentDatabase (New-FixtureDatabase @($Fixture.CNRecord,$agentRecord,$Fixture.PTRRecord,$Fixture.OtherRecord,$Fixture.LauncherRecord))
    Write-FixtureBytes (Join-Path $Fixture.EUDirectory '.product.db') $localRecord
    $buildPath=Join-Path $Fixture.EUDirectory '.build.info'
    $lines=@(([IO.File]::ReadAllText($buildPath) -split '\r?\n')|Where-Object {$_})
    $columns=@(($lines[0] -split '\|')|ForEach-Object {($_ -split '!')[0]})
    $branchIndex=[Array]::IndexOf($columns,'Branch')
    $activeIndex=[Array]::IndexOf($columns,'Active')
    Assert-OC ($branchIndex -ge 0 -and $activeIndex -ge 0) 'Synthetic build table needs named branch and active columns'
    $activeRows=0
    for($i=1;$i -lt $lines.Count;$i++) {
        $cells=$lines[$i] -split '\|'
        if($cells[$activeIndex] -eq '1') {$cells[$branchIndex]=$BuildBranch;$activeRows++}
        $lines[$i]=$cells -join '|'
    }
    Assert-OC ($activeRows -eq 1) 'Synthetic international fixture must have one active row'
    Write-FixtureText $buildPath (($lines -join "`r`n")+"`r`n")
}
function Get-OCFixtureFingerprint($Fixture) {Get-OneClickTreeSignature @(Get-OneClickTree $Fixture.Root -Hash) -Hash}
function Set-OCDiscovery($Fixture) {
    $script:fixtureAgent = $Fixture.AgentDatabase
    function script:Get-OneClickDiscovery { Get-Sc2AutoDiscovery -AgentDatabase $script:fixtureAgent }
}
function Set-OCSafeCopy {
    function script:Invoke-OneClickRobocopy([string]$Source,[string]$Destination) {
        foreach ($file in Get-OneClickTree $Source) {
            $from = Join-Path $Source $file.Relative
            $to = Join-Path $Destination $file.Relative
            Write-FixtureBytes $to ([IO.File]::ReadAllBytes($from))
        }
        # Keep empty ordinary folders too, as robocopy /E does.
        foreach ($directory in Get-ChildItem -Force -Directory -Recurse -LiteralPath $Source) {
            $relative = $directory.FullName.Substring((Get-OneClickFullPath $Source).Length + 1)
            [IO.Directory]::CreateDirectory((Join-Path $Destination $relative)) | Out-Null
        }
    }
}
function Test-OC([string]$Name,[scriptblock]$Action) {
    Reset-OCMocks
    try { & $Action; $script:results.Add([pscustomobject]@{ Name=$Name; Passed=$true }); Write-Host ('PASS ' + $Name) }
    catch { $script:results.Add([pscustomobject]@{ Name=$Name; Passed=$false }); Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}

try {
    Test-OC 'automatic conflict discovery uses registered launcher and sibling EU directory' {
        $f=New-OCFixture; $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase
        Assert-OC ($d.Status -eq 'Conflict') ('Expected Conflict: ' + $d.Reason)
        Assert-OC ($d.CNDirectory -eq $f.CNDirectory) 'CN path was not discovered'
        Assert-OC ($d.EUDirectory -eq ($f.CNDirectory + ' EU')) 'EU sibling name is wrong'
        Assert-OC ($d.LauncherPath -eq (Join-Path $f.Root 'Official launcher synthetic\Battle.net Launcher.exe')) 'Launcher was not discovered'
        Assert-OC (-not [IO.Directory]::Exists($d.EUDirectory)) 'Discovery must not create a folder'
    }
    Test-OC 'unknown existing EU candidate rejects automatic discovery and execution' {
        $f=New-OCFixture; $candidate=$f.CNDirectory + ' EU'; Write-FixtureText (Join-Path $candidate 'unknown.synthetic') 'unknown installation'
        $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase
        Assert-OC ($d.Status -eq 'Unsupported') 'Unknown existing copy must reject'
        Set-OCDiscovery $f
        Assert-OCRejected { Invoke-SC2DualRegionOneClick -Run } 'Unknown copy must reject execution'
        Assert-OC ((Get-Content -LiteralPath (Join-Path $candidate 'unknown.synthetic') -Raw) -eq 'unknown installation') 'Unknown copy was changed'
    }
    Test-OC 'unknown third CN-local product rejects before copying or launching' {
        $f=New-OCFixture; Set-OCDiscovery $f
        Write-FixtureBytes (Join-Path $f.CNDirectory '.product.db') (New-FixtureDatabase @($f.CNRecord,$f.EURecord,$f.OtherRecord))
        function script:Start-OneClickEU { throw 'Unsupported discovery tried to launch' }
        Assert-OC ((Get-OneClickDiscovery).Status -eq 'Unsupported') 'Unknown CN-local product must reject discovery'
        Assert-OCRejected { Invoke-SC2DualRegionOneClick -Run } 'Unknown CN-local product must reject execution'
        Assert-OC (-not [IO.Directory]::Exists(($f.CNDirectory + ' EU'))) 'Unsupported CN product triggered a copy'
    }
    Test-OC 'duplicate CN-local s2 rejects before copying or launching' {
        $f=New-OCFixture; Set-OCDiscovery $f
        Write-FixtureBytes (Join-Path $f.CNDirectory '.product.db') (New-FixtureDatabase @($f.CNRecord,$f.EURecord,$f.EURecord))
        function script:Start-OneClickEU { throw 'Unsupported discovery tried to launch' }
        Assert-OC ((Get-OneClickDiscovery).Status -eq 'Unsupported') 'Duplicate CN-local s2 must reject discovery'
        Assert-OCRejected { Invoke-SC2DualRegionOneClick -Run } 'Duplicate CN-local s2 must reject execution'
        Assert-OC (-not [IO.Directory]::Exists(($f.CNDirectory + ' EU'))) 'Duplicate CN-local s2 triggered a copy'
    }
    Test-OC 'default entry is a read-only preview' {
        $f=New-OCFixture; Set-OCDiscovery $f
        function script:Ensure-OneClickShortcuts { throw 'Preview tried to write a shortcut' }
        function script:Start-OneClickEU { throw 'Preview tried to launch' }
        $d=Invoke-SC2DualRegionOneClick
        Assert-OC ($d.Status -eq 'Conflict') 'Preview did not return discovery'
        Assert-OC (-not [IO.Directory]::Exists($d.EUDirectory)) 'Preview created an EU directory'
        Assert-OC (-not [IO.Directory]::Exists((Join-Path $f.Root '.sc2-dual-region-backups'))) 'Preview created backups'
    }
    Test-OC 'running game blocks conflict without killing or copying' {
        $f=New-OCFixture; Set-OCDiscovery $f; $script:gamePath=Join-Path $f.CNDirectory 'Versions\SC2_x64.exe'
        function script:Get-OneClickProcesses { [pscustomobject]@{Name='SC2_x64';Id=123;Path=$script:gamePath;Process=$null} }
        Assert-OCRejected { Invoke-SC2DualRegionOneClick -Run } 'Running game must block'
        Assert-OC (-not [IO.Directory]::Exists(($f.CNDirectory + ' EU'))) 'Running game triggered a copy'
    }
    Test-OC 'a same-named unrelated Agent process is not killed' {
        $f=New-OCFixture; $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase
        $script:unrelatedAgent=Join-Path $f.Root 'Other software\Agent.exe'
        function script:Get-OneClickProcesses { [pscustomobject]@{Name='Agent';Id=999;Path=$script:unrelatedAgent;Process=$null} }
        Close-OneClickBattleNet $d
    }
    Test-OC 'unrelated Agent blocks before the large copy or archive without being killed' {
        $f=New-OCFixture; Set-OCDiscovery $f
        $script:unrelatedAgent=Join-Path $f.Root 'Other software\Agent.exe'
        function script:Get-OneClickProcesses { [pscustomobject]@{Name='Agent';Id=999;Path=$script:unrelatedAgent;Process=$null} }
        function script:Ensure-OneClickShortcuts { }
        Assert-OCRejected { Invoke-SC2DualRegionOneClick -Run } 'Core offline guard must be checked before copying'
        Assert-OC (-not [IO.Directory]::Exists(($f.CNDirectory + ' EU'))) 'Unrelated Agent triggered a copy'
        Assert-OC (-not [IO.Directory]::Exists((Join-Path $f.Root '.sc2-dual-region-backups'))) 'Unrelated Agent triggered backup writes'
    }
    Test-OC 'already separated execution skips copying shutdown metadata and launch' {
        $f=New-OCFixture -Separated; Set-OCDiscovery $f
        function script:Ensure-OneClickShortcuts { $script:shortcutCalls++ }
        function script:Start-OneClickEU { throw 'Separated task launched EU' }
        function script:Invoke-OneClickRobocopy { throw 'Separated task copied files' }
        function script:Get-OneClickProcesses { throw 'Separated task tried to stop or inspect running games' }
        $before=(Get-FileHash -LiteralPath $f.AgentDatabase -Algorithm SHA256).Hash
        $result=Invoke-SC2DualRegionOneClick -Run
        Assert-OC ($result.Status -eq 'AlreadySeparated' -and $script:shortcutCalls -eq 1) 'Separated entry was not reused'
        Assert-OC ((Get-FileHash -LiteralPath $f.AgentDatabase -Algorithm SHA256).Hash -eq $before) 'Separated metadata changed'
    }
    Test-OC 'registered Americas and Asia global installs with consistent regional build rows are discovered read-only' {
        foreach($region in @('us','kr')) {
            $f=New-OCFixture -Separated
            Set-OCInternationalRegions $f $region $region $region
            $before=Get-OCFixtureFingerprint $f
            $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase
            Assert-OC ($d.Status -eq 'Separated') ('Registered '+$region+' install rejected: '+$d.Reason)
            Assert-OC ($d.CNDirectory -eq $f.CNDirectory -and $d.EUDirectory -eq $f.EUDirectory) 'Global discovery changed an installation path'
            Assert-OC ($d.EUVersion -eq $f.EUVersion -and $d.EUBuildKey -eq $f.EUKey) 'Global discovery lost the verified international version or build key'
            Assert-OC ((Get-OCFixtureFingerprint $f) -eq $before) 'Regional discovery rewrote a fixture installation file'
        }
    }
    Test-OC 'official global game region us or kr may retain an eu build branch without losing discovery' {
        foreach($region in @('us','kr')) {
            $f=New-OCFixture -Separated
            Set-OCInternationalRegions $f $region $region 'eu'
            $before=Get-OCFixtureFingerprint $f
            $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase
            Assert-OC ($d.Status -eq 'Separated') ('Official global record '+$region+' with eu branch rejected: '+$d.Reason)
            Assert-OC ($d.EUDirectory -eq $f.EUDirectory -and $d.EUVersion -eq $f.EUVersion -and $d.EUBuildKey -eq $f.EUKey) 'Global region selection did not retain the same verified install and active build'
            Assert-OC ((Get-OCFixtureFingerprint $f) -eq $before) 'Global region recognition rewrote the build branch or registration region'
        }
    }
    Test-OC 'unknown registered global game regions remain unsupported and unmodified' {
        foreach($region in @('cn','unknown','tw')) {
            $f=New-OCFixture -Separated
            Set-OCInternationalRegions $f $region $region 'eu'
            $before=Get-OCFixtureFingerprint $f
            $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase
            Assert-OC ($d.Status -eq 'Unsupported') 'Unknown or CN international registration was accepted'
            Assert-OC ((Get-OCFixtureFingerprint $f) -eq $before) 'Unknown registration detection changed files'
        }
    }
    Test-OC 'Agent and local global game regions must still match exactly' {
        foreach($pair in @([pscustomobject]@{Agent='us';Local='eu'},[pscustomobject]@{Agent='kr';Local='us'},[pscustomobject]@{Agent='eu';Local='kr'})) {
            $f=New-OCFixture -Separated
            Set-OCInternationalRegions $f $pair.Agent $pair.Local 'eu'
            $before=Get-OCFixtureFingerprint $f
            $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase
            Assert-OC ($d.Status -eq 'Unsupported') 'Mismatched Agent and local global regions were treated as verified'
            Assert-OC ((Get-OCFixtureFingerprint $f) -eq $before) 'Region mismatch detection changed files'
        }
    }
    Test-OC 'valid global registration cannot make CN or unknown active build branches acceptable' {
        foreach($branch in @('cn','unknown','s2_ptr')) {
            $f=New-OCFixture -Separated
            Set-OCInternationalRegions $f 'us' 'us' $branch
            $before=Get-OCFixtureFingerprint $f
            $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase
            Assert-OC ($d.Status -eq 'Unsupported') 'CN or unknown branch was accepted for international s2'
            Assert-OC ((Get-OCFixtureFingerprint $f) -eq $before) 'Branch rejection changed files'
        }
    }
    Test-OC 'CN active build branch remains strict when the international game region is us' {
        $f=New-OCFixture -Separated
        Set-OCInternationalRegions $f 'us' 'us' 'eu'
        $cnBuildPath=Join-Path $f.CNDirectory '.build.info'
        $cnBuild=[IO.File]::ReadAllText($cnBuildPath)
        Write-FixtureText $cnBuildPath ($cnBuild.Replace('cn|1|','us|1|'))
        $before=Get-OCFixtureFingerprint $f
        $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase
        Assert-OC ($d.Status -eq 'Unsupported') 'International branch flexibility was incorrectly applied to s2_cn'
        Assert-OC ((Get-OCFixtureFingerprint $f) -eq $before) 'CN branch rejection changed files'
    }
    Test-OC 'copy command copies files without mirror deletion movement or links' {
        $args=@(Get-OneClickRobocopyArguments 'source synthetic' 'destination synthetic')
        Assert-OC ($args[0] -eq 'source synthetic' -and $args[1] -eq 'destination synthetic') 'Copy arguments lost literal paths'
        Assert-OC ($args -contains '/E' -and $args -contains '/XJ') 'Required safe copy options missing'
        Assert-OC (@($args | Where-Object { $_ -match '^/(MIR|PURGE|MOV|MOVE|SL|B|ZB)(:|$)' }).Count -eq 0) 'Dangerous copy option found'
    }
    Test-OC 'both CMD entry points select UTF8 before Chinese paths and use process-only policy' {
        $repo=Join-Path $PSScriptRoot '..'
        $english=[IO.File]::ReadAllText((Join-Path $repo 'Start.cmd'))
        $chinese=[IO.File]::ReadAllText((Join-Path $repo '开始修复.cmd'))
        Assert-OC ($english.IndexOf('chcp 65001') -ge 0 -and $english.IndexOf('chcp 65001') -lt $english.IndexOf('call ')) 'English CMD reads a Chinese path before selecting UTF8'
        Assert-OC ($chinese.IndexOf('chcp 65001') -ge 0 -and $chinese.IndexOf('chcp 65001') -lt $chinese.IndexOf('powershell.exe')) 'Chinese CMD does not select UTF8 first'
        Assert-OC ($chinese -match 'powershell\.exe -NoProfile -ExecutionPolicy Bypass -File' -and $chinese -match ' -Run' -and $chinese -notmatch 'Set-ExecutionPolicy|Scope LocalMachine|Scope CurrentUser') 'CMD must only bypass policy for its child process'
    }
    Test-OC 'ordinary full copy validates relative names counts lengths and preserves source' {
        $f=New-OCFixture; $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase; Set-OCSafeCopy
        $source=@(Get-OneClickTree $d.CNDirectory); $signature=Get-OneClickTreeSignature $source
        $copied=Copy-OneClickGame $d $source
        Assert-OC ($copied.Verified -and $copied.FileCount -eq $source.Count) 'Copy was not verified'
        Assert-OC ((Get-OneClickTreeSignature @(Get-OneClickTree $d.CNDirectory)) -eq $signature) 'CN source changed'
    }
    Test-OC 'an existing empty destination is still refused before copy' {
        $f=New-OCFixture; $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase
        [IO.Directory]::CreateDirectory($d.EUDirectory)|Out-Null
        Assert-OCRejected { Copy-OneClickGame $d @(Get-OneClickTree $d.CNDirectory) } 'Empty existing copy must not be reused'
    }
    Test-OC 'incomplete copy rejects before any metadata replacement' {
        $f=New-OCFixture; $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase
        function script:Invoke-OneClickRobocopy { }
        $before=(Get-FileHash -LiteralPath $f.AgentDatabase -Algorithm SHA256).Hash
        Assert-OCRejected { Copy-OneClickGame $d @(Get-OneClickTree $d.CNDirectory) } 'Incomplete copy must reject'
        Assert-OC ((Get-FileHash -LiteralPath $f.AgentDatabase -Algorithm SHA256).Hash -eq $before) 'Incomplete copy changed Agent metadata'
    }
    Test-OC 'pre-update CN copy archive is recoverable and leaves original CN untouched' {
        $f=New-OCFixture; $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase; Set-OCSafeCopy
        Copy-OneClickGame $d @(Get-OneClickTree $d.CNDirectory)|Out-Null
        $work=New-OneClickWorkDirectory $d
        $archive=Archive-OneClickCopiedCNBuild $d $work
        $base='Versions\Base' + $d.CNVersion.Split('.')[-1]
        Assert-OC ([IO.Directory]::Exists((Join-Path $d.CNDirectory $base))) 'Original CN Base was moved'
        Assert-OC (-not [IO.Directory]::Exists((Join-Path $d.EUDirectory $base))) 'Copied CN Base was not archived'
        Restore-Sc2VersionsArchive -ArchiveDirectory $archive|Out-Null
        Assert-OC ([IO.Directory]::Exists((Join-Path $d.EUDirectory $base))) 'Pre-update archive cannot restore through core tool'
    }
    Test-OC 'all numeric copied Base directories archive and restore without touching data or nonnumeric directories' {
        $f=New-OCFixture; $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase; Set-OCSafeCopy
        New-FixtureVersion $d.CNDirectory 'Base40001' 'synthetic older copied build'|Out-Null
        New-FixtureVersion $d.CNDirectory 'Base60001' 'synthetic higher copied build'|Out-Null
        New-FixtureVersion $d.CNDirectory 'BasePreview' 'synthetic nonnumeric build'|Out-Null
        $sourceBefore=Get-OneClickTreeSignature @(Get-OneClickTree $d.CNDirectory -Hash) -Hash
        Copy-OneClickGame $d @(Get-OneClickTree $d.CNDirectory)|Out-Null
        $dataBefore=Get-OneClickTreeSignature @(Get-OneClickTree (Join-Path $d.EUDirectory 'SC2Data') -Hash) -Hash
        $archive=Archive-OneClickCopiedCNBuild $d (New-OneClickWorkDirectory $d)
        $manifest=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $archive 'archive.json')|ConvertFrom-Json
        Assert-OC ($manifest.Mode -eq 'NewEUCopyBeforeOfficialUpdate' -and @($manifest.Moves).Count -eq 3) 'All copied numeric builds were not archived'
        Assert-OC (@(Get-ChildItem -Directory -Force -LiteralPath (Join-Path $d.EUDirectory 'Versions')|Where-Object {$_.Name -match '^Base\d+$'}).Count -eq 0) 'A copied numeric Base remained'
        Assert-OC ([IO.Directory]::Exists((Join-Path $d.EUDirectory 'Versions\BasePreview'))) 'Nonnumeric Base was moved'
        Assert-OC ((Get-OneClickTreeSignature @(Get-OneClickTree $d.CNDirectory -Hash) -Hash) -eq $sourceBefore) 'Original installation changed'
        Assert-OC ((Get-OneClickTreeSignature @(Get-OneClickTree (Join-Path $d.EUDirectory 'SC2Data') -Hash) -Hash) -eq $dataBefore) 'EU large data changed'
        Restore-Sc2VersionsArchive -ArchiveDirectory $archive|Out-Null
        foreach($name in @('Base40001','Base60001',('Base'+$d.CNVersion.Split('.')[-1]))) { Assert-OC ([IO.Directory]::Exists((Join-Path $d.EUDirectory ('Versions\'+$name)))) 'A multi-build archive did not restore' }
    }
    Test-OC 'all build copies must validate before the first archive move' {
        $f=New-OCFixture; $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase; Set-OCSafeCopy
        New-FixtureVersion $d.CNDirectory 'Base60001' 'synthetic copied high build'|Out-Null
        Copy-OneClickGame $d @(Get-OneClickTree $d.CNDirectory)|Out-Null
        Write-FixtureText (Join-Path $d.EUDirectory 'Versions\Base60001\client.synthetic') 'synthetic corrupted copied file'
        $work=New-OneClickWorkDirectory $d
        Assert-OCRejected { Archive-OneClickCopiedCNBuild $d $work } 'A mismatched copied build must reject all moves'
        foreach($name in @('Base60001',('Base'+$d.CNVersion.Split('.')[-1]))) { Assert-OC ([IO.Directory]::Exists((Join-Path $d.EUDirectory ('Versions\'+$name)))) 'Validation failure moved another build' }
        Assert-OC (@(Get-ChildItem -Force -LiteralPath $work).Count -eq 0) 'Validation failure created an archive'
    }
    Test-OC 'archive failure after one move returns every completed copy to EU' {
        $f=New-OCFixture; $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase; Set-OCSafeCopy
        New-FixtureVersion $d.CNDirectory 'Base60001' 'synthetic copied high build'|Out-Null
        Copy-OneClickGame $d @(Get-OneClickTree $d.CNDirectory)|Out-Null
        $before=Get-OneClickTreeSignature @(Get-OneClickTree $d.EUDirectory -Hash) -Hash
        $script:moveCount=0
        function script:Move-OneClickDirectory([string]$Source,[string]$Destination) {
            $script:moveCount++
            if ($script:moveCount -eq 2) { throw 'Injected synthetic archive move failure' }
            [IO.Directory]::Move($Source,$Destination)
        }
        Assert-OCRejected { Archive-OneClickCopiedCNBuild $d (New-OneClickWorkDirectory $d) } 'Injected archive failure should report failure'
        Assert-OC ((Get-OneClickTreeSignature @(Get-OneClickTree $d.EUDirectory -Hash) -Hash) -eq $before) 'Archive failure did not return all completed moves'
    }
    Test-OC 'wrong same-name desktop shortcut refuses before overwriting' {
        $f=New-OCFixture; $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase
        $script:fakeDesktop=Join-Path $f.Root 'Desktop synthetic'; [IO.Directory]::CreateDirectory($script:fakeDesktop)|Out-Null
        $script:fakeOtherTarget=Join-Path $f.Root 'Other launcher.exe'
        function script:Get-OneClickDesktop { $script:fakeDesktop }
        function script:Read-OneClickShortcut { [pscustomobject]@{Target=$script:fakeOtherTarget;Arguments='--other'} }
        Assert-OCRejected { Ensure-OneClickShortcuts $d } 'Wrong shortcut must refuse'
    }
    Test-OC 'correct existing regional shortcuts are reused without COM writes' {
        $f=New-OCFixture; $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase
        $script:fakeDesktop=Join-Path $f.Root 'Desktop synthetic'; [IO.Directory]::CreateDirectory($script:fakeDesktop)|Out-Null
        $script:fakeTarget=$d.LauncherPath
        function script:Get-OneClickDesktop { $script:fakeDesktop }
        function script:Read-OneClickShortcut([string]$Path) {
            $arguments='--setregion=EU --exec="launch s2"'
            if ([IO.Path]::GetFileName($Path) -like '*网易*') { $arguments='--setregion=CN --exec="launch s2_cn"' }
            [pscustomobject]@{Target=$script:fakeTarget;Arguments=$arguments}
        }
        Ensure-OneClickShortcuts $d
        Assert-OC (@(Get-ChildItem -Force -LiteralPath $script:fakeDesktop).Count -eq 0) 'Reuse wrote files'
    }
    Test-OC 'full synthetic conflict orchestrates copy archive repair entries and official launch mock' {
        $f=New-OCFixture; Set-OCDiscovery $f; Set-OCSafeCopy
        function script:Ensure-OneClickShortcuts($Discovery,[switch]$ValidateOnly) { if (-not $ValidateOnly) {$script:shortcutCalls++} }
        function script:Start-OneClickEU { $script:launchCalls++ }
        $script:configPath=Join-Path $f.Root 'No config\Battle.net.config'
        function script:Get-OneClickConfigPath { $script:configPath }
        $result=Invoke-SC2DualRegionOneClick -Run
        Assert-OC ($result.Status -eq 'Repaired' -and $script:shortcutCalls -eq 1 -and $script:launchCalls -eq 1) 'Orchestrator skipped a step'
        Assert-OC ([IO.File]::Exists((Join-Path $result.MetadataBackupDirectory 'Agent.original'))) 'Core metadata backup missing'
        Assert-OC ([IO.File]::Exists((Join-Path $result.WorkDirectory 'operation.json'))) 'Private progress marker missing'
        Assert-OC ([IO.File]::Exists((Join-Path $result.VersionsArchiveDirectory 'archive.json'))) 'Versions restore manifest missing'
    }
    Test-OC 'confirmed multi-instance preference changes only its setting and keeps original backup' {
        $f=New-OCFixture; $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase; $work=New-OneClickWorkDirectory $d
        $script:configPath=Join-Path $f.Root 'Roaming synthetic\Battle.net.config'
        Write-FixtureText $script:configPath '{"Client":{"SingleInstance":"true","UnknownPreference":"keep"},"Other":{"Value":17}}'
        $original=[IO.File]::ReadAllBytes($script:configPath)
        function script:Get-OneClickConfigPath { $script:configPath }
        $status=Enable-OneClickMultipleInstances $d $work
        $after=Get-Content -LiteralPath $script:configPath -Raw -Encoding UTF8|ConvertFrom-Json
        Assert-OC ($status -eq 'Enabled' -and $after.Client.SingleInstance -eq 'false' -and $after.Client.UnknownPreference -eq 'keep' -and $after.Other.Value -eq 17) 'Unknown configuration settings changed'
        Assert-OC ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $work 'Battle.net.config.original'))) -eq [Convert]::ToBase64String($original)) 'Original configuration backup changed'
        Assert-OC ((Enable-OneClickMultipleInstances $d $work) -eq 'AlreadyEnabled') 'Repeated multi-instance preference is not idempotent'
    }
    Test-OC 'same-build cn international state still archives the current CN copy in full workflow' {
        $f=New-OCFixture -SameBuild; Set-OCDiscovery $f; Set-OCSafeCopy
        function script:Ensure-OneClickShortcuts { }
        function script:Start-OneClickEU { }
        $script:configPath=Join-Path $f.Root 'No config\Battle.net.config'
        function script:Get-OneClickConfigPath { $script:configPath }
        $d=Get-OneClickDiscovery
        Assert-OC ($d.Status -eq 'Conflict' -and $d.CNVersion -eq $d.EUVersion) 'Same-build conflict fixture is invalid'
        $result=Invoke-SC2DualRegionOneClick -Run
        Assert-OC ($result.Status -eq 'Repaired' -and [IO.File]::Exists((Join-Path $result.VersionsArchiveDirectory 'archive.json'))) 'Same-build CN copy was not archived'
        $base='Versions\Base' + $d.CNVersion.Split('.')[-1]
        Assert-OC ([IO.Directory]::Exists((Join-Path $d.CNDirectory $base))) 'Same-build workflow moved the original CN Base'
        Assert-OC (-not [IO.Directory]::Exists((Join-Path $d.EUDirectory $base))) 'Same-build workflow retained current CN Base in EU'
    }
    Test-OC 'unknown preference format and active Battle.net refuse configuration overwrite' {
        $f=New-OCFixture; $d=Get-Sc2AutoDiscovery -AgentDatabase $f.AgentDatabase; $work=New-OneClickWorkDirectory $d
        $script:configPath=Join-Path $f.Root 'Roaming synthetic\Battle.net.config'; function script:Get-OneClickConfigPath { $script:configPath }
        Write-FixtureText $script:configPath '{"Client":{"SingleInstance":true}}'
        Assert-OC ((Enable-OneClickMultipleInstances $d $work) -eq 'Unsupported') 'Boolean format was guessed'
        Write-FixtureText $script:configPath '{"Client":{"SingleInstance":"true"}}'
        $script:runningLauncher=$d.LauncherPath
        function script:Get-OneClickProcesses { [pscustomobject]@{Name='Battle.net Launcher';Id=123;Path=$script:runningLauncher;Process=$null} }
        Assert-OCRejected { Enable-OneClickMultipleInstances $d $work } 'Running Battle.net config must not be rewritten'
        Assert-OC ((Get-Content -LiteralPath $script:configPath -Raw) -eq '{"Client":{"SingleInstance":"true"}}') 'Active config changed'
    }
}
finally {
    Reset-OCMocks
    & $testCore { Remove-Item -LiteralPath Function:script:Get-Process -ErrorAction SilentlyContinue }
}
$failed=@($script:results|Where-Object {-not $_.Passed}); $passed=@($script:results|Where-Object Passed)
Write-Host ("One-click result: {0} passed; {1} failed." -f $passed.Count,$failed.Count)
if ($failed.Count -or $KeepFixtures) { Write-Host ('Synthetic one-click fixtures preserved: ' + $testRoot) }
else {
    $fullRoot=[IO.Path]::GetFullPath($testRoot)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    Assert-OC ($fullRoot.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($fullRoot) -match '^sc2-oneclick-tests-[a-f0-9]{32}$') 'Unsafe fixture cleanup path'
    Assert-OC (([IO.File]::GetAttributes($fullRoot) -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Fixture cleanup root is a link'
    Remove-Item -LiteralPath $fullRoot -Recurse -Force
}
if ($failed.Count) { exit 1 }
