#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Reuse the guarded repair implementation rather than maintaining a second
# installer or accepting paths from the graphical interface.
. (Join-Path $PSScriptRoot 'Start-SC2DualRegion.ps1')

function Get-Sc2LauncherDiscovery { Get-Sc2AutoDiscovery }
function Get-Sc2LauncherProcesses { Get-OneClickProcesses }
function Invoke-Sc2LauncherRepair { Invoke-SC2DualRegionOneClick -Run -SkipLaunch }

function ConvertTo-Sc2LauncherDiscovery($Discovery) {
    if ($null -eq $Discovery) { return $null }
    $public = [ordered]@{}
    foreach ($name in @('AgentDatabase','CNDirectory','EUDirectory','LauncherPath','CNVersion','EUVersion','Status','Reason')) {
        $property = $Discovery.PSObject.Properties[$name]
        $public[$name] = if ($null -eq $property) { $null } else { [string]$property.Value }
    }
    [pscustomobject]$public
}

function New-Sc2LauncherResult([string]$Action, [bool]$Success, [string]$Status, $Discovery, [string]$Message) {
    [pscustomobject][ordered]@{
        SchemaVersion = 1
        Success = $Success
        Action = $Action
        Status = $Status
        Discovery = ConvertTo-Sc2LauncherDiscovery $Discovery
        Message = $Message
    }
}

function Get-Sc2LauncherInspection {
    [CmdletBinding()]
    param()
    Invoke-Sc2LauncherAction -Action Inspect
}

function Get-Sc2OfficialLauncherSignature([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    $signerName = $null
    if ($null -ne $signature.SignerCertificate) {
        $signerName = $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false)
    }
    [pscustomobject]@{ Status=[string]$signature.Status; SignerName=$signerName }
}

function Assert-Sc2OfficialLauncher([string]$LauncherPath) {
    Assert-OneClickOrdinaryPath $LauncherPath
    if ([IO.Path]::GetFileName($LauncherPath) -notin @('Battle.net.exe','Battle.net Launcher.exe') -or
        -not [IO.File]::Exists($LauncherPath) -or ([IO.FileInfo]::new($LauncherPath)).Length -le 0) { throw '自动识别的官方战网启动器不可用，请重新检查。' }
    $signature = Get-Sc2OfficialLauncherSignature -Path $LauncherPath
    if ($null -eq $signature -or $null -eq $signature.PSObject.Properties['Status'] -or
        $signature.Status -isnot [string] -or $signature.Status -ne 'Valid' -or
        $null -eq $signature.PSObject.Properties['SignerName'] -or $signature.SignerName -isnot [string] -or
        $signature.SignerName -notin @('Blizzard Entertainment','Blizzard Entertainment, Inc.','Blizzard Entertainment Inc.')) {
        throw '战网启动器的有效暴雪数字签名未通过验证，操作已停止。请使用官方安装器修复战网后重试。'
    }
}

function Open-Sc2EUUpdateClient([string]$LauncherPath) {
    Assert-Sc2OfficialLauncher $LauncherPath
    # Updating the official client is a separate step from launching a game.
    Start-Process -FilePath $LauncherPath -ArgumentList '--setregion=EU'
}

function Start-Sc2RegionalLauncher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LauncherPath,
        [Parameter(Mandatory)][ValidateSet('CN','EU')][string]$Region,
        [Parameter(Mandatory)][ValidateSet('s2_cn','s2')][string]$Product
    )
    if (($Region -eq 'CN' -and $Product -ne 's2_cn') -or ($Region -eq 'EU' -and $Product -ne 's2')) { throw '启动地区与游戏产品不一致。' }
    Assert-Sc2OfficialLauncher $LauncherPath
    $arguments = '--setregion=' + $Region + ' --exec="launch ' + $Product + '"'
    Start-Process -FilePath $LauncherPath -ArgumentList $arguments
}

