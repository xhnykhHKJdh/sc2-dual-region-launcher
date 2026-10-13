#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Inspect','LaunchCN','LaunchEU','LaunchUS','LaunchAsia','Repair')][string]$Action = 'Inspect',
    [string]$ResultPath,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Sc2Launcher.psm1') -Force

function Assert-Sc2LauncherWorkerPaths([string]$ResultPath, [string]$LogPath) {
    if (-not $ResultPath -or -not $LogPath -or -not [IO.Path]::IsPathRooted($ResultPath) -or -not [IO.Path]::IsPathRooted($LogPath)) { throw '工作进程需要已创建的本机临时目录和完整输出路径。' }
    $result = [IO.Path]::GetFullPath($ResultPath)
    $log = [IO.Path]::GetFullPath($LogPath)
    $parent = [IO.Path]::GetDirectoryName($result)
    if ($result -eq $log -or $parent -ne [IO.Path]::GetDirectoryName($log)) { throw '结果文件与日志必须使用同一个私人临时目录中的不同文件。' }
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if ([IO.Path]::GetDirectoryName($parent) -ne $temp -or [IO.Path]::GetFileName($parent) -notmatch '^sc2-launcher-[0-9a-f]{32}$' -or -not [IO.Directory]::Exists($parent)) { throw '输出目录必须是本机临时目录下由界面新建的 sc2-launcher-GUID 目录。' }
    if ($result.StartsWith('\\') -or $result.StartsWith('//')) { throw '工作进程不能输出到网络共享路径。' }
    $item = [IO.DirectoryInfo]::new($parent)
    while ($null -ne $item) {
        if ($item.Exists -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '输出目录不能使用链接或目录联接。' }
        $item = $item.Parent
    }
    foreach ($path in @($result,$log)) {
        if ($null -ne (Get-Item -Force -LiteralPath $path -ErrorAction SilentlyContinue)) { throw '工作进程不会覆盖已有结果或日志文件。' }
    }
    [pscustomobject]@{ ResultPath=$result; LogPath=$log; Directory=$parent }
}

function Invoke-Sc2LauncherWorker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Inspect','LaunchCN','LaunchEU','LaunchUS','LaunchAsia','Repair')][string]$Action,
        [Parameter(Mandatory)][string]$ResultPath,
        [Parameter(Mandatory)][string]$LogPath
    )
    $paths = Assert-Sc2LauncherWorkerPaths $ResultPath $LogPath
    $stream = [IO.File]::Open($paths.LogPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $writer = [IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true
    $captured = @{ Result=$null }
    try {
        $writer.WriteLine('Action: ' + $Action)
        & { Invoke-Sc2LauncherAction -Action $Action } *>&1 | ForEach-Object {
            if ($null -ne $_ -and $null -ne $_.PSObject.Properties['Success'] -and $null -ne $_.PSObject.Properties['Action'] -and $null -ne $_.PSObject.Properties['Status'] -and $null -ne $_.PSObject.Properties['Message']) {
                $captured.Result = $_
                $writer.WriteLine([string]$_.Message)
            }
            elseif ($null -ne $_) { $writer.WriteLine([string]$_) }
        }
        if ($null -eq $captured.Result) { throw '工作进程没有收到有效操作结果。' }
    }
    catch {
        $message = '工作进程停止：' + $_.Exception.Message
        $writer.WriteLine($message)
        $captured.Result = [pscustomobject][ordered]@{ SchemaVersion=1; Success=$false; Action=$Action; Status='Failed'; Discovery=$null; Message=$message }
    }
    finally { $writer.Dispose() }
    $temporary = Join-Path $paths.Directory ('.result-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary,($captured.Result | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$paths.ResultPath)
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    if ($captured.Result.Success) { return 0 }
    return 1
}

if ($MyInvocation.InvocationName -ne '.') {
    try { $workerExitCode = Invoke-Sc2LauncherWorker -Action $Action -ResultPath $ResultPath -LogPath $LogPath; exit $workerExitCode }
    catch { Write-Error ('工作进程无法写入结果：' + $_.Exception.Message) -ErrorAction Continue; exit 1 }
}
