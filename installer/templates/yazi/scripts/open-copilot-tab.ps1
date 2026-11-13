$ErrorActionPreference = 'Stop'

$arguments = @($args)
$workingDirectoryMarker = '__YAZI_CWD__'
$workingDirectoryMarkerIndex = [Array]::IndexOf($arguments, $workingDirectoryMarker)
if ($workingDirectoryMarkerIndex -lt 0 -or ($workingDirectoryMarkerIndex + 1) -ge $arguments.Count) {
    throw 'Yazi did not pass its current working directory to the Copilot launcher.'
}

$workingDirectory = [string]$arguments[$workingDirectoryMarkerIndex + 1]
$workingDirectoryItem = Get-Item -LiteralPath $workingDirectory
if (-not $workingDirectoryItem.PSIsContainer) {
    throw "Yazi working directory is not a directory: $workingDirectory"
}
if ([string]::IsNullOrWhiteSpace($env:WEZTERM_PANE)) {
    throw 'WezTerm pane context is missing; launch Yazi from WezTerm to open Copilot in the same window.'
}

$personalToolsRoot = $env:PD_PLAYGROUND_ROOT
if ([string]::IsNullOrWhiteSpace($personalToolsRoot)) {
    throw 'The managed personal-tools root is missing from this Yazi launcher.'
}
$personalToolsRoot = [IO.Path]::GetFullPath($personalToolsRoot)
$weztermExecutable = Join-Path $personalToolsRoot 'bin\wezterm.cmd'
$powershellExecutable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$copilotScript = Join-Path $PSScriptRoot 'run-copilot.ps1'
foreach ($path in @($weztermExecutable, $powershellExecutable, $copilotScript)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required executable or script was not found: $path"
    }
}

$spawnArguments = @(
    'cli'
    'spawn'
    '--pane-id'
    $env:WEZTERM_PANE
    '--cwd'
    $workingDirectoryItem.FullName
    '--'
    $powershellExecutable
    '-NoLogo'
    '-NoProfile'
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    $copilotScript
)
& $weztermExecutable @spawnArguments
if ($LASTEXITCODE -ne 0) {
    throw "WezTerm could not open the Copilot tab (exit code $LASTEXITCODE)."
}