function Get-Sc2InternationalHelperPath {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $helperPath = Join-Path $repositoryRoot 'dist\SC2Launcher.exe'
    Assert-OneClickOrdinaryPath $helperPath
    if (-not [IO.File]::Exists($helperPath) -or ([IO.FileInfo]::new($helperPath)).Length -le 0) {
        throw '地区切换组件尚未编译。请双击仓库中的“星际2启动器.cmd”或 Start.cmd，窗口会自动完成本机编译，无需填写路径。'
    }
    # Old hosts launch their own form when handed unknown command arguments.
    # Verify the local build record before asking this binary to act as a helper.
    try {
        $manifestPath = Join-Path $repositoryRoot 'dist\SC2Launcher.build.json'
        Assert-OneClickOrdinaryPath $manifestPath
        if (-not [IO.File]::Exists($manifestPath) -or ([IO.FileInfo]::new($manifestPath)).Length -gt 16KB) { throw 'Missing build record.' }
        $manifest = [IO.File]::ReadAllText($manifestPath,[Text.UTF8Encoding]::new($false,$true)).TrimStart([char]65279) | ConvertFrom-Json
        if ($manifest.Schema -ne 1) { throw 'Unknown build record.' }
        $buildInputs = @{
            HostSourceSha256 = Join-Path $repositoryRoot 'src\Sc2LauncherHost.cs'
            RegionSelectorSourceSha256 = Join-Path $repositoryRoot 'src\Sc2BattleRegionSelector.cs'
            BuildScriptSha256 = Join-Path $PSScriptRoot 'Build-SC2Launcher.ps1'
            ExecutableSha256 = $helperPath
        }
        foreach ($key in $buildInputs.Keys) {
            Assert-OneClickOrdinaryPath $buildInputs[$key]
            $recorded = $manifest.PSObject.Properties[$key]
            if ($null -eq $recorded -or $recorded.Value -isnot [string] -or
                $recorded.Value -ne (Get-FileHash -LiteralPath $buildInputs[$key] -Algorithm SHA256).Hash) { throw 'Local build differs from its sources.' }
        }
    }
    catch { throw '地区切换组件缺失或版本尚未更新。请双击“星际2启动器.cmd”或 Start.cmd 自动重新编译后使用，无需填写路径。' }
    $helperPath
}

