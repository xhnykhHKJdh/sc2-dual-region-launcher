#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:Sc2GuiScriptRoot = $PSScriptRoot
$script:Sc2GuiView = $null
$script:Sc2GuiJob = $null
$script:Sc2GuiDiscovery = $null
$script:Sc2GuiLastCheck = [DateTime]::MinValue
$script:Sc2GuiRegionPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SC2DualRegionLauncher\preferences.json'

function Get-Sc2GuiSavedRegion {
    try {
        if ([IO.File]::Exists($script:Sc2GuiRegionPath) -and ([IO.FileInfo]::new($script:Sc2GuiRegionPath)).Length -lt 4096) {
            $preference = [IO.File]::ReadAllText($script:Sc2GuiRegionPath) | ConvertFrom-Json
            if ($preference.InternationalRegion -in @('EU','US','KR')) { return [string]$preference.InternationalRegion }
        }
    } catch { }
    return 'EU'
}

function Save-Sc2GuiRegion([string]$Region) {
    try {
        if ($Region -notin @('EU','US','KR')) { return }
        $parent = [IO.Path]::GetDirectoryName($script:Sc2GuiRegionPath)
        if ([IO.Directory]::Exists($parent) -and ([IO.File]::GetAttributes($parent) -band [IO.FileAttributes]::ReparsePoint)) { return }
        if ([IO.File]::Exists($script:Sc2GuiRegionPath) -and ([IO.File]::GetAttributes($script:Sc2GuiRegionPath) -band [IO.FileAttributes]::ReparsePoint)) { return }
        $null = [IO.Directory]::CreateDirectory($parent)
        $temporary = Join-Path $parent ('.region-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            $text = [pscustomobject]@{SchemaVersion=1;InternationalRegion=$Region} | ConvertTo-Json
            [IO.File]::WriteAllText($temporary,$text,[Text.UTF8Encoding]::new($false))
            if ([IO.File]::Exists($script:Sc2GuiRegionPath)) { [IO.File]::Replace($temporary,$script:Sc2GuiRegionPath,[NullString]::Value) }
            else { [IO.File]::Move($temporary,$script:Sc2GuiRegionPath) }
        } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    } catch { }
}

function Set-Sc2GuiRegionSelection {
    $index = $script:Sc2GuiView.RegionSelector.SelectedIndex
    $region = @('EU','US','KR')[$index]
    $script:Sc2GuiView.EUButton.Text = @('启动欧服','启动美服','启动亚服')[$index]
    Save-Sc2GuiRegion $region
}

function Get-Sc2GuiValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Add-Sc2GuiLog([string]$Text) {
    if (-not $Text -or $null -eq $script:Sc2GuiView) { return }
    $box = $script:Sc2GuiView.Log
    if ($box.TextLength -gt 100000) { $box.Text = $box.Text.Substring($box.TextLength - 70000) }
    $box.AppendText($Text.Replace("`r`n","`n").Replace("`n",[Environment]::NewLine))
    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()
}

function Set-Sc2GuiBusy([bool]$Busy, [string]$Action) {
    $view = $script:Sc2GuiView
    $status = [string](Get-Sc2GuiValue $script:Sc2GuiDiscovery 'Status')
    $view.CNButton.Enabled = -not $Busy -and $status -in @('Separated','Conflict')
    $view.EUButton.Enabled = -not $Busy -and $status -eq 'Separated'
    $view.RegionSelector.Enabled = -not $Busy -and $status -eq 'Separated'
    $view.RepairButton.Enabled = -not $Busy
    $view.Progress.Visible = $Busy
    $view.Form.UseWaitCursor = $Busy
    # A repair transaction must not be interrupted by closing its worker.
    $view.Form.ControlBox = -not ($Busy -and $Action -ne 'Inspect')
}

