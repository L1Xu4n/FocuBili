[CmdletBinding()]
param(
    [string]$InnoCompilerPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
Reads the semantic version and build number from pubspec.yaml.
#>
function Get-FocuBiliVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PubspecPath
    )

    $pubspec = Get-Content -Raw -LiteralPath $PubspecPath
    $match = [regex]::Match(
        $pubspec,
        '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$'
    )
    if (-not $match.Success) {
        throw "pubspec.yaml does not contain a supported version such as 1.4.0+15."
    }

    return [pscustomobject]@{
        Version = $match.Groups[1].Value
        Build = $match.Groups[2].Value
    }
}

<#
.SYNOPSIS
Finds the Inno Setup command-line compiler without changing the system PATH.
#>
function Find-InnoCompiler {
    param(
        [string]$RequestedPath
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
            throw "The requested Inno Setup compiler was not found: $RequestedPath"
        }
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    $command = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'Inno Setup 6 was not found. Install JRSoftware.InnoSetup with winget first.'
}

<#
.SYNOPSIS
Finds the newest x64 Visual C++ runtime bundled with an installed Visual Studio.
#>
function Find-VcRuntimeDirectory {
    $installationPaths = @()
    $vswhereCommand = Get-Command 'vswhere.exe' -ErrorAction SilentlyContinue
    $vswherePath = if ($null -ne $vswhereCommand) {
        $vswhereCommand.Source
    } else {
        Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    }
    if (Test-Path -LiteralPath $vswherePath -PathType Leaf) {
        $vswhereInstallations = & $vswherePath -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath -format value
        $installationPaths += @(
            $vswhereInstallations |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    foreach ($programFilesRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($programFilesRoot)) {
            continue
        }
        $visualStudioRoot = Join-Path $programFilesRoot 'Microsoft Visual Studio'
        if (-not (Test-Path -LiteralPath $visualStudioRoot -PathType Container)) {
            continue
        }
        Get-ChildItem -LiteralPath $visualStudioRoot -Directory |
            ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -Directory
            } |
            ForEach-Object {
                $installationPaths += $_.FullName
            }
    }

    $runtimeDirectories = foreach ($installationPath in ($installationPaths | Sort-Object -Unique)) {
        $redistRoot = Join-Path $installationPath 'VC\Redist\MSVC'
        if (-not (Test-Path -LiteralPath $redistRoot -PathType Container)) {
            continue
        }
        foreach ($redistVersion in (Get-ChildItem -LiteralPath $redistRoot -Directory)) {
            $x64Root = Join-Path $redistVersion.FullName 'x64'
            if (-not (Test-Path -LiteralPath $x64Root -PathType Container)) {
                continue
            }
            Get-ChildItem -LiteralPath $x64Root -Directory -Filter 'Microsoft.VC*.CRT' |
                ForEach-Object { $_.FullName }
        }
    }

    $runtimeDirectory = $runtimeDirectories | Sort-Object -Descending | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($runtimeDirectory)) {
        throw 'An x64 Visual C++ runtime directory was not found in the installed Visual Studio instances.'
    }
    return (Resolve-Path -LiteralPath $runtimeDirectory).Path
}

<#
.SYNOPSIS
Rejects cleanup targets outside the dedicated Windows installer output directory.
#>
function Assert-SafeInstallerOutputPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot
    )

    $resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith(
        "$resolvedOutputRoot\",
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to modify a path outside the installer output directory: $resolvedPath"
    }
}

<#
.SYNOPSIS
Removes an old generated file or directory after validating its absolute path.
#>
function Remove-GeneratedItem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    Assert-SafeInstallerOutputPath -Path $Path -OutputRoot $OutputRoot
    Remove-Item -LiteralPath $Path -Recurse -Force
}

$repositoryRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\..')
)
$pubspecPath = Join-Path $repositoryRoot 'pubspec.yaml'
$releaseDirectory = Join-Path $repositoryRoot 'build\windows\x64\runner\Release'
$outputDirectory = Join-Path $repositoryRoot 'build\windows\x64\installer'
$installerScript = Join-Path $PSScriptRoot 'FocuBili.iss'

if (-not (Test-Path -LiteralPath (Join-Path $releaseDirectory 'FocuBili.exe') -PathType Leaf)) {
    throw 'Windows Release output is missing. Run flutter build windows --release first.'
}

$versionInfo = Get-FocuBiliVersion -PubspecPath $pubspecPath
$portableName = "FocuBili-v$($versionInfo.Version)-windows-x64-portable"
$portableDirectory = Join-Path $outputDirectory $portableName
$portableArchive = Join-Path $outputDirectory "$portableName.zip"
$setupPath = Join-Path $outputDirectory "FocuBili-v$($versionInfo.Version)-windows-x64-setup.exe"

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
Remove-GeneratedItem -Path $portableDirectory -OutputRoot $outputDirectory
Remove-GeneratedItem -Path $portableArchive -OutputRoot $outputDirectory
Remove-GeneratedItem -Path $setupPath -OutputRoot $outputDirectory
New-Item -ItemType Directory -Path $portableDirectory -Force | Out-Null

Get-ChildItem -LiteralPath $releaseDirectory -Force |
    Copy-Item -Destination $portableDirectory -Recurse -Force

$vcRuntimeDirectory = Find-VcRuntimeDirectory
Get-ChildItem -LiteralPath $vcRuntimeDirectory -File -Filter '*.dll' |
    Copy-Item -Destination $portableDirectory -Force

$requiredRuntimeFiles = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')
foreach ($runtimeFile in $requiredRuntimeFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $portableDirectory $runtimeFile) -PathType Leaf)) {
        throw "The required VC++ runtime file was not bundled: $runtimeFile"
    }
}

Compress-Archive -Path (Join-Path $portableDirectory '*') -DestinationPath $portableArchive -CompressionLevel Optimal

$compiler = Find-InnoCompiler -RequestedPath $InnoCompilerPath
& $compiler "/DAppVersion=$($versionInfo.Version)" "/DAppBuild=$($versionInfo.Build)" "/DSourceDir=$portableDirectory" "/DOutputDir=$outputDirectory" $installerScript
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
    throw "Inno Setup did not produce the expected installer: $setupPath"
}

Get-Item -LiteralPath $portableArchive, $setupPath |
    ForEach-Object {
        $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
        [pscustomobject]@{
            Name = $_.Name
            Length = $_.Length
            Sha256 = $hash.Hash
        }
    } |
    Format-Table -AutoSize