function ConvertTo-Sc2LauncherArgument([string]$Value) {
    # Every value here is an absolute ordinary Windows path or a fixed enum.
    # Embedded quotes/newlines are rejected rather than treated as shell code.
    if ($Value -match '["\r\n]' -or $Value.EndsWith('\')) { throw '地区切换参数包含无法安全传递的字符。' }
    '"' + $Value + '"'
}

function Start-Sc2InternationalHelperProcess([string]$FilePath, [string]$Arguments) {
    Start-Process -FilePath $FilePath -ArgumentList $Arguments -WindowStyle Hidden -PassThru
}

function Invoke-Sc2InternationalLaunch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LauncherPath,
        [Parameter(Mandatory)][string]$GameDirectory,
        [Parameter(Mandatory)][ValidateSet('EU','US','KR')][string]$Region
    )
    Assert-Sc2OfficialLauncher $LauncherPath
    Assert-OneClickOrdinaryPath $GameDirectory
    if (-not [IO.Directory]::Exists($GameDirectory)) { throw '自动识别的国际游戏目录不存在。' }
    $helperPath = Get-Sc2InternationalHelperPath
    $work = Join-Path ([IO.Path]::GetTempPath()) ('sc2-launcher-' + [Guid]::NewGuid().ToString('N'))
    Assert-OneClickAbsent $work
    $null = [IO.Directory]::CreateDirectory($work)
    $resultPath = Join-Path $work 'region.json'
    $arguments = '--switch-region ' + $Region +
        ' --launcher-path ' + (ConvertTo-Sc2LauncherArgument $LauncherPath) +
        ' --game-directory ' + (ConvertTo-Sc2LauncherArgument (Get-OneClickFullPath $GameDirectory)) +
        ' --result-path ' + (ConvertTo-Sc2LauncherArgument $resultPath)
    # Login region and SC2 game region are distinct. Reuse the international
    # login client and let the helper select the actual game region in its UI.
    Open-Sc2EUUpdateClient $LauncherPath
    Write-Host '正在官方战网中确认星际游戏地区；不会改写游戏安装登记或结束已有游戏。'
    $helper = Start-Sc2InternationalHelperProcess -FilePath $helperPath -Arguments $arguments
    try {
        if (-not $helper.WaitForExit(60000)) {
            # Only our own hung helper is stopped, never Battle.net or SC2.
            try { if (-not $helper.HasExited) { $helper.Kill(); $null = $helper.WaitForExit(5000) } } catch { }
            return [pscustomobject]@{ Success=$false; GameRegionConfirmed=$false; Region=$Region; Status='NeedsOfficialSelection'; Message='等待官方游戏地区确认超时。请在已登录的战网星际页面选择 Play 旁的游戏地区后再启动；工具没有结束战网或游戏。' }
        }
        $helperExitCode = $helper.ExitCode
    }
    finally { if ($null -ne $helper) { $helper.Dispose() } }
    Assert-OneClickOrdinaryPath $resultPath
    if (-not [IO.File]::Exists($resultPath) -or ([IO.FileInfo]::new($resultPath)).Length -gt 64KB) {
        return [pscustomobject]@{ Success=$false; GameRegionConfirmed=$false; Region=$Region; Status='NeedsOfficialSelection'; Message='官方游戏地区没有返回可确认的结果。请在战网星际页面手动确认游戏地区后启动；尚未认定服务器切换成功。' }
    }
    $reported = ([Text.UTF8Encoding]::new($false,$true)).GetString([IO.File]::ReadAllBytes($resultPath)).TrimStart([char]65279) | ConvertFrom-Json
    foreach ($field in @('Success','GameRegionConfirmed','Region','Status','Message')) {
        if ($null -eq $reported.PSObject.Properties[$field]) { throw '官方地区确认结果格式不完整，请在战网内确认地区后启动。' }
    }
    $confirmed = $helperExitCode -eq 0 -and $reported.Success -is [bool] -and $reported.Success -and
        $reported.GameRegionConfirmed -is [bool] -and $reported.GameRegionConfirmed -and
        $reported.Region -is [string] -and $reported.Region -eq $Region -and
        $reported.Status -is [string] -and $reported.Status -eq 'Started'
    if ($confirmed) {
        return [pscustomobject]@{ Success=$true; GameRegionConfirmed=$true; Region=$Region; Status='Started'; Message=[string]$reported.Message }
    }
    $message = [string]$reported.Message
    if (-not $message) { $message = '未确认目标游戏地区。请完成官方登录，在星际页面选择游戏地区后启动。' }
    return [pscustomobject]@{ Success=$false; GameRegionConfirmed=$false; Region=$Region; Status='NeedsOfficialSelection'; Message=$message }
}

