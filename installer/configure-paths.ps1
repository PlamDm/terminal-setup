#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $PlaygroundRoot,
    [string] $YaziConfigFile,
    [switch] $EnsureYaziConfig,
    [switch] $Force,
    [switch] $NoPrompt
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('PlaygroundRoot')) {
    if ((Split-Path -Leaf $PSScriptRoot) -ieq 'installer') {
        $PlaygroundRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'personal-tools'
    } else {
        $PlaygroundRoot = $PSScriptRoot
    }
}
$PlaygroundRoot = [IO.Path]::GetFullPath($PlaygroundRoot).TrimEnd('\', '/')
$configHomeFile = Join-Path $PlaygroundRoot 'config\path\yazi-config-home.txt'
$managedConfigHome = Join-Path $PlaygroundRoot 'config\yazi'

function ConvertTo-PDWindowsPath {
    param([string] $Path)
    if ($Path -match '^/([A-Za-z])/(.*)$') {
        return ($Matches[1] + ':\' + $Matches[2].Replace('/', '\'))
    }
    return $Path
}

function Resolve-PDYaziConfigHome {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $Path = ConvertTo-PDWindowsPath $Path.Trim()
    if ($Path -match '[%"\r\n]') { return $null }
    try { $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }
    catch { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path $fullPath 'yazi.toml') -PathType Leaf)) {
        return $null
    }
    return $fullPath
}

function Set-PDYaziConfigHome {
    param([string] $Path)
    $resolvedPath = Resolve-PDYaziConfigHome $Path
    if (-not $resolvedPath) {
        throw "The selected folder must contain yazi.toml and be usable by a Windows launcher: $Path"
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $configHomeFile)) | Out-Null
    [IO.File]::WriteAllText(
        $configHomeFile,
        $resolvedPath + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host "[terminal-setup] Yazi config: $resolvedPath"
}

if ($YaziConfigFile) {
    $selectedFile = ConvertTo-PDWindowsPath $YaziConfigFile.Trim()
    if ([IO.Path]::GetFileName($selectedFile) -ine 'yazi.toml' -or
        -not (Test-Path -LiteralPath $selectedFile -PathType Leaf)) {
        throw "Select an existing yazi.toml file: $YaziConfigFile"
    }
    Set-PDYaziConfigHome -Path (Split-Path -Parent ([IO.Path]::GetFullPath($selectedFile)))
    return
}

$savedConfigHome = $null
if (Test-Path -LiteralPath $configHomeFile -PathType Leaf) {
    $savedConfigHome = [IO.File]::ReadAllText($configHomeFile).Trim()
}
$resolvedSavedConfigHome = Resolve-PDYaziConfigHome $savedConfigHome
if ($resolvedSavedConfigHome -and -not $Force) {
    return
}

$resolvedManagedConfigHome = Resolve-PDYaziConfigHome $managedConfigHome
$canPrompt = -not $NoPrompt -and
    -not [Console]::IsInputRedirected -and
    -not [Console]::IsOutputRedirected
if (-not $canPrompt) {
    if (-not $resolvedManagedConfigHome) {
        throw "No valid Yazi config was found. Rerun configure-paths.ps1 interactively or pass -YaziConfigFile."
    }
    Set-PDYaziConfigHome -Path $resolvedManagedConfigHome
    return
}

$yaziExecutable = Join-Path $PlaygroundRoot 'install\yazi\bin\yazi.exe'
if (-not (Test-Path -LiteralPath $yaziExecutable -PathType Leaf)) {
    throw "Yazi is not installed under $PlaygroundRoot. Install Yazi first or pass -YaziConfigFile."
}
if (-not $resolvedManagedConfigHome) {
    throw "The managed fallback config is missing: $managedConfigHome\yazi.toml"
}

$temporaryDirectory = Join-Path $PlaygroundRoot 'tmp'
[IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
$selectionFile = Join-Path $temporaryDirectory ('yazi-config-' + [Guid]::NewGuid().ToString('N') + '.txt')
$savedEnvironment = @{
    YAZI_CONFIG_HOME = [Environment]::GetEnvironmentVariable('YAZI_CONFIG_HOME', 'Process')
    YAZI_CACHE_HOME = [Environment]::GetEnvironmentVariable('YAZI_CACHE_HOME', 'Process')
    YAZI_STATE_HOME = [Environment]::GetEnvironmentVariable('YAZI_STATE_HOME', 'Process')
}
try {
    $env:YAZI_CONFIG_HOME = $resolvedManagedConfigHome
    $env:YAZI_CACHE_HOME = Join-Path $PlaygroundRoot 'cache\yazi'
    $env:YAZI_STATE_HOME = Join-Path $PlaygroundRoot 'state\yazi'
    Write-Host 'Select the yazi.toml file for this installation; press q to keep the managed config.'
    & $yaziExecutable '--chooser-file' $selectionFile $PlaygroundRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Yazi config selection failed with exit code $LASTEXITCODE."
    }
    if (Test-Path -LiteralPath $selectionFile -PathType Leaf) {
        $selectedPath = [IO.File]::ReadAllLines($selectionFile) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -First 1
        if ($selectedPath) {
            $selectedPath = ConvertTo-PDWindowsPath $selectedPath.Trim()
            if ([IO.Path]::GetFileName($selectedPath) -ine 'yazi.toml' -or
                -not (Test-Path -LiteralPath $selectedPath -PathType Leaf)) {
                throw "Yazi selected a file other than an existing yazi.toml: $selectedPath"
            }
            Set-PDYaziConfigHome -Path (Split-Path -Parent ([IO.Path]::GetFullPath($selectedPath)))
            return
        }
    }
    Set-PDYaziConfigHome -Path $resolvedManagedConfigHome
    Write-Host '[terminal-setup] No config was selected; using the managed Yazi config.'
} finally {
    if (Test-Path -LiteralPath $selectionFile -PathType Leaf) {
        Remove-Item -LiteralPath $selectionFile -Force
    }
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
}
