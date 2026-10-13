#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$LauncherPath,
    [Parameter(Mandatory = $true)][string]$CNDirectory,
    [Parameter(Mandatory = $true)][string]$EUDirectory,
    [string]$DesktopPath = [Environment]::GetFolderPath('Desktop'),
    [string]$CNName = '星际2-国服（网易）',
    [string]$EUName = '星际2-欧服（国际）',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-ExistingPath([string]$Path, [bool]$IsDirectory) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -ne $IsDirectory) { throw 'Unexpected path type.' }
    return [IO.Path]::GetFullPath($item.FullName).TrimEnd('\','/')
}

$launcher = Get-ExistingPath $LauncherPath $false
if ([IO.Path]::GetFileName($launcher) -notin @('Battle.net Launcher.exe','Battle.net.exe')) {
    throw 'Choose the installed official Battle.net Launcher.exe or Battle.net.exe.'
}
$cn = Get-ExistingPath $CNDirectory $true
$eu = Get-ExistingPath $EUDirectory $true
$desktop = Get-ExistingPath $DesktopPath $true
if ($cn.Equals($eu,[StringComparison]::OrdinalIgnoreCase) -or
    $cn.StartsWith($eu + '\',[StringComparison]::OrdinalIgnoreCase) -or
    $eu.StartsWith($cn + '\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'CN and EU need separate, non-nested game directories.'
}
foreach ($name in @($CNName,$EUName)) {
    if ([string]::IsNullOrWhiteSpace($name) -or
        $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw 'Shortcut names must be plain file names.'
    }
}
if ($CNName.Equals($EUName,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'The shortcuts need different names.'
}
$shortcuts = @(
    [pscustomobject]@{
        Path=Join-Path $desktop ($CNName + '.lnk')
        Target=$launcher
        Arguments='--setregion=CN --exec="launch s2_cn"'
        Icon=Join-Path $cn 'StarCraft II.exe'
        Description='国服：网易战网登录，独立国服游戏目录。'
    },
    [pscustomobject]@{
        Path=Join-Path $desktop ($EUName + '.lnk')
        Target=$launcher
        Arguments='--setregion=EU --exec="launch s2"'
        Icon=Join-Path $eu 'StarCraft II.exe'
        Description='欧服：国际战网登录，独立欧服游戏目录。'
    }
)
if (-not $Apply) {
    $shortcuts | Select-Object Path,Target,Arguments,@{Name='AlreadyExists';Expression={Test-Path -LiteralPath $_.Path}}
    return
}
foreach ($shortcut in $shortcuts) {
    if (Test-Path -LiteralPath $shortcut.Path) {
        throw 'A named shortcut already exists. Choose other names; no files were changed.'
    }
}
$createdPaths = @()
try {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($shortcut in $shortcuts) {
        if ($PSCmdlet.ShouldProcess($shortcut.Path,'Create a regional Battle.net shortcut')) {
            $link = $shell.CreateShortcut($shortcut.Path)
            $link.TargetPath=$shortcut.Target
            $link.Arguments=$shortcut.Arguments
            $link.WorkingDirectory=Split-Path -Parent $launcher
            if (Test-Path -LiteralPath $shortcut.Icon -PathType Leaf) {
                $link.IconLocation=$shortcut.Icon + ',0'
            }
            $link.Description=$shortcut.Description
            $link.Save()
            $createdPaths += $shortcut.Path
        }
    }
}
catch {
    foreach ($createdPath in $createdPaths) {
        if (Test-Path -LiteralPath $createdPath -PathType Leaf) {
            Remove-Item -LiteralPath $createdPath -Force
        }
    }
    throw
}
$shortcuts | Where-Object {$_.Path -in $createdPaths} | Select-Object Path,Target,Arguments
