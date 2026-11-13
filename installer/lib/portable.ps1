# Native portable applications: no global installers or machine PATH changes.
function Install-PortableWindowsTools {
    if (Test-PDSelected 'copilot') {
        $env:PD_COPILOT_EXE = Install-ZipTool -Repo 'github/copilot-cli' -Pattern '^copilot-win32-x64\.zip$' -Name 'copilot' -Executable 'copilot.exe'
    }
    if (Test-PDSelected 'pwsh') {
        $env:PD_PWSH_EXE = Install-ZipTool -Repo 'PowerShell/PowerShell' -Pattern '^PowerShell-.*-win-x64\.zip$' -Name 'powershell' -Executable 'pwsh.exe'
    }
    if (Test-PDSelected 'notepadpp') {
        $env:PD_NOTEPAD_EXE = Install-ZipTool -Repo 'notepad-plus-plus/notepad-plus-plus' -Pattern '^npp\..*\.portable\.x64\.zip$' -Name 'notepad++' -Executable 'notepad++.exe'
        $notepadDirectory = Split-Path -Parent $env:PD_NOTEPAD_EXE
        $localConfig = Join-Path $notepadDirectory 'doLocalConf.xml'
        if (-not (Test-Path -LiteralPath $localConfig)) { [IO.File]::WriteAllText($localConfig, '') }
    }

    if (Test-PDSelected 'vscode') {
        $executable = Find-InstalledTool -Name 'vscode' -Executable 'Code.exe'
        if ($executable) {
            Write-Host "[playground] Keeping installed VS Code at $executable."
            $destination = Split-Path -Parent $executable
        } else {
            $executable = Install-PDArchive -Id vscode -Name vscode -Executable Code.exe
            $destination = Split-Path -Parent $executable
        }
        $data = Join-Path $configDirectory 'vscode'
        foreach ($directory in @($data, (Join-Path $data 'tmp'), (Join-Path $data 'user-data'), (Join-Path $data 'extensions'))) {
            [IO.Directory]::CreateDirectory($directory) | Out-Null
        }
        $env:PD_CODE_EXE = $executable
    }

    if (Test-PDSelected 'wezterm') {
        $fontDirectory = Join-Path $installRoot 'fonts'
        if (-not (Test-Path -LiteralPath (Join-Path $fontDirectory '.installed'))) {
            $release = Get-GitHubRelease -Repo 'ryanoasis/nerd-fonts'
            $asset = $release.assets | Where-Object { $_.name -eq 'JetBrainsMono.zip' } | Select-Object -First 1
            if (-not $asset) { throw 'JetBrainsMono Nerd Font archive was not found.' }
            $archive = Save-Asset -Asset $asset -Release $release
            [IO.Directory]::CreateDirectory($fontDirectory) | Out-Null
            Expand-Archive -LiteralPath $archive -DestinationPath $fontDirectory -Force
            [IO.File]::WriteAllText((Join-Path $fontDirectory '.installed'), '')
        }
    }
}
