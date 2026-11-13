#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$installer = [IO.File]::ReadAllText((Join-Path $repository 'install.ps1'))
$base = Join-Path $env:TEMP ('devtools-console-' + [Guid]::NewGuid().ToString('N'))
$PlaygroundRoot = Join-Path $base 'personal-tools'
$DevToolsRoot = Join-Path $base 'd_t'
$userHome = Join-Path $DevToolsRoot $env:USERNAME
$wezterm = Join-Path $PlaygroundRoot 'install\wezterm\test\wezterm.exe'
$weztermGui = Join-Path $PlaygroundRoot 'install\wezterm\test\wezterm-gui.exe'
$launcher = Join-Path $PlaygroundRoot 'bin\wezterm-dt.cmd'
function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
try {
    if ($PlaygroundRoot -match '\s' -or $DevToolsRoot -match '\s') {
        throw 'The test temporary path must not contain spaces.'
    }
    & powershell.exe -NoProfile -NonInteractive -File (Join-Path $repository 'configure-devtools-console.ps1') `
        -PlaygroundRoot $PlaygroundRoot
    if ($LASTEXITCODE) { throw 'Noninteractive setup did not skip the d_t folder picker.' }
    Assert (-not (Test-Path -LiteralPath $launcher)) 'Noninteractive setup created a launcher without a selected d_t root.'
    foreach ($directory in @(
        (Split-Path -Parent $wezterm),
        (Join-Path $PlaygroundRoot 'state'),
        (Join-Path $PlaygroundRoot 'config\path'),
        (Join-Path $PlaygroundRoot 'config\bash'),
        (Join-Path $PlaygroundRoot 'config\wezterm'),
        (Join-Path $PlaygroundRoot 'bin'),
        (Join-Path $DevToolsRoot 'bin\MSYS2Portable\App\msys64\usr\bin'),
        (Join-Path $userHome '.cmn')
    )) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    [IO.File]::WriteAllText($wezterm, '')
    [IO.File]::WriteAllText($weztermGui, '')
    [IO.File]::WriteAllText((Join-Path $PlaygroundRoot 'config\wezterm\wezterm.lua'), 'return {}')
    [IO.File]::WriteAllText((Join-Path $PlaygroundRoot 'state\windows-commands.tsv'),
        "wezterm`tinstall\wezterm\test\wezterm.exe`n")
    [IO.File]::WriteAllText(
        (Join-Path $DevToolsRoot 'bin\MSYS2Portable\App\msys64\usr\bin\bash.exe'), ''
    )
    [IO.File]::WriteAllText((Join-Path $userHome '.bashrc'), '# d_t bashrc')
    [IO.File]::WriteAllText((Join-Path $userHome '.bash_profile'), 'test -f ~/.bashrc && . ~/.bashrc')
    [IO.File]::WriteAllText((Join-Path $userHome 'console.bat'), '@echo off')
    [IO.File]::WriteAllText((Join-Path $userHome '.cmn\cmn.bat'), '@echo off')
    [IO.File]::WriteAllText((Join-Path $PlaygroundRoot 'activate.sh'), '. "$PD_PLAYGROUND_ROOT/config/shell/env-extra.sh"')

    & (Join-Path $repository 'configure-devtools-console.ps1') `
        -PlaygroundRoot $PlaygroundRoot -DevToolsRoot $DevToolsRoot
    $testInstaller = Join-Path $base 'installer'
    $testLibrary = Join-Path $testInstaller 'lib'
    [IO.Directory]::CreateDirectory($testLibrary) | Out-Null
    Copy-Item -LiteralPath (Join-Path $repository 'configure-devtools-console.ps1') `
        -Destination (Join-Path $testInstaller 'configure-devtools-console.ps1')
    Copy-Item -LiteralPath (Join-Path $repository 'lib\interactive.ps1') `
        -Destination (Join-Path $testLibrary 'interactive.ps1')
    Copy-Item -LiteralPath (Join-Path $repository 'lib\interactive-tools.tsv') `
        -Destination (Join-Path $testLibrary 'interactive-tools.tsv')
    & (Join-Path $testInstaller 'configure-devtools-console.ps1') -DevToolsRoot $DevToolsRoot
    if ($LASTEXITCODE) { throw 'The console setup did not default to its sibling personal-tools folder.' }

    $bashConfig = Join-Path $PlaygroundRoot 'config\bash\devtools-console.bashrc'
    $weztermConfig = Join-Path $PlaygroundRoot 'config\wezterm\devtools-console.lua'
    Assert (Test-Path -LiteralPath $launcher -PathType Leaf) 'The d_t WezTerm launcher was not created.'
    Assert (([IO.File]::ReadAllText((Join-Path $PlaygroundRoot 'config\path\devtools-root.txt')).Trim()) -ceq $DevToolsRoot) `
        'The selected d_t root was not stored.'
    Assert (([IO.File]::ReadAllText((Join-Path $PlaygroundRoot 'config\path\devtools-home.txt')).Trim()) -ceq $userHome) `
        'The d_t home was not derived from the Windows username.'
    $bashContent = [IO.File]::ReadAllText($bashConfig)
    Assert ($bashContent.Contains('. /etc/profile')) 'The WezTerm shell did not load the MSYS2 system profile.'
    Assert ($bashContent.Contains('. "$_pd_login_profile"')) 'The WezTerm shell did not load d_t login startup.'
    $loginProfileIndex = $bashContent.IndexOf('. "$_pd_login_profile"')
    $activateIndex = $bashContent.IndexOf('. "$_pd_playground_root/activate.sh"')
    Assert ($activateIndex -gt $loginProfileIndex) 'Personal tools are activated before d_t startup.'
    Assert (-not $bashContent.Contains('yazi() {')) 'The d_t startup overrides the shared Yazi shell integration.'
    $environmentContent = [IO.File]::ReadAllText((Join-Path $repository 'lib\environment.sh'))
    Assert ($environmentContent.Contains('command yazi.cmd "$@"')) 'The shared Yazi integration does not use the fast Windows launcher.'
    Assert ($environmentContent.Contains('--cwd-file')) 'The shared Yazi integration does not restore the terminal directory.'
    $weztermContent = [IO.File]::ReadAllText($weztermConfig)
    Assert ($weztermContent.Contains("read_path('config/path/devtools-root.txt')")) 'The WezTerm profile does not read the selected d_t root.'
    Assert ($weztermContent.Contains("MSYSTEM = 'MSYS2'")) 'The WezTerm profile does not select the d_t MSYS2 environment.'
    Assert ($weztermContent.Contains('PD_TERMINAL_SETUP_ROOT = root')) 'The WezTerm profile does not preserve the playground root for activation.'
    Assert ($weztermContent.Contains("os.getenv('DEVTOOLS_BASH_EXE')")) 'The WezTerm profile does not use the configured Bash executable.'
    Assert ($weztermContent.Contains("dofile(root .. '/config/wezterm/wezterm.lua')")) 'The d_t profile does not load personal-tools WezTerm settings.'
    Assert ($weztermContent.Contains('devtools-console.bashrc')) 'The WezTerm profile does not use the generated startup file.'
    $defaultWeztermConfig = [IO.File]::ReadAllText((Join-Path $repository 'wezterm.lua'))
    $templateWeztermConfig = [IO.File]::ReadAllText((Join-Path $repository 'templates\wezterm\wezterm.lua'))
    Assert ($defaultWeztermConfig.Contains('config.enable_kitty_graphics = false')) 'The installer default does not disable Kitty graphics.'
    Assert ($defaultWeztermConfig.Contains("config.font = wezterm.font('Lucida Console')")) 'The installer default does not use the requested font.'
    Assert ($defaultWeztermConfig.Contains('config.font_size = 10.0')) 'The installer default does not use the requested font size.'
    Assert ($defaultWeztermConfig.Contains("key = 'LeftArrow'")) 'The installer default is missing the requested tab shortcuts.'
    Assert ($templateWeztermConfig -ceq $defaultWeztermConfig) 'The installed WezTerm template differs from its default configuration.'
    $launcherContent = [IO.File]::ReadAllText($launcher)
    Assert ($launcherContent.Contains('rem Managed by terminal-setup.')) 'The launcher is not marked as managed.'
    Assert ($launcherContent.Contains('%PD_ROOT%\install\wezterm\test\wezterm-gui.exe')) `
        'The launcher does not use the managed WezTerm GUI executable.'
    Assert ($launcherContent.Contains('start "" "%PD_ROOT%\install\wezterm\test\wezterm-gui.exe"')) `
        'The launcher does not detach WezTerm from its command window.'
    Assert ($launcherContent.Contains('DEVTOOLS_CONSOLE_DIRECTORY_TO_OPEN=%~1')) `
        'The launcher does not forward the optional open directory.'
    Assert ($launcherContent.Contains('set "DEVTOOLS_BASH_EXE=%PD_DEVTOOLS_ROOT%\bin\MSYS2Portable\App\msys64\usr\bin\bash.exe"')) `
        'The launcher does not select d_t Bash for the WezTerm profile.'
    Assert ($installer.Contains('if not "%~1"=="" goto terminal_setup_wezterm_foreground')) `
        'The managed WezTerm launcher does not preserve synchronous CLI calls.'
    Assert ($installer.Contains('start "" "')) `
        'The managed WezTerm launcher does not detach its GUI launch.'

    $initialLauncherContent = $launcherContent
    & (Join-Path $repository 'configure-devtools-console.ps1') `
        -PlaygroundRoot $PlaygroundRoot -DevToolsRoot $DevToolsRoot
    Assert (([IO.File]::ReadAllText($launcher)) -ceq $initialLauncherContent) `
        'Reconfiguring the same d_t root changed the launcher unexpectedly.'

    [IO.File]::WriteAllText($launcher, 'user file')
    try {
        & (Join-Path $repository 'configure-devtools-console.ps1') `
            -PlaygroundRoot $PlaygroundRoot -DevToolsRoot $DevToolsRoot
        throw 'Test failed: an unmarked user launcher was overwritten.'
    } catch {
        if ($_.Exception.Message -eq 'Test failed: an unmarked user launcher was overwritten.') { throw }
        if ($_.Exception.Message -notlike 'Refusing to overwrite an existing user launcher:*') { throw }
    }
    Write-Host 'd_t WezTerm launcher configuration passed.'
} finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}
