$script:PDInteractiveCatalog = Join-Path $PSScriptRoot 'interactive-tools.tsv'

function Get-PDInteractiveCatalog {
    param([string] $Platform)
    foreach ($line in [IO.File]::ReadAllLines($script:PDInteractiveCatalog)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        $parts = $line.Split([char]9)
        if ($parts.Count -ge 3 -and $parts[2].Split(',') -contains $Platform) {
            [pscustomobject]@{ Id = $parts[0]; Label = $parts[1] }
        }
    }
}

function Read-PDConsoleLine {
    param([string] $Prompt)
    [Console]::Write($Prompt)
    $line = [Console]::ReadLine()
    if ($null -eq $line) { throw 'Interactive console input ended before a response was received.' }
    return $line
}

function Get-PDToolCommandName {
    param([string] $Id)
    switch ($Id) {
        bash { return 'bash.exe' }
        git { return 'git.exe' }
        tmux { return 'tmux.exe' }
        fzf { return 'fzf.exe' }
        yazi { return 'yazi.exe' }
        rustifiedgit { return 'rustifiedgit.exe' }
        wezterm { return 'wezterm.exe' }
        btop { return 'btop4win.exe' }
        codex { return 'codex.exe' }
        copilot { return 'copilot.exe' }
        vscode { return 'Code.exe' }
        notepadpp { return 'notepad++.exe' }
        pwsh { return 'pwsh.exe' }
        default { return $null }
    }
}

function Test-PDPathInside {
    param([string] $Path, [string] $Root)
    if (-not $Path -or -not $Root) { return $false }
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') + '\'
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + '\'
    return $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)
}

function Get-PDToolStatus {
    param([string] $Id, [string] $PlaygroundRoot, [string] $MsysRoot)
    $installRoot = Join-Path $PlaygroundRoot 'install'
    $binDirectory = Join-Path $PlaygroundRoot 'bin'
    $exe = Get-PDToolCommandName -Id $Id
    $managed = $false
    $available = $false
    $launcherNames = @{
        bash = 'bash.cmd'; git = 'git.cmd'; tmux = 'tmux.cmd'; fzf = 'fzf.cmd'
        yazi = 'yazi.cmd'; rustifiedgit = 'rustifiedgit.cmd'; wezterm = 'wezterm.cmd'
        btop = 'btop.cmd'; codex = 'codex.cmd'; copilot = 'copilot.cmd'
        vscode = 'code.cmd'; notepadpp = 'notepad++.cmd'; pwsh = 'pwsh.cmd'
    }
    if (Test-Path -LiteralPath (Join-Path $binDirectory $launcherNames[$Id]) -PathType Leaf) {
        $managed = $true
    }
    $installDirectory = switch ($Id) {
        bash { Join-Path $installRoot 'msys2' }
        git { Join-Path $installRoot 'msys2' }
        tmux { Join-Path $installRoot 'msys2' }
        fzf { Join-Path $installRoot 'msys2' }
        yazi { Join-Path $installRoot 'yazi\bin' }
        rustifiedgit { Join-Path $installRoot 'rustifiedgit\bin' }
        wezterm { Join-Path $installRoot 'wezterm' }
        btop { Join-Path $installRoot 'btop' }
        codex { Join-Path $installRoot 'codex\bin' }
        copilot { Join-Path $installRoot 'copilot' }
        vscode { Join-Path $installRoot 'vscode' }
        notepadpp { Join-Path $installRoot 'notepad++' }
        pwsh { Join-Path $installRoot 'powershell' }
        default { $null }
    }
    if (-not $managed -and $installDirectory -and (Test-Path -LiteralPath $installDirectory -PathType Container)) {
        $found = @(Get-ChildItem -LiteralPath $installDirectory -Recurse -File -Filter $exe -ErrorAction Stop)
        if ($found.Count -gt 0) { $managed = $true }
    }
    $msysRelative = switch ($Id) {
        bash { 'usr\bin\bash.exe' }
        git { 'usr\bin\git.exe' }
        tmux { 'usr\bin\tmux.exe' }
        fzf { 'ucrt64\bin\fzf.exe' }
        default { $null }
    }
    if ($msysRelative -and $MsysRoot -and (Test-Path -LiteralPath (Join-Path $MsysRoot $msysRelative) -PathType Leaf)) {
        if (Test-PDPathInside -Path $MsysRoot -Root $PlaygroundRoot) { $managed = $true }
        else { $available = $true }
    }
    $commandName = switch ($Id) {
        bash { 'bash' }
        git { 'git' }
        tmux { 'tmux' }
        fzf { 'fzf' }
        yazi { 'yazi' }
        rustifiedgit { 'rustifiedgit' }
        wezterm { 'wezterm' }
        btop { 'btop' }
        codex { 'codex' }
        copilot { 'copilot' }
        vscode { 'code' }
        notepadpp { 'notepad++' }
        pwsh { 'pwsh' }
    }
    foreach ($command in @(Get-Command $commandName -All -ErrorAction SilentlyContinue)) {
        if ($command.CommandType -ne 'Application') { continue }
        $commandPath = $command.Path
        if (-not $commandPath) { $commandPath = $command.Source }
        if ($commandPath -and -not (Test-PDPathInside -Path $commandPath -Root $PlaygroundRoot)) {
            $available = $true
            break
        }
    }
    return [pscustomobject]@{ Managed = $managed; Available = $available }
}

