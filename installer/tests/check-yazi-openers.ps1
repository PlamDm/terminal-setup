#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $repository 'yazi\yazi.toml'))
$template = [IO.File]::ReadAllText((Join-Path $repository 'templates\yazi\yazi.toml'))
$environment = [IO.File]::ReadAllText((Join-Path $repository 'lib\environment.sh'))
$installer = [IO.File]::ReadAllText((Join-Path $repository 'install.ps1'))
$configHelper = [IO.File]::ReadAllText((Join-Path $repository 'set-yazi-config-home.cmd'))
foreach ($config in @($source, $template)) {
    foreach ($required in @(
        'notepadpp',
        'nvim',
        'explorer',
        'compare_selected',
        'hexview',
        'wireshark',
        'hxd',
        'renesas_flash_programmer',
        'jflash',
        'arxml_visualizer',
        'fzf_search',
        'rsgit',
        'copilot',
        'brave_pdf',
        'psexe',
        'wezterm.cmd cli spawn --cwd "%d1" -- cmd.exe /d /c pwsh.cmd -NoLogo -NoExit -File "%s1"',
        'url = "*.{ps1,PS1}"',
        '{ url = "*.{ps1,PS1}", use = [ "psexe",',
        'mime = "folder/*"',
        'mime = "text/*"',
        'open_offset = [0, 1, 80, 24]',
        'ya emit plugin fzf'
    )) {
        if (-not $config.Contains($required)) { throw "Missing Yazi menu configuration: $required" }
    }
    if ($config.Contains('gitui')) { throw 'GitUI should not be listed in the Yazi menu.' }
    if ($config.Contains('C:\MTC\d_t')) {
        throw 'The portable Yazi template contains a hard-coded d_t path.'
    }
}
if ($source -cne $template) { throw 'The Yazi source and template configurations differ.' }
foreach ($required in @(
    'templates\yazi\scripts\open-copilot-tab.ps1',
    'templates\yazi\scripts\run-copilot.ps1',
    'templates\yazi\plugins\compare-menu.yazi\main.lua'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $repository $required) -PathType Leaf)) {
        throw "The Yazi menu dependency is missing: $required"
    }
}
foreach ($required in @(
    'yazi() {',
    '--cwd-file',
    'command yazi.cmd "$@"',
    'yazi-config-home.txt'
)) {
    if (-not $environment.Contains($required)) {
        throw "The generated shell environment is missing Yazi integration: $required"
    }
}
$emptyCwdGuard = $environment.IndexOf('if [ -n "$pd_yazi_native_cwd" ]; then')
$cwdPathConversion = $environment.IndexOf('cygpath -u "$pd_yazi_native_cwd"')
if ($emptyCwdGuard -lt 0 -or $emptyCwdGuard -gt $cwdPathConversion) {
    throw 'The generated shell environment may pass an empty Yazi cwd to cygpath.'
}
foreach ($required in @(
    'copilot-yazi.cmd',
    'Write-YaziIntegrationLaunchers',
    'set-yazi-config-home.cmd',
    'PD_YAZI_CWD_FILE'
)) {
    if (-not $installer.Contains($required)) {
        throw "The Windows installer is missing Yazi integration: $required"
    }
}
if (-not $configHelper.Contains('configure-paths.ps1')) {
    throw 'The Windows Yazi launcher does not invoke the config-path selector.'
}
Write-Host 'Yazi integration fixtures passed.'
