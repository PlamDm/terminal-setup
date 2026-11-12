#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $WorkDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) '.ci-playground\lock-tmp'),
    [string] $Msys2Root
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repository = Split-Path -Parent $PSScriptRoot
$output = Join-Path $repository 'packages'
[IO.Directory]::CreateDirectory($WorkDirectory) | Out-Null
[IO.Directory]::CreateDirectory($output) | Out-Null
$lines = New-Object 'System.Collections.Generic.List[string]'
$lines.Add('# id	platform	version	sha256	url	archive	executable	repository')
function Convert-VendoredManifest {
    param([string] $Workspace, [string] $Package)
    $root = [IO.File]::ReadAllText((Join-Path $Workspace 'Cargo.toml'))
    $defaults = @{}
    foreach ($section in [regex]::Matches($root, '(?ms)^\[workspace\.(package|dependencies)\]\r?\n(.*?)(?=^\[|\z)')) {
        foreach ($entry in [regex]::Matches($section.Groups[2].Value, '(?m)^([\w-]+)\s*=\s*(.+)$')) {
            $defaults[$section.Groups[1].Value + ':' + $entry.Groups[1].Value] = $entry.Groups[2].Value.Trim()
        }
    }
    $sectionName = ''
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $Package 'Cargo.toml'))) {
        if ($line -match '^\[([^\]]+)\]$') { $sectionName = $Matches[1] }
        if ($sectionName -eq 'lints') { continue }
        if ($line -match '^([\w-]+)\.workspace\s*=\s*true$') {
            $key = $Matches[1]
            $group = if ($sectionName -eq 'package') { 'package' } else { 'dependencies' }
            if (-not $defaults.ContainsKey("${group}:$key")) { throw "Missing inherited $key" }
            $result.Add("$key = $($defaults["${group}:$key"])")
        } elseif ($line -match '^([\w-]+)\s*=\s*\{(.*workspace\s*=\s*true.*)\}$') {
            $key, $overrides = $Matches[1], $Matches[2]
            if (-not $defaults.ContainsKey("dependencies:$key")) { throw "Missing inherited dependency $key" }
            $value = $defaults["dependencies:$key"]
            $values = [ordered]@{}
            if ($value.StartsWith('"')) { $values.version = $value }
            else {
                foreach ($entry in [regex]::Matches($value, '([\w-]+)\s*=\s*(\[[^\]]*\]|"[^"]*"|[^,}]+)')) {
                    $values[$entry.Groups[1].Value] = $entry.Groups[2].Value.Trim()
                }
            }
            foreach ($entry in [regex]::Matches($overrides, '([\w-]+)\s*=\s*(\[[^\]]*\]|"[^"]*"|[^,}]+)')) {
                if ($entry.Groups[1].Value -ne 'workspace') { $values[$entry.Groups[1].Value] = $entry.Groups[2].Value.Trim() }
            }
            $result.Add("$key = { " + (@($values.Keys | ForEach-Object { "$_ = $($values[$_])" }) -join ', ') + ' }')
        } else { $result.Add($line) }
    }
    foreach ($lint in [regex]::Matches($root, '(?ms)^\[workspace\.lints\.([^\]]+)\]\r?\n(.*?)(?=^\[|\z)')) {
        $result.Add('[lints.' + $lint.Groups[1].Value + ']')
        $result.Add($lint.Groups[2].Value)
    }
    while ($result.Count -gt 0 -and [string]::IsNullOrWhiteSpace($result[$result.Count - 1])) {
        $result.RemoveAt($result.Count - 1)
    }
    return $result.ToArray()
}
function Add-Artifact {
    param([string] $Id, [string] $Platform, [string] $Repo, [string] $Tag,
        [string] $AssetName, [string] $Archive, [string] $Executable)
    $url = "https://github.com/$Repo/releases/download/$Tag/$AssetName"
    $file = Join-Path $WorkDirectory $AssetName
    if (-not (Test-Path -LiteralPath $file)) { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $file }
    $sha = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    $lines.Add((@($Id, $Platform, $Tag, $sha, $url, $Archive, $Executable, $Repo) -join "`t"))
}
Add-Artifact msys2 windows-x64 msys2/msys2-installer 2026-09-27 msys2-base-x86_64-20260927.sfx.exe sfx usr/bin/bash.exe
Add-Artifact pwsh windows-x64 PowerShell/PowerShell v7.6.10 PowerShell-7.6.10-win-x64.zip zip pwsh.exe
Add-Artifact btop windows-x64 aristocratos/btop4win v1.0.5 btop4win-x64.zip zip btop4win.exe
Add-Artifact notepadpp windows-x64 notepad-plus-plus/notepad-plus-plus v8.9.8.1 npp.8.9.8.1.portable.x64.zip zip notepad++.exe
Add-Artifact font all ryanoasis/nerd-fonts v3.5.1 JetBrainsMono.zip zip '*.ttf'
Add-Artifact wezterm windows-x64 wezterm/wezterm 20240203-110809-5046fc22 WezTerm-windows-20240203-110809-5046fc22.zip zip wezterm.exe
Add-Artifact wezterm macos-x64 wezterm/wezterm 20240203-110809-5046fc22 WezTerm-macos-20240203-110809-5046fc22.zip zip WezTerm.app/Contents/MacOS/wezterm
Add-Artifact wezterm macos-arm64 wezterm/wezterm 20240203-110809-5046fc22 WezTerm-macos-20240203-110809-5046fc22.zip zip WezTerm.app/Contents/MacOS/wezterm
Add-Artifact wezterm linux-x64 wezterm/wezterm 20240203-110809-5046fc22 WezTerm-20240203-110809-5046fc22-Ubuntu20.04.AppImage appimage usr/bin/wezterm
foreach ($platform in @('windows-x64', 'linux-x64', 'linux-arm64', 'macos-x64', 'macos-arm64')) {
    $parts = $platform.Split('-')
    $os = switch ($parts[0]) { windows { 'win32' }; macos { 'darwin' }; linux { 'linux' } }
    $arch = $parts[1]
    $archive = if ($os -eq 'win32') { 'zip' } else { 'tar.gz' }
    Add-Artifact copilot $platform github/copilot-cli v1.0.109 "copilot-$os-$arch.$archive" $archive $(if ($os -eq 'win32') { 'copilot.exe' } else { 'copilot' })
    $target = switch ($platform) {
        windows-x64 { 'x86_64-pc-windows-msvc.exe.zip' }
        linux-x64 { 'x86_64-unknown-linux-musl.tar.gz' }
        linux-arm64 { 'aarch64-unknown-linux-musl.tar.gz' }
        macos-x64 { 'x86_64-apple-darwin.tar.gz' }
        macos-arm64 { 'aarch64-apple-darwin.tar.gz' }
    }
    Add-Artifact codex $platform openai/codex rust-v0.167.1 "codex-$target" $archive $(if ($os -eq 'win32') { 'codex-x86_64-pc-windows-msvc.exe' } else { "codex-$($target -replace '\.tar\.gz$','')" })
    if ($platform -ne 'windows-x64') {
        $subdir = switch ($platform) { linux-x64 { 'linux-64' }; linux-arm64 { 'linux-aarch64' }; macos-x64 { 'osx-64' }; macos-arm64 { 'osx-arm64' } }
        Add-Artifact micromamba $platform mamba-org/micromamba-releases 2.10.0-0 "micromamba-$subdir.tar.bz2" tar.bz2 bin/micromamba
    }
    $codePlatform = if ($platform -eq 'macos-x64') { 'darwin' } elseif ($platform -eq 'windows-x64') { 'win32-x64-archive' } else { "$os-$arch" }
    $metadata = Invoke-RestMethod -Uri "https://update.code.visualstudio.com/api/update/$codePlatform/stable/latest"
    if ($metadata.productVersion -ne '1.146.0') { throw 'VS Code release changed; review and update the explicit version before regenerating locks.' }
    if ($metadata.version -notmatch '^[a-f0-9]{40}$' -or $metadata.sha256hash -notmatch '^[a-f0-9]{64}$') { throw 'Invalid VS Code release metadata' }
    $codeArchive = if ($parts[0] -eq 'linux') { 'tar.gz' } else { 'zip' }
    $codeExecutable = switch ($parts[0]) { windows { 'Code.exe' }; macos { 'Visual Studio Code.app/Contents/Resources/app/bin/code' }; linux { 'bin/code' } }
    $lines.Add((@('vscode', $platform, '1.146.0', $metadata.sha256hash, $metadata.url, $codeArchive, $codeExecutable, 'microsoft/vscode') -join "`t"))
}
foreach ($platform in @('linux-x64', 'macos-x64', 'macos-arm64')) {
    Add-Artifact rustifiedgit $platform PlamDm/RustifiedGit v0.1.0 "rustifiedgit-$($platform -replace 'x64','x86_64').tar.gz" tar.gz rustifiedgit
}
$recipes = @{
    'yazi-source' = @('sxyazi/yazi', '8dd895c695a5950330c2623eb43debf323b60654')
    'rustifiedgit-source' = @('PlamDm/RustifiedGit', '7a2be2ebfa45cfc5be78e788a820ee145953f36b')
}
$crateLines = New-Object 'System.Collections.Generic.List[string]'
$crateLines.Add('# feature	name	version	sha256	url')
foreach ($id in @('yazi-source', 'rustifiedgit-source')) {
    $repo, $ref = $recipes[$id]
    $url = "https://github.com/$repo/archive/$ref.tar.gz"
    $file = Join-Path $WorkDirectory "$id.tar.gz"
    if (-not (Test-Path -LiteralPath $file)) { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $file }
    $sha = (Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant()
    $lines.Add((@($id, 'windows-x64', $ref, $sha, $url, 'source', 'Cargo.lock', $repo) -join "`t"))
    $source = Join-Path $WorkDirectory $id
    [IO.Directory]::CreateDirectory($source) | Out-Null
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -xzf $file --strip-components=1 -C $source
    if ($LASTEXITCODE) { throw "Could not extract $id" }
    $lock = [IO.File]::ReadAllText((Join-Path $source 'Cargo.lock'))
    foreach ($block in ($lock -split '(?m)^\[\[package\]\]')) {
        if ($block -notmatch '(?m)^source = "([^"]+)"') { continue }
        $crateSource = $Matches[1]
        if ($block -notmatch '(?m)^name = "([^"]+)"') { throw 'Missing crate name' }; $name = $Matches[1]
        if ($block -notmatch '(?m)^version = "([^"]+)"') { throw 'Missing crate version' }; $version = $Matches[1]
        if ($crateSource -eq 'registry+https://github.com/rust-lang/crates.io-index') {
            if ($block -notmatch '(?m)^checksum = "([a-f0-9]{64})"') { throw 'Missing crate checksum' }; $checksum = $Matches[1]
            $crateUrl = "https://static.crates.io/crates/$name/$name-$version.crate"
        } elseif ($crateSource -match '^git\+https://github.com/([^?]+)\?branch=([^#]+)#([a-f0-9]{40})$') {
            $gitRepo, $branch, $commit = $Matches[1], $Matches[2], $Matches[3]
            $gitRepo = $gitRepo -replace '\.git$', ''
            $crateUrl = "https://github.com/$gitRepo/archive/$commit.tar.gz"
            $gitFile = Join-Path $WorkDirectory "$name-$version.tar.gz"
            if (-not (Test-Path -LiteralPath $gitFile)) { Invoke-WebRequest -UseBasicParsing -Uri $crateUrl -OutFile $gitFile }
            $checksum = (Get-FileHash -LiteralPath $gitFile).Hash.ToLowerInvariant()
            $gitRoot = Join-Path $WorkDirectory "$name-git"
            [IO.Directory]::CreateDirectory($gitRoot) | Out-Null
            & (Join-Path $env:SystemRoot 'System32\tar.exe') -xzf $gitFile --strip-components=1 -C $gitRoot
            if ($LASTEXITCODE) { throw "Could not extract $name" }
            $gitPackage = @(Get-ChildItem -LiteralPath $gitRoot -Filter Cargo.toml -Recurse | Where-Object {
                [IO.File]::ReadAllText($_.FullName) -match ('(?m)^name\s*=\s*"' + [regex]::Escape($name) + '"')
            })
            if ($gitPackage.Count -ne 1) { throw "Cannot locate pinned Git package $name" }
            $manifestDirectory = Join-Path $output 'vendor-manifests'
            [IO.Directory]::CreateDirectory($manifestDirectory) | Out-Null
            $flattened = Convert-VendoredManifest $gitRoot $gitPackage[0].DirectoryName
            [IO.File]::WriteAllLines((Join-Path $manifestDirectory "$name-$version.toml"), $flattened, [Text.UTF8Encoding]::new($false))
        } else { throw "Unsupported pinned crate source: $crateSource" }
        $crateLines.Add((@(($id -replace '-source$',''), $name, $version, $checksum, $crateUrl) -join "`t"))
    }
}
[IO.File]::WriteAllLines((Join-Path $output 'artifacts.tsv'), $lines, [Text.Encoding]::ASCII)
[IO.File]::WriteAllLines((Join-Path $output 'crates.windows-x64.tsv'), $crateLines, [Text.Encoding]::ASCII)
if ($Msys2Root) {
    $groups = @{
        tmux = @('tmux')
        git = @('git')
        fzf = @('mingw-w64-ucrt-x86_64-fzf')
        rustifiedgit = @('git', 'mingw-w64-ucrt-x86_64-rust', 'mingw-w64-ucrt-x86_64-gcc', 'mingw-w64-ucrt-x86_64-cmake', 'mingw-w64-ucrt-x86_64-pkgconf')
        yazi = @('git', 'file', 'mingw-w64-ucrt-x86_64-rust', 'mingw-w64-ucrt-x86_64-gcc', 'mingw-w64-ucrt-x86_64-cmake', 'mingw-w64-ucrt-x86_64-pkgconf',
            'mingw-w64-ucrt-x86_64-ffmpeg', 'mingw-w64-ucrt-x86_64-7zip', 'mingw-w64-ucrt-x86_64-jq', 'mingw-w64-ucrt-x86_64-poppler',
            'mingw-w64-ucrt-x86_64-fd', 'mingw-w64-ucrt-x86_64-ripgrep', 'mingw-w64-ucrt-x86_64-zoxide', 'mingw-w64-ucrt-x86_64-resvg', 'mingw-w64-ucrt-x86_64-imagemagick')
    }
    $msysLines = New-Object 'System.Collections.Generic.List[string]'
    $msysLines.Add('# feature	name	version	filename	sha256	url	signature')
    $previousPath = $env:PATH
    try {
        $env:PATH = (Join-Path $Msys2Root 'usr\bin') + ';' + (Join-Path $env:SystemRoot 'System32')
        foreach ($feature in @('tmux', 'git', 'fzf', 'rustifiedgit', 'yazi')) {
            $resolved = & (Join-Path $Msys2Root 'usr\bin\pacman.exe') -Sp --needed --print-format '%n|%v|%f|%h|%l' @($groups[$feature])
            if ($LASTEXITCODE) { throw "Dependency resolution failed for $feature" }
            foreach ($line in $resolved) {
                $parts = $line.Split('|')
                if ($parts.Count -ne 5 -or $parts[3] -notmatch '^[a-f0-9]{64}$') { throw "Invalid pacman lock record: $line" }
                $parts[4] = $parts[4].Replace('https://mirror.msys2.org/', 'https://repo.msys2.org/')
                $database = if ($parts[0].StartsWith('mingw-w64-ucrt-')) { 'ucrt64.db' } else { 'msys.db' }
                $description = & (Join-Path $env:SystemRoot 'System32\tar.exe') -xOf `
                    (Join-Path $Msys2Root ('var\lib\pacman\sync\' + $database)) ($parts[0] + '-' + $parts[1] + '/desc')
                if ($LASTEXITCODE) { throw "Cannot read signature metadata for $($parts[0])" }
                $text = $description -join "`n"
                $signature = if ($text -match '%PGPSIG%\n([A-Za-z0-9+/=]+)') { $Matches[1] } else { '' }
                $record = @($feature) + $parts
                if ($signature) { $record += $signature }
                $msysLines.Add(($record -join "`t"))
            }
        }
    } finally { $env:PATH = $previousPath }
    [IO.File]::WriteAllLines((Join-Path $output 'msys2.windows-x64.tsv'), $msysLines, [Text.Encoding]::ASCII)
}
Write-Host 'Locks generated. Review versions, hashes, dependency snapshots and support policy before committing.'