function Test-PDInstallPath {
    param([string] $Path)
    return [bool]($Path -match '^[A-Za-z]:[\\/][A-Za-z0-9._\\/-]+$')
}

function Test-PDReadOnlyBuildAvailable {
    param([string] $Id, [string] $MsysRoot)
    if ($Id -notin @('yazi', 'rustifiedgit')) { return $false }
    foreach ($relative in @('ucrt64\bin\cargo.exe', 'ucrt64\bin\rustc.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $MsysRoot $relative) -PathType Leaf)) { return $false }
    }
    if (Test-Path -LiteralPath (Join-Path $MsysRoot 'usr\bin\git.exe') -PathType Leaf) { return $true }
    return [bool](Get-Command git.exe -ErrorAction SilentlyContinue)
}

function Show-PDInstallDirectoryPicker {
    param([string] $InitialPath, [switch] $SearchForMsys2, [string] $SelectionLabel = 'install folder')
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw 'Interactive directory selection requires a terminal.'
    }
    $suggested = [IO.Path]::GetFullPath($InitialPath)
    if (Test-Path -LiteralPath $suggested -PathType Container) {
        $current = $suggested
        if ($current -notmatch '^[A-Za-z]:\\$') { $current = $current.TrimEnd('\', '/') }
        $suggested = $null
    } else {
        $current = Split-Path -Parent $suggested
        while ($current -and -not (Test-Path -LiteralPath $current -PathType Container)) {
            $current = Split-Path -Parent $current
        }
        if (-not $current) { $current = [Environment]::GetFolderPath('UserProfile') }
    }
    $index = 0
    $cursorVisible = [Console]::CursorVisible
    try {
        [Console]::CursorVisible = $false
        while ($true) {
            $rows = New-Object 'System.Collections.Generic.List[object]'
            if (-not $SearchForMsys2 -and $suggested -and (Test-PDInstallPath -Path $suggested) -and
                (Split-Path -Parent $suggested).TrimEnd('\', '/') -ieq $current.TrimEnd('\', '/')) {
                $rows.Add([pscustomobject]@{
                    Kind = 'Suggested'; Path = $suggested
                    Label = "Use suggested destination (created on install): $suggested"
                })
            }
            if ($SearchForMsys2 -or (Test-PDInstallPath -Path $current)) {
                $currentLabel = if ($SearchForMsys2) { "Search this folder: $current" } else { "Use this directory: $current" }
                $rows.Add([pscustomobject]@{ Kind = 'Current'; Path = $current; Label = $currentLabel })
            }
            if (-not $SearchForMsys2) {
                $rows.Add([pscustomobject]@{ Kind = 'Create'; Path = $current; Label = '[Create a new subdirectory]' })
            }
            $driveRoot = [IO.Path]::GetPathRoot($current)
            $atDriveRoot = $driveRoot -and $driveRoot.TrimEnd('\', '/') -ieq $current.TrimEnd('\', '/')
            $parent = if ($atDriveRoot) { $null } else { Split-Path -Parent ($current.TrimEnd('\', '/')) }
            if ($parent -and $parent -ine $current) {
                $rows.Add([pscustomobject]@{ Kind = 'Parent'; Path = $parent; Label = '[..]' })
            }
            if ($atDriveRoot) {
                foreach ($root in @([IO.Directory]::GetLogicalDrives() | Sort-Object)) {
                    if ($root -match '^[A-Za-z]:\\$' -and $root -ine $driveRoot) {
                        $rows.Add([pscustomobject]@{ Kind = 'Drive'; Path = $root; Label = $root })
                    }
                }
            }
            $listingError = $null
            try {
                foreach ($directory in @(Get-ChildItem -LiteralPath $current -Directory -Force -ErrorAction Stop | Sort-Object Name)) {
                    $rows.Add([pscustomobject]@{ Kind = 'Directory'; Path = $directory.FullName; Label = $directory.Name + '\' })
                }
            } catch {
                $listingError = $_.Exception.Message
            }
            if ($index -ge $rows.Count) { $index = 0 }
            [Console]::Clear()
            if ($SearchForMsys2) {
                [Console]::WriteLine('Choose a folder to search for MSYS2 (Enter searches this folder and descendants; Esc cancels)')
            } else {
                [Console]::WriteLine("Select $SelectionLabel (Enter selects; arrows navigate; Backspace goes up; Esc cancels)")
            }
            [Console]::WriteLine("Current: $current")
            if ($SearchForMsys2) {
                [Console]::WriteLine('Searching a drive root may take a long time.')
            } elseif ($SelectionLabel -eq 'install folder') {
                [Console]::WriteLine('Choose a dedicated path without spaces. The suggested destination is not created until install.')
            } else {
                [Console]::WriteLine("Choose the existing $SelectionLabel directory.")
            }
            if ($listingError) { [Console]::WriteLine("Cannot list this folder: $listingError") }
            [Console]::WriteLine()
            $start = [Math]::Max(0, $index - 7)
            $end = [Math]::Min($rows.Count, $start + 15)
            for ($rowIndex = $start; $rowIndex -lt $end; $rowIndex++) {
                $prefix = if ($rowIndex -eq $index) { '>' } else { ' ' }
                [Console]::WriteLine("$prefix $($rows[$rowIndex].Label)")
            }
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                UpArrow { $index--; if ($index -lt 0) { $index = $rows.Count - 1 } }
                DownArrow { $index++; if ($index -ge $rows.Count) { $index = 0 } }
                Backspace { if ($parent) { $current = $parent; $index = 0 } }
                Escape { return $null }
                Enter {
                    $row = $rows[$index]
                    switch ($row.Kind) {
                        Current { return $row.Path }
                        Suggested { return $row.Path }
                        Parent { $current = $row.Path; $index = 0 }
                        Directory { $current = $row.Path; $index = 0 }
                        Drive { $current = $row.Path; $index = 0 }
                        Create {
                            [Console]::CursorVisible = $true
                            $name = Read-PDConsoleLine 'New directory name (letters, digits, dot, underscore or hyphen): '
                            if ($name -match '^[A-Za-z0-9._-]+$' -and $name -ne '.' -and $name -ne '..') {
                                $newPath = Join-Path $current $name
                                if (Test-PDInstallPath -Path $newPath) {
                                    [IO.Directory]::CreateDirectory($newPath) | Out-Null
                                    $current = [IO.Path]::GetFullPath($newPath)
                                    $index = 0
                                } else {
                                    Write-Host 'Choose a destination without spaces or special characters.'
                                    Start-Sleep -Seconds 1
                                }
                            } else {
                                Write-Host 'Invalid directory name.'
                                Start-Sleep -Seconds 1
                            }
                            [Console]::CursorVisible = $false
                        }
                    }
                }
            }
        }
    } finally {
        [Console]::CursorVisible = $cursorVisible
    }
}

function Show-PDMSYS2ChoiceMenu {
    param([string] $PrivateRoot, [switch] $AllowInstall)
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw 'Interactive MSYS2 selection requires a terminal.'
    }
    $choices = New-Object 'System.Collections.Generic.List[object]'
    if ($AllowInstall) {
        $choices.Add([pscustomobject]@{
            Id = 'private'
            Label = "Use/install a private MSYS2 under $PrivateRoot"
        })
    }
    $choices.Add([pscustomobject]@{
        Id = 'search'
        Label = 'Search for an existing MSYS2 installation'
    })
    $index = 0
    $cursorVisible = [Console]::CursorVisible
    try {
        [Console]::CursorVisible = $false
        while ($true) {
            [Console]::Clear()
            [Console]::WriteLine('Choose how to provide MSYS2 (arrows navigate; Enter selects; Esc cancels)')
            [Console]::WriteLine('Reused MSYS2 defaults to read-only; existing packages are never upgraded automatically.')
            [Console]::WriteLine()
            for ($choiceIndex = 0; $choiceIndex -lt $choices.Count; $choiceIndex++) {
                $prefix = if ($choiceIndex -eq $index) { '>' } else { ' ' }
                [Console]::WriteLine("$prefix $($choices[$choiceIndex].Label)")
            }
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                UpArrow { $index--; if ($index -lt 0) { $index = $choices.Count - 1 } }
                DownArrow { $index++; if ($index -ge $choices.Count) { $index = 0 } }
                Enter { return $choices[$index].Id }
                Escape { return $null }
            }
        }
    } finally {
        [Console]::CursorVisible = $cursorVisible
    }
}

function Show-PDToolSelectionMenu {
    param(
        [string] $PlaygroundRoot,
        [string] $MsysRoot,
        [bool] $Msys2ReadOnly,
        [switch] $OnlyCodex
    )
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw 'Interactive tool selection requires a terminal.'
    }
    $tools = @()
    foreach ($item in (Get-PDInteractiveCatalog -Platform 'windows')) {
        if ($OnlyCodex -and $item.Id -ne 'codex') { continue }
        $status = Get-PDToolStatus -Id $item.Id -PlaygroundRoot $PlaygroundRoot -MsysRoot $MsysRoot
        $checked = -not ($status.Managed -or $status.Available)
        if ($Msys2ReadOnly -and -not ($status.Managed -or $status.Available)) {
            if ($item.Id -in @('git', 'tmux', 'fzf')) { $checked = $false }
            if ($item.Id -in @('yazi', 'rustifiedgit') -and
                -not (Test-PDReadOnlyBuildAvailable -Id $item.Id -MsysRoot $MsysRoot)) { $checked = $false }
        }
        $required = $item.Id -eq 'bash'
        if ($required) { $checked = $true }
        $tools += [pscustomobject]@{
            Id = $item.Id; Label = $item.Label; Managed = $status.Managed
            Available = $status.Available; Checked = $checked; Required = $required
        }
    }
    $index = 0
    $cursorVisible = [Console]::CursorVisible
    try {
        [Console]::CursorVisible = $false
        while ($true) {
            [Console]::Clear()
            [Console]::WriteLine('Select tools to install (Space toggles; Enter continues; Esc cancels)')
            [Console]::WriteLine('Copilot CLI requires PowerShell 7; it is included automatically when Copilot is selected.')
            if ($Msys2ReadOnly) { [Console]::WriteLine('Read-only MSYS2 skips missing packages; Yazi and RustifiedGit need Git, Cargo and Rust.') }
            [Console]::WriteLine('Tool                         Managed here   Available elsewhere')
            [Console]::WriteLine()
            for ($toolIndex = 0; $toolIndex -lt $tools.Count; $toolIndex++) {
                $tool = $tools[$toolIndex]
                $check = if ($tool.Checked) { '[x]' } else { '[ ]' }
                $label = $tool.Label
                if ($tool.Required) { $label += ' (required MSYS2 runtime)' }
                $managed = if ($tool.Managed) { 'yes' } else { 'no' }
                $available = if ($tool.Available) { 'yes' } else { 'no' }
                $prefix = if ($toolIndex -eq $index) { '>' } else { ' ' }
                [Console]::WriteLine(('{0} {1,-35} {2,-14} {3}' -f $prefix, "$check $label", $managed, $available))
            }
            [Console]::WriteLine()
            [Console]::WriteLine("Install root: $PlaygroundRoot")
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                UpArrow { $index--; if ($index -lt 0) { $index = $tools.Count - 1 } }
                DownArrow { $index++; if ($index -ge $tools.Count) { $index = 0 } }
                Spacebar {
                    if (-not $tools[$index].Required) { $tools[$index].Checked = -not $tools[$index].Checked }
                }
                Enter { return @($tools | Where-Object { $_.Checked } | ForEach-Object { $_.Id }) }
                Escape { return $null }
            }
        }
    } finally {
        [Console]::CursorVisible = $cursorVisible
    }
}
