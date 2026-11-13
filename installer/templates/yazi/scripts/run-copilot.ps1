$ErrorActionPreference = 'Stop'

$personalToolsRoot = $env:PD_PLAYGROUND_ROOT
if ([string]::IsNullOrWhiteSpace($personalToolsRoot)) {
    throw 'The managed personal-tools root is missing from this Yazi launcher.'
}
$personalToolsRoot = [IO.Path]::GetFullPath($personalToolsRoot)
$copilotLauncher = Join-Path $personalToolsRoot 'bin\copilot.cmd'
if (-not (Test-Path -LiteralPath $copilotLauncher -PathType Leaf)) {
    throw "The managed Copilot launcher was not found: $copilotLauncher"
}

& $copilotLauncher @args
exit $LASTEXITCODE
