#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $PlaygroundRoot,
    [string] $DevToolsRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('PlaygroundRoot')) {
    $PlaygroundRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'personal-tools'
}
$PlaygroundRoot = [IO.Path]::GetFullPath($PlaygroundRoot).TrimEnd('\', '/')
. (Join-Path $PSScriptRoot 'lib\interactive.ps1')
if (-not (Test-PDInstallPath -Path $PlaygroundRoot)) {
    throw 'PlaygroundRoot must be a Windows path without spaces or special characters.'
}

if ([string]::IsNullOrWhiteSpace($DevToolsRoot)) {
    $previousRootFile = Join-Path $PlaygroundRoot 'config\path\devtools-root.txt'
    $initialPath = 'C:\MTC\d_t'
    if (Test-Path -LiteralPath $previousRootFile -PathType Leaf) {
        $previousRoot = [IO.File]::ReadAllText($previousRootFile).Trim()
        if ($previousRoot) { $initialPath = $previousRoot }
    }
    if (-not (Test-Path -LiteralPath $initialPath -PathType Container)) {
        $initialPath = Split-Path -Parent $PlaygroundRoot
    }
    $nonInteractiveHost = @([Environment]::GetCommandLineArgs() | Where-Object { $_ -ieq '-NonInteractive' }).Count -gt 0
    if ($nonInteractiveHost -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        Write-Warning "d_t console launcher setup needs a selected d_t folder. Rerun configure-devtools-console.ps1 -PlaygroundRoot `"$PlaygroundRoot`" -DevToolsRoot <d_t-root>."
        return
    }
    $DevToolsRoot = Show-PDInstallDirectoryPicker -InitialPath $initialPath -SelectionLabel 'd_t root'
    if (-not $DevToolsRoot) {
        Write-Host '[playground] d_t folder selection cancelled; no d_t console launcher was created.'
        return
    }
}

if (-not (Test-PDInstallPath -Path $DevToolsRoot)) {
    throw 'DevToolsRoot must be a Windows path without spaces or special characters.'
}
$DevToolsRoot = [IO.Path]::GetFullPath($DevToolsRoot).TrimEnd('\', '/')
$DevToolsHome = Join-Path $DevToolsRoot $env:USERNAME
$msys2Root = Join-Path $DevToolsRoot 'bin\MSYS2Portable\App\msys64'
$bashPath = Join-Path $msys2Root 'usr\bin\bash.exe'
$bashrcPath = Join-Path $DevToolsHome '.bashrc'
$consolePath = Join-Path $DevToolsHome 'console.bat'
$commonPath = Join-Path $DevToolsHome '.cmn\cmn.bat'
if (-not (Test-PDInstallPath -Path $DevToolsHome)) {
    throw 'The derived d_t home must be a Windows path without spaces or special characters.'
}

foreach ($requiredPath in @($bashPath, $bashrcPath, $consolePath, $commonPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Selected folder does not contain the expected d_t console files: $requiredPath"
    }
}

$manifestPath = Join-Path $PlaygroundRoot 'state\windows-commands.tsv'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "The WezTerm package is not installed under $PlaygroundRoot."
}
$weztermRecords = @([IO.File]::ReadAllLines($manifestPath) | Where-Object {
    if ([string]::IsNullOrWhiteSpace($_)) { return $false }
    $parts = $_.Split([char]9, 2)
    return $parts.Count -eq 2 -and $parts[0] -ceq 'wezterm'
})
if ($weztermRecords.Count -ne 1) {
    throw "Expected one managed WezTerm launcher in $manifestPath."
}
$weztermRecord = $weztermRecords[0].Split([char]9, 2)
$weztermPath = $weztermRecord[1].Replace('/', '\')
if (-not [IO.Path]::IsPathRooted($weztermPath)) {
    $weztermPath = Join-Path $PlaygroundRoot $weztermPath
}
$weztermPath = [IO.Path]::GetFullPath($weztermPath)
$playgroundPrefix = [IO.Path]::GetFullPath($PlaygroundRoot).TrimEnd('\') + '\'
if (-not $weztermPath.StartsWith($playgroundPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-Path -LiteralPath $weztermPath -PathType Leaf)) {
    throw "The managed WezTerm executable is missing or outside the playground: $weztermPath"
}
$weztermGuiPath = Join-Path (Split-Path -Parent $weztermPath) 'wezterm-gui.exe'
if (-not (Test-Path -LiteralPath $weztermGuiPath -PathType Leaf)) {
    throw "The managed WezTerm GUI executable is missing: $weztermGuiPath"
}
$weztermRelativePath = $weztermGuiPath.Substring($playgroundPrefix.Length)
if ($weztermRelativePath -match '[%"\r\n]') {
    throw "The managed WezTerm path cannot be represented safely in a CMD launcher: $weztermRelativePath"
}

$bashConfigPath = Join-Path $PlaygroundRoot 'config\bash\devtools-console.bashrc'
$bashConfig = @'
# Managed by terminal-setup. Load d_t's login environment, then this playground's tools.
if [ -r /etc/profile ]; then
  . /etc/profile || return 1
fi

_pd_login_profile=
for _pd_profile_name in .bash_profile .bash_login .profile; do
  if [ -r "$HOME/$_pd_profile_name" ]; then
    _pd_login_profile="$HOME/$_pd_profile_name"
    break
  fi
done
if [ -n "$_pd_login_profile" ]; then
  . "$_pd_login_profile" || return 1
elif [ -r "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc" || return 1
else
  printf '%s\n' 'terminal-setup: d_t home has no readable Bash startup file.' >&2
  return 1
fi

_pd_playground_root=${PD_TERMINAL_SETUP_ROOT:-}
if [ -z "$_pd_playground_root" ] || [ ! -r "$_pd_playground_root/activate.sh" ]; then
  printf '%s\n' 'terminal-setup: activate.sh is missing from the playground.' >&2
  return 1
fi
export PD_PLAYGROUND_ROOT="$_pd_playground_root"
. "$_pd_playground_root/activate.sh" || return 1
unset _pd_login_profile _pd_profile_name _pd_playground_root
'@

$weztermConfigPath = Join-Path $PlaygroundRoot 'config\wezterm\devtools-console.lua'
$weztermConfig = @'
local wezterm = require 'wezterm'
local config_file = assert(wezterm.config_file, 'Load the d_t console config with --config-file')
local root = config_file:gsub('\\', '/'):match('^(.*)/config/wezterm/[^/]+$')
assert(root and root ~= '', 'WezTerm config must be inside the playground/config/wezterm directory')

local function read_path(relative)
  local file, err = io.open(root .. '/' .. relative, 'r')
  assert(file, err)
  local value = file:read('*a'):match('^%s*(.-)%s*$')
  file:close()
  assert(value and value ~= '', 'Empty path setting: ' .. relative)
  return value:gsub('\\', '/')
end

local config = dofile(root .. '/config/wezterm/wezterm.lua')
local devtools_root = read_path('config/path/devtools-root.txt')
local devtools_home = read_path('config/path/devtools-home.txt')
local msys2_root = devtools_root .. '/bin/MSYS2Portable/App/msys64'
local bash = os.getenv('DEVTOOLS_BASH_EXE') or msys2_root .. '/usr/bin/bash.exe'
bash = bash:gsub('\\', '/')
local bash_rc = root .. '/config/bash/devtools-console.bashrc'

config.default_cwd = devtools_home
config.default_prog = {
  bash,
  '--rcfile', bash_rc, '-i',
}
config.set_environment_variables = config.set_environment_variables or {}
config.set_environment_variables.MSYSTEM = 'MSYS2'
config.set_environment_variables.CHERE_INVOKING = '1'
config.set_environment_variables.MSYS2_PATH_TYPE = 'inherit'
config.set_environment_variables.HOME = devtools_home
config.set_environment_variables.PD_DEVTOOLS_ROOT = devtools_root
config.set_environment_variables.PD_DEVTOOLS_HOME = devtools_home
config.set_environment_variables.DEVTOOLS_BASH_EXE = bash
config.set_environment_variables.PD_PLAYGROUND_ROOT = root
config.set_environment_variables.PD_TERMINAL_SETUP_ROOT = root
config.set_environment_variables.devtoolsbindir = devtools_root .. '/bin/'
config.set_environment_variables.devtoolscache = devtools_root .. '/.cache/'
config.set_environment_variables.cmd_launcherdir = devtools_root .. '/bin/cmd_launcher'
config.set_environment_variables.DEVTOOLS_CONSOLE_DIRECTORY_TO_OPEN =
  os.getenv('DEVTOOLS_CONSOLE_DIRECTORY_TO_OPEN') or ''
config.set_environment_variables.PATH =
  devtools_root .. '/bin/package_manager/7zip;' ..
  msys2_root .. '/usr/bin;' .. msys2_root .. '/mingw64/bin;' ..
  root .. '/bin;' .. root .. '/install/msys2/ucrt64/bin;' ..
  root .. '/install/msys2/usr/bin;' .. (os.getenv('PATH') or '')

return config
'@

function Write-PDManagedConfig {
    param([string] $Path, [string] $Content, [string] $Marker)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if (-not [IO.File]::ReadAllText($Path).Contains($Marker)) {
            throw "Refusing to overwrite an existing user file: $Path"
        }
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Content + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}
$launcherPath = Join-Path $PlaygroundRoot 'bin\wezterm-dt.cmd'
$managedFiles = @(
    @{ Path = $bashConfigPath; Marker = '# Managed by terminal-setup.'; Description = 'configuration' },
    @{ Path = $weztermConfigPath; Marker = "local wezterm = require 'wezterm'"; Description = 'configuration' },
    @{ Path = $launcherPath; Marker = 'rem Managed by terminal-setup.'; Description = 'launcher' }
)
foreach ($file in $managedFiles) {
    if (Test-Path -LiteralPath $file.Path) {
        if (-not (Test-Path -LiteralPath $file.Path -PathType Leaf)) {
            throw "Cannot create the managed $($file.Description); a directory already exists at $($file.Path)."
        }
        if (-not [IO.File]::ReadAllText($file.Path).Contains($file.Marker)) {
            throw "Refusing to overwrite an existing user $($file.Description): $($file.Path)"
        }
    }
}

$configPathDirectory = Join-Path $PlaygroundRoot 'config\path'
[IO.Directory]::CreateDirectory($configPathDirectory) | Out-Null
[IO.File]::WriteAllText((Join-Path $configPathDirectory 'devtools-root.txt'), $DevToolsRoot + [Environment]::NewLine)
[IO.File]::WriteAllText((Join-Path $configPathDirectory 'devtools-home.txt'), $DevToolsHome + [Environment]::NewLine)
Write-PDManagedConfig -Path $bashConfigPath -Content $bashConfig -Marker '# Managed by terminal-setup.'
Write-PDManagedConfig -Path $weztermConfigPath -Content $weztermConfig -Marker "local wezterm = require 'wezterm'"

$launcherLines = @(
    '@echo off',
    'rem Managed by terminal-setup.',
    'setlocal',
    'for %%I in ("%~dp0..") do set "PD_ROOT=%%~fI"',
    'for /f "usebackq delims=" %%I in ("%PD_ROOT%\config\path\devtools-root.txt") do set "PD_DEVTOOLS_ROOT=%%I"',
    'for /f "usebackq delims=" %%I in ("%PD_ROOT%\config\path\devtools-home.txt") do set "PD_DEVTOOLS_HOME=%%I"',
    'if not defined PD_DEVTOOLS_ROOT exit /b 1',
    'if not defined PD_DEVTOOLS_HOME exit /b 1',
    'set "HOME=%PD_DEVTOOLS_HOME%"',
    'set "DEVTOOLS_BASH_EXE=%PD_DEVTOOLS_ROOT%\bin\MSYS2Portable\App\msys64\usr\bin\bash.exe"',
    'set "devtoolsbindir=%PD_DEVTOOLS_ROOT%\bin\"',
    'set "devtoolscache=%PD_DEVTOOLS_ROOT%\.cache\"',
    'set "cmd_launcherdir=%PD_DEVTOOLS_ROOT%\bin\cmd_launcher"',
    'set "MSYSTEM=MSYS2"',
    'set "CHERE_INVOKING=1"',
    'set "MSYS2_PATH_TYPE=inherit"',
    'set "XDG_CONFIG_HOME=%PD_ROOT%\config"',
    'set "XDG_CACHE_HOME=%PD_ROOT%\cache"',
    'set "XDG_DATA_HOME=%PD_ROOT%\state\data"',
    'set "XDG_STATE_HOME=%PD_ROOT%\state"',
    'set "TEMP=%PD_ROOT%\tmp"',
    'set "TMP=%PD_ROOT%\tmp"',
    'set "PATH=%PD_DEVTOOLS_ROOT%\bin\package_manager\7zip;%PD_ROOT%\bin;%PD_ROOT%\install\msys2\ucrt64\bin;%PD_ROOT%\install\msys2\usr\bin;%PATH%"',
    'set "DEVTOOLS_CONSOLE_DIRECTORY_TO_OPEN=%~1"',
    ('start "" "%PD_ROOT%\' + $weztermRelativePath + '" --config-file "%PD_ROOT%\config\wezterm\devtools-console.lua"'),
    'exit /b %errorlevel%'
)
$launcherContent = ($launcherLines -join [Environment]::NewLine) + [Environment]::NewLine
[IO.Directory]::CreateDirectory((Split-Path -Parent $launcherPath)) | Out-Null
[IO.File]::WriteAllText($launcherPath, $launcherContent, [Text.UTF8Encoding]::new($false))
Write-Host "[playground] Created d_t console launcher: $launcherPath"