function Get-Sc2LauncherGameState($Discovery, [string]$Region) {
    $target = if ($Region -eq 'CN') { $Discovery.CNDirectory } else { $Discovery.EUDirectory }
    foreach ($process in Get-Sc2LauncherProcesses) {
        if ($process.Name -notin @('SC2','SC2_x64','SC2Switcher','SC2Switcher_x64','SC2Editor','SC2Editor_x64')) { continue }
        if ($process.Name -in @('SC2Editor','SC2Editor_x64')) {
            return [pscustomobject]@{ Status='GameRunning'; Message='星际编辑器正在运行。请先保存进度并正常退出编辑器，再启动游戏；工具不会结束编辑器。' }
        }
        if (-not $process.Path) {
            return [pscustomobject]@{ Status='GameRunning'; Message='检测到星际游戏进程，但无法确认程序路径。请正常退出游戏后重试；工具不会结束游戏。' }
        }
        if (Test-OneClickWithin $process.Path $target) {
            if ($Region -eq 'CN') { return [pscustomobject]@{ Status='AlreadyRunning'; Message='当前国服游戏已经运行，无需重复启动。' } }
            return [pscustomobject]@{ Status='GameRunning'; Message='国际服游戏已经运行，程序路径无法确认它当前选择的服务器。请先正常退出游戏，再切换欧服、美服或亚服；工具不会结束游戏。' }
        }
        if ((Test-OneClickWithin $process.Path $Discovery.CNDirectory) -or (Test-OneClickWithin $process.Path $Discovery.EUDirectory)) {
            return [pscustomobject]@{ Status='GameRunning'; Message='另一个地区的星际游戏已经运行。请先正常退出当前游戏，再启动这个地区；工具不会结束游戏。' }
        }
        # Do not guess the region from process names or close unrelated installs.
        return [pscustomobject]@{ Status='GameRunning'; Message='检测到其他安装目录的星际游戏正在运行。请先正常退出游戏再重试；工具不会结束游戏。' }
    }
    $null
}

