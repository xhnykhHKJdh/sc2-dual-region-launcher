#requires -Version 5.1
[CmdletBinding()]
param([switch]$KeepFixtures)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot '..\scripts\Sc2Launcher.psm1') -Force
. (Join-Path $PSScriptRoot '..\scripts\Invoke-SC2LauncherAction.ps1')
. (Join-Path $PSScriptRoot 'SyntheticFixtures.ps1')
$launcherModule = Get-Module Sc2Launcher
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sc2-launcher-tests-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($testRoot)
$script:launcherResults = [Collections.Generic.List[object]]::new()
$script:launcherCase = 0
$script:launcherWorkerDirectories = [Collections.Generic.List[string]]::new()
$script:launcherOriginalFunctions = @{}
foreach ($name in @('Get-Sc2LauncherDiscovery','Get-Sc2LauncherProcesses','Start-Sc2RegionalLauncher','Invoke-Sc2LauncherRepair','Open-Sc2EUUpdateClient','Invoke-SC2DualRegionOneClick','Invoke-Sc2InternationalLaunch','Get-Sc2InternationalHelperPath','Start-Sc2InternationalHelperProcess','Get-Sc2OfficialLauncherSignature')) {
    $script:launcherOriginalFunctions[$name] = & $launcherModule { param($FunctionName) (Get-Item ('Function:' + $FunctionName)).ScriptBlock } $name
}
$script:originalWorkerAction = (Get-Item Function:Invoke-Sc2LauncherAction).ScriptBlock

