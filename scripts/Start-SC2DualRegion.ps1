#requires -Version 5.1
[CmdletBinding()]
param([switch]$Run)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Sc2Metadata.psm1') -Force
$script:OneClickScriptRoot = $PSScriptRoot

function Get-OneClickDiscovery { Get-Sc2AutoDiscovery }
function Get-OneClickDesktop { [Environment]::GetFolderPath('Desktop') }
function Get-OneClickConfigPath { Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Battle.net\Battle.net.config' }
function Get-OneClickProcesses {
    foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
        if ($process.ProcessName -notin @('Battle.net','Battle.net Launcher','Agent','AgentHelper','SC2','SC2_x64','SC2Switcher','SC2Switcher_x64','SC2Editor','SC2Editor_x64')) { continue }
        $path = $null
        try { $path = $process.Path } catch { }
        [pscustomobject]@{ Name = $process.ProcessName; Id = $process.Id; Path = $path; Process = $process }
    }
}

function Get-OneClickFullPath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { throw '路径必须是完整绝对路径。' }
    [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
}

function Test-OneClickWithin([string]$Path, [string]$Directory) {
    if (-not $Path) { return $false }
    $root = (Get-OneClickFullPath $Directory) + [IO.Path]::DirectorySeparatorChar
    (Get-OneClickFullPath $Path).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-OneClickOrdinaryPath([string]$Path) {
    $full = Get-OneClickFullPath $Path
    $item = [IO.FileInfo]::new($full)
    if ([IO.Directory]::Exists($full)) { $item = [IO.DirectoryInfo]::new($full) }
    while ($null -ne $item) {
        if ($item.Exists -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '不能使用符号链接、目录联接或共享的游戏目录。' }
        if ($item -is [IO.FileInfo]) { $item = $item.Directory } else { $item = $item.Parent }
    }
}

function Assert-OneClickAbsent([string]$Path) {
    Assert-OneClickOrdinaryPath $Path
    if ($null -ne (Get-Item -Force -LiteralPath $Path -ErrorAction SilentlyContinue)) { throw "目标已经存在，不能覆盖或盲目复用：$Path" }
}

function Assert-OneClickGameClosed($Discovery) {
    foreach ($process in Get-OneClickProcesses) {
        if ($process.Name -notin @('SC2','SC2_x64','SC2Switcher','SC2Switcher_x64','SC2Editor','SC2Editor_x64')) { continue }
        if (-not $process.Path -or (Test-OneClickWithin $process.Path $Discovery.CNDirectory) -or (Test-OneClickWithin $process.Path $Discovery.EUDirectory)) {
            throw '检测到星际游戏或编辑器正在运行。请先保存进度并正常退出，再双击本工具；工具不会强制结束游戏。'
        }
    }
}

function Close-OneClickBattleNet($Discovery) {
    Assert-OneClickGameClosed $Discovery
    $launcherRoot = Split-Path -Parent $Discovery.LauncherPath
    $agentRoot = Split-Path -Parent $Discovery.AgentDatabase
    foreach ($process in Get-OneClickProcesses) {
        $relatedLauncher = $process.Name -in @('Battle.net','Battle.net Launcher') -and (Test-OneClickWithin $process.Path $launcherRoot)
        $relatedAgent = $process.Name -in @('Agent','AgentHelper') -and (Test-OneClickWithin $process.Path $agentRoot)
        if (-not ($relatedLauncher -or $relatedAgent)) { continue }
        Write-Host ('正在退出相关战网进程：' + $process.Name)
        $null = $process.Process.CloseMainWindow()
        if (-not $process.Process.WaitForExit(5000)) { $process.Process.Kill(); $process.Process.WaitForExit(5000) | Out-Null }
    }
    Assert-OneClickGameClosed $Discovery
    foreach ($process in Get-OneClickProcesses) {
        if (-not $process.Path -and $process.Name -in @('Battle.net','Battle.net Launcher','Agent','AgentHelper')) { throw '无法确认战网或 Agent 进程的程序路径，停止操作。请正常退出相关进程后重试。' }
        if (($process.Name -in @('Battle.net','Battle.net Launcher') -and (Test-OneClickWithin $process.Path $launcherRoot)) -or
            ($process.Name -in @('Agent','AgentHelper') -and (Test-OneClickWithin $process.Path $agentRoot))) { throw '相关战网进程仍在运行，尚未修改安装。请正常退出它后重试。' }
    }
}

function Assert-OneClickMetadataOffline {
    # Match the metadata module's conservative process guard before any large copy.
    # Unrelated same-name software is left running and requires the user's attention.
    foreach ($process in Get-OneClickProcesses) {
        if ($process.Name -in @('Battle.net','Battle.net Launcher','Agent','AgentHelper','SC2','SC2_x64','SC2Switcher','SC2Switcher_x64')) {
            throw ('检测到仍运行的 ' + $process.Name + '，核心元数据安全检查要求先退出。工具没有终止无关程序，也尚未复制游戏。')
        }
    }
}

function Get-OneClickTree([string]$Directory, [switch]$Hash) {
    Assert-OneClickOrdinaryPath $Directory
    if (-not [IO.Directory]::Exists($Directory)) { throw "游戏目录不存在：$Directory" }
    $root = Get-OneClickFullPath $Directory
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($root)
    $files = [Collections.Generic.List[object]]::new()
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -Force -LiteralPath $pending.Pop()) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "游戏数据中存在链接，停止复制：$($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            $hashValue = $null
            if ($Hash) { $hashValue = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
            $files.Add([pscustomobject]@{ Relative = $item.FullName.Substring($root.Length + 1).Replace('\','/').ToLowerInvariant(); Length = [long]$item.Length; Hash = $hashValue })
        }
    }
    return $files.ToArray()
}

function Get-OneClickTreeSignature([object[]]$Files, [switch]$Hash) {
    $lines = @($Files | Sort-Object Relative | ForEach-Object {
        if ($Hash) { $_.Relative + '|' + $_.Length + '|' + $_.Hash } else { $_.Relative + '|' + $_.Length }
    })
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-OneClickAvailableSpace([string]$Path) {
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot((Get-OneClickFullPath $Path)))
    if (-not $drive.IsReady) { throw '目标磁盘尚未就绪。' }
    [long]$drive.AvailableFreeSpace
}

function Get-OneClickRobocopyArguments([string]$Source, [string]$Destination) {
    # /E copies ordinary files and empty directories. No mirror, purge, move, or deletion flags.
    @($Source, $Destination, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/XJ', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
}

function Invoke-OneClickRobocopy([string]$Source, [string]$Destination) {
    $copyArguments = @(Get-OneClickRobocopyArguments $Source $Destination)
    & robocopy.exe @copyArguments | Out-Host
    if ($LASTEXITCODE -ge 8) { throw "复制失败（robocopy 返回 $LASTEXITCODE）。保留部分副本以便检查，请不要覆盖它重试。" }
}

function Copy-OneClickGame($Discovery, [object[]]$SourceFiles) {
    Assert-OneClickAbsent $Discovery.EUDirectory
    if (-not $SourceFiles.Count) { throw '原游戏目录没有可复制的文件。' }
    $bytes = [long](($SourceFiles | Measure-Object Length -Sum).Sum)
    $reserve = [Math]::Max(1GB, [Math]::Ceiling($bytes * 0.05))
    if ((Get-OneClickAvailableSpace $Discovery.EUDirectory) -lt ($bytes + $reserve)) { throw '空间不足：需要完整游戏副本和至少 1 GB 的补丁余量。尚未复制或修改元数据。' }
    $null = New-Item -ItemType Directory -Path $Discovery.EUDirectory -ErrorAction Stop
    Write-Host ('正在完整复制现有游戏，约 ' + [Math]::Round($bytes / 1GB, 1) + ' GB；这一步可能需要几分钟。')
    Invoke-OneClickRobocopy $Discovery.CNDirectory $Discovery.EUDirectory
    $originalNow = @(Get-OneClickTree $Discovery.CNDirectory)
    $copyFiles = @(Get-OneClickTree $Discovery.EUDirectory)
    $expected = Get-OneClickTreeSignature $SourceFiles
    if ((Get-OneClickTreeSignature $originalNow) -ne $expected -or (Get-OneClickTreeSignature $copyFiles) -ne $expected) { throw '复制后的相对文件名、数量或长度与原始快照不一致，停止修改元数据。请检查部分 EU 副本。' }
    [pscustomobject]@{ FileCount = $copyFiles.Count; Bytes = $bytes; Verified = $true }
}

function New-OneClickWorkDirectory($Discovery) {
    $parent = Split-Path -Parent (Get-OneClickFullPath $Discovery.CNDirectory)
    $root = Join-Path $parent '.sc2-dual-region-backups'
    Assert-OneClickOrdinaryPath $root
    if ([IO.File]::Exists($root)) { throw '自动备份路径已被文件占用。' }
    $null = [IO.Directory]::CreateDirectory($root)
    $work = Join-Path $root ('sc2-oneclick-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    $null = [IO.Directory]::CreateDirectory($work)
    $work
}

function Write-OneClickMarker([string]$WorkDirectory, $Discovery, [string]$Status, $Details) {
    $marker = [pscustomobject]@{ SchemaVersion = 1; Status = $Status; AgentDatabase = $Discovery.AgentDatabase; CNDirectory = $Discovery.CNDirectory; EUDirectory = $Discovery.EUDirectory; Details = $Details }
    [IO.File]::WriteAllText((Join-Path $WorkDirectory 'operation.json'), ($marker | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($true))
}

function Move-OneClickDirectory([string]$Source, [string]$Destination) { [IO.Directory]::Move($Source,$Destination) }

function Archive-OneClickCopiedCNBuild($Discovery, [string]$WorkDirectory) {
    Assert-OneClickGameClosed $Discovery
    Assert-OneClickMetadataOffline
    if ($Discovery.CNVersion -notmatch '^\d+(?:\.\d+){3}$') { throw '无法明确确认国服当前构建，停止预归档。' }
    # The original international record is still cn. No known EU target version
    # exists yet, so copied program builds must wait for the official EU update.
    $cnVersions = Join-Path $Discovery.CNDirectory 'Versions'
    $euVersions = Join-Path $Discovery.EUDirectory 'Versions'
    foreach($path in @($cnVersions,$euVersions,$WorkDirectory)) { Assert-OneClickOrdinaryPath $path }
    if ([IO.Path]::GetPathRoot((Get-OneClickFullPath $WorkDirectory)) -ne [IO.Path]::GetPathRoot((Get-OneClickFullPath $Discovery.EUDirectory))) { throw '程序构建档案必须在 EU 副本同一个盘。' }
    $currentName = 'Base' + $Discovery.CNVersion.Split('.')[-1]
    if (-not [IO.Directory]::Exists((Join-Path $cnVersions $currentName)) -or -not [IO.Directory]::Exists((Join-Path $euVersions $currentName))) { throw '当前国服程序构建目录缺失，停止预归档。' }
    $directories = @(Get-ChildItem -Directory -Force -LiteralPath $euVersions | Where-Object { $_.Name -match '^Base\d+$' })
    if (-not $directories.Count -or $directories.Count -gt 128) { throw '复制的数字 Base 目录数量超出可安全预归档范围。' }
    # Validate every proposed move before creating an archive or moving any file.
    $validated = @(foreach ($directory in $directories) {
        $source = Join-Path $cnVersions $directory.Name
        $sourceFiles = @(Get-OneClickTree $source -Hash)
        $copyFiles = @(Get-OneClickTree $directory.FullName -Hash)
        if (-not $sourceFiles.Count) { throw '一个数字 Base 目录为空，无法确认复制内容。' }
        $fingerprint = Get-OneClickTreeSignature $sourceFiles -Hash
        if ((Get-OneClickTreeSignature $copyFiles -Hash) -ne $fingerprint) { throw ('复制的程序构建与原目录不一致，停止全部预归档：' + $directory.Name) }
        [pscustomobject]@{ Name=$directory.Name; SourcePath=$source; OriginalPath=$directory.FullName; Fingerprint=$fingerprint }
    })
    $archive = Join-Path $WorkDirectory ('sc2-versions-archive-pre-update-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    $null = [IO.Directory]::CreateDirectory($archive)
    $moves = @($validated | ForEach-Object { [pscustomobject]@{ OriginalPath=$_.OriginalPath; ArchivePath=(Join-Path $archive $_.Name); Fingerprint=$_.Fingerprint } })
    $manifest = [pscustomobject]@{
        SchemaVersion = 1; Mode = 'NewEUCopyBeforeOfficialUpdate'
        Inputs = [pscustomobject]@{ AgentDatabase = $Discovery.AgentDatabase; CNDirectory = $Discovery.CNDirectory; EUDirectory = $Discovery.EUDirectory }
        OfficialEU = $null
        Moves = $moves
    }
    [IO.File]::WriteAllText((Join-Path $archive 'archive.json'), ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($true))
    $completed = [Collections.Generic.List[object]]::new()
    try {
        foreach ($move in $moves) {
            Assert-OneClickGameClosed $Discovery
            Assert-OneClickMetadataOffline
            if ((Get-OneClickTreeSignature @(Get-OneClickTree $move.OriginalPath -Hash) -Hash) -ne $move.Fingerprint) { throw '程序构建在归档前发生变化。' }
            Move-OneClickDirectory $move.OriginalPath $move.ArchivePath
            $completed.Add($move)
            if ((Get-OneClickTreeSignature @(Get-OneClickTree $move.ArchivePath -Hash) -Hash) -ne $move.Fingerprint) { throw '归档后的程序构建校验失败。' }
        }
    }
    catch {
        $cause = $_.Exception.Message
        try {
            for($i=$completed.Count-1;$i -ge 0;$i--) {
                $move=$completed[$i]
                Assert-OneClickGameClosed $Discovery
                Assert-OneClickMetadataOffline
                Assert-OneClickAbsent $move.OriginalPath
                if ((Get-OneClickTreeSignature @(Get-OneClickTree $move.ArchivePath -Hash) -Hash) -ne $move.Fingerprint) { throw '归档内容变化，不能自动回移。' }
                Move-OneClickDirectory $move.ArchivePath $move.OriginalPath
            }
        }
        catch { throw "预归档失败且自动回移未完成。请保留档案：$archive" }
        throw ("预归档失败，已回移本次移动的副本：$cause")
    }
    Write-Host ('已归档新 EU 副本从原安装复制的 ' + $moves.Count + ' 个程序构建目录，原国服和 EU 大型数据保留。')
    $archive
}

function Read-OneClickShortcut([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    Assert-OneClickOrdinaryPath $Path
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Path)
    [pscustomobject]@{ Target = $link.TargetPath; Arguments = $link.Arguments }
}

function Ensure-OneClickShortcuts($Discovery, [switch]$ValidateOnly) {
    $desktop = Get-OneClickDesktop
    Assert-OneClickOrdinaryPath $desktop
    $expected = @(
        [pscustomobject]@{ Name = '星际2-国服（网易）'; Arguments = '--setregion=CN --exec="launch s2_cn"' },
        [pscustomobject]@{ Name = '星际2-欧服（国际）'; Arguments = '--setregion=EU --exec="launch s2"' }
    )
    $missing = @()
    foreach ($entry in $expected) {
        $path = Join-Path $desktop ($entry.Name + '.lnk')
        $existing = Read-OneClickShortcut $path
        if ($null -eq $existing) { Assert-OneClickAbsent $path; $missing += $entry; continue }
        if ((Get-OneClickFullPath $existing.Target) -ne (Get-OneClickFullPath $Discovery.LauncherPath) -or $existing.Arguments -ne $entry.Arguments) { throw "桌面存在同名但内容不同的入口，不能覆盖：$path" }
    }
    if ($ValidateOnly) { return }
    if (-not $missing.Count) { Write-Host '桌面两个入口已经正确，直接复用。'; return }
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('sc2-shortcuts-' + [Guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($stage)
    try {
        & (Join-Path $script:OneClickScriptRoot 'New-SC2Shortcuts.ps1') -LauncherPath $Discovery.LauncherPath -CNDirectory $Discovery.CNDirectory -EUDirectory $Discovery.EUDirectory -DesktopPath $stage -Apply | Out-Null
        foreach ($entry in $missing) { [IO.File]::Move((Join-Path $stage ($entry.Name + '.lnk')), (Join-Path $desktop ($entry.Name + '.lnk'))) }
    }
    finally {
        foreach ($entry in $expected) { $staged = Join-Path $stage ($entry.Name + '.lnk'); if ([IO.File]::Exists($staged)) { [IO.File]::Delete($staged) } }
        if ([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage) }
    }
    Write-Host '已建立桌面入口：星际2-国服（网易）、星际2-欧服（国际）。'
}

function Start-OneClickEU($Discovery) {
    Start-Process -FilePath $Discovery.LauncherPath -ArgumentList '--setregion=EU --exec="launch s2"'
}

function Enable-OneClickMultipleInstances($Discovery, [string]$WorkDirectory) {
    $path = Get-OneClickConfigPath
    Assert-OneClickOrdinaryPath $path
    if (-not [IO.File]::Exists($path)) { Write-Host '未发现战网多开设置，请在战网设置中手动开启允许多个实例。'; return 'Missing' }
    if (([IO.FileInfo]::new($path)).Length -gt 2MB) { throw '战网配置超出可安全检查的大小。' }
    $bytes = [IO.File]::ReadAllBytes($path)
    try { $config = ([Text.UTF8Encoding]::new($false,$true)).GetString($bytes).TrimStart([char]65279) | ConvertFrom-Json }
    catch { Write-Host '多开配置格式无法安全解析，请在战网设置中手动开启允许多个实例。'; return 'Unsupported' }
    $clientProperty = $config.PSObject.Properties['Client']
    $setting = $null
    if ($null -ne $clientProperty -and $null -ne $clientProperty.Value) { $setting = $clientProperty.Value.PSObject.Properties['SingleInstance'] }
    if ($null -eq $setting -or $setting.Value -isnot [string] -or $setting.Value -notin @('true','false')) { Write-Host '多开设置格式未确认，请在战网“设置 → App”手动开启允许多个实例。'; return 'Unsupported' }
    if ($setting.Value -eq 'false') { return 'AlreadyEnabled' }
    foreach ($process in Get-OneClickProcesses) {
        if (-not $process.Path -or (Test-OneClickWithin $process.Path (Split-Path -Parent $Discovery.LauncherPath)) -or (Test-OneClickWithin $process.Path (Split-Path -Parent $Discovery.AgentDatabase))) { throw '战网仍在运行，不会重写它的用户配置。' }
    }
    $backup = Join-Path $WorkDirectory 'Battle.net.config.original'
    Assert-OneClickAbsent $backup
    [IO.File]::WriteAllBytes($backup, $bytes)
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backup)) -ne [Convert]::ToBase64String($bytes)) { throw '多开设置的私人备份校验失败。' }
    $config.Client.SingleInstance = 'false'
    $temporary = Join-Path (Split-Path -Parent $path) ('.sc2-multiinstance-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($config | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ne [Convert]::ToBase64String($bytes)) { throw '战网配置在准备期间变化，已保留备份且停止写入。' }
        [IO.File]::Replace($temporary, $path, [NullString]::Value)
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    Write-Host '已开启已确认的战网多开设置，原配置保存在私人备份中。'
    return 'Enabled'
}

function Invoke-SC2DualRegionOneClick([switch]$Run, [switch]$SkipLaunch) {
    $discovery = Get-OneClickDiscovery
    if ($discovery.Status -notin @('Conflict','Separated')) { throw ('自动识别未通过，尚未修改任何安装。' + $discovery.Reason) }
    Write-Host ('国服目录：' + $discovery.CNDirectory)
    Write-Host ('欧服目录：' + $discovery.EUDirectory)
    if ($discovery.Status -eq 'Separated') { Write-Host '状态：两个安装已分离，重复执行只核验并整理桌面入口。' }
    else { Write-Host '状态：检测到国服和国际服共用目录，执行时将建立独立 EU 副本。' }
    if (-not $Run) { Write-Host '只读预览完成。双击仓库中的“开始修复.cmd”可自动执行。'; return $discovery }
    if ($discovery.Status -eq 'Separated') {
        Ensure-OneClickShortcuts $discovery
        Write-Host '两个安装已经分离；未复制游戏或修改安装登记。请使用桌面入口。'
        return [pscustomobject]@{ Status = 'AlreadySeparated'; Discovery = $discovery }
    }
    Assert-OneClickGameClosed $discovery
    Assert-OneClickAbsent $discovery.EUDirectory
    Ensure-OneClickShortcuts $discovery -ValidateOnly
    $sourceFiles = @(Get-OneClickTree $discovery.CNDirectory)
    $bytes = [long](($sourceFiles | Measure-Object Length -Sum).Sum)
    if ((Get-OneClickAvailableSpace $discovery.EUDirectory) -lt ($bytes + [Math]::Max(1GB,[Math]::Ceiling($bytes * 0.05)))) { throw '目标磁盘空间不足，尚未关闭战网或写入安装。' }
    Close-OneClickBattleNet $discovery
    $fresh = Get-OneClickDiscovery
    foreach ($key in @('Status','AgentDatabase','CNDirectory','EUDirectory','LauncherPath','CNVersion','EUVersion')) {
        if ($fresh.$key -ne $discovery.$key) { throw '退出战网期间安装状态发生变化，尚未复制游戏。请重新运行只读检查。' }
    }
    Assert-OneClickMetadataOffline
    $sourceFiles = @(Get-OneClickTree $discovery.CNDirectory)
    $work = New-OneClickWorkDirectory $discovery
    try {
        Write-OneClickMarker $work $discovery 'PreparingCopy' $null
        $copy = Copy-OneClickGame $discovery $sourceFiles
        Write-OneClickMarker $work $discovery 'CopyVerified' $copy
        $archive = Archive-OneClickCopiedCNBuild $discovery $work
        Write-OneClickMarker $work $discovery 'CopiedCNBuildArchived' ([pscustomobject]@{ Copy = $copy; ArchiveDirectory = $archive })
        Write-Host '正在备份并分离五个安装元数据文件。'
        $plan = New-Sc2RepairPlan -AgentDatabase $discovery.AgentDatabase -CNDirectory $discovery.CNDirectory -EUDirectory $discovery.EUDirectory
        $application = Invoke-Sc2RepairPlan -Plan $plan -BackupDirectory $work
        Write-OneClickMarker $work $discovery 'MetadataRepaired' ([pscustomobject]@{ MetadataBackupDirectory = $application.BackupDirectory; VersionsArchiveDirectory = $archive })
        try { $null = Enable-OneClickMultipleInstances $discovery $work }
        catch { Write-Host ('多开设置未自动完成，安装分离已保留；请在战网设置中开启允许多个实例。原因：' + $_.Exception.Message) }
        Ensure-OneClickShortcuts $discovery
        if (-not $SkipLaunch) { Start-OneClickEU $discovery }
        if ($SkipLaunch) { Write-Host '分离完成。请通过官方欧服战网完成校验和更新后再进入游戏。' }
        else { Write-Host '分离完成，已打开官方欧服入口。若战网等待更新，请点“更新”完成官方补丁，再进入游戏。' }
        Write-Host '国服使用“星际2-国服（网易）”。网易登录、验证码和账号确认请在官方窗口完成。'
        Write-Host '需要同时保留两个战网窗口时，在战网“设置 → App”开启允许多个实例。'
        Write-Host 'EU 程序构建由官方更新补齐；新副本的 SC2Data 大型数据已保留供官方校验复用。'
        Write-Host ('私人备份和进度记录：' + $work)
        return [pscustomobject]@{ Status = 'Repaired'; WorkDirectory = $work; MetadataBackupDirectory = $application.BackupDirectory; VersionsArchiveDirectory = $archive }
    }
    catch { throw ($_.Exception.Message + "`n已保留私人进度记录和可能的 EU 副本，不能盲目覆盖重试：$work") }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-SC2DualRegionOneClick -Run:$Run | Out-Null }
    catch { Write-Host ('操作停止：' + $_.Exception.Message) -ForegroundColor Red; exit 1 }
}