function Set-Sc2GuiResult($Result) {
    $view = $script:Sc2GuiView
    $discovery = Get-Sc2GuiValue $Result 'Discovery'
    if ($null -ne $discovery) {
        $script:Sc2GuiDiscovery = $discovery
        foreach ($region in @('CN','EU')) {
            $path = [string](Get-Sc2GuiValue $discovery ($region + 'Directory'))
            $version = [string](Get-Sc2GuiValue $discovery ($region + 'Version'))
            $label = if ($region -eq 'CN') { $view.CNPath } else { $view.EUPath }
            $versionLabel = if ($region -eq 'CN') { $view.CNVersion } else { $view.EUVersion }
            $label.Text = if ($path) { $path } else { '尚未识别到安装目录' }
            $view.ToolTip.SetToolTip($label,$path)
            $versionLabel.Text = if ($version) { '版本 ' + $version } else { '版本 —' }
        }
    }
    elseif (-not [bool](Get-Sc2GuiValue $Result 'Success')) {
        # A crashed or malformed worker cannot keep an earlier green state
        # authorizing buttons. A fresh inspection is required before launch.
        $script:Sc2GuiDiscovery = $null
    }
    $status = [string](Get-Sc2GuiValue $Result 'Status')
    $message = [string](Get-Sc2GuiValue $Result 'Message')
    $titles = @{
        Separated='两服已分离，可以启动'; Conflict='检测到安装冲突，请检查修复'
        Unsupported='安装需要进一步检查'; Failed='本次操作未完成'
        Started='已打开官方战网入口'; AlreadyRunning='游戏已经运行'
        GameRunning='请先退出当前游戏'; NeedsRepair='请先分离国服和欧服'
        RepairAlreadySeparated='检查完成，两服安装正常'; RepairNeedsUpdate='分离完成，等待官方欧服更新'
    }
    $view.Status.Text = if ($titles.ContainsKey($status)) { $titles[$status] } elseif ([bool](Get-Sc2GuiValue $Result 'Success')) { '操作已完成' } else { '本次操作未完成' }
    $view.Detail.Text = $message
    $view.ToolTip.SetToolTip($view.Detail,$message)
    $view.Status.ForeColor = if ($status -in @('Separated','RepairAlreadySeparated','AlreadyRunning')) {
        [Drawing.Color]::FromArgb(20,115,88)
    } elseif ($status -in @('Conflict','NeedsRepair','GameRunning','RepairNeedsUpdate')) {
        [Drawing.Color]::FromArgb(155,96,10)
    } elseif (-not [bool](Get-Sc2GuiValue $Result 'Success')) {
        [Drawing.Color]::FromArgb(175,42,48)
    } else { [Drawing.Color]::FromArgb(32,95,166) }
    $backup = [string](Get-Sc2GuiValue $Result 'WorkDirectory')
    if ($backup) { Add-Sc2GuiLog ("私人备份：$backup`r`n") }
    Set-Sc2GuiBusy $false ''
}

function ConvertTo-Sc2GuiArgument([string]$Value) {
    # These arguments are repository paths or newly-created GUID paths, never
    # commands. Use Windows argument quoting without invoking a shell.
    if ($Value.IndexOfAny([char[]]@([char]0,[char]10,[char]13,[char]34)) -ge 0) { throw '启动路径包含不支持的字符。' }
    return '"' + $Value + '"'
}

