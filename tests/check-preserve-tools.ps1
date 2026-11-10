#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ('terminal-preserve-' + [Guid]::NewGuid().ToString('N'))
$PlaygroundRoot = $root
$installRoot = Join-Path $root 'install'
$configDirectory = Join-Path $root 'config'
$cacheDirectory = Join-Path $root 'cache'
$Interactive = $false
$OnlyCodex = $false
$selectedTools = @()
$names = @('PD_COPILOT_EXE', 'PD_PWSH_EXE', 'PD_NOTEPAD_EXE', 'PD_CODE_EXE', 'PATH')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
function Assert {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
function Get-InstalledSnapshot {
    return (@(Get-ChildItem -LiteralPath $installRoot -File -Recurse | Sort-Object FullName | ForEach-Object {
        $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash
    }) -join "`n")
}
try {
    foreach ($relative in @('copilot\v1\copilot.exe', 'copilot\v2\copilot.exe', 'powershell\v1\pwsh.exe',
        'notepad++\v1\notepad++.exe', 'notepad++\v1\doLocalConf.xml', 'vscode\v1\Code.exe',
        'fonts\.installed', 'codex\bin\codex.exe', 'wezterm\v1\wezterm.exe', 'btop\v1\btop.exe')) {
        $path = Join-Path $installRoot $relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
        [IO.File]::WriteAllText($path, 'existing ' + $relative)
    }
    [IO.Directory]::CreateDirectory((Join-Path $root 'state')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $configDirectory 'vscode')) | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $installRoot 'vscode\v1\data') `
        -Target (Join-Path $configDirectory 'vscode') | Out-Null
    $manifest = Join-Path $root 'state\windows-commands.tsv'
    $activeCopilot = Join-Path $installRoot 'copilot\v1\copilot.exe'
    [IO.File]::WriteAllText($manifest, "copilot`t$activeCopilot`n")
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repository 'install.ps1'), [ref]$null, [ref]$null)
    foreach ($name in @('Find-InstalledTool', 'Install-ZipTool', 'Install-Codex', 'Save-Asset', 'Test-PDSelected')) {
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        Set-Item -Path "Function:$name" -Value $definition.Body.GetScriptBlock()
    }
    [IO.Directory]::CreateDirectory($cacheDirectory) | Out-Null
    $script:assetFixtureBytes = [Text.Encoding]::UTF8.GetBytes('verified archive fixture')
    $fixtureSource = Join-Path $root 'fixture-source.zip'
    [IO.File]::WriteAllBytes($fixtureSource, $script:assetFixtureBytes)
    $fixtureDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixtureSource).Hash.ToLowerInvariant()
    $script:assetChecksumBytes = [Text.Encoding]::UTF8.GetBytes("$fixtureDigest  fixture.zip`n")
    function Invoke-WebRequest {
        param([string] $Uri, [string] $OutFile, [switch] $UseBasicParsing)
        if ($Uri -eq 'https://fixture/fixture.zip.sha256') {
            return [pscustomobject]@{ Content = $script:assetChecksumBytes }
        }
        if ($Uri -eq 'https://fixture/fixture.zip') {
            [IO.File]::WriteAllBytes($OutFile, $script:assetFixtureBytes)
            return
        }
        throw "Unexpected fixture request: $Uri"
    }
    $fixtureAsset = [pscustomobject]@{
        name = 'fixture.zip'
        digest = $null
        browser_download_url = 'https://fixture/fixture.zip'
    }
    $fixtureChecksum = [pscustomobject]@{
        name = 'fixture.zip.sha256'
        browser_download_url = 'https://fixture/fixture.zip.sha256'
    }
    $fixtureRelease = [pscustomobject]@{ assets = @($fixtureChecksum) }
    $verifiedArchive = Save-Asset -Asset $fixtureAsset -Release $fixtureRelease
    Assert ((Get-FileHash -Algorithm SHA256 -LiteralPath $verifiedArchive).Hash -eq $fixtureDigest) `
        'Binary checksum asset content was not decoded and verified.'

    $script:allowDownload = $false
    $script:releaseCalls = 0
    function Get-GitHubRelease {
        param([string] $Repo)
        if (-not $script:allowDownload) { throw "Existing tool attempted a download: $Repo" }
        $script:releaseCalls++
        return [pscustomobject]@{
            tag_name = 'v1'
            assets = @([pscustomobject]@{ name = 'new-tool.zip' })
        }
    }
    function Save-Asset {
        param([object] $Asset, [object] $Release)
        return (Join-Path $root 'new-tool.zip')
    }
    function Invoke-RestMethod { throw 'Existing VS Code attempted to fetch an update.' }
    function Invoke-WebRequest { throw 'Existing Codex attempted to run its installer.' }
    . (Join-Path $repository 'lib\portable.ps1')
    $before = Get-InstalledSnapshot
    Install-PortableWindowsTools
    Install-Codex
    foreach ($name in @('wezterm', 'btop')) {
        $path = Install-ZipTool -Repo 'fixture/forbidden' -Pattern '.*' -Name $name -Executable "$name.exe"
        Assert ($path -eq (Join-Path $installRoot "$name\v1\$name.exe")) "Existing $name was not reused."
    }
    Assert ($env:PD_COPILOT_EXE -eq $activeCopilot) 'Setup switched the active Copilot version.'
    Assert ((Get-InstalledSnapshot) -ceq $before) 'Setup changed an existing tool installation.'

    $previousPlaygroundRoot = $PlaygroundRoot
    $previousInstallRoot = $installRoot
    $previousConfigDirectory = $configDirectory
    $previousCacheDirectory = $cacheDirectory
    $previousProcessPath = $env:PATH
    $codexFixtureRoot = Join-Path $root 'codex-path-fixture'
    $PlaygroundRoot = $codexFixtureRoot
    $installRoot = Join-Path $codexFixtureRoot 'install'
    $configDirectory = Join-Path $codexFixtureRoot 'config'
    $cacheDirectory = Join-Path $codexFixtureRoot 'cache'
    $NoActivate = $true
    $fixtureTarDirectory = Join-Path $root 'fake-msys\usr\bin'
    [IO.Directory]::CreateDirectory($fixtureTarDirectory) | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixtureTarDirectory 'tar.exe'), 'MSYS tar fixture')
    $env:PATH = $fixtureTarDirectory + [IO.Path]::PathSeparator + $previousProcessPath
    function Invoke-WebRequest {
        param([string] $Uri, [string] $OutFile, [switch] $UseBasicParsing)
        [IO.Directory]::CreateDirectory((Split-Path -Parent $OutFile)) | Out-Null
        [IO.File]::WriteAllText($OutFile, 'Codex installer fixture')
    }
    function Invoke-Checked {
        param([string] $Program, [string[]] $Arguments)
        $script:codexInstallerTar = (Get-Command tar.exe -ErrorAction Stop).Source
        [IO.Directory]::CreateDirectory($env:CODEX_INSTALL_DIR) | Out-Null
        [IO.File]::WriteAllText((Join-Path $env:CODEX_INSTALL_DIR 'codex.exe'), 'Codex fixture')
    }
    try {
        Install-Codex
        $nativeTar = Join-Path $env:SystemRoot 'System32\tar.exe'
        Assert ($script:codexInstallerTar -ieq $nativeTar) "Codex installer selected non-native tar: $script:codexInstallerTar"
        Assert ($env:PATH -ceq $fixtureTarDirectory + [IO.Path]::PathSeparator + $previousProcessPath) `
            'Codex installer did not restore PATH after the install.'
    } finally {
        $PlaygroundRoot = $previousPlaygroundRoot
        $installRoot = $previousInstallRoot
        $configDirectory = $previousConfigDirectory
        $cacheDirectory = $previousCacheDirectory
        [Environment]::SetEnvironmentVariable('Path', $previousProcessPath, 'Process')
    }

    [IO.File]::WriteAllText($manifest, '')
    $message = ''
    try { Find-InstalledTool -Name 'copilot' -Executable 'copilot.exe' } catch { $message = $_.Exception.Message }
    Assert ($message.Contains('no unique active version')) 'Setup silently chose a different installed version.'

    $source = Join-Path $root 'new.exe'
    [IO.File]::WriteAllText($source, 'new tool fixture')
    Compress-Archive -LiteralPath $source -DestinationPath (Join-Path $root 'new-tool.zip')
    $script:allowDownload = $true
    $path = Install-ZipTool -Repo 'fixture/new' -Pattern '^new-tool\.zip$' -Name 'new-tool' -Executable 'new.exe'
    Assert ((Test-Path -LiteralPath $path) -and $script:releaseCalls -eq 1) 'Setup did not install a missing tool.'
    $script:allowDownload = $false
    $again = Install-ZipTool -Repo 'fixture/forbidden' -Pattern '.*' -Name 'new-tool' -Executable 'new.exe'
    Assert ($again -eq $path) 'Rerunning setup replaced the newly installed tool.'
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Write-Host 'Existing portable versions and active launchers were preserved; binary checksum files were verified.'
