#requires -Version 5.1
[CmdletBinding()]
param([switch]$Launch)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Windows PowerShell supplies the .NET Framework/GAC assembly used by the host.
# A direct PowerShell 7 invocation delegates once to that built-in runtime.
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    $windowsPowerShell = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw 'Windows PowerShell 5.1 is required. Run Start.cmd on Windows.'
    }
    $delegateOutput = [IO.Path]::GetTempFileName()
    $delegateError = [IO.Path]::GetTempFileName()
    $inheritedModulePath = $env:PSModulePath
    try {
        # Start-Process does not apply PowerShell 7's native-shell module-path fix.
        $windowsModulePath = Join-Path (Split-Path -Parent $windowsPowerShell) 'Modules'
        $env:PSModulePath = $windowsModulePath + [IO.Path]::PathSeparator + $inheritedModulePath
        $delegateArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
        if ($Launch) { $delegateArguments += ' -Launch' }
        $delegateProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList $delegateArguments -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $delegateOutput -RedirectStandardError $delegateError
        if ($delegateProcess.ExitCode -ne 0) {
            $details = (Get-Content -LiteralPath $delegateError -Raw -Encoding UTF8).Trim()
            throw ('The Windows PowerShell build failed. ' + $details)
        }
        $metadata = Get-Content -LiteralPath $delegateOutput -Raw -Encoding UTF8
        if ($metadata) { Write-Output $metadata.TrimEnd() }
    } finally {
        $env:PSModulePath = $inheritedModulePath
        Remove-Item -LiteralPath $delegateOutput,$delegateError -Force -ErrorAction SilentlyContinue
    }
    return
}

[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Import-Module -Name (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1')

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $repositoryRoot 'src\Sc2LauncherHost.cs'
$regionSelectorSourcePath = Join-Path $repositoryRoot 'src\Sc2BattleRegionSelector.cs'
$distributionPath = Join-Path $repositoryRoot 'dist'
$launcherPath = Join-Path $distributionPath 'SC2Launcher.exe'
$manifestPath = Join-Path $distributionPath 'SC2Launcher.build.json'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw ('The launcher host source is missing: ' + $sourcePath)
}
if (-not (Test-Path -LiteralPath $regionSelectorSourcePath -PathType Leaf)) {
    throw ('The native region selector source is missing: ' + $regionSelectorSourcePath)
}

$sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
$regionSelectorSourceHash = (Get-FileHash -LiteralPath $regionSelectorSourcePath -Algorithm SHA256).Hash
$buildHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
$powerShellAssembly = [psobject].Assembly.Location
$powerShellVersion = [psobject].Assembly.GetName().Version.ToString()
$current = $false
if ((Test-Path -LiteralPath $launcherPath -PathType Leaf) -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $current = (Get-Item -LiteralPath $launcherPath).Length -gt 0 -and
            $manifest.Schema -eq 1 -and
            $manifest.HostSourceSha256 -eq $sourceHash -and
            $manifest.RegionSelectorSourceSha256 -eq $regionSelectorSourceHash -and
            $manifest.BuildScriptSha256 -eq $buildHash -and
            $manifest.PowerShellAssemblyVersion -eq $powerShellVersion -and
            $manifest.ExecutableSha256 -eq (Get-FileHash -LiteralPath $launcherPath -Algorithm SHA256).Hash
    } catch {
        # A missing, damaged or outdated build record triggers a fresh local build.
        $current = $false
    }
}

$buildState = 'Current'
if (-not $current) {
    $runtimePath = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    $compilerPath = Join-Path $runtimePath 'csc.exe'
    if (-not (Test-Path -LiteralPath $compilerPath -PathType Leaf)) {
        throw 'The built-in .NET Framework C# compiler is unavailable.'
    }
    New-Item -ItemType Directory -Path $distributionPath -Force | Out-Null
    $temporaryName = 'SC2Launcher.build-' + [Guid]::NewGuid().ToString('N')
    $compileDirectory = Join-Path $distributionPath $temporaryName
    New-Item -ItemType Directory -Path $compileDirectory | Out-Null
    $compiledPath = Join-Path $compileDirectory 'SC2Launcher.exe'
    $responsePath = Join-Path $distributionPath ($temporaryName + '.rsp')
    $compilerOutput = Join-Path $distributionPath ($temporaryName + '.out')
    $compilerError = Join-Path $distributionPath ($temporaryName + '.err')
    try {
        $compilerOptions = @(
            '/nologo'
            '/target:winexe'
            '/platform:anycpu'
            '/optimize+'
            '/codepage:65001'
            '/utf8output'
            ('/out:"' + $compiledPath + '"')
            ('/reference:"' + (Join-Path $runtimePath 'System.dll') + '"')
            ('/reference:"' + (Join-Path $runtimePath 'System.Core.dll') + '"')
            ('/reference:"' + (Join-Path $runtimePath 'System.Windows.Forms.dll') + '"')
            ('/reference:"' + (Join-Path $runtimePath 'System.Web.Extensions.dll') + '"')
            ('/reference:"' + (Join-Path $runtimePath 'WPF\WindowsBase.dll') + '"')
            ('/reference:"' + (Join-Path $runtimePath 'WPF\UIAutomationClient.dll') + '"')
            ('/reference:"' + (Join-Path $runtimePath 'WPF\UIAutomationTypes.dll') + '"')
            ('/reference:"' + $powerShellAssembly + '"')
            ('"' + $sourcePath + '"')
            ('"' + $regionSelectorSourcePath + '"')
        )
        [IO.File]::WriteAllLines($responsePath,$compilerOptions,(New-Object Text.UTF8Encoding($true)))
        $compilerArguments = '/noconfig @"' + $responsePath + '"'
        $compilerProcess = Start-Process -FilePath $compilerPath -ArgumentList $compilerArguments -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $compilerOutput -RedirectStandardError $compilerError
        if ($compilerProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $compiledPath -PathType Leaf)) {
            $details = @(
                (Get-Content -LiteralPath $compilerOutput -Raw -Encoding UTF8)
                (Get-Content -LiteralPath $compilerError -Raw -Encoding UTF8)
            ) -join [Environment]::NewLine
            throw ('The launcher host could not be compiled. ' + $details.Trim())
        }
        Move-Item -LiteralPath $compiledPath -Destination $launcherPath -Force
        $manifest = [ordered]@{
            Schema = 1
            HostSourceSha256 = $sourceHash
            RegionSelectorSourceSha256 = $regionSelectorSourceHash
            BuildScriptSha256 = $buildHash
            PowerShellAssemblyVersion = $powerShellVersion
            ExecutableSha256 = (Get-FileHash -LiteralPath $launcherPath -Algorithm SHA256).Hash
        }
        $manifestJson = $manifest | ConvertTo-Json
        [IO.File]::WriteAllText($manifestPath,$manifestJson,(New-Object Text.UTF8Encoding($true)))
        $buildState = 'Compiled'
    } finally {
        Remove-Item -LiteralPath $compiledPath,$responsePath,$compilerOutput,$compilerError -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $compileDirectory -Force -ErrorAction SilentlyContinue
    }
}

if ($Launch) {
    Start-Process -FilePath $launcherPath -WorkingDirectory $repositoryRoot | Out-Null
}
[pscustomobject]@{ Build = $buildState; Path = $launcherPath }
