#requires -Version 5.1
[CmdletBinding()]
param([switch]$KeepFixtures)

# These tests construct hidden controls and invoke their existing event handlers.
# They never show a form, run an application loop, start a timer or launch a worker.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\Show-SC2Launcher.ps1')
$script:windowTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('sc2-window-tests-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($script:windowTestRoot)
# Override this before constructing any view; never read or write real preferences.
$script:Sc2GuiRegionPath = Join-Path $script:windowTestRoot 'preferences.json'
$script:windowResults = [Collections.Generic.List[object]]::new()
$script:windowWorkerDirectories = [Collections.Generic.List[string]]::new()
$script:windowOriginalStart = (Get-Item Function:Start-Sc2GuiAction).ScriptBlock
$script:windowActions = [Collections.Generic.List[string]]::new()

function Assert-Window([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Write-WindowText([string]$Path,[string]$Text) {
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function New-WindowDiscovery([string]$Status) {
    [pscustomobject]@{
        Status=$Status
        CNDirectory=(Join-Path $script:windowTestRoot 'synthetic CN')
        EUDirectory=(Join-Path $script:windowTestRoot 'synthetic international')
        CNVersion='5.0.16.51029'; EUVersion='5.0.15.50913'
    }
}
function New-WindowResult([string]$Action,[string]$Status,[bool]$Success,$Discovery) {
    [pscustomobject]@{ SchemaVersion=1; Action=$Action; Status=$Status; Success=$Success; Message='Synthetic worker result'; Discovery=$Discovery }
}
function Set-WindowDiscovery([string]$Status) {
    Set-Sc2GuiResult (New-WindowResult 'Inspect' $Status ($Status -eq 'Separated') (New-WindowDiscovery $Status))
}
function New-WindowProcess([bool]$HasExited) {
    # A deliberately inert stand-in: no System.Diagnostics.Process is created.
    $process=[pscustomobject]@{HasExited=$HasExited;DisposeCalls=0;KillCalls=0}
    $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.DisposeCalls++ }
    $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { $this.KillCalls++; $this.HasExited=$true }
    return $process
}
function New-WindowTask([string]$Text) {
    $task=[pscustomobject]@{Text=$Text}
    $task | Add-Member -MemberType ScriptMethod -Name GetAwaiter -Value { return $this }
    $task | Add-Member -MemberType ScriptMethod -Name GetResult -Value { return $this.Text }
    return $task
}
function New-WindowJob([string]$Action,[bool]$HasExited=$true,[string]$ErrorText='') {
    $directory=Join-Path ([IO.Path]::GetTempPath()) ('sc2-launcher-' + [Guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($directory)
    $script:windowWorkerDirectories.Add($directory)
    [pscustomobject]@{
        Action=$Action; Process=(New-WindowProcess $HasExited)
        WorkDirectory=$directory; ResultPath=(Join-Path $directory 'result.json'); LogPath=(Join-Path $directory 'activity.log')
        LogPosition=0; Started=[DateTime]::UtcNow.AddSeconds(-2)
        OutputTask=(New-WindowTask ''); ErrorTask=(New-WindowTask $ErrorText)
    }
}
function Save-WindowJobResult($Job,$Result) {
    Write-WindowText $Job.ResultPath ($Result | ConvertTo-Json -Depth 8)
}
function Set-WindowActionSpy {
    function script:Start-Sc2GuiAction {
        param([ValidateSet('Inspect','LaunchCN','LaunchEU','LaunchUS','LaunchAsia','Repair')][string]$Action)
        $script:windowActions.Add($Action)
    }
}
function Invoke-WindowClick($Button) {
    Assert-Window $Button.Enabled 'A disabled button cannot represent an available user action'
    # PerformClick requires a selectable, displayed parent. OnClick reaches the
    # actual subscribed handler while keeping the entire window hidden.
    $method=[Windows.Forms.Button].GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
    $null=$method.Invoke($Button,[object[]]@([EventArgs]::Empty))
}
function Get-WindowClosingCancel {
    $args=[Windows.Forms.FormClosingEventArgs]::new([Windows.Forms.CloseReason]::UserClosing,$false)
    $method=[Windows.Forms.Form].GetMethod('OnFormClosing',[Reflection.BindingFlags]'Instance,NonPublic')
    $null=$method.Invoke($script:Sc2GuiView.Form,[object[]]@($args))
    return $args.Cancel
}
function Close-WindowFixture {
    $script:Sc2GuiJob=$null
    if ($null -ne $script:Sc2GuiView) {
        $script:Sc2GuiView.Timer.Stop()
        $script:Sc2GuiView.Timer.Dispose()
        $script:Sc2GuiView.ToolTip.Dispose()
        $script:Sc2GuiView.Form.Dispose()
        $script:Sc2GuiView=$null
    }
}
function Reset-WindowFixture {
    Close-WindowFixture
    if ([IO.File]::Exists($script:Sc2GuiRegionPath)) { [IO.File]::Delete($script:Sc2GuiRegionPath) }
    $script:Sc2GuiDiscovery=$null
    $script:Sc2GuiLastCheck=[DateTime]::UtcNow
    $script:windowActions.Clear()
    Set-WindowActionSpy
    $null=New-Sc2LauncherWindow
}
function Test-Window([string]$Name,[scriptblock]$Action) {
    try {
        Reset-WindowFixture
        & $Action
        Assert-Window (-not $script:Sc2GuiView.Form.Visible -and -not $script:Sc2GuiView.Timer.Enabled) 'Tests must keep the form hidden and timer stopped'
        $script:windowResults.Add([pscustomobject]@{Name=$Name;Passed=$true})
        Write-Host ('PASS ' + $Name)
    } catch {
        $script:windowResults.Add([pscustomobject]@{Name=$Name;Passed=$false})
        Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message)
    } finally { Close-WindowFixture }
}
function Assert-WindowReady([bool]$CN,[bool]$International) {
    $view=$script:Sc2GuiView
    Assert-Window ($view.CNButton.Enabled -eq $CN) 'CN action state is wrong'
    Assert-Window ($view.EUButton.Enabled -eq $International) 'International action state is wrong'
    Assert-Window ($view.RegionSelector.Enabled -eq $International) 'Region selector state is wrong'
    Assert-Window $view.RepairButton.Enabled 'Check/repair must remain available for retry'
    Assert-Window $view.Form.ControlBox 'The completed window must be closeable'
    Assert-Window (-not $view.Form.UseWaitCursor) 'The completed window still has a busy cursor'
}
function Assert-WindowBusy([string]$Action,$Job) {
    $script:Sc2GuiJob=$Job
    Set-Sc2GuiBusy $true $Action
    $view=$script:Sc2GuiView
    Assert-Window (-not $view.CNButton.Enabled -and -not $view.EUButton.Enabled -and -not $view.RepairButton.Enabled -and -not $view.RegionSelector.Enabled) 'Busy actions must reject duplicate user input'
    Assert-Window $view.Form.UseWaitCursor 'A busy worker must show the wait cursor'
    # Exercise the production guard with an occupied job. It must return before
    # checking an executable path or creating any worker process.
    & $script:windowOriginalStart 'Repair'
    Assert-Window ([object]::ReferenceEquals($script:Sc2GuiJob,$Job)) 'Duplicate action replaced the active job'
}
function Remove-WindowOwnedDirectory([string]$Path,[string]$Prefix) {
    if (-not [IO.Directory]::Exists($Path)) { return }
    $full=[IO.Path]::GetFullPath($Path)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    Assert-Window ([IO.Path]::GetDirectoryName($full) -eq $temp -and [IO.Path]::GetFileName($full) -match ('^' + [regex]::Escape($Prefix) + '[a-f0-9]{32}$')) 'Unsafe test cleanup target'
    Assert-Window (([IO.File]::GetAttributes($full) -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Test cleanup target is a reparse point'
    foreach ($entry in Get-ChildItem -LiteralPath $full -Force -Recurse) {
        Assert-Window (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Test cleanup refuses reparse points'
    }
    Remove-Item -LiteralPath $full -Recurse -Force
}

try {
    Test-Window 'hidden construction has no timer worker or launch before inspection' {
        $view=$script:Sc2GuiView
        Assert-Window ($null -eq $script:Sc2GuiJob -and $script:windowActions.Count -eq 0) 'Construction dispatched a worker'
        Assert-Window (-not $view.CNButton.Enabled -and -not $view.EUButton.Enabled -and -not $view.RepairButton.Enabled) 'Initial controls must wait for discovery'
        Assert-Window ($view.RegionSelector.DropDownStyle -eq [Windows.Forms.ComboBoxStyle]::DropDownList) 'Region must be an enumeration, not a free-text path'
        Assert-Window ($view.Log.ReadOnly -and $view.Log.DetectUrls -eq $false) 'Progress must be read-only'
    }
    Test-Window 'Separated discovery enables both launches and displays synthetic evidence' {
        Set-WindowDiscovery 'Separated'
        Assert-WindowReady $true $true
        $view=$script:Sc2GuiView
        Assert-Window ($view.CNPath.Text -eq (Join-Path $script:windowTestRoot 'synthetic CN') -and $view.EUPath.Text -eq (Join-Path $script:windowTestRoot 'synthetic international')) 'Displayed install paths lost discovery evidence'
        Assert-Window ($view.CNVersion.Text.Contains('51029') -and $view.EUVersion.Text.Contains('50913')) 'Displayed versions lost discovery evidence'
        Assert-Window ($view.ToolTip.GetToolTip($view.EUPath) -eq $view.EUPath.Text) 'Truncated paths must remain inspectable in the tooltip'
    }
    Test-Window 'Conflict permits CN and check repair while blocking international input' {
        Set-WindowDiscovery 'Conflict'
        Assert-WindowReady $true $false
        Invoke-WindowClick $script:Sc2GuiView.CNButton
        Invoke-WindowClick $script:Sc2GuiView.RepairButton
        Assert-Window (($script:windowActions -join ',') -eq 'LaunchCN,Repair') 'Available controls dispatched the wrong actions'
    }
    Test-Window 'Unsupported permits only check repair' {
        Set-WindowDiscovery 'Unsupported'
        Assert-WindowReady $false $false
        Invoke-WindowClick $script:Sc2GuiView.RepairButton
        Assert-Window (($script:windowActions -join ',') -eq 'Repair') 'Unsupported installation dispatched a launch'
    }
    Test-Window 'active Repair disables duplicate actions and cancels user closing' {
        Set-WindowDiscovery 'Separated'
        $job=New-WindowJob 'Repair' $false
        Assert-WindowBusy 'Repair' $job
        Assert-Window (-not $script:Sc2GuiView.Form.ControlBox -and (Get-WindowClosingCancel)) 'Repair must keep its worker alive until completion'
        Assert-Window ($job.Process.KillCalls -eq 0 -and $job.Process.DisposeCalls -eq 0) 'Rejected close touched the repair worker'
    }
    Test-Window 'exited launch remains protected until its result is processed' {
        Set-WindowDiscovery 'Separated'
        $job=New-WindowJob 'LaunchUS' $true
        Assert-WindowBusy 'LaunchUS' $job
        Assert-Window (-not $script:Sc2GuiView.Form.ControlBox -and (Get-WindowClosingCancel)) 'An exited but unprocessed launch must not allow a late helper result after closing'
        Save-WindowJobResult $job (New-WindowResult 'LaunchUS' 'Started' $true (New-WindowDiscovery 'Separated'))
        Update-Sc2GuiWorker
        Assert-WindowReady $true $true
        Assert-Window (-not (Get-WindowClosingCancel) -and $null -eq $script:Sc2GuiJob) 'A processed launch must release closing protection'
        Assert-Window ($job.Process.DisposeCalls -eq 1 -and $job.Process.KillCalls -eq 0) 'Completed launch worker lifetime is wrong'
    }
    Test-Window 'busy Inspect allows closing and closes only the owned synthetic worker' {
        Set-WindowDiscovery 'Separated'
        $job=New-WindowJob 'Inspect' $false
        Assert-WindowBusy 'Inspect' $job
        Assert-Window ($script:Sc2GuiView.Form.ControlBox -and -not (Get-WindowClosingCancel)) 'Read-only inspection must permit closing'
        $method=[Windows.Forms.Form].GetMethod('OnFormClosed',[Reflection.BindingFlags]'Instance,NonPublic')
        $null=$method.Invoke($script:Sc2GuiView.Form,[object[]]@([Windows.Forms.FormClosedEventArgs]::new([Windows.Forms.CloseReason]::UserClosing)))
        Assert-Window ($job.Process.KillCalls -eq 1 -and $job.Process.DisposeCalls -eq 1 -and $null -eq $script:Sc2GuiJob) 'Closing did not dispose just this window worker'
    }
    Test-Window 'valid Repair completion consumes the result restores controls and streams the log once' {
        Set-WindowDiscovery 'Conflict'
        $job=New-WindowJob 'Repair' $true
        Write-WindowText $job.LogPath "synthetic copy complete`nfinal synthetic line"
        Save-WindowJobResult $job (New-WindowResult 'Repair' 'RepairNeedsUpdate' $true (New-WindowDiscovery 'Separated'))
        Assert-WindowBusy 'Repair' $job
        Update-Sc2GuiWorker
        Assert-WindowReady $true $true
        Assert-Window ($null -eq $script:Sc2GuiJob -and $job.Process.DisposeCalls -eq 1) 'Completion left a job or failed to dispose the worker'
        Assert-Window ($script:Sc2GuiView.Detail.Text -eq 'Synthetic worker result') 'Completion did not parse the worker result'
        Assert-Window ($script:Sc2GuiView.Log.Text.Contains('final synthetic line') -and $job.LogPosition -eq ([IO.File]::ReadAllText($job.LogPath)).Length) 'Exited worker log did not include its final unterminated line'
        $before=$script:Sc2GuiView.Log.Text
        Update-Sc2GuiWorker
        Assert-Window ($script:Sc2GuiView.Log.Text -eq $before -and $script:windowActions.Count -eq 0) 'Completed output repeated or retriggered inspection immediately'
    }
    Test-Window 'malformed missing and mismatched worker results fail closed but permit repair retry' {
        foreach ($kind in @('malformed','missing','mismatched')) {
            Set-WindowDiscovery 'Separated'
            $job=New-WindowJob 'LaunchEU' $true 'synthetic worker stderr'
            Write-WindowText $job.LogPath 'synthetic failure evidence'
            if ($kind -eq 'malformed') { Write-WindowText $job.ResultPath '{not valid JSON' }
            elseif ($kind -eq 'mismatched') { Save-WindowJobResult $job (New-WindowResult 'Repair' 'Started' $true (New-WindowDiscovery 'Separated')) }
            Assert-WindowBusy 'LaunchEU' $job
            Update-Sc2GuiWorker
            Assert-WindowReady $false $false
            Assert-Window ($null -eq $script:Sc2GuiJob -and $job.Process.DisposeCalls -eq 1) ($kind + ' result left the window permanently busy')
            Assert-Window ($script:Sc2GuiView.Log.Text.Contains($job.LogPath) -and [IO.File]::Exists($job.LogPath)) ($kind + ' failure lost its private log')
            Invoke-WindowClick $script:Sc2GuiView.RepairButton
        }
        Assert-Window (($script:windowActions -join ',') -eq 'Repair,Repair,Repair') 'Every invalid result must leave a usable retry action'
    }
    Test-Window 'failed Inspect retains evidence and uses its confirmed Unsupported discovery' {
        $job=New-WindowJob 'Inspect' $true
        Write-WindowText $job.LogPath 'synthetic inspect failure'
        Save-WindowJobResult $job (New-WindowResult 'Inspect' 'Failed' $false (New-WindowDiscovery 'Unsupported'))
        Assert-WindowBusy 'Inspect' $job
        Update-Sc2GuiWorker
        Assert-WindowReady $false $false
        Assert-Window ([IO.File]::Exists($job.ResultPath) -and [IO.File]::Exists($job.LogPath)) 'Failed inspection must retain both output files'
        Assert-Window ($script:Sc2GuiView.Log.Text.Contains('Synthetic worker result') -and $script:Sc2GuiView.Log.Text.Contains($job.LogPath)) 'Failure and private log location must be visible'
        Assert-Window ($null -eq $script:Sc2GuiJob -and $job.Process.DisposeCalls -eq 1) 'Failed inspect lifetime is wrong'
    }
    Test-Window 'EU US and KR selector persists only a local enum and dispatches corresponding launch events' {
        Set-WindowDiscovery 'Separated'
        $regions=@('EU','US','KR'); $actions=@('LaunchEU','LaunchUS','LaunchAsia'); $captions=@('启动欧服','启动美服','启动亚服')
        for ($index=0;$index -lt $regions.Count;$index++) {
            $script:Sc2GuiView.RegionSelector.SelectedIndex=$index
            $saved=[IO.File]::ReadAllText($script:Sc2GuiRegionPath) | ConvertFrom-Json
            Assert-Window ($saved.SchemaVersion -eq 1 -and $saved.InternationalRegion -eq $regions[$index]) 'Selector did not persist its selected region enum'
            Assert-Window (@($saved.PSObject.Properties).Count -eq 2) 'Preferences must not serialize installation paths or account data'
            Assert-Window ($script:Sc2GuiView.EUButton.Text -eq $captions[$index]) 'International launch caption does not match the selection'
            Invoke-WindowClick $script:Sc2GuiView.EUButton
            Assert-Window ($script:windowActions[$index] -eq $actions[$index]) 'Selected region button dispatched the wrong action signal'
        }
        Close-WindowFixture
        $null=New-Sc2LauncherWindow
        Assert-Window ($script:Sc2GuiView.RegionSelector.SelectedIndex -eq 2 -and $script:Sc2GuiView.EUButton.Text -eq $captions[2]) 'Reopening the hidden window did not restore KR selection'
        Assert-Window ($null -eq $script:Sc2GuiJob -and -not $script:Sc2GuiView.Timer.Enabled) 'Reloading preferences started work'
    }
    Test-Window 'invalid saved region defaults to EU without editable path or account inputs' {
        foreach ($text in @('{"InternationalRegion":"CN"}','{not JSON','{"InternationalRegion":"C:\\\\synthetic"}')) {
            Close-WindowFixture
            Write-WindowText $script:Sc2GuiRegionPath $text
            $null=New-Sc2LauncherWindow
            Assert-Window ($script:Sc2GuiView.RegionSelector.SelectedIndex -eq 0) 'Invalid preference did not default to EU'
        }
        $pending=[Collections.Generic.Queue[Windows.Forms.Control]]::new()
        $pending.Enqueue($script:Sc2GuiView.Form)
        while ($pending.Count -gt 0) {
            $control=$pending.Dequeue()
            if ($control -is [Windows.Forms.TextBoxBase]) { Assert-Window $control.ReadOnly 'The launcher must not ask for a path login or account cache input' }
            foreach ($child in $control.Controls) { $pending.Enqueue($child) }
        }
    }
    Test-Window 'successful Inspect deletes only its known GUID outputs and preserves unrelated files' {
        $job=New-WindowJob 'Inspect' $true
        $other=New-WindowJob 'Inspect' $true
        $sentinel=Join-Path $job.WorkDirectory 'unrelated.synthetic'
        Write-WindowText $sentinel 'keep synthetic sentinel'
        Write-WindowText $other.LogPath 'other job evidence'
        Write-WindowText $job.LogPath 'successful synthetic inspection'
        Save-WindowJobResult $job (New-WindowResult 'Inspect' 'Separated' $true (New-WindowDiscovery 'Separated'))
        Assert-WindowBusy 'Inspect' $job
        Update-Sc2GuiWorker
        Assert-WindowReady $true $true
        Assert-Window (-not [IO.File]::Exists($job.ResultPath) -and -not [IO.File]::Exists($job.LogPath)) 'Successful inspect did not remove its two output files'
        Assert-Window ([IO.File]::ReadAllText($sentinel) -eq 'keep synthetic sentinel' -and [IO.File]::Exists($other.LogPath)) 'Cleanup changed an unrelated file or another job'
        Assert-Window (-not $script:Sc2GuiView.Log.Text.Contains('successful synthetic inspection')) 'Successful background inspection added progress noise'
        # A job object with a redirected filename must not expand the cleanup scope.
        $job.ResultPath=$sentinel
        Remove-Sc2GuiInspectionFiles $job
        Assert-Window ([IO.File]::Exists($sentinel)) 'Cleanup trusted a redirected filename instead of the known result.json/activity.log outputs'
        $empty=New-WindowJob 'Inspect' $true
        Save-WindowJobResult $empty (New-WindowResult 'Inspect' 'Separated' $true (New-WindowDiscovery 'Separated'))
        Write-WindowText $empty.LogPath 'successful synthetic inspection'
        $script:Sc2GuiJob=$empty
        Update-Sc2GuiWorker
        Assert-Window (-not [IO.Directory]::Exists($empty.WorkDirectory)) 'An otherwise empty successful inspect directory was not removed'
    }
    Test-Window 'idle polling waits sixty seconds and then dispatches only an Inspect signal' {
        $script:Sc2GuiLastCheck=[DateTime]::UtcNow.AddSeconds(-30)
        Update-Sc2GuiWorker
        Assert-Window ($script:windowActions.Count -eq 0) 'Idle polling retried before sixty seconds'
        $script:Sc2GuiLastCheck=[DateTime]::UtcNow.AddSeconds(-61)
        Update-Sc2GuiWorker
        Assert-Window (($script:windowActions -join ',') -eq 'Inspect') 'Idle polling dispatched an unexpected action'
    }
} finally {
    Close-WindowFixture
    Set-Item -LiteralPath Function:script:Start-Sc2GuiAction -Value $script:windowOriginalStart
}

$failed=@($script:windowResults | Where-Object { -not $_.Passed })
$passed=@($script:windowResults | Where-Object Passed)
Write-Host ('Launcher window result (PowerShell {0} {1}, apartment {2}): {3} passed; {4} failed.' -f $PSVersionTable.PSVersion,$PSVersionTable.PSEdition,[Threading.Thread]::CurrentThread.ApartmentState,$passed.Count,$failed.Count)
if ($failed.Count -gt 0 -or $KeepFixtures) {
    Write-Host ('Synthetic window fixtures preserved: ' + $script:windowTestRoot)
    foreach ($path in $script:windowWorkerDirectories) { if ([IO.Directory]::Exists($path)) { Write-Host ('Synthetic window worker fixture preserved: ' + $path) } }
} else {
    foreach ($path in $script:windowWorkerDirectories) { Remove-WindowOwnedDirectory $path 'sc2-launcher-' }
    Remove-WindowOwnedDirectory $script:windowTestRoot 'sc2-window-tests-'
}
if ($failed.Count -gt 0) { exit 1 }