function Start-Sc2GuiAction([ValidateSet('Inspect','LaunchCN','LaunchEU','LaunchUS','LaunchAsia','Repair')][string]$Action) {
    if ($null -ne $script:Sc2GuiJob) { return }
    $view = $script:Sc2GuiView
    $workerPath = Join-Path $script:Sc2GuiScriptRoot 'Invoke-SC2LauncherAction.ps1'
    $powershellPath = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $work = Join-Path ([IO.Path]::GetTempPath()) ('sc2-launcher-' + [Guid]::NewGuid().ToString('N'))
    $process = $null
    try {
        if (-not [IO.File]::Exists($powershellPath) -or -not [IO.File]::Exists($workerPath)) { throw '未找到 Windows PowerShell 或完整的启动器脚本，请完整解压下载文件。' }
        $null = [IO.Directory]::CreateDirectory($work)
        $resultPath = Join-Path $work 'result.json'
        $logPath = Join-Path $work 'activity.log'
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $powershellPath
        $info.Arguments = '-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ' +
            (ConvertTo-Sc2GuiArgument $workerPath) + ' -Action ' + $Action +
            ' -ResultPath ' + (ConvertTo-Sc2GuiArgument $resultPath) + ' -LogPath ' + (ConvertTo-Sc2GuiArgument $logPath)
        $info.WorkingDirectory = $script:Sc2GuiScriptRoot
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $info
        $null = $process.Start()
        $script:Sc2GuiJob = [pscustomobject]@{
            Action=$Action; Process=$process; ResultPath=$resultPath; LogPath=$logPath; WorkDirectory=$work
            LogPosition=0; Started=[DateTime]::UtcNow
            OutputTask=$process.StandardOutput.ReadToEndAsync(); ErrorTask=$process.StandardError.ReadToEndAsync()
        }
        Set-Sc2GuiBusy $true $Action
        $view.Status.ForeColor = [Drawing.Color]::FromArgb(32,95,166)
        $view.Status.Text = switch ($Action) {
            Inspect { '正在自动识别安装…' }; LaunchCN { '正在检查并启动国服…' }
            LaunchEU { '正在检查并启动欧服…' }; LaunchUS { '正在检查并启动美服…' }
            LaunchAsia { '正在检查并启动亚服…' }; Repair { '正在检查修复，请等待…' }
        }
        $view.Detail.Text = if ($Action -eq 'Repair') { '首次分离会复制游戏并保留备份。完成前请保持窗口打开。' } else { '正在读取当前安装登记，无需填写路径。' }
        if ($Action -ne 'Inspect') { Add-Sc2GuiLog ("`r`n" + (Get-Date -Format 'HH:mm:ss') + '  ' + $view.Status.Text + "`r`n") }
    }
    catch {
        if ($null -ne $process) { $process.Dispose() }
        $script:Sc2GuiJob = $null
        Set-Sc2GuiResult ([pscustomobject]@{Success=$false;Status='Failed';Message=$_.Exception.Message;Discovery=$null})
        Add-Sc2GuiLog ($_.Exception.Message + "`r`n")
    }
}

function Read-Sc2GuiProgress($Job) {
    if (-not [IO.File]::Exists($Job.LogPath)) { return }
    try {
        $text = [IO.File]::ReadAllText($Job.LogPath,[Text.UTF8Encoding]::new($false))
        $completeLength = if ($Job.Process.HasExited) { $text.Length } else { $text.LastIndexOf("`n") + 1 }
        if ($completeLength -gt $Job.LogPosition) {
            $newText = $text.Substring($Job.LogPosition,$completeLength - $Job.LogPosition)
            if ($Job.Action -ne 'Inspect') { Add-Sc2GuiLog $newText }
            $Job.LogPosition = $completeLength
        }
    } catch { }
}

function Remove-Sc2GuiInspectionFiles($Job) {
    # Delete only this successful, read-only worker's two known output files.
    $full = [IO.Path]::GetFullPath($Job.WorkDirectory)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if ([IO.Path]::GetDirectoryName($full) -ne $temp -or [IO.Path]::GetFileName($full) -notmatch '^sc2-launcher-[a-f0-9]{32}$') { return }
    if (([IO.File]::GetAttributes($full) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return }
    foreach ($path in @($Job.ResultPath,$Job.LogPath)) {
        if ([IO.Path]::GetFileName($path) -in @('result.json','activity.log') -and [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)) -eq $full -and [IO.File]::Exists($path)) {
            if (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -eq 0) { [IO.File]::Delete($path) }
        }
    }
    if (@(Get-ChildItem -Force -LiteralPath $full).Count -eq 0) { [IO.Directory]::Delete($full) }
}

