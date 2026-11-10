#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'lib\interactive.ps1')

function Assert {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$windowsTools = @(Get-PDInteractiveCatalog -Platform 'windows')
$unixTools = @(Get-PDInteractiveCatalog -Platform 'linux')
Assert (@($windowsTools | Where-Object { $_.Id -eq 'notepadpp' }).Count -eq 1) 'Notepad++ is missing from the Windows menu.'
Assert (@($windowsTools | Where-Object { $_.Id -eq 'pwsh' }).Count -eq 1) 'PowerShell 7 is missing from the Windows menu.'
Assert (@($unixTools | Where-Object { $_.Id -in @('notepadpp', 'pwsh') }).Count -eq 0) 'Windows-only tools leaked into the Unix menu.'
Assert (@($unixTools | Where-Object { $_.Id -eq 'yazi' }).Count -eq 1) 'Yazi is missing from the Unix menu.'
Assert (Test-PDInstallPath -Path 'D:\my-tools') 'A valid playground path was rejected.'
Assert (-not (Test-PDInstallPath -Path 'D:\my tools')) 'A path containing spaces was accepted.'
Assert (-not (Test-PDInstallPath -Path 'D:\')) 'A drive root was accepted as the playground.'

$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repository 'install.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Test-PDSelected', 'Resolve-PDSelectedTools')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    Set-Item -Path "Function:$name" -Value $definition.Body.GetScriptBlock()
}
$Interactive = $true
$OnlyCodex = $false
$selectedTools = @(Resolve-PDSelectedTools -SelectedTools @('copilot'))
Assert ($selectedTools -contains 'pwsh') 'The Copilot selection did not include its PowerShell launcher dependency.'
Assert (Test-PDSelected 'copilot') 'The selected Copilot feature was not enabled.'
Assert (Test-PDSelected 'pwsh') 'Copilot did not select its PowerShell 7 dependency.'
Assert (-not (Test-PDSelected 'vscode')) 'An unselected tool was enabled.'
$selectedTools = @('vscode')
Assert (Test-PDSelected 'vscode') 'The selected VS Code feature was not enabled.'
Assert (-not (Test-PDSelected 'pwsh')) 'PowerShell 7 was installed without selection or a dependent feature.'

$root = Join-Path ([IO.Path]::GetTempPath()) ('terminal-interactive-' + [Guid]::NewGuid().ToString('N'))
$externalMsys = Join-Path ([IO.Path]::GetTempPath()) ('terminal-external-msys-' + [Guid]::NewGuid().ToString('N'))
try {
    $managedMsys = Join-Path $root 'install\msys2'
    $copilot = Join-Path $root 'install\copilot\v1\copilot.exe'
    $git = Join-Path $managedMsys 'usr\bin\git.exe'
    $cargo = Join-Path $managedMsys 'ucrt64\bin\cargo.exe'
    $rustc = Join-Path $managedMsys 'ucrt64\bin\rustc.exe'
    $tmux = Join-Path $externalMsys 'usr\bin\tmux.exe'
    foreach ($path in @($copilot, $git, $cargo, $rustc, $tmux)) {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
        [IO.File]::WriteAllText($path, 'fixture')
    }
    $status = Get-PDToolStatus -Id 'copilot' -PlaygroundRoot $root -MsysRoot $externalMsys
    Assert $status.Managed 'A tool under the playground was not marked as managed.'
    $status = Get-PDToolStatus -Id 'git' -PlaygroundRoot $root -MsysRoot $managedMsys
    Assert $status.Managed 'A private MSYS2 package was not marked as managed.'
    $status = Get-PDToolStatus -Id 'tmux' -PlaygroundRoot $root -MsysRoot $externalMsys
    Assert $status.Available 'A package in reused MSYS2 was not marked as externally available.'
    Assert (-not $status.Managed) 'A package in reused MSYS2 was incorrectly marked as playground-managed.'
    Assert (Test-PDReadOnlyBuildAvailable -Id 'yazi' -MsysRoot $managedMsys) 'Installed read-only build prerequisites were not detected.'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    if (Test-Path -LiteralPath $externalMsys) { Remove-Item -LiteralPath $externalMsys -Recurse -Force }
}

Write-Host 'Interactive catalog, selection dependencies and installation status passed.'
