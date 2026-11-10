#requires -Version 5.1
# Test the delegated installer's persistent PATH side effect without downloads.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$installer = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$null, [ref]$null)
$definition = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-Codex'
}, $true)
Invoke-Expression $definition.Extent.Text
$root = Join-Path ([IO.Path]::GetTempPath()) ('terminal-codex-' + [Guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $root 'install'
$configDirectory = Join-Path $root 'config'
$cacheDirectory = Join-Path $root 'cache'
[IO.Directory]::CreateDirectory($cacheDirectory) | Out-Null
$NoActivate = $true
$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$script:simulateFailure = $false
function Invoke-WebRequest {
    param([switch] $UseBasicParsing, [string] $Uri, [string] $OutFile)
    [IO.File]::WriteAllText($OutFile, '# fixture installer')
}
function Invoke-Checked {
    param([string] $Program, [string[]] $Arguments)
    [Environment]::SetEnvironmentVariable('Path', 'delegated-installer-path', 'User')
    if ($script:simulateFailure) { throw 'Fixture install failure' }
    [IO.Directory]::CreateDirectory($env:CODEX_INSTALL_DIR) | Out-Null
    [IO.File]::WriteAllText((Join-Path $env:CODEX_INSTALL_DIR 'codex.exe'), 'fixture')
}
try {
    Install-Codex
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -cne $originalUserPath) {
        throw 'Successful delegated install changed user PATH in manual mode.'
    }
    $script:simulateFailure = $true
    Remove-Item -LiteralPath (Join-Path $installRoot 'codex\bin\codex.exe')
    $failed = $false
    try { Install-Codex } catch {
        if ($_.Exception.Message -ne 'Fixture install failure') { throw }
        $failed = $true
    }
    if (-not $failed) { throw 'Expected fixture failure did not occur.' }
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -cne $originalUserPath) {
        throw 'Failed delegated install changed user PATH in manual mode.'
    }
} finally {
    [Environment]::SetEnvironmentVariable('Path', $originalUserPath, 'User')
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-Host 'Delegated Codex installer PATH isolation passed.'
