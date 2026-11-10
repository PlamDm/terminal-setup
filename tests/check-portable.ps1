# Real portable downloads and native command launchers on a Windows CI runner.
# Does not register PATH, edit profiles, or launch a GUI.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PlaygroundRoot = Join-Path $PSScriptRoot '..\.ci-portable'
$PlaygroundRoot = [IO.Path]::GetFullPath($PlaygroundRoot)
$installRoot = Join-Path $PlaygroundRoot 'install'
$binDirectory = Join-Path $PlaygroundRoot 'bin'
$configDirectory = Join-Path $PlaygroundRoot 'config'
$cacheDirectory = Join-Path $PlaygroundRoot 'cache'
$msysRoot = Join-Path $installRoot 'msys2'
$headers = @{ 'User-Agent' = 'terminal-setup-test'; 'Accept' = 'application/vnd.github+json' }
if ($env:GITHUB_TOKEN) { $headers.Authorization = 'Bearer ' + $env:GITHUB_TOKEN }
$previousUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$savedEnvironment = @{}
$names = @('PD_PWSH_EXE', 'PD_COPILOT_EXE', 'PD_CODE_EXE', 'PD_NOTEPAD_EXE')
foreach ($name in $names) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $parseErrors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot '..\install.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    foreach ($name in @('Invoke-Checked', 'Get-GitHubRelease', 'Save-Asset', 'Install-ZipTool', 'Write-WindowsLaunchers', 'Configure-Btop')) {
        $function = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        Invoke-Expression $function.Extent.Text
    }
    foreach ($directory in @($installRoot, $binDirectory, $configDirectory, $cacheDirectory,
        (Join-Path $PlaygroundRoot 'tmp'), (Join-Path $PlaygroundRoot 'state'))) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    . (Join-Path $PSScriptRoot '..\lib\portable.ps1')
    Install-PortableWindowsTools
    $btop = Install-ZipTool -Repo 'aristocratos/btop4win' -Pattern '^btop4win-x64\.zip$' -Name 'btop' -Executable 'btop4win.exe'
    Configure-Btop -Executable $btop
    $manifest = @(
        "copilot`t$env:PD_COPILOT_EXE", "code`t$env:PD_CODE_EXE",
        "notepad++`t$env:PD_NOTEPAD_EXE", "pwsh`t$env:PD_PWSH_EXE", "btop`t$btop"
    )
    [IO.File]::WriteAllLines((Join-Path $PlaygroundRoot 'state\windows-commands.tsv'), $manifest)
    Write-WindowsLaunchers
    foreach ($name in @('copilot', 'code', 'btop')) {
        Invoke-Checked -Program (Join-Path $binDirectory ($name + '.cmd')) -Arguments @('--version')
    }
    Invoke-Checked -Program (Join-Path $binDirectory 'pwsh.cmd') -Arguments @('-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()')
    $notepadLauncher = [IO.File]::ReadAllText((Join-Path $binDirectory 'notepad++.cmd'))
    if (-not $notepadLauncher.Contains('-multiInst -settingsDir="' + $configDirectory + '\notepad++"')) {
        throw 'Notepad++ launcher did not isolate its settings and instance.'
    }
    $portableData = Get-Item -LiteralPath (Join-Path (Split-Path -Parent $env:PD_CODE_EXE) 'data')
    if (-not ($portableData.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'VS Code data junction was not created.' }
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -cne $previousUserPath) { throw 'Portable installs changed persistent PATH.' }
    Write-Host 'Native portable tools and their launchers passed.'
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -cne $previousUserPath) {
        [Environment]::SetEnvironmentVariable('Path', $previousUserPath, 'User')
    }
}