function Invoke-Sc2LauncherAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Inspect','LaunchCN','LaunchEU','LaunchUS','LaunchAsia','Repair')][string]$Action)
    $discovery = $null
    try {
        # Each action reads current official installation records; no cached UI
        # paths or state can authorize a launch or a metadata write.
        $discovery = Get-Sc2LauncherDiscovery
        if ($Action -eq 'Inspect') {
            if ($discovery.Status -eq 'Separated') { return New-Sc2LauncherResult $Action $true 'Separated' $discovery '国服和国际服安装已正确分离。欧服、美服和亚服共用这一套国际客户端，可选择目标地区后启动。' }
            if ($discovery.Status -eq 'Conflict') { return New-Sc2LauncherResult $Action $true 'Conflict' $discovery '检测到国服和国际服共用国服目录。国服可以启动；请点击“检查修复”分离安装后再启动国际服。' }
            return New-Sc2LauncherResult $Action $false 'Unsupported' $discovery ('自动识别未通过：' + $discovery.Reason + ' 请保留现有文件，不要反复删除 version 或安装登记。')
        }
        if ($Action -eq 'Repair') {
            if ($discovery.Status -notin @('Conflict','Separated')) { return New-Sc2LauncherResult $Action $false 'Unsupported' $discovery ('当前安装无法安全自动修复：' + $discovery.Reason) }
            $repair = Invoke-Sc2LauncherRepair
            $fresh = Get-Sc2LauncherDiscovery
            if ($repair.Status -eq 'AlreadySeparated') {
                if ($fresh.Status -eq 'Separated') { $result = New-Sc2LauncherResult $Action $true 'RepairAlreadySeparated' $fresh '检查完成，两服已分离，桌面入口已核验。未再次复制游戏。' }
                else { $result = New-Sc2LauncherResult $Action $false 'Unsupported' $fresh ('桌面入口已核验，但当前安装状态已发生变化：' + $fresh.Reason + ' 请等待官方更新完成后重新检查。未再次复制游戏。') }
            }
            elseif ($repair.Status -eq 'Repaired') {
                $opened = $false
                $message = '安装分离和备份完成。已打开官方欧服战网客户端；请完成登录和官方更新，窗口会自动重新检查。未自动启动游戏。'
                try { Open-Sc2EUUpdateClient $discovery.LauncherPath; $opened = $true }
                catch { $message = '安装分离和备份完成，但未能打开官方欧服客户端：' + $_.Exception.Message + ' 请手动打开官方战网完成欧服登录和更新，窗口会自动重新检查。' }
                $result = New-Sc2LauncherResult $Action $true 'RepairNeedsUpdate' $fresh $message
                $result | Add-Member -MemberType NoteProperty -Name UpdateClientOpened -Value $opened
            }
            else { throw '修复流程没有返回可确认的完成状态，请保留日志和备份。' }
            foreach ($name in @('WorkDirectory','MetadataBackupDirectory','VersionsArchiveDirectory')) {
                $property = $repair.PSObject.Properties[$name]
                if ($null -ne $property -and $property.Value) { $result | Add-Member -MemberType NoteProperty -Name $name -Value ([string]$property.Value) }
            }
            return $result
        }
        if ($discovery.Status -notin @('Conflict','Separated')) { return New-Sc2LauncherResult $Action $false 'Unsupported' $discovery ('当前安装尚未通过启动检查：' + $discovery.Reason + ' 请先检查修复并完成官方更新。') }
        if ($Action -ne 'LaunchCN' -and $discovery.Status -ne 'Separated') { return New-Sc2LauncherResult $Action $false 'NeedsRepair' $discovery '国服和国际服仍共用国服目录。请先点击“检查修复”，完成官方国际服更新后再启动。' }
        $region = switch ($Action) { 'LaunchCN' {'CN'} 'LaunchEU' {'EU'} 'LaunchUS' {'US'} 'LaunchAsia' {'KR'} }
        $game = Get-Sc2LauncherGameState $discovery $region
        if ($null -ne $game) { return New-Sc2LauncherResult $Action ($game.Status -eq 'AlreadyRunning') $game.Status $discovery $game.Message }
        if ($region -eq 'CN') {
            Start-Sc2RegionalLauncher -LauncherPath $discovery.LauncherPath -Region CN -Product s2_cn
            return New-Sc2LauncherResult $Action $true 'Started' $discovery '已打开官方国服入口。网易登录、验证码以及必要的官方补丁请在战网窗口中完成。'
        }
        $international = Invoke-Sc2InternationalLaunch -LauncherPath $discovery.LauncherPath -GameDirectory $discovery.EUDirectory -Region $region
        $confirmed = $null -ne $international -and $null -ne $international.PSObject.Properties['Success'] -and
            $international.Success -is [bool] -and $international.Success -and
            $null -ne $international.PSObject.Properties['GameRegionConfirmed'] -and
            $international.GameRegionConfirmed -is [bool] -and $international.GameRegionConfirmed -and
            $null -ne $international.PSObject.Properties['Region'] -and $international.Region -is [string] -and $international.Region -eq $region -and
            $null -ne $international.PSObject.Properties['Status'] -and $international.Status -is [string] -and $international.Status -eq 'Started'
        $label = switch ($region) { 'EU' {'欧服'} 'US' {'美服'} 'KR' {'亚服'} }
        if ($confirmed) { $result = New-Sc2LauncherResult $Action $true 'Started' $discovery ('已在官方星际页面确认' + $label + '游戏地区，并点击官方启动按钮。登录和必要补丁请在官方窗口完成。') }
        else {
            $message = '尚未确认目标游戏地区。请完成官方战网登录，在星际页面选择目标游戏区后启动。'
            if ($null -ne $international -and $null -ne $international.PSObject.Properties['Message'] -and $international.Message) { $message = [string]$international.Message }
            $result = New-Sc2LauncherResult $Action $false 'NeedsOfficialSelection' $discovery ('未完成' + $label + '游戏地区确认。' + $message)
        }
        $result | Add-Member -MemberType NoteProperty -Name TargetRegion -Value $region
        $result | Add-Member -MemberType NoteProperty -Name GameRegionConfirmed -Value ([bool]$confirmed)
        return $result
    }
    catch { return New-Sc2LauncherResult $Action $false 'Failed' $discovery ('操作停止：' + $_.Exception.Message) }
}

Export-ModuleMember -Function Get-Sc2LauncherInspection, Invoke-Sc2LauncherAction
