#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$installer = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$null, [ref]$null)
$definition = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-Codex'
}, $true)
Set-Item Function:Install-Codex $definition.Body.GetScriptBlock()
$root = Join-Path ([IO.Path]::GetTempPath()) ('terminal-codex-' + [Guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $root 'install'
$configDirectory = Join-Path $root 'config'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$processPath = $env:PATH
$script:downloads = 0
function Install-PDArchive {
    param([string] $Id, [string] $Name, [string] $Executable)
    if ($Id -ne 'codex' -or $Executable -ne 'codex-x86_64-pc-windows-msvc.exe') { throw 'Incorrect standalone Codex distribution.' }
    $script:downloads++
    $file = Join-Path $root $Executable
    [IO.File]::WriteAllText($file, 'verified archive fixture')
    return $file
}
function Invoke-WebRequest { throw 'Codex must not execute an upstream installation script.' }
try {
    [IO.Directory]::CreateDirectory($root) | Out-Null
    Install-Codex
    Install-Codex
    if ($script:downloads -ne 1) { throw 'Repeat Codex installation downloaded or replaced the tool.' }
    if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'codex\bin\codex.exe'))) { throw 'Codex was not installed under the selected root.' }
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -cne $userPath -or $env:PATH -cne $processPath) {
        throw 'Standalone Codex installation changed PATH.'
    }
    Write-Host 'Standalone Codex installation and repeat installation leave PATH unchanged.'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