function Update-Sc2GuiWorker {
    $job = $script:Sc2GuiJob
    if ($null -eq $job) {
        if (([DateTime]::UtcNow - $script:Sc2GuiLastCheck).TotalSeconds -ge 60) { Start-Sc2GuiAction 'Inspect' }
        return
    }
    Read-Sc2GuiProgress $job
    $seconds = [int]([DateTime]::UtcNow - $job.Started).TotalSeconds
    $script:Sc2GuiView.Footer.Text = '处理中 · 已用 ' + [int][Math]::Floor($seconds / 60) + ' 分 ' + ($seconds % 60) + ' 秒'
    if (-not $job.Process.HasExited) { return }
    $result = $null
    try {
        $stderr = $job.ErrorTask.GetAwaiter().GetResult()
        $stdout = $job.OutputTask.GetAwaiter().GetResult()
        if (-not [IO.File]::Exists($job.ResultPath)) {
            $reason = if ($stderr) { $stderr } elseif ($stdout) { $stdout } else { '未收到工作进程结果。' }
            throw ('后台进程未完成：' + $reason)
        }
        $result = [IO.File]::ReadAllText($job.ResultPath,[Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        if ((Get-Sc2GuiValue $result 'SchemaVersion') -ne 1 -or (Get-Sc2GuiValue $result 'Action') -ne $job.Action) { throw '后台结果格式无法确认，请保留日志。' }
        Set-Sc2GuiResult $result
        if (-not [bool](Get-Sc2GuiValue $result 'Success')) {
            if ($job.Action -eq 'Inspect') { Add-Sc2GuiLog ([string](Get-Sc2GuiValue $result 'Message') + "`r`n") }
            Add-Sc2GuiLog ('私人日志：' + $job.LogPath + "`r`n")
            $script:Sc2GuiView.Footer.Text = '本次未完成，日志已留在本机；可再次点击“检查修复”。'
        } else { $script:Sc2GuiView.Footer.Text = '账号登录和验证码请在官方战网窗口完成。' }
        if ($job.Action -eq 'Inspect' -and [bool](Get-Sc2GuiValue $result 'Success')) { Remove-Sc2GuiInspectionFiles $job }
    }
    catch {
        $message = $_.Exception.Message
        Set-Sc2GuiResult ([pscustomobject]@{Success=$false;Status='Failed';Message=$message;Discovery=$null})
        Add-Sc2GuiLog ($message + "`r`n私人日志：" + $job.LogPath + "`r`n")
    }
    finally {
        $job.Process.Dispose()
        $script:Sc2GuiJob = $null
        $script:Sc2GuiLastCheck = [DateTime]::UtcNow
        Set-Sc2GuiBusy $false ''
    }
}

function New-Sc2LauncherWindow {
    $form = [Windows.Forms.Form]::new()
    $form.Text = '星际争霸 II · 国服 / 国际服启动器'
    $form.Size = [Drawing.Size]::new(890,690)
    $form.MinimumSize = [Drawing.Size]::new(760,650)
    $form.StartPosition = 'CenterScreen'
    $form.AutoScaleMode = 'Dpi'
    $form.Font = [Drawing.Font]::new('Microsoft YaHei UI',9)
    $form.BackColor = [Drawing.Color]::FromArgb(244,247,251)
    $form.ForeColor = [Drawing.Color]::FromArgb(27,40,58)

    $layout = [Windows.Forms.TableLayoutPanel]::new()
    $layout.Dock = 'Fill'; $layout.Padding = [Windows.Forms.Padding]::new(24,16,24,16)
    $layout.ColumnCount = 1; $layout.RowCount = 8
    foreach ($height in @(72,82,102,136,30)) { $null = $layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,$height)) }
    $null = $layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,100))
    $null = $layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,10))
    $null = $layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,35))
    $form.Controls.Add($layout)

    $header = [Windows.Forms.Panel]::new(); $header.Dock='Fill'
    $title = [Windows.Forms.Label]::new(); $title.Text='星际争霸 II'; $title.Font=[Drawing.Font]::new('Microsoft YaHei UI',21,[Drawing.FontStyle]::Bold)
    $title.AutoSize=$true; $title.Location=[Drawing.Point]::new(0,0); $header.Controls.Add($title)
    $subtitle = [Windows.Forms.Label]::new(); $subtitle.Text='国服独立保留 · 欧服 / 美服 / 亚服共用国际客户端'
    $subtitle.AutoSize=$true; $subtitle.Location=[Drawing.Point]::new(1,45); $subtitle.ForeColor=[Drawing.Color]::FromArgb(90,104,121)
    $header.Controls.Add($subtitle); $layout.Controls.Add($header,0,0)

    $statusPanel = [Windows.Forms.Panel]::new(); $statusPanel.Dock='Fill'
    $status = [Windows.Forms.Label]::new(); $status.Text='正在自动识别安装…'; $status.Dock='Top'; $status.Height=29
    $status.Font=[Drawing.Font]::new('Microsoft YaHei UI',12,[Drawing.FontStyle]::Bold)
    $detail = [Windows.Forms.Label]::new(); $detail.Text='打开窗口只会检查安装，修复由你点击按钮开始。'
    $detail.Dock='Fill'; $detail.ForeColor=[Drawing.Color]::FromArgb(90,104,121); $detail.UseMnemonic=$false
    $statusPanel.Controls.Add($detail); $statusPanel.Controls.Add($status); $layout.Controls.Add($statusPanel,0,1)

    $buttons = [Windows.Forms.TableLayoutPanel]::new(); $buttons.Dock='Fill'; $buttons.ColumnCount=3; $buttons.RowCount=2
    $null=$buttons.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,56))
    $null=$buttons.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,36))
    foreach ($i in 1..3) { $null=$buttons.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,33.3333)) }
    $buttonList=@()
    foreach ($label in @('启动国服','启动欧服','检查修复')) {
        $button=[Windows.Forms.Button]::new(); $button.Text=$label; $button.Dock='Fill'; $button.Margin=[Windows.Forms.Padding]::new(0,0,10,12)
        $button.Font=[Drawing.Font]::new('Microsoft YaHei UI',12,[Drawing.FontStyle]::Bold); $button.FlatStyle='Flat'; $button.FlatAppearance.BorderSize=0
        $button.Enabled=$false; $button.UseVisualStyleBackColor=$false; $buttonList += $button
    }
    $buttonList[0].BackColor=[Drawing.Color]::FromArgb(0,105,194); $buttonList[0].ForeColor=[Drawing.Color]::White
    $buttonList[1].BackColor=[Drawing.Color]::FromArgb(67,83,161); $buttonList[1].ForeColor=[Drawing.Color]::White
    $buttonList[2].BackColor=[Drawing.Color]::White; $buttonList[2].ForeColor=[Drawing.Color]::FromArgb(28,70,115)
    $buttonList[2].FlatAppearance.BorderSize=1; $buttonList[2].FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(202,213,227)
    $buttonList[2].Margin=[Windows.Forms.Padding]::new(0,0,0,12)
    for($i=0;$i -lt 3;$i++) { $buttons.Controls.Add($buttonList[$i],$i,0) }
    $regionLabel=[Windows.Forms.Label]::new(); $regionLabel.Text='国际服游戏地区'; $regionLabel.Dock='Fill'; $regionLabel.TextAlign='MiddleRight'
    $regionLabel.ForeColor=[Drawing.Color]::FromArgb(90,104,121); $regionLabel.Margin=[Windows.Forms.Padding]::new(0,0,12,6)
    $regionSelector=[Windows.Forms.ComboBox]::new(); $regionSelector.DropDownStyle='DropDownList'; $regionSelector.Dock='Fill'
    $regionSelector.Margin=[Windows.Forms.Padding]::new(0,0,10,6); $regionSelector.AccessibleName='国际服游戏地区'
    $null=$regionSelector.Items.AddRange([object[]]@('欧服 · Europe','美服 · Americas','亚服 · Asia（韩国 / 台湾）'))
    $savedRegion=Get-Sc2GuiSavedRegion; $regionSelector.SelectedIndex=[Array]::IndexOf([string[]]@('EU','US','KR'),$savedRegion)
    $regionSelector.Enabled=$false
    $regionNote=[Windows.Forms.Label]::new(); $regionNote.Text='三地区复用同一套游戏文件'; $regionNote.Dock='Fill'; $regionNote.TextAlign='MiddleLeft'
    $regionNote.Font=[Drawing.Font]::new('Microsoft YaHei UI',8); $regionNote.ForeColor=[Drawing.Color]::FromArgb(99,110,127)
    $buttons.Controls.Add($regionLabel,0,1); $buttons.Controls.Add($regionSelector,1,1); $buttons.Controls.Add($regionNote,2,1)
    $layout.Controls.Add($buttons,0,2)

    $cards=[Windows.Forms.TableLayoutPanel]::new(); $cards.Dock='Fill'; $cards.RowCount=2; $cards.ColumnCount=1
    $null=$cards.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,50))
    $null=$cards.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,50))
    $paths=@(); $versions=@()
    for($i=0;$i -lt 2;$i++) {
        $card=[Windows.Forms.Panel]::new(); $card.Dock='Fill'; $card.BackColor=[Drawing.Color]::White; $card.Padding=[Windows.Forms.Padding]::new(12,7,12,6)
        $card.Margin=[Windows.Forms.Padding]::new(0,0,0,7)
        $cardHeader=[Windows.Forms.TableLayoutPanel]::new(); $cardHeader.Dock='Top'; $cardHeader.Height=23; $cardHeader.ColumnCount=2; $cardHeader.RowCount=1
        $null=$cardHeader.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,55))
        $null=$cardHeader.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,45))
        $cardTitle=[Windows.Forms.Label]::new(); $cardTitle.Text=if($i -eq 0){'国服 · 网易'}else{'国际服 · 欧 / 美 / 亚共用'}
        $cardTitle.Dock='Fill'; $cardTitle.Margin=[Windows.Forms.Padding]::new(0); $cardTitle.Font=[Drawing.Font]::new('Microsoft YaHei UI',9,[Drawing.FontStyle]::Bold)
        $path=[Windows.Forms.Label]::new(); $path.Text='正在识别…'; $path.Dock='Fill'; $path.AutoEllipsis=$true; $path.UseMnemonic=$false
        $path.AccessibleName=if($i -eq 0){'国服安装目录'}else{'欧服安装目录'}
        $version=[Windows.Forms.Label]::new(); $version.Text='版本 —'; $version.Dock='Fill'; $version.TextAlign='MiddleRight'; $version.Margin=[Windows.Forms.Padding]::new(0)
        $version.ForeColor=[Drawing.Color]::FromArgb(99,110,127)
        $cardHeader.Controls.Add($cardTitle,0,0); $cardHeader.Controls.Add($version,1,0)
        $card.Controls.Add($path); $card.Controls.Add($cardHeader)
        $cards.Controls.Add($card,0,$i); $paths += $path; $versions += $version
    }
    $layout.Controls.Add($cards,0,3)
    $logTitle=[Windows.Forms.Label]::new(); $logTitle.Text='操作进度'; $logTitle.Dock='Fill'; $logTitle.TextAlign='MiddleLeft'
    $logTitle.Font=[Drawing.Font]::new('Microsoft YaHei UI',9,[Drawing.FontStyle]::Bold); $layout.Controls.Add($logTitle,0,4)
    $log=[Windows.Forms.RichTextBox]::new(); $log.Dock='Fill'; $log.ReadOnly=$true; $log.BackColor=[Drawing.Color]::White
    $log.BorderStyle='FixedSingle'; $log.DetectUrls=$false; $log.ScrollBars='Vertical'; $log.Font=[Drawing.Font]::new('Microsoft YaHei UI',9)
    $log.Text="正在检查当前安装；平时选择对应地区启动即可。`r`n"; $layout.Controls.Add($log,0,5)
    $progress=[Windows.Forms.ProgressBar]::new(); $progress.Dock='Fill'; $progress.Style='Marquee'; $progress.MarqueeAnimationSpeed=28
    $progress.Visible=$false; $layout.Controls.Add($progress,0,6)
    $footer=[Windows.Forms.Label]::new(); $footer.Dock='Fill'; $footer.TextAlign='MiddleLeft'; $footer.ForeColor=[Drawing.Color]::FromArgb(99,110,127)
    $footer.Text='账号登录和验证码请在官方战网窗口完成。'; $layout.Controls.Add($footer,0,7)

    $timer=[Windows.Forms.Timer]::new(); $timer.Interval=250
    $toolTip=[Windows.Forms.ToolTip]::new(); $toolTip.AutoPopDelay=20000
    $view=[pscustomobject]@{Form=$form;Status=$status;Detail=$detail;CNButton=$buttonList[0];EUButton=$buttonList[1];RepairButton=$buttonList[2];RegionSelector=$regionSelector;CNPath=$paths[0];EUPath=$paths[1];CNVersion=$versions[0];EUVersion=$versions[1];Log=$log;Progress=$progress;Footer=$footer;Timer=$timer;ToolTip=$toolTip}
    $script:Sc2GuiView=$view
    $buttonList[0].Add_Click({ Start-Sc2GuiAction 'LaunchCN' })
    $buttonList[1].Add_Click({ Start-Sc2GuiAction @('LaunchEU','LaunchUS','LaunchAsia')[$script:Sc2GuiView.RegionSelector.SelectedIndex] })
    $regionSelector.Add_SelectedIndexChanged({ Set-Sc2GuiRegionSelection })
    Set-Sc2GuiRegionSelection
    $buttonList[2].Add_Click({ Start-Sc2GuiAction 'Repair' })
    $timer.Add_Tick({ try { Update-Sc2GuiWorker } catch { Add-Sc2GuiLog ($_.Exception.Message + "`r`n") } })
    $form.Add_Shown({ $script:Sc2GuiView.Timer.Start(); Start-Sc2GuiAction 'Inspect' })
    $form.Add_FormClosing({
        param($sender,$eventArgs)
        if ($null -ne $script:Sc2GuiJob -and $script:Sc2GuiJob.Action -ne 'Inspect') {
            $eventArgs.Cancel=$true
            $script:Sc2GuiView.Detail.Text='本次操作仍在进行。请等待启动或检查修复结束后再关闭窗口。'
        }
    })
    $form.Add_FormClosed({
        $script:Sc2GuiView.Timer.Stop()
        $script:Sc2GuiView.Timer.Dispose()
        $script:Sc2GuiView.ToolTip.Dispose()
        if ($null -ne $script:Sc2GuiJob) {
            # Only this window's own non-repair worker can be stopped here.
            if (-not $script:Sc2GuiJob.Process.HasExited) { $script:Sc2GuiJob.Process.Kill() }
            $script:Sc2GuiJob.Process.Dispose(); $script:Sc2GuiJob=$null
        }
    })
    return $view
}

if ($MyInvocation.InvocationName -ne '.') {
    $guiMutex = $null
    $ownsGuiMutex = $false
    try {
        if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw '请双击“星际2启动器.cmd”，或使用 Windows PowerShell 的 -STA 参数打开窗口。' }
        $guiMutex = [Threading.Mutex]::new($true,'Local\SC2DualRegionLauncherGui',[ref]$ownsGuiMutex)
        if (-not $ownsGuiMutex) { return }
        [Windows.Forms.Application]::EnableVisualStyles()
        $view=New-Sc2LauncherWindow
        [Windows.Forms.Application]::Run($view.Form)
        $view.Form.Dispose()
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'星际启动器未能打开','OK','Error') | Out-Null; exit 1 }
    finally {
        if ($null -ne $guiMutex) {
            if ($ownsGuiMutex) { $guiMutex.ReleaseMutex() }
            $guiMutex.Dispose()
        }
    }
}