function Assert-Launcher([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-LauncherRejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Launcher $rejected $Message
}
function New-LauncherFixture([switch]$Separated) {
    $script:launcherCase++
    $fixture = New-SyntheticInstallation (Join-Path $testRoot ('case-' + $script:launcherCase)) -Separated:$Separated
    Write-FixtureBuildConfig $fixture.CNDirectory $fixture.CNKey $fixture.CNVersion | Out-Null
    New-FixtureVersion $fixture.CNDirectory ('Base' + $fixture.CNVersion.Split('.')[-1]) 'synthetic CN; never execute' | Out-Null
    if ($Separated) {
        Write-FixtureBuildConfig $fixture.EUDirectory $fixture.EUKey $fixture.EUVersion | Out-Null
        New-FixtureVersion $fixture.EUDirectory ('Base' + $fixture.EUVersion.Split('.')[-1]) 'synthetic EU; never execute' | Out-Null
    }
    $launcherDirectory = Join-Path $fixture.Root 'Official launcher synthetic'
    Write-FixtureText (Join-Path $launcherDirectory 'Battle.net Launcher.exe') 'synthetic marker; never execute'
    $launcherRecord = New-FixtureProduct 'battle.net' $launcherDirectory 'eu' '2.0.0.12345' (New-FixtureKey) (New-FixtureKey)
    Write-FixtureBytes $fixture.AgentDatabase (New-FixtureDatabase @($fixture.CNRecord,$fixture.EURecord,$fixture.PTRRecord,$fixture.OtherRecord,$launcherRecord))
    return $fixture
}
function Get-LauncherFixtureDiscovery($Fixture) {
    & $launcherModule { param($Agent) Get-Sc2AutoDiscovery -AgentDatabase $Agent } $Fixture.AgentDatabase
}
function Set-LauncherDiscovery([object[]]$Discoveries) {
    & $launcherModule {
        param($Values)
        $script:LauncherTestDiscoveries = @($Values)
        $script:LauncherTestDiscoveryCalls = 0
        function script:Get-Sc2LauncherDiscovery {
            $index = [Math]::Min($script:LauncherTestDiscoveryCalls, $script:LauncherTestDiscoveries.Count - 1)
            $script:LauncherTestDiscoveryCalls++
            $script:LauncherTestDiscoveries[$index]
        }
    } $Discoveries
}
function Set-LauncherProcesses([object[]]$Processes) {
    & $launcherModule {
        param($Values)
        $script:LauncherTestProcesses = @($Values)
        function script:Get-Sc2LauncherProcesses { $script:LauncherTestProcesses }
    } $Processes
}
function Get-LauncherCalls { & $launcherModule { @($script:LauncherTestStarts) } }
function Reset-LauncherMocks {
    Set-Item -LiteralPath Function:script:Invoke-Sc2LauncherAction -Value $script:originalWorkerAction
    foreach ($name in $script:launcherOriginalFunctions.Keys) {
        & $launcherModule { param($Name,$Body) Set-Item -LiteralPath ('Function:script:' + $Name) -Value $Body } $name $script:launcherOriginalFunctions[$name]
    }
    & $launcherModule {
        $script:LauncherTestStarts = [Collections.Generic.List[object]]::new()
        $script:LauncherTestRepairCalls = 0
        $script:LauncherTestUpdateCalls = 0
        $script:LauncherTestDiscoveries = @()
        $script:LauncherTestDiscoveryCalls = 0
        $script:LauncherTestProcesses = @()
        function script:Get-Sc2LauncherDiscovery { throw 'Tests require an explicitly supplied synthetic discovery.' }
        function script:Get-Sc2LauncherProcesses { $script:LauncherTestProcesses }
        function script:Get-Sc2OfficialLauncherSignature([string]$Path) {[pscustomobject]@{Status='Valid';SignerName='Blizzard Entertainment, Inc.'}}
        function script:Start-Sc2RegionalLauncher([string]$LauncherPath,[string]$Region,[string]$Product) {
            $script:LauncherTestStarts.Add([pscustomobject]@{ LauncherPath=$LauncherPath; Region=$Region; Product=$Product; Kind='CNDirect' })
        }
        function script:Invoke-Sc2InternationalLaunch([string]$LauncherPath,[string]$GameDirectory,[string]$Region) {
            $script:LauncherTestStarts.Add([pscustomobject]@{LauncherPath=$LauncherPath;GameDirectory=$GameDirectory;Region=$Region;Product='s2';Kind='InternationalConfirmed'})
            [pscustomobject]@{Success=$true;GameRegionConfirmed=$true;Region=$Region;Status='Started';Message='synthetic confirmed official game region'}
        }
        function script:Get-Sc2InternationalHelperPath { throw 'Tests require an explicitly supplied synthetic helper path.' }
        function script:Start-Sc2InternationalHelperProcess { throw 'Tests forbid starting actual international helper processes.' }
        function script:Invoke-Sc2LauncherRepair {
            $script:LauncherTestRepairCalls++
            [pscustomobject]@{ Status='AlreadySeparated' }
        }
        function script:Open-Sc2EUUpdateClient([string]$LauncherPath) { $script:LauncherTestUpdateCalls++ }
        # Any accidental native process mutation is a hard failure, including unknown names.
        function script:Stop-Process { throw 'Tests forbid stopping processes.' }
        function script:Start-Process { throw 'Tests forbid starting actual processes.' }
    }
}
function Get-LauncherTreeFingerprint([string]$Root) {
    @((Get-ChildItem -LiteralPath $Root -File -Force -Recurse | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($Root.Length) + '|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    })) -join "`n"
}
function New-LauncherWorkerFixture {
    $directory=Join-Path ([IO.Path]::GetTempPath()) ('sc2-launcher-'+[Guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($directory)
    $script:launcherWorkerDirectories.Add($directory)
    [pscustomobject]@{Directory=$directory;ResultPath=(Join-Path $directory 'result.json');LogPath=(Join-Path $directory 'action.log')}
}
function Set-LauncherSyntheticHelper($Fixture,$Reported,[int]$ExitCode=0,[bool]$WaitResult=$true,[switch]$NoResult) {
    $helperPath=Join-Path $Fixture.Root 'synthetic region helper.exe'
    Write-FixtureText $helperPath 'synthetic marker; never execute'
    & $launcherModule {
        param($Path,$Report,$Code,$Wait,$SkipResult,$Directories)
        $script:LauncherTestHelperPath=$Path
        $script:LauncherTestHelperReport=$Report
        $script:LauncherTestHelperCode=$Code
        $script:LauncherTestHelperWait=$Wait
        $script:LauncherTestHelperNoResult=$SkipResult
        $script:LauncherTestHelperDirectories=$Directories
        $script:LauncherTestHelperEvents=[Collections.Generic.List[string]]::new()
        $script:LauncherTestHelperCall=$null
        function script:Get-Sc2InternationalHelperPath {$script:LauncherTestHelperPath}
        function script:Open-Sc2EUUpdateClient([string]$LauncherPath) {
            $script:LauncherTestUpdateCalls++
            $script:LauncherTestHelperEvents.Add('OpenInternationalClient')
        }
        function script:Start-Sc2InternationalHelperProcess([string]$FilePath,[string]$Arguments) {
            $script:LauncherTestHelperEvents.Add('ConfirmGameRegionAndInvokeOfficialPlay')
            $script:LauncherTestHelperCall=[pscustomobject]@{FilePath=$FilePath;Arguments=$Arguments}
            if($Arguments -notmatch '--result-path "([^"]+)"') {throw 'Synthetic helper did not receive a safely quoted result path.'}
            $resultPath=$matches[1]
            $script:LauncherTestHelperDirectories.Add([IO.Path]::GetDirectoryName($resultPath))
            if(-not $script:LauncherTestHelperNoResult) {
                [IO.File]::WriteAllText($resultPath,($script:LauncherTestHelperReport|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
            }
            $process=[pscustomobject]@{ExitCode=$script:LauncherTestHelperCode;HasExited=$false;WaitResult=$script:LauncherTestHelperWait;KillCalls=0;DisposeCalls=0}
            $process|Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {param([int]$Timeout) $this.WaitResult}
            $process|Add-Member -MemberType ScriptMethod -Name Kill -Value {$this.KillCalls++;$this.HasExited=$true}
            $process|Add-Member -MemberType ScriptMethod -Name Dispose -Value {$this.DisposeCalls++}
            $script:LauncherTestHelperProcess=$process
            return $process
        }
    } $helperPath $Reported $ExitCode $WaitResult ([bool]$NoResult) $script:launcherWorkerDirectories
}
function Initialize-LauncherRegionParser {
    $framework=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319'
    if(-not [IO.File]::Exists((Join-Path $framework 'csc.exe'))) {$framework=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework\v4.0.30319'}
    $compiler=Join-Path $framework 'csc.exe'
    Assert-Launcher ([IO.File]::Exists($compiler)) 'Built-in .NET Framework compiler is unavailable.'
    $source=Join-Path $PSScriptRoot '..\src\Sc2BattleRegionSelector.cs'
    $output=Join-Path $testRoot 'RegionSelector.synthetic.dll'
    $response=Join-Path $testRoot 'RegionSelector.synthetic.rsp'
    $options=@('/nologo','/target:library','/codepage:65001','/utf8output',('/out:"'+$output+'"'))
    foreach($reference in @('System.dll','System.Core.dll','System.Web.Extensions.dll','WPF\WindowsBase.dll','WPF\UIAutomationClient.dll','WPF\UIAutomationTypes.dll')) {
        $options+=('/reference:"'+(Join-Path $framework $reference)+'"')
    }
    $options+=('"'+$source+'"')
    [IO.File]::WriteAllLines($response,$options,[Text.UTF8Encoding]::new($true))
    $compilerMessages=@(& $compiler '/noconfig' ('@'+$response) 2>&1)
    if($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($output)) {throw ('Actual region helper source did not compile: '+($compilerMessages -join ' '))}
    $script:launcherRegionAssembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($output))
    $script:launcherRegionType=$script:launcherRegionAssembly.GetType('Sc2BattleRegionSelector',$true)
}
function Invoke-LauncherRegionMethod([string]$Method,[object[]]$Arguments,[switch]$Private) {
    $flags=[Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::Public
    if($Private) {$flags=[Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::NonPublic}
    $methodInfo=$script:launcherRegionType.GetMethod($Method,$flags)
    Assert-Launcher ($null -ne $methodInfo) ('Actual helper method unavailable: '+$Method)
    $parameters=$methodInfo.GetParameters()
    $values=[object[]]::new($Arguments.Count)
    for($i=0;$i -lt $Arguments.Count;$i++) {
        $values[$i]=if($null -eq $Arguments[$i]) {$null} elseif($parameters[$i].ParameterType -eq [string]) {[string]$Arguments[$i]} else {$Arguments[$i]}
    }
    $methodInfo.Invoke($null,$values)
}
function Assert-LauncherNativeMetadataRejected([string]$Directory,[string]$Message) {
    $rejected=$false
    try {Invoke-LauncherRegionMethod ReadInternationalVersion @($Directory) -Private|Out-Null}
    catch {
        $exception=$_.Exception
        while($null -ne $exception) {
            if($exception -is [ArgumentException]) {$rejected=$true;break}
            $exception=$exception.InnerException
        }
    }
    Assert-Launcher $rejected $Message
}
function Assert-LauncherSignatureStopsProcesses($Fixture,$Signature,[switch]$LookupThrows) {
    $discovery=Get-LauncherFixtureDiscovery $Fixture
    Set-LauncherDiscovery @($discovery)
    foreach($name in @('Start-Sc2RegionalLauncher','Open-Sc2EUUpdateClient','Invoke-Sc2InternationalLaunch')) {
        & $launcherModule {param($Name,$Body) Set-Item -LiteralPath ('Function:script:'+$Name) -Value $Body} $name $script:launcherOriginalFunctions[$name]
    }
    & $launcherModule {
        param($Report,$ThrowLookup)
        $script:LauncherTestSignatureReport=$Report
        $script:LauncherTestSignatureThrows=$ThrowLookup
        $script:LauncherTestSignatureCalls=0
        $script:LauncherTestNativeStarts=0
        $script:LauncherTestHelperLookups=0
        $script:LauncherTestNativeHelpers=0
        function script:Get-Sc2OfficialLauncherSignature([string]$Path) {
            $script:LauncherTestSignatureCalls++
            if($script:LauncherTestSignatureThrows) {throw 'synthetic Authenticode lookup unavailable'}
            $script:LauncherTestSignatureReport
        }
        # Recording mocks return normally. Rejections must originate in the
        # signature guard, rather than an artificial Start-Process failure.
        function script:Start-Process {$script:LauncherTestNativeStarts++}
        function script:Get-Sc2InternationalHelperPath {$script:LauncherTestHelperLookups++;'synthetic helper must remain unused'}
        function script:Start-Sc2InternationalHelperProcess {$script:LauncherTestNativeHelpers++}
    } $Signature ([bool]$LookupThrows)
    $r=Invoke-Sc2LauncherAction -Action LaunchCN
    Assert-Launcher (-not $r.Success -and $r.Status -eq 'Failed') 'CN launch did not reject an unverified executable.'
    Assert-LauncherRejected {& $launcherModule {param($Path) Open-Sc2EUUpdateClient -LauncherPath $Path} $discovery.LauncherPath} 'International login-client opening accepted an unverified executable.'
    Assert-LauncherRejected {& $launcherModule {param($Path,$Game) Invoke-Sc2InternationalLaunch -LauncherPath $Path -GameDirectory $Game -Region US} $discovery.LauncherPath $discovery.EUDirectory} 'International region launch accepted an unverified executable.'
    Assert-Launcher ((& $launcherModule {$script:LauncherTestSignatureCalls}) -eq 3) 'A native startup path bypassed the Authenticode check.'
    Assert-Launcher ((& $launcherModule {$script:LauncherTestNativeStarts}) -eq 0) 'A rejected signature still created a native process.'
    Assert-Launcher ((& $launcherModule {$script:LauncherTestHelperLookups}) -eq 0 -and (& $launcherModule {$script:LauncherTestNativeHelpers}) -eq 0) 'Signature rejection reached the international helper pipeline.'
}
function Test-Launcher([string]$Name,[scriptblock]$Action) {
    Reset-LauncherMocks
    try { & $Action; $script:launcherResults.Add([pscustomobject]@{Name=$Name;Passed=$true}); Write-Host ('PASS ' + $Name) }
    catch { $script:launcherResults.Add([pscustomobject]@{Name=$Name;Passed=$false}); Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}

try {
    Test-Launcher 'inspection discovers a separated synthetic installation without changing files' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        $before=Get-LauncherTreeFingerprint $f.Root
        $r=Get-Sc2LauncherInspection
        Assert-Launcher ($r.Status -eq 'Separated') 'Separated installation was not recognized.'
        Assert-Launcher ($r.Discovery.CNDirectory -eq $f.CNDirectory -and $r.Discovery.EUDirectory -eq $f.EUDirectory) 'Discovered game paths differ from registered synthetic paths.'
        Assert-Launcher ((Get-LauncherTreeFingerprint $f.Root) -eq $before) 'Inspection changed installation files.'
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'Inspection started a launcher.'
    }
    Test-Launcher 'CN launch remains available while CN and international registrations conflict' {
        $f=New-LauncherFixture; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        Assert-Launcher ($d.Status -eq 'Conflict') 'Conflict fixture did not represent a registered collision.'
        $r=Invoke-Sc2LauncherAction -Action LaunchCN; $calls=@(Get-LauncherCalls)
        Assert-Launcher ($r.Success -and $r.Status -eq 'Started' -and $calls.Count -eq 1) 'CN launch should remain available before EU repair.'
        Assert-Launcher ($calls[0].LauncherPath -eq $d.LauncherPath -and $calls[0].Region -eq 'CN' -and $calls[0].Product -eq 's2_cn') 'CN launch did not use the registered full launcher path and CN product.'
        Assert-Launcher (-not [IO.Directory]::Exists($d.EUDirectory)) 'A CN launch created an EU clone.'
    }
    Test-Launcher 'EU launch refuses a conflicting installation before it can overwrite CN' {
        $f=New-LauncherFixture; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        $before=Get-LauncherTreeFingerprint $f.Root
        $r=Invoke-Sc2LauncherAction -Action LaunchEU
        Assert-Launcher (-not $r.Success -and $r.Status -eq 'NeedsRepair') 'Conflict did not block EU launch.'
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'EU conflict started the official launcher.'
        Assert-Launcher ((Get-LauncherTreeFingerprint $f.Root) -eq $before) 'Refused EU launch changed files.'
    }
    Test-Launcher 'separated EU launch uses the international product and EU region' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        $r=Invoke-Sc2LauncherAction -Action LaunchEU; $calls=@(Get-LauncherCalls)
        Assert-Launcher ($r.Success -and $r.Status -eq 'Started' -and $calls.Count -eq 1) 'Separated EU launch did not start once.'
        Assert-Launcher ($calls[0].LauncherPath -eq $d.LauncherPath -and $calls[0].Region -eq 'EU' -and $calls[0].Product -eq 's2') 'EU launch passed an incorrect path, region or product.'
    }
    Test-Launcher 'unrecognized metadata blocks both launch buttons without invoking repairs' {
        $d=[pscustomobject]@{Status='Unsupported';Reason='synthetic unsupported format'}; Set-LauncherDiscovery @($d)
        foreach($action in @('LaunchCN','LaunchEU')) {
            $r=Invoke-Sc2LauncherAction -Action $action
            Assert-Launcher (-not $r.Success -and $r.Status -eq 'Unsupported') 'Unsupported installation was allowed to start.'
        }
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'Unsupported installation launched a process.'
        Assert-Launcher ((& $launcherModule {$script:LauncherTestRepairCalls}) -eq 0) 'A launch action silently attempted repair.'
    }
    Test-Launcher 'launch rechecks discovery instead of trusting a previous successful inspection' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f
        Set-LauncherDiscovery @($d,[pscustomobject]@{Status='Unsupported';Reason='synthetic state changed'})
        $inspection=Get-Sc2LauncherInspection
        Assert-Launcher ($inspection.Status -eq 'Separated') 'Initial inspection unexpectedly failed.'
        $r=Invoke-Sc2LauncherAction -Action LaunchEU
        Assert-Launcher (-not $r.Success -and $r.Status -eq 'Unsupported') 'Launch relied on cached inspection after metadata changed.'
        Assert-Launcher ((& $launcherModule {$script:LauncherTestDiscoveryCalls}) -ge 2) 'Launch did not rediscover.'
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'Stale cached state launched a process.'
    }
    Test-Launcher 'inspection exposes only allowlisted installation fields' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f
        $d | Add-Member -NotePropertyName AccountToken -NotePropertyValue 'synthetic-private-token-never-return'
        $d | Add-Member -NotePropertyName LoginEmail -NotePropertyValue 'synthetic-private.invalid'
        Set-LauncherDiscovery @($d); $r=Get-Sc2LauncherInspection
        $json=$r | ConvertTo-Json -Depth 10
        Assert-Launcher ($json -notmatch 'synthetic-private') 'Unknown private discovery fields leaked into UI / worker data.'
        Assert-Launcher ($r.Discovery.LauncherPath -eq $d.LauncherPath) 'Allowed launcher path was discarded.'
    }
    Test-Launcher 'a running CN game prevents additional launch and is never terminated' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        Set-LauncherProcesses @([pscustomobject]@{Name='SC2_x64';Id=101;Path=(Join-Path $f.CNDirectory ('Versions\Base' + $f.CNVersion.Split('.')[-1] + '\SC2_x64.exe'))})
        foreach($action in @('LaunchCN','LaunchEU')) {
            $r=Invoke-Sc2LauncherAction -Action $action
            Assert-Launcher ($r.Status -in @('AlreadyRunning','GameRunning')) 'A running game was not preserved.'
        }
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'A second launcher started while the game was running.'
    }
    Test-Launcher 'a running EU game prevents additional launch and is never terminated' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        Set-LauncherProcesses @([pscustomobject]@{Name='SC2';Id=102;Path=(Join-Path $f.EUDirectory ('Versions\Base' + $f.EUVersion.Split('.')[-1] + '\SC2.exe'))})
        $r=Invoke-Sc2LauncherAction -Action LaunchEU
        Assert-Launcher ($r.Status -in @('AlreadyRunning','GameRunning')) 'A running EU game was not recognized.'
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'Running EU game triggered an additional launcher.'
    }
    Test-Launcher 'unreadable SC2 process path stops launch conservatively' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        Set-LauncherProcesses @([pscustomobject]@{Name='SC2_x64';Id=103;Path=$null})
        $r=Invoke-Sc2LauncherAction -Action LaunchEU
        Assert-Launcher ($r.Status -in @('AlreadyRunning','GameRunning','Unsupported') -and -not $r.Success) 'Unconfirmed game process path was treated as safe.'
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'Unconfirmed game process triggered a launcher.'
    }
    Test-Launcher 'a running SC2 editor is preserved when launch is requested' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        Set-LauncherProcesses @([pscustomobject]@{Name='SC2Editor_x64';Id=104;Path=(Join-Path $f.CNDirectory 'Support64\SC2Editor_x64.exe')})
        $r=Invoke-Sc2LauncherAction -Action LaunchCN
        Assert-Launcher ($r.Status -in @('AlreadyRunning','GameRunning')) 'Running editor was not preserved.'
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'Running editor triggered another launcher.'
    }
    Test-Launcher 'native starter passes explicit CN arguments to the registered executable' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f
        & $launcherModule {
            param($Body)
            Set-Item -LiteralPath Function:script:Start-Sc2RegionalLauncher -Value $Body
            $script:NativeStarterCall=$null
            function script:Start-Process([string]$FilePath,$ArgumentList) { $script:NativeStarterCall=[pscustomobject]@{FilePath=$FilePath;Arguments=($ArgumentList -join ' ')} }
        } $script:launcherOriginalFunctions['Start-Sc2RegionalLauncher']
        & $launcherModule { param($Path) Start-Sc2RegionalLauncher -LauncherPath $Path -Region CN -Product s2_cn } $d.LauncherPath
        $call=& $launcherModule { $script:NativeStarterCall }
        Assert-Launcher ($call.FilePath -eq $d.LauncherPath -and $call.Arguments -eq '--setregion=CN --exec="launch s2_cn"') 'Native CN starter lost the full path or argument quoting.'
    }
    Test-Launcher 'native starter passes explicit EU arguments without embedding game paths' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f
        & $launcherModule {
            param($Body)
            Set-Item -LiteralPath Function:script:Start-Sc2RegionalLauncher -Value $Body
            $script:NativeStarterCall=$null
            function script:Start-Process([string]$FilePath,$ArgumentList) { $script:NativeStarterCall=[pscustomobject]@{FilePath=$FilePath;Arguments=($ArgumentList -join ' ')} }
        } $script:launcherOriginalFunctions['Start-Sc2RegionalLauncher']
        & $launcherModule { param($Path) Start-Sc2RegionalLauncher -LauncherPath $Path -Region EU -Product s2 } $d.LauncherPath
        $call=& $launcherModule { $script:NativeStarterCall }
        Assert-Launcher ($call.FilePath -eq $d.LauncherPath -and $call.Arguments -eq '--setregion=EU --exec="launch s2"') 'Native EU starter lost the full path or argument quoting.'
    }
    Test-Launcher 'repair uses the protected one-click workflow and suppresses implicit EU launch' {
        & $launcherModule {
            param($Body)
            Set-Item -LiteralPath Function:script:Invoke-Sc2LauncherRepair -Value $Body
            $script:RepairParameters=$null
            function script:Invoke-SC2DualRegionOneClick([switch]$Run,[switch]$SkipLaunch) {
                $script:RepairParameters=[pscustomobject]@{Run=[bool]$Run;SkipLaunch=[bool]$SkipLaunch}
                [pscustomobject]@{Status='Repaired'}
            }
            Invoke-Sc2LauncherRepair | Out-Null
        } $script:launcherOriginalFunctions['Invoke-Sc2LauncherRepair']
        $call=& $launcherModule { $script:RepairParameters }
        Assert-Launcher ($call.Run -and $call.SkipLaunch) 'GUI repair did not reuse the protected workflow with implicit EU launch disabled.'
    }
    Test-Launcher 'unsupported repair stops before invoking the protected write workflow' {
        Set-LauncherDiscovery @([pscustomobject]@{Status='Unsupported';Reason='synthetic unrecognized metadata'})
        $r=Invoke-Sc2LauncherAction -Action Repair
        Assert-Launcher (-not $r.Success -and $r.Status -eq 'Unsupported') 'Unsupported repair was accepted.'
        Assert-Launcher ((& $launcherModule {$script:LauncherTestRepairCalls}) -eq 0) 'Unsupported repair invoked a write workflow.'
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'Unsupported repair started a game.'
    }
    Test-Launcher 'repair of an already separated installation only checks existing entrances' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        $r=Invoke-Sc2LauncherAction -Action Repair
        Assert-Launcher ($r.Success -and $r.Status -eq 'RepairAlreadySeparated') 'Repeated repair did not report an already separated installation.'
        Assert-Launcher ((& $launcherModule {$script:LauncherTestRepairCalls}) -eq 1) 'Repeated repair bypassed the protected shortcut checks.'
        Assert-Launcher ((& $launcherModule {$script:LauncherTestDiscoveryCalls}) -ge 2) 'Repair did not read the installation state after protected checks.'
        Assert-Launcher ((& $launcherModule {$script:LauncherTestUpdateCalls}) -eq 0 -and @(Get-LauncherCalls).Count -eq 0) 'Repeated repair opened an unnecessary game or update client.'
    }
    Test-Launcher 'repeated repair never reports success if refreshed installation records become unsupported' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f
        Set-LauncherDiscovery @($d,[pscustomobject]@{Status='Unsupported';Reason='synthetic state changed during protected checks'})
        $r=Invoke-Sc2LauncherAction -Action Repair
        Assert-Launcher (-not $r.Success -and $r.Status -eq 'Unsupported' -and $r.Discovery.Status -eq 'Unsupported') 'Repeated repair trusted stale pre-repair installation state.'
        Assert-Launcher ((& $launcherModule {$script:LauncherTestUpdateCalls}) -eq 0 -and @(Get-LauncherCalls).Count -eq 0) 'Failed refreshed state opened a client or game.'
    }
    Test-Launcher 'newly repaired installation awaits official EU updates and returns backup paths' {
        $f=New-LauncherFixture; $d=Get-LauncherFixtureDiscovery $f
        $pending=[pscustomobject]@{Status='Unsupported';Reason='synthetic EU patch pending';CNDirectory=$d.CNDirectory;EUDirectory=$d.EUDirectory;LauncherPath=$d.LauncherPath}
        Set-LauncherDiscovery @($d,$pending)
        & $launcherModule {
            function script:Invoke-Sc2LauncherRepair {
                $script:LauncherTestRepairCalls++
                [pscustomobject]@{Status='Repaired';WorkDirectory='synthetic work';MetadataBackupDirectory='synthetic metadata';VersionsArchiveDirectory='synthetic archive';AccountToken='synthetic-private-repair-never-return'}
            }
        }
        $r=Invoke-Sc2LauncherAction -Action Repair
        Assert-Launcher ($r.Success -and $r.Status -eq 'RepairNeedsUpdate' -and $r.UpdateClientOpened) 'New repair incorrectly claimed the game is ready.'
        Assert-Launcher ($r.Discovery.Status -eq 'Unsupported') 'Post-repair state was not refreshed.'
        Assert-Launcher ($r.WorkDirectory -eq 'synthetic work' -and $r.MetadataBackupDirectory -eq 'synthetic metadata' -and $r.VersionsArchiveDirectory -eq 'synthetic archive') 'Private backup locations were lost.'
        Assert-Launcher (($r|ConvertTo-Json -Depth 8) -notmatch 'synthetic-private-repair') 'Unrecognized repair fields leaked into result data.'
        Assert-Launcher ((& $launcherModule {$script:LauncherTestUpdateCalls}) -eq 1 -and @(Get-LauncherCalls).Count -eq 0) 'Repair should open only the official update client, never start the game.'
    }
    Test-Launcher 'failure to open the update client preserves the completed repair result' {
        $f=New-LauncherFixture; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        & $launcherModule {
            function script:Invoke-Sc2LauncherRepair {[pscustomobject]@{Status='Repaired';WorkDirectory='synthetic retained backup'}}
            function script:Open-Sc2EUUpdateClient {throw 'synthetic client opening failed'}
        }
        $r=Invoke-Sc2LauncherAction -Action Repair
        Assert-Launcher ($r.Success -and $r.Status -eq 'RepairNeedsUpdate' -and -not $r.UpdateClientOpened) 'Client-open failure erased a completed repair.'
        Assert-Launcher ($r.WorkDirectory -eq 'synthetic retained backup' -and $r.Message -match 'synthetic client opening failed') 'Client-open failure did not preserve actionable repair details.'
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'Client-open failure started a game.'
    }
    Test-Launcher 'protected repair failure returns a failed result without an implicit game launch' {
        $f=New-LauncherFixture; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        & $launcherModule {function script:Invoke-Sc2LauncherRepair {throw 'synthetic protected offline guard'}}
        $r=Invoke-Sc2LauncherAction -Action Repair
        Assert-Launcher (-not $r.Success -and $r.Status -eq 'Failed' -and $r.Message -match 'synthetic protected offline guard') 'Protected repair exception was not reported.'
        Assert-Launcher ((& $launcherModule {$script:LauncherTestUpdateCalls}) -eq 0 -and @(Get-LauncherCalls).Count -eq 0) 'Failed repair started a client or game.'
    }
    Test-Launcher 'update client opening contains no game launch command' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f
        & $launcherModule {
            param($Body)
            Set-Item -LiteralPath Function:script:Open-Sc2EUUpdateClient -Value $Body
            $script:NativeStarterCall=$null
            function script:Start-Process([string]$FilePath,$ArgumentList) {$script:NativeStarterCall=[pscustomobject]@{FilePath=$FilePath;Arguments=($ArgumentList -join ' ')}}
        } $script:launcherOriginalFunctions['Open-Sc2EUUpdateClient']
        & $launcherModule {param($Path) Open-Sc2EUUpdateClient -LauncherPath $Path} $d.LauncherPath
        $call=& $launcherModule {$script:NativeStarterCall}
        Assert-Launcher ($call.FilePath -eq $d.LauncherPath -and $call.Arguments -eq '--setregion=EU') 'Update-client opening tried to launch the game.'
    }
    Test-Launcher 'native starter rejects mismatched product and region before creating a process' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f
        & $launcherModule {
            param($Body)
            Set-Item -LiteralPath Function:script:Start-Sc2RegionalLauncher -Value $Body
            $script:NativeStarterCalls=0
            function script:Start-Process {$script:NativeStarterCalls++}
        } $script:launcherOriginalFunctions['Start-Sc2RegionalLauncher']
        Assert-LauncherRejected {& $launcherModule {param($Path) Start-Sc2RegionalLauncher -LauncherPath $Path -Region CN -Product s2} $d.LauncherPath} 'Native starter accepted a CN / EU product mismatch.'
        Assert-Launcher ((& $launcherModule {$script:NativeStarterCalls}) -eq 0) 'Native starter created a process before validating the region and product.'
    }
    Test-Launcher 'native starter rejects missing registered executables rather than searching PATH' {
        $missing=Join-Path $testRoot 'missing\Battle.net Launcher.exe'
        & $launcherModule {
            param($Body)
            Set-Item -LiteralPath Function:script:Start-Sc2RegionalLauncher -Value $Body
            $script:NativeStarterCalls=0
            function script:Start-Process {$script:NativeStarterCalls++}
        } $script:launcherOriginalFunctions['Start-Sc2RegionalLauncher']
        Assert-LauncherRejected {& $launcherModule {param($Path) Start-Sc2RegionalLauncher -LauncherPath $Path -Region EU -Product s2} $missing} 'Native starter accepted a missing executable.'
        Assert-Launcher ((& $launcherModule {$script:NativeStarterCalls}) -eq 0) 'Missing launcher triggered a native process creation.'
    }
    Test-Launcher 'discovery failure becomes an actionable result and never falls through to launch' {
        & $launcherModule {function script:Get-Sc2LauncherDiscovery {throw 'synthetic database unreadable'}}
        $r=Invoke-Sc2LauncherAction -Action LaunchCN
        Assert-Launcher (-not $r.Success -and $r.Status -eq 'Failed' -and $r.Message -match 'synthetic database unreadable') 'Discovery exception was not represented as failure.'
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'Discovery exception fell through to a native launch.'
    }
    Test-Launcher 'worker success writes UTF8 JSON and captures every diagnostic stream' {
        $worker=New-LauncherWorkerFixture
        $script:workerChinese=([char]0x56FD).ToString()+([char]0x670D).ToString()
        function script:Invoke-Sc2LauncherAction([string]$Action) {
            Write-Host ('host '+$script:workerChinese)
            Write-Warning 'synthetic warning'
            Write-Verbose 'synthetic verbose' -Verbose
            Write-Information 'synthetic information' -InformationAction Continue
            Write-Error 'synthetic continued error' -ErrorAction Continue
            [pscustomobject]@{SchemaVersion=1;Success=$true;Action=$Action;Status='Separated';Discovery=$null;Message=('synthetic success '+$script:workerChinese)}
        }
        $code=Invoke-Sc2LauncherWorker -Action Inspect -ResultPath $worker.ResultPath -LogPath $worker.LogPath
        $result=Get-Content -LiteralPath $worker.ResultPath -Raw -Encoding UTF8|ConvertFrom-Json
        $log=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($worker.LogPath))
        Assert-Launcher ($code -eq 0 -and $result.Success -and $result.Action -eq 'Inspect' -and $result.Status -eq 'Separated') 'Worker success JSON is incomplete or returned a failure code.'
        foreach($marker in @(('host '+$script:workerChinese),'synthetic warning','synthetic verbose','synthetic information','synthetic continued error',('synthetic success '+$script:workerChinese))) {
            Assert-Launcher ($log.Contains($marker)) ('Worker log lost a diagnostic stream: '+$marker)
        }
        Assert-Launcher (@(Get-ChildItem -LiteralPath $worker.Directory -Force -Filter '*.tmp').Count -eq 0) 'Worker left an incomplete JSON temporary file.'
    }
    Test-Launcher 'worker captures real controller repair progress without corrupting its result assignment' {
        $worker=New-LauncherWorkerFixture; $f=New-LauncherFixture; $d=Get-LauncherFixtureDiscovery $f
        Set-LauncherDiscovery @($d,[pscustomobject]@{Status='Unsupported';Reason='synthetic waiting for official update'})
        & $launcherModule {
            function script:Invoke-Sc2LauncherRepair {
                Write-Host 'synthetic repair host progress'
                Write-Warning 'synthetic repair warning'
                Write-Verbose 'synthetic repair verbose' -Verbose
                # Windows PowerShell -Debug selects Inquire and needs an
                # interactive host. Emit a debug stream without prompting.
                $DebugPreference='Continue'
                Write-Debug 'synthetic repair debug'
                [pscustomobject]@{Status='Repaired';WorkDirectory='synthetic repair retained backup'}
            }
        }
        $code=Invoke-Sc2LauncherWorker -Action Repair -ResultPath $worker.ResultPath -LogPath $worker.LogPath
        $result=Get-Content -LiteralPath $worker.ResultPath -Raw -Encoding UTF8|ConvertFrom-Json
        Assert-Launcher ($code -eq 0 -and $result.Success -and $result.Status -eq 'RepairNeedsUpdate' -and $result.WorkDirectory -eq 'synthetic repair retained backup') 'Merged diagnostic streams corrupted the internal repair object.'
        $log=Get-Content -LiteralPath $worker.LogPath -Raw -Encoding UTF8
        foreach($marker in @('synthetic repair host progress','synthetic repair warning','synthetic repair verbose','synthetic repair debug')) {Assert-Launcher ($log.Contains($marker)) ('Worker lost repair progress: '+$marker)}
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'Repair worker started a game.'
    }
    Test-Launcher 'worker preserves rejected controller results and returns a failure exit code' {
        $worker=New-LauncherWorkerFixture
        function script:Invoke-Sc2LauncherAction([string]$Action) {[pscustomobject]@{SchemaVersion=1;Success=$false;Action=$Action;Status='NeedsRepair';Discovery=$null;Message='synthetic guarded refusal'}}
        $code=Invoke-Sc2LauncherWorker -Action LaunchEU -ResultPath $worker.ResultPath -LogPath $worker.LogPath
        $result=Get-Content -LiteralPath $worker.ResultPath -Raw -Encoding UTF8|ConvertFrom-Json
        Assert-Launcher ($code -eq 1 -and -not $result.Success -and $result.Status -eq 'NeedsRepair' -and $result.Action -eq 'LaunchEU') 'Worker lost a guarded refusal or returned success.'
        Assert-Launcher ((Get-Content -LiteralPath $worker.LogPath -Raw -Encoding UTF8).Contains('synthetic guarded refusal')) 'Worker refusal message was not logged.'
    }
    Test-Launcher 'worker catches unexpected errors and still emits parseable failure JSON' {
        $worker=New-LauncherWorkerFixture
        function script:Invoke-Sc2LauncherAction {throw 'synthetic worker exception'}
        $code=Invoke-Sc2LauncherWorker -Action Repair -ResultPath $worker.ResultPath -LogPath $worker.LogPath
        $result=Get-Content -LiteralPath $worker.ResultPath -Raw -Encoding UTF8|ConvertFrom-Json
        Assert-Launcher ($code -eq 1 -and -not $result.Success -and $result.Status -eq 'Failed' -and $result.Action -eq 'Repair' -and $result.Message -match 'synthetic worker exception') 'Worker exception did not produce a useful failure result.'
    }
    Test-Launcher 'worker missing result cannot masquerade as a successful operation' {
        $worker=New-LauncherWorkerFixture
        function script:Invoke-Sc2LauncherAction {Write-Host 'synthetic progress without a result'}
        $code=Invoke-Sc2LauncherWorker -Action Inspect -ResultPath $worker.ResultPath -LogPath $worker.LogPath
        $result=Get-Content -LiteralPath $worker.ResultPath -Raw -Encoding UTF8|ConvertFrom-Json
        Assert-Launcher ($code -eq 1 -and -not $result.Success -and $result.Status -eq 'Failed') 'Worker accepted a progress message as a successful result.'
    }
    Test-Launcher 'worker refuses to overwrite an existing result before creating a log' {
        $worker=New-LauncherWorkerFixture; Write-FixtureText $worker.ResultPath 'synthetic existing result'
        function script:Invoke-Sc2LauncherAction {throw 'Worker should not invoke an action after output rejection.'}
        Assert-LauncherRejected {Invoke-Sc2LauncherWorker -Action Inspect -ResultPath $worker.ResultPath -LogPath $worker.LogPath} 'Worker overwrote an existing result.'
        Assert-Launcher ((Get-Content -LiteralPath $worker.ResultPath -Raw) -eq 'synthetic existing result' -and -not [IO.File]::Exists($worker.LogPath)) 'Output rejection changed files.'
    }
    Test-Launcher 'worker refuses to overwrite an existing log before creating a result' {
        $worker=New-LauncherWorkerFixture; Write-FixtureText $worker.LogPath 'synthetic existing log'
        Assert-LauncherRejected {Invoke-Sc2LauncherWorker -Action Inspect -ResultPath $worker.ResultPath -LogPath $worker.LogPath} 'Worker overwrote an existing log.'
        Assert-Launcher ((Get-Content -LiteralPath $worker.LogPath -Raw) -eq 'synthetic existing log' -and -not [IO.File]::Exists($worker.ResultPath)) 'Log rejection changed files.'
    }
    Test-Launcher 'worker refuses arbitrary output directories outside its private temporary namespace' {
        $resultPath=Join-Path $testRoot 'unapproved-result.json'; $logPath=Join-Path $testRoot 'unapproved-log.txt'
        Assert-LauncherRejected {Invoke-Sc2LauncherWorker -Action Inspect -ResultPath $resultPath -LogPath $logPath} 'Worker accepted arbitrary output paths.'
        Assert-Launcher (-not [IO.File]::Exists($resultPath) -and -not [IO.File]::Exists($logPath)) 'Rejected output paths were written.'
    }
    Test-Launcher 'worker requires separate result and log files in the same private directory' {
        $one=New-LauncherWorkerFixture; $two=New-LauncherWorkerFixture
        Assert-LauncherRejected {Invoke-Sc2LauncherWorker -Action Inspect -ResultPath $one.ResultPath -LogPath $one.ResultPath} 'Worker accepted one file for JSON and logs.'
        Assert-LauncherRejected {Invoke-Sc2LauncherWorker -Action Inspect -ResultPath $one.ResultPath -LogPath $two.LogPath} 'Worker accepted result and log files in different directories.'
        Assert-Launcher (-not [IO.File]::Exists($one.ResultPath) -and -not [IO.File]::Exists($two.LogPath)) 'Rejected worker output layout was written.'
    }
    Test-Launcher 'Europe Americas and Asia use one international install without rewriting its records' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        $before=Get-LauncherTreeFingerprint $f.Root
        $choices=@([pscustomobject]@{Action='LaunchEU';Region='EU'},[pscustomobject]@{Action='LaunchUS';Region='US'},[pscustomobject]@{Action='LaunchAsia';Region='KR'})
        foreach($choice in $choices) {
            $r=Invoke-Sc2LauncherAction -Action $choice.Action
            Assert-Launcher ($r.Success -and $r.Status -eq 'Started' -and $r.GameRegionConfirmed -and $r.TargetRegion -eq $choice.Region) 'International launch did not report the confirmed target game region.'
        }
        $calls=@(Get-LauncherCalls)
        Assert-Launcher ($calls.Count -eq 3) 'International launch count is incorrect.'
        for($i=0;$i -lt $choices.Count;$i++) {
            Assert-Launcher ($calls[$i].LauncherPath -eq $d.LauncherPath -and $calls[$i].GameDirectory -eq $d.EUDirectory -and $calls[$i].Product -eq 's2' -and $calls[$i].Region -eq $choices[$i].Region) 'International selection changed product / directory or used a login-region argument as the game region.'
        }
        Assert-Launcher ((Get-LauncherTreeFingerprint $f.Root) -eq $before) 'International region selection rewrote an installation file.'
    }
    Test-Launcher 'Americas and Asia are blocked while international files still collide with CN' {
        $f=New-LauncherFixture; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        $before=Get-LauncherTreeFingerprint $f.Root
        foreach($action in @('LaunchUS','LaunchAsia')) {
            $r=Invoke-Sc2LauncherAction -Action $action
            Assert-Launcher (-not $r.Success -and $r.Status -eq 'NeedsRepair') 'An international target started from a CN-conflicting install.'
        }
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0 -and (Get-LauncherTreeFingerprint $f.Root) -eq $before) 'Conflict rejection launched a helper or changed metadata.'
    }
    Test-Launcher 'Americas and Asia reject unsupported installation metadata' {
        Set-LauncherDiscovery @([pscustomobject]@{Status='Unsupported';Reason='synthetic unsupported product mapping'})
        foreach($action in @('LaunchUS','LaunchAsia')) {
            $r=Invoke-Sc2LauncherAction -Action $action
            Assert-Launcher (-not $r.Success -and $r.Status -eq 'Unsupported') 'Unsupported international install was accepted.'
        }
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'Unsupported metadata invoked an international helper.'
    }
    Test-Launcher 'international action rechecks current records when the selected dropdown region changes' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f
        Set-LauncherDiscovery @($d,[pscustomobject]@{Status='Conflict';Reason='synthetic collision after initial inspection'})
        $null=Get-Sc2LauncherInspection
        $r=Invoke-Sc2LauncherAction -Action LaunchUS
        Assert-Launcher (-not $r.Success -and $r.Status -eq 'NeedsRepair' -and @(Get-LauncherCalls).Count -eq 0) 'International action used stale inspection / dropdown state.'
    }
    Test-Launcher 'CN launch does not invoke international region UI automation' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        & $launcherModule {function script:Invoke-Sc2InternationalLaunch {throw 'CN must not use international controls.'}}
        $r=Invoke-Sc2LauncherAction -Action LaunchCN; $calls=@(Get-LauncherCalls)
        Assert-Launcher ($r.Success -and $r.Status -eq 'Started' -and $calls.Count -eq 1 -and $calls[0].Kind -eq 'CNDirect' -and $calls[0].Product -eq 's2_cn') 'CN launch used international controls.'
    }
    Test-Launcher 'international helper must confirm typed booleans exact target and actual Started status' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        $outcomes=@(
            $null,
            [pscustomobject]@{Success=$false;GameRegionConfirmed=$false;Region='US';Status='NeedsOfficialSelection';Message='synthetic official login needed'},
            [pscustomobject]@{Success='true';GameRegionConfirmed='true';Region='US';Status='Started';Message='synthetic incorrect types'},
            [pscustomobject]@{Success=$true;GameRegionConfirmed=$false;Region='US';Status='Started';Message='synthetic unconfirmed caption'},
            [pscustomobject]@{Success=$true;GameRegionConfirmed=$true;Region='EU';Status='Started';Message='synthetic wrong actual region'},
            [pscustomobject]@{Success=$true;GameRegionConfirmed=$true;Region='US';Status='Confirmed';Message='synthetic not launched'},
            [pscustomobject]@{GameRegionConfirmed=$true;Region='US';Status='Started';Message='synthetic missing success'}
        )
        foreach($outcome in $outcomes) {
            & $launcherModule {param($Value) $script:LauncherTestInternationalOutcome=$Value;function script:Invoke-Sc2InternationalLaunch {$script:LauncherTestInternationalOutcome}} $outcome
            $r=Invoke-Sc2LauncherAction -Action LaunchUS
            Assert-Launcher (-not $r.Success -and $r.Status -eq 'NeedsOfficialSelection' -and -not $r.GameRegionConfirmed -and $r.TargetRegion -eq 'US') 'Unconfirmed / mismatched / untyped helper result was promoted to a started game.'
        }
    }
    Test-Launcher 'already running international game blocks all game-region helpers rather than guessing its server' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        Set-LauncherProcesses @([pscustomobject]@{Name='SC2_x64';Id=205;Path=(Join-Path $f.EUDirectory ('Versions\Base'+$f.EUVersion.Split('.')[-1]+'\SC2_x64.exe'))})
        foreach($action in @('LaunchEU','LaunchUS','LaunchAsia')) {
            $r=Invoke-Sc2LauncherAction -Action $action
            Assert-Launcher (-not $r.Success -and $r.Status -eq 'GameRunning') 'An international executable path was incorrectly treated as proof of the selected server.'
        }
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'Running international game triggered region UI automation.'
    }
    Test-Launcher 'unconfirmed game paths and running editors stop Americas and Asia UI attempts' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        foreach($process in @([pscustomobject]@{Name='SC2';Id=206;Path=$null},[pscustomobject]@{Name='SC2Editor';Id=207;Path=(Join-Path $f.CNDirectory 'Support\SC2Editor.exe')})) {
            Set-LauncherProcesses @($process)
            foreach($action in @('LaunchUS','LaunchAsia')) {
                $r=Invoke-Sc2LauncherAction -Action $action
                Assert-Launcher (-not $r.Success -and $r.Status -eq 'GameRunning') 'An unknown game or active editor allowed international region automation.'
            }
        }
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'A game / editor guard still invoked region UI automation.'
    }
    Test-Launcher 'worker supports Americas and Asia and preserves exact confirmed target fields' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f; Set-LauncherDiscovery @($d)
        foreach($choice in @([pscustomobject]@{Action='LaunchUS';Region='US'},[pscustomobject]@{Action='LaunchAsia';Region='KR'})) {
            $worker=New-LauncherWorkerFixture
            $code=Invoke-Sc2LauncherWorker -Action $choice.Action -ResultPath $worker.ResultPath -LogPath $worker.LogPath
            $result=Get-Content -LiteralPath $worker.ResultPath -Raw -Encoding UTF8|ConvertFrom-Json
            Assert-Launcher ($code -eq 0 -and $result.Success -and $result.Action -eq $choice.Action -and $result.TargetRegion -eq $choice.Region -and $result.GameRegionConfirmed) 'Worker lost the selected international target or confirmation result.'
        }
    }
    Test-Launcher 'international helper opens one login client then selects game region in the same install' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f
        Set-LauncherSyntheticHelper $f ([pscustomobject]@{Success=$true;GameRegionConfirmed=$true;Region='US';Status='Started';Message='synthetic Americas official Play confirmed'})
        $before=Get-LauncherTreeFingerprint $f.Root
        & $launcherModule {param($Body) Set-Item -LiteralPath Function:script:Invoke-Sc2InternationalLaunch -Value $Body} $script:launcherOriginalFunctions['Invoke-Sc2InternationalLaunch']
        $r=& $launcherModule {param($Path,$Game) Invoke-Sc2InternationalLaunch -LauncherPath $Path -GameDirectory $Game -Region US} $d.LauncherPath $d.EUDirectory
        $call=& $launcherModule {$script:LauncherTestHelperCall}; $events=@(& $launcherModule {$script:LauncherTestHelperEvents})
        Assert-Launcher ($r.Success -and $r.GameRegionConfirmed -and $r.Region -eq 'US' -and $r.Status -eq 'Started') 'Typed helper confirmation was not accepted.'
        Assert-Launcher ($events.Count -eq 2 -and $events[0] -eq 'OpenInternationalClient' -and $events[1] -eq 'ConfirmGameRegionAndInvokeOfficialPlay') 'Game-region confirmation was attempted before opening the official international client.'
        Assert-Launcher ($call.Arguments.Contains('--switch-region US') -and $call.Arguments.Contains('--launcher-path "'+$d.LauncherPath+'"') -and $call.Arguments.Contains('--game-directory "'+$d.EUDirectory+'"') -and $call.Arguments -notmatch '--exec') 'Helper arguments confused login region with game region or launched before confirmation.'
        Assert-Launcher ((Get-LauncherTreeFingerprint $f.Root) -eq $before) 'International helper invocation changed metadata.'
        Assert-Launcher ((& $launcherModule {$script:LauncherTestHelperProcess.DisposeCalls}) -eq 1 -and (& $launcherModule {$script:LauncherTestHelperProcess.KillCalls}) -eq 0) 'Completed helper was not disposed safely.'
    }
    Test-Launcher 'international helper rejects wrong region and unsuccessful exit even when JSON claims success' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f
        & $launcherModule {param($Body) Set-Item -LiteralPath Function:script:Invoke-Sc2InternationalLaunch -Value $Body} $script:launcherOriginalFunctions['Invoke-Sc2InternationalLaunch']
        foreach($choice in @([pscustomobject]@{Region='EU';ExitCode=0},[pscustomobject]@{Region='US';ExitCode=1})) {
            Set-LauncherSyntheticHelper $f ([pscustomobject]@{Success=$true;GameRegionConfirmed=$true;Region=$choice.Region;Status='Started';Message='synthetic inconsistent confirmation'}) -ExitCode $choice.ExitCode
            $r=& $launcherModule {param($Path,$Game) Invoke-Sc2InternationalLaunch -LauncherPath $Path -GameDirectory $Game -Region US} $d.LauncherPath $d.EUDirectory
            Assert-Launcher (-not $r.Success -and -not $r.GameRegionConfirmed -and $r.Status -eq 'NeedsOfficialSelection') 'Wrong helper region / failed native exit was trusted.'
        }
    }
    Test-Launcher 'international helper timeout stops only its own synthetic helper and never a game or battle process' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f
        Set-LauncherSyntheticHelper $f $null -WaitResult $false -NoResult
        & $launcherModule {param($Body) Set-Item -LiteralPath Function:script:Invoke-Sc2InternationalLaunch -Value $Body} $script:launcherOriginalFunctions['Invoke-Sc2InternationalLaunch']
        $r=& $launcherModule {param($Path,$Game) Invoke-Sc2InternationalLaunch -LauncherPath $Path -GameDirectory $Game -Region KR} $d.LauncherPath $d.EUDirectory
        Assert-Launcher (-not $r.Success -and -not $r.GameRegionConfirmed -and $r.Status -eq 'NeedsOfficialSelection') 'Timed-out helper reported a started game.'
        Assert-Launcher ((& $launcherModule {$script:LauncherTestHelperProcess.KillCalls}) -eq 1 -and (& $launcherModule {$script:LauncherTestHelperProcess.DisposeCalls}) -eq 1) 'Timed-out own helper was not closed / disposed.'
        Assert-Launcher (@(Get-LauncherCalls).Count -eq 0) 'Helper timeout fell through to game launch.'
    }
    Test-Launcher 'missing helper result refuses successful server selection' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f
        Set-LauncherSyntheticHelper $f $null -NoResult
        & $launcherModule {param($Body) Set-Item -LiteralPath Function:script:Invoke-Sc2InternationalLaunch -Value $Body} $script:launcherOriginalFunctions['Invoke-Sc2InternationalLaunch']
        $r=& $launcherModule {param($Path,$Game) Invoke-Sc2InternationalLaunch -LauncherPath $Path -GameDirectory $Game -Region EU} $d.LauncherPath $d.EUDirectory
        Assert-Launcher (-not $r.Success -and -not $r.GameRegionConfirmed -and $r.Status -eq 'NeedsOfficialSelection') 'Missing helper result was treated as game-region confirmation.'
    }
    Test-Launcher 'actual native region helper compiles and recognizes all supported international option labels' {
        Initialize-LauncherRegionParser
        foreach($choice in @(
            [pscustomobject]@{Name='Europe';Region='EU'},[pscustomobject]@{Name='欧洲';Region='EU'},[pscustomobject]@{Name='歐洲';Region='EU'},
            [pscustomobject]@{Name='Americas';Region='US'},[pscustomobject]@{Name='美洲';Region='US'},
            [pscustomobject]@{Name='Asia';Region='KR'},[pscustomobject]@{Name='亚洲';Region='KR'},[pscustomobject]@{Name='亞洲';Region='KR'})) {
            Assert-Launcher ((Invoke-LauncherRegionMethod ParseRegionOptionName @($choice.Name)) -eq $choice.Region) ('Known option not recognized: '+$choice.Name)
        }
    }
    Test-Launcher 'native option parsing refuses CN unknown languages aliases and caption fragments' {
        foreach($name in @($null,'','China','中国','國服','CN','EU','US','KR','Europa','United States','Europe account login','Region: Europe','Play: StarCraft II, Region: Asia, Version: 5.0.17.98310')) {
            Assert-Launcher ($null -eq (Invoke-LauncherRegionMethod ParseRegionOptionName @($name))) 'Unknown / non-option caption was accepted as an international option.'
        }
    }
    Test-Launcher 'native region-menu parsing requires an explicit known field and full caption' {
        foreach($choice in @([pscustomobject]@{Name='Region: Europe';Region='EU'},[pscustomobject]@{Name='地区：美洲';Region='US'},[pscustomobject]@{Name='區域：亞洲';Region='KR'})) {
            Assert-Launcher ((Invoke-LauncherRegionMethod ParseRegionMenuName @($choice.Name)) -eq $choice.Region) 'A supported region menu field was not recognized.'
        }
        foreach($name in @('Europe','Americas','Asia','Battle.net Region: Europe','Region: China','Region: Europe Version: 5.0.17.98310','Your current region is Americas','Región: Europe','地区：美洲 account')) {
            Assert-Launcher ($null -eq (Invoke-LauncherRegionMethod ParseRegionMenuName @($name))) 'An ambiguous caption was treated as the region menu.'
        }
    }
    Test-Launcher 'native Play parsing recognizes complete English simplified and traditional Chinese identities' {
        foreach($choice in @(
            [pscustomobject]@{Name='Play: StarCraft II, Region: Europe, Version: 5.0.17.98310';Region='EU'},
            [pscustomobject]@{Name='Play: StarCraft II, Region: Americas, Version: 5.0.17.98310';Region='US'},
            [pscustomobject]@{Name='Play: StarCraft II, Region: Asia, Version: 5.0.17.98310';Region='KR'},
            [pscustomobject]@{Name='开始游戏：星际争霸 II，地区：美洲，版本：5.0.17.98310';Region='US'},
            [pscustomobject]@{Name='開始遊戲：星海爭霸 II，地區：亞洲，版本：5.0.17.98310';Region='KR'})) {
            Assert-Launcher ((Invoke-LauncherRegionMethod ParseRegionFromPlayName @($choice.Name)) -eq $choice.Region) 'Complete official game identity / known localization was not recognized.'
            Assert-Launcher ([bool](Invoke-LauncherRegionMethod IsConfirmedPlay @($choice.Name,$choice.Region))) 'Exact region match was not confirmed.'
        }
    }
    Test-Launcher 'native Play confirmation refuses unknown CN missing version other games and region mismatches' {
        foreach($name in @(
            $null,'','Play: StarCraft II, Region: China, Version: 5.0.17.98370','Play: StarCraft II, Region: Europe, Version:',
            'Play: StarCraft II, Region: Europe, Version: unknown','Play: StarCraft II, Region: Europe, Version: 98310',
            'Play: Warcraft III, Region: Europe, Version: 5.0.17.98310','Play: StarCraft II PTR, Region: Europe, Version: 5.0.17.98310',
            'Play: StarCraft II, Region: Europe, Version: 5.0.17.98310 account','Region: Europe',
            'Jouer: StarCraft II, Region: Europe, Version: 5.0.17.98310')) {
            Assert-Launcher ($null -eq (Invoke-LauncherRegionMethod ParseRegionFromPlayName @($name))) 'Unconfirmed game caption was recognized.'
            Assert-Launcher (-not [bool](Invoke-LauncherRegionMethod IsConfirmedPlay @($name,'EU'))) 'Invalid game caption allowed a Play invocation.'
        }
        $known='Play: StarCraft II, Region: Europe, Version: 5.0.17.98310'
        foreach($expected in @('US','KR','CN','eu','')) {Assert-Launcher (-not [bool](Invoke-LauncherRegionMethod IsConfirmedPlay @($known,$expected))) 'A mismatched / unknown requested region was confirmed.'}
    }
    Test-Launcher 'native international metadata check reads a single active official global version without writing' {
        $f=New-LauncherFixture -Separated; $before=Get-LauncherTreeFingerprint $f.Root
        $version=Invoke-LauncherRegionMethod ReadInternationalVersion @($f.EUDirectory) -Private
        Assert-Launcher ($version -eq $f.EUVersion) 'Native region helper did not read the active international version.'
        Assert-Launcher ((Get-LauncherTreeFingerprint $f.Root) -eq $before) 'Native metadata verification changed a game file.'
    }
    Test-Launcher 'native international metadata rejects CN rows duplicate active rows and wrong products' {
        $f=New-LauncherFixture -Separated; $path=Join-Path $f.EUDirectory '.build.info'; $original=Get-Content -LiteralPath $path -Raw
        Write-FixtureText $path ($original.Replace('eu|1|','cn|1|'))
        Assert-LauncherNativeMetadataRejected $f.EUDirectory 'Native helper accepted a CN branch as an international install.'
        $lines=@($original -split '\r?\n'|Where-Object {$_})
        Write-FixtureText $path ($original+$lines[1]+"`r`n")
        Assert-LauncherNativeMetadataRejected $f.EUDirectory 'Native helper accepted two active international builds.'
        Write-FixtureText $path ($lines[0]+'|Product!STRING:0'+"`r`n"+$lines[1]+'|s2_cn'+"`r`n")
        Assert-LauncherNativeMetadataRejected $f.EUDirectory 'Native helper accepted an explicit CN product in the international install.'
    }
    Test-Launcher 'native startup accepts only valid signatures from the known Blizzard publisher names' {
        $f=New-LauncherFixture -Separated; $d=Get-LauncherFixtureDiscovery $f
        & $launcherModule {
            param($Body)
            Set-Item -LiteralPath Function:script:Start-Sc2RegionalLauncher -Value $Body
            $script:LauncherTestNativeStarts=0
            $script:LauncherTestSignaturePaths=[Collections.Generic.List[string]]::new()
            function script:Get-Sc2OfficialLauncherSignature([string]$Path) {
                $script:LauncherTestSignaturePaths.Add($Path)
                [pscustomobject]@{Status='Valid';SignerName=$script:LauncherTestSigner}
            }
            function script:Start-Process {$script:LauncherTestNativeStarts++}
        } $script:launcherOriginalFunctions['Start-Sc2RegionalLauncher']
        foreach($signer in @('Blizzard Entertainment','Blizzard Entertainment, Inc.','Blizzard Entertainment Inc.')) {
            & $launcherModule {param($Name) $script:LauncherTestSigner=$Name} $signer
            & $launcherModule {param($Path) Start-Sc2RegionalLauncher -LauncherPath $Path -Region CN -Product s2_cn} $d.LauncherPath
        }
        $paths=@(& $launcherModule {$script:LauncherTestSignaturePaths})
        Assert-Launcher ((& $launcherModule {$script:LauncherTestNativeStarts}) -eq 3 -and $paths.Count -eq 3) 'Valid known publisher signatures were not accepted before startup.'
        foreach($path in $paths) {Assert-Launcher ($path -eq $d.LauncherPath) 'Signature lookup did not inspect the exact executable selected for launch.'}
    }
    Test-Launcher 'unsigned or missing certificate metadata stops every native launcher path' {
        $f=New-LauncherFixture -Separated
        foreach($signature in @($null,[pscustomobject]@{Status='NotSigned';SignerName=''},[pscustomobject]@{Status='Valid';SignerName=$null},[pscustomobject]@{SignerName='Blizzard Entertainment, Inc.'})) {
            Assert-LauncherSignatureStopsProcesses $f $signature
        }
    }
    Test-Launcher 'invalid or untrusted Blizzard signatures cannot start a launcher or helper' {
        $f=New-LauncherFixture -Separated
        foreach($status in @('HashMismatch','NotTrusted','UnknownError')) {
            Assert-LauncherSignatureStopsProcesses $f ([pscustomobject]@{Status=$status;SignerName='Blizzard Entertainment, Inc.'})
        }
    }
    Test-Launcher 'valid signatures from other or misleading publishers cannot pass the Blizzard identity guard' {
        $f=New-LauncherFixture -Separated
        foreach($name in @('Synthetic Other Company','Not Blizzard Entertainment, Inc.','Blizzard Entertainment Malware','Blizzard Entertainment, Inc. (unverified)')) {
            Assert-LauncherSignatureStopsProcesses $f ([pscustomobject]@{Status='Valid';SignerName=$name})
        }
    }
    Test-Launcher 'Authenticode lookup errors fail closed before starting native processes' {
        $f=New-LauncherFixture -Separated
        Assert-LauncherSignatureStopsProcesses $f $null -LookupThrows
    }
}
finally {
    foreach($name in $script:launcherOriginalFunctions.Keys) {
        & $launcherModule {param($Name,$Body) Set-Item -LiteralPath ('Function:script:'+$Name) -Value $Body} $name $script:launcherOriginalFunctions[$name]
    }
    Set-Item -LiteralPath Function:script:Invoke-Sc2LauncherAction -Value $script:originalWorkerAction
    & $launcherModule { foreach($name in @('Start-Process','Stop-Process')) { Remove-Item -LiteralPath ('Function:script:'+$name) -ErrorAction SilentlyContinue } }
}
$failed=@($script:launcherResults|Where-Object {-not $_.Passed}); $passed=@($script:launcherResults|Where-Object Passed)
Write-Host ("Launcher result: {0} passed; {1} failed." -f $passed.Count,$failed.Count)
if($failed.Count -or $KeepFixtures) {
    Write-Host ('Synthetic launcher fixtures preserved: '+$testRoot)
    foreach($workerDirectory in $script:launcherWorkerDirectories) {Write-Host ('Synthetic worker fixtures preserved: '+$workerDirectory)}
}
else {
    $fullRoot=[IO.Path]::GetFullPath($testRoot)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    Assert-Launcher ($fullRoot.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($fullRoot) -match '^sc2-launcher-tests-[a-f0-9]{32}$') 'Unsafe fixture cleanup path.'
    Assert-Launcher (([IO.File]::GetAttributes($fullRoot) -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Fixture cleanup root is a link.'
    Remove-Item -LiteralPath $fullRoot -Recurse -Force
    foreach($workerDirectory in $script:launcherWorkerDirectories) {
        $fullWorkerRoot=[IO.Path]::GetFullPath($workerDirectory)
        Assert-Launcher ($fullWorkerRoot.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetDirectoryName($fullWorkerRoot) -eq $temp.TrimEnd('\','/') -and [IO.Path]::GetFileName($fullWorkerRoot) -match '^sc2-launcher-[a-f0-9]{32}$') 'Unsafe worker fixture cleanup path.'
        Assert-Launcher (([IO.File]::GetAttributes($fullWorkerRoot) -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Worker cleanup root is a link.'
        Remove-Item -LiteralPath $fullWorkerRoot -Recurse -Force
    }
}
if($failed.Count) { exit 1 }
