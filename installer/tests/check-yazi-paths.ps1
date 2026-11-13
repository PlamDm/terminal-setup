#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$configurator = Join-Path $repository 'configure-paths.ps1'
$configHelper = Join-Path $repository 'set-yazi-config-home.cmd'
$base = Join-Path $env:TEMP ('yazi-paths-' + [Guid]::NewGuid().ToString('N'))
$managedConfig = Join-Path $base 'config\yazi'
$externalConfig = Join-Path $base 'external\yazi-config'
$pathFile = Join-Path $base 'config\path\yazi-config-home.txt'
function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Invoke-Configurator {
    param([string[]] $Arguments)
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $configurator @Arguments
    if ($LASTEXITCODE) { throw "configure-paths.ps1 failed with exit code $LASTEXITCODE." }
}
function Invoke-ConfigHomeHelper {
    param([string] $HelperPath)
    $commandLine = 'call "' + $HelperPath + '" && echo !YAZI_CONFIG_HOME!'
    $output = & cmd.exe /d /v:on /c $commandLine
    if ($LASTEXITCODE) { throw "set-yazi-config-home.cmd failed with exit code $LASTEXITCODE." }
    return ([string]($output | Select-Object -Last 1)).Trim()
}
try {
    [IO.Directory]::CreateDirectory($managedConfig) | Out-Null
    [IO.Directory]::CreateDirectory($externalConfig) | Out-Null
    Copy-Item -LiteralPath $configHelper -Destination (Join-Path $base 'set-yazi-config-home.cmd')
    Copy-Item -LiteralPath $configurator -Destination (Join-Path $base 'configure-paths.ps1')
    [IO.File]::WriteAllText((Join-Path $managedConfig 'yazi.toml'), '# managed')
    [IO.File]::WriteAllText((Join-Path $externalConfig 'yazi.toml'), '# custom')

    $helperPath = Join-Path $base 'set-yazi-config-home.cmd'
    Assert ((Invoke-ConfigHomeHelper $helperPath) -ceq $managedConfig) `
        'The Yazi launcher did not default to the config seeded under the managed root.'

    Invoke-Configurator @(
        '-PlaygroundRoot', $base,
        '-YaziConfigFile', (Join-Path $externalConfig 'yazi.toml')
    )
    $selected = [IO.File]::ReadAllText($pathFile).Trim()
    Assert ($selected -ceq [IO.Path]::GetFullPath($externalConfig).TrimEnd('\', '/')) `
        'The explicitly selected Yazi config directory was not saved.'
    Assert ((Invoke-ConfigHomeHelper $helperPath) -ceq [IO.Path]::GetFullPath($externalConfig).TrimEnd('\', '/')) `
        'The Yazi launcher did not honor an explicit custom config selection.'

    [IO.File]::WriteAllText($pathFile, (Join-Path $base 'missing') + [Environment]::NewLine)
    Assert ((Invoke-ConfigHomeHelper $helperPath) -ceq $managedConfig) `
        'A stale config override did not fall back to the managed config.'
    Invoke-Configurator @('-PlaygroundRoot', $base, '-EnsureYaziConfig', '-NoPrompt')
    $fallback = [IO.File]::ReadAllText($pathFile).Trim()
    Assert ($fallback -ceq [IO.Path]::GetFullPath($managedConfig).TrimEnd('\', '/')) `
        'A stale Yazi config path did not fall back to the managed config noninteractively.'

    $layoutBase = Join-Path $base 'layout'
    $layoutInstaller = Join-Path $layoutBase 'installer'
    $layoutRoot = Join-Path $layoutBase 'personal-tools'
    $layoutManagedConfig = Join-Path $layoutRoot 'config\yazi'
    $layoutExternalConfig = Join-Path $layoutBase 'external\yazi-config'
    $layoutPathFile = Join-Path $layoutRoot 'config\path\yazi-config-home.txt'
    [IO.Directory]::CreateDirectory($layoutInstaller) | Out-Null
    [IO.Directory]::CreateDirectory($layoutManagedConfig) | Out-Null
    [IO.Directory]::CreateDirectory($layoutExternalConfig) | Out-Null
    [IO.File]::WriteAllText((Join-Path $layoutManagedConfig 'yazi.toml'), '# managed')
    [IO.File]::WriteAllText((Join-Path $layoutExternalConfig 'yazi.toml'), '# custom')
    $layoutInstallerConfigurator = Join-Path $layoutInstaller 'configure-paths.ps1'
    $layoutRuntimeConfigurator = Join-Path $layoutRoot 'configure-paths.ps1'
    Copy-Item -LiteralPath $configurator -Destination $layoutInstallerConfigurator
    Copy-Item -LiteralPath $configurator -Destination $layoutRuntimeConfigurator
    $originalConfigurator = $configurator
    try {
        $configurator = $layoutInstallerConfigurator
        Invoke-Configurator @('-YaziConfigFile', (Join-Path $layoutExternalConfig 'yazi.toml'))
        Assert (
            [IO.File]::ReadAllText($layoutPathFile).Trim() -ceq
            [IO.Path]::GetFullPath($layoutExternalConfig).TrimEnd('\', '/')
        ) 'The installer helper did not default to its sibling personal-tools folder.'

        $configurator = $layoutRuntimeConfigurator
        Invoke-Configurator @('-Force', '-NoPrompt')
        Assert (
            [IO.File]::ReadAllText($layoutPathFile).Trim() -ceq
            [IO.Path]::GetFullPath($layoutManagedConfig).TrimEnd('\', '/')
        ) 'The runtime helper did not default to its own personal-tools folder.'
    } finally {
        $configurator = $originalConfigurator
    }

    Write-Host 'Yazi config path selection passed.'
} finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}
