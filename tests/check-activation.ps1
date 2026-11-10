#requires -Version 5.1
param([string] $ActivationFile, [string] $ExpectedDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$separator = [IO.Path]::PathSeparator
$originalProcessPath = $env:PATH
$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
try {
    $existing = 'existing-one' + $separator + 'existing-two'
    $env:PATH = $ExpectedDirectory + $separator + $existing + $separator + $ExpectedDirectory
    . $ActivationFile
    . $ActivationFile
    if ($env:PATH -cne ($existing + $separator + $ExpectedDirectory)) {
        throw 'Extra activation did not preserve existing priority or remove duplicate entries.'
    }
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -cne $originalUserPath) {
        throw 'Extra activation changed the persistent user PATH.'
    }
} finally {
    $env:PATH = $originalProcessPath
}
Write-Host 'PowerShell manual activation passed.'
