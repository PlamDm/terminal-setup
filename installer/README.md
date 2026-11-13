# Terminal setup

A folder-owned launcher and pinned package installer for **Bash, Git, tmux,
Yazi, fzf, btop, WezTerm, RustifiedGit, Codex, Copilot and VS Code**, plus
**Notepad++ and PowerShell 7 on Windows**. Yazi includes its preview/search
dependencies; WezTerm includes a private JetBrainsMono Nerd Font.

The default output is **the repository's `personal-tools` folder**, beside the
`installer` folder, regardless of the current working directory. Installed
tools, dependencies, managed configuration, package archives and build state
stay beneath that output root. The default installation does not register
applications, install fonts globally, modify Git configuration, or change
profiles/persistent PATH.

This is a portable installation layout, **not an OS security sandbox**. See the
runtime and platform limitations below before deploying it.

## Install and select tools

Clone the repository and invoke the installer from its `installer` folder.
Generated files go to the sibling `personal-tools` folder by default.

```powershell
# Native x64 Windows PowerShell 5.1 or newer:
& C:\path\terminal-setup\installer\install.ps1 -Tools bash,tmux,yazi,fzf,copilot
. "C:\path\terminal-setup\personal-tools\activate.ps1"
```

```bash
# Linux/macOS:
bash /path/terminal-setup/installer/install.sh --tools bash,tmux,yazi,fzf,copilot
source /path/terminal-setup/personal-tools/activate.sh
```

Omit `-Tools` / `--tools` to request the full supported set. Tool IDs are
`bash`, `git`, `tmux`, `yazi`, `fzf`, `btop`, `wezterm`, `rustifiedgit`,
`codex`, `copilot`, `vscode`, and, on Windows, `notepadpp` and `pwsh`.
Selecting Copilot on Windows also selects its private PowerShell 7 dependency.
Windows MSYS2 Bash is an installer runtime even for a smaller selection.

Use `-PlaygroundRoot D:\my-tools` / `--root "$HOME/my-tools"` to choose another
output root. `-DryRun` / `--dry-run` previews without creating the root.
`-OnlyCodex` / `--only-codex` selects only Codex.

For the directory browser and tool menu:

```powershell
.\installer\install.ps1 -Interactive
```

```bash
bash installer/install.sh --interactive
```

Use arrows and Enter to choose a folder, then Space to toggle tools and Enter
to continue. Status distinguishes managed tools from commands available
elsewhere. Selecting a tool installs its managed copy; an unrelated command
on PATH is not a clean-bootstrap dependency.

On Windows, when WezTerm is selected, the installer also offers a final setup
step for a separate d_t console launcher. It prompts for the d_t root and
creates `personal-tools\bin\wezterm-dt.cmd`, which opens d_t's MSYS2 Bash
environment in WezTerm, loads d_t's Bash startup files, then activates this
playground's tools. The existing `personal-tools\bin\wezterm.cmd` remains the
self-contained playground console. To configure or regenerate the d_t launcher
independently, run `.\installer\configure-devtools-console.ps1`; pass
`-DevToolsRoot` to skip the folder picker. The d_t installation and its
credentials remain external and are not copied into the playground.

On Windows, Yazi uses the configuration seeded under the installation's
`personal-tools\config\yazi` directory. To opt into another existing
configuration, run
`.\personal-tools\configure-paths.ps1 -YaziConfigFile C:\path\to\config\yazi.toml`;
that override is recorded in
`personal-tools\config\path\yazi-config-home.txt`. Missing or stale overrides
fall back to the installation's config. Bash and PowerShell shell integrations
restore the calling directory to Yazi's last location when Yazi exits.

## Platform support and prerequisites

| Platform | Supported baseline |
| --- | --- |
| Windows | x64 Windows 10/11, 64-bit Windows PowerShell 5.1+, OS `tar.exe`; writable NTFS-style filesystem supporting hard links |
| Linux x64 | glibc 2.28+ for core packages/Copilot; 2.29+ for WezTerm, 2.34+ for RustifiedGit; compatible desktop host libraries for GUI applications |
| Linux arm64 | supported binary packages/AI CLIs; no locked WezTerm or RustifiedGit artifact, so requesting those or the full set fails preflight |
| macOS x64 | macOS 13+ |
| macOS arm64 | macOS 14.5+; required by the current locked Ghostscript dependency |

Use an OS release still supported by your organization. A minimum compatible
version is not a recommendation to run an unmaintained OS.

Unix bootstrap uses system Bash, curl, tar, SHA-256 utilities and the platform's
ordinary archive/file utilities. It does **not** require existing Homebrew,
managed Git, Rust, Node.js, Xcode or another compiler. Missing OS prerequisites
fail explicitly; the installer does not install them globally.

Windows paths must contain only letters, digits, dot, underscore, hyphen and
path separators, with no spaces. Unix paths may contain spaces.
Linux GUI tools still require host desktop libraries, display services and
appropriate Electron sandbox permissions. The installer does not change
system packages, kernel settings or sandbox permissions.

## Locked packages and corporate HTTPS

Normal installation never resolves `latest`, refreshes a rolling package
repository, or runs an upstream delegated installer. Reviewed inputs are
recorded with exact URLs, versions and SHA-256:

| Lock | Contents |
| --- | --- |
| `packages/artifacts.tsv` | Standalone applications, base runtimes and source archives |
| `packages/msys2.windows-x64.tsv` | Frozen Windows package/dependency closure from signed MSYS2 metadata |
| `packages/crates.windows-x64.tsv` | Offline Rust source dependencies and their checksums |
| `packages/unix-*.tsv` | Per-platform binary package/dependency closures |

Representative pins include PowerShell **7.6.10**, Copilot **1.0.109**, Codex
**0.167.1**, VS Code **1.146.0**, Yazi **26.9.1**, and WezTerm's upstream
stable **20240203-110809-5046fc22** release. The locks, not this overview, are
authoritative; package versions can differ by platform.

Windows downloads use native PowerShell/.NET HTTPS with **existing Windows
system trust**. The launcher does not import/export corporate or public
certificates, replace certificate chains, disable verification, or relax
revocation policy. There is no universal certificate that can authenticate
every public site or intercepting proxy. If system policy blocks a download,
installation fails with the URL; use an independently verified offline bundle
or ask your administrator to provide approved access.

MSYS2 receives local verified archives rather than HTTPS requests through its
separate OpenSSL trust store. A fresh private signing keyring is initialized
locally and populated from the bundled MSYS2 keys; package signature policy
remains enabled. No `pacman -Syu` is performed.

Exact pins give reproducible inputs, **not blanket enterprise/security approval**.
WezTerm's old stable release, applications' licenses, platform support and AI
network access still require organizational review. Default VS Code application
and extension automatic updates and Copilot automatic updates are disabled;
existing customized settings are preserved.

## Offline bundles

Prepare the selected platform's archives on an approved connected machine:

```powershell
& C:\path\terminal-setup\installer\install.ps1 -PlaygroundRoot D:\bundle -Tools bash,tmux,fzf -DownloadOnly
```

```bash
bash /path/terminal-setup/installer/install.sh --root "$HOME/bundle" --tools bash,tmux,fzf --download-only
```

Transfer the bundle's `cache` directory and the matching installer/locks. From
the desired destination, install without network access:

```powershell
& C:\path\terminal-setup\installer\install.ps1 -PlaygroundRoot D:\target -Tools bash,tmux,fzf -PackageDirectory D:\bundle\cache -Offline
```

```bash
bash /path/terminal-setup/installer/install.sh --root /path/target --tools bash,tmux,fzf --package-dir /path/bundle/cache --offline
```

Archive names are `SHA256-URL_basename`. Every reused or imported archive is
verified. A missing or corrupt archive fails, rather than falling back to the
network in offline mode. Include all dependencies for the selected tools.
Windows Yazi/RustifiedGit source builds use vendored dependencies offline.

## Templates, activation and moving the folder

```text
terminal-setup/
  installer/                     installer, libraries, locks, templates, tests and guide
  personal-tools/                generated output; ignored by Git
    configure-paths.ps1          Windows Yazi runtime helper
    set-yazi-config-home.cmd     Windows Yazi launcher helper
    activate.sh / activate.ps1   session-only activation
    bin/                         root-relative tool launchers
    install/                     portable applications and private runtimes
      msys2/                     Windows runtime, libraries and build tools
      conda/                     Unix binary environments and dependencies
    templates/                   editable copies of default configuration
    config/                      editable managed configuration
    state/                       history, private sockets and application state
    cache/                       verified packages, previews and build artifacts
    tmp/                         installer/application temporary files
    lib/ / packages/             Unix offline-relocation support, when applicable
```

The installer copies templates into `personal-tools\templates` and then into
`config` **only when a destination is missing**. Reruns preserve edits in both
locations. To change an existing configuration, edit it or explicitly merge a
newer template.

`activate.sh` and `config/shell/env-extra.sh` append commands to the current
Bash/Zsh session without displacing existing commands; repeated sourcing does
not duplicate PATH entries. Fish uses `config/shell/env-extra.fish`.
PowerShell uses `activate.ps1`. In plain POSIX shells, provide
`PD_PLAYGROUND_ROOT` explicitly before sourcing activation.
To prioritize managed commands, source `config/shell/env.sh` instead, or call
`bin/yazi` / `bin\yazi.cmd` directly.

Close managed applications and tmux servers before copying or moving the root.
Move the **whole folder**, then source activation from its new location. Native
launchers discover their root at runtime. Unix activation re-links recorded
binary prefixes using the already-verified local archives, offline. Keep those
archives. To add tools later, keep the `installer` folder and rerun its entry
point with `-PlaygroundRoot` / `--root` pointing to the output folder.
Do not combine folders for different OS/architecture targets.

btop4win requires a co-located configuration hard link. After a copy, rerun the
installer to restore linkage; if the two configurations diverged, reconcile
them explicitly rather than overwriting either customization.

`--activate` / `-Activate` explicitly opts into persistent shell/user PATH
registration and is outside the default folder-only contract.
`--no-activate` / `-NoActivate` does not remove earlier opt-in registration.

## Existing installations and limitations

Fresh Windows installation always uses private MSYS2 unless reuse is explicitly
requested with `-Msys2Root`, `-Msys2SearchPath` or `-UseExistingMsys2` (equivalent
Bash options exist). Reuse is **not** a self-contained transferable bundle.
Keep the destination outside the reused MSYS2 folder.

Existing Windows application versions are preserved, not silently upgraded.
Only missing MSYS2 packages are installed. A pre-transaction guard rejects
upgrades, downgrades, reinstalls or removals of installed packages; incompatible
dependencies require a fresh root. `-Msys2ReadOnly` does not query or modify its
package database; selected unavailable commands fail explicitly.
Unix binary prefixes retain exact lock identities and validate executables;
changed locks require an explicit migration, not a background update.
Unreviewed source-ref overrides are rejected.

Yazi includes `file`, FFmpeg, 7-Zip, jq, Poppler, fd, ripgrep, zoxide, resvg and
ImageMagick (plus platform dependencies such as Ghostscript). Core Yazi remains
usable; **this bundle does not provide full Wayland clipboard parity**.
Enter opens an action chooser for the OS default app, RustifiedGit, VS Code
and, on Windows, Notepad++. Right/`l` retains directory navigation.

No Git identity/global configuration is generated. Direct shell Git preserves
the caller's configuration environment. Git inside managed child terminals or
applications can discover different global configuration because of inherited
HOME/XDG paths; native Windows launchers other than direct Git scope HOME
beneath the root. Direct Git does not receive a managed HOME/config override.

Programs retain your user permissions. Browser/credential/desktop services,
host libraries and upstream **Windows WezTerm logs/font caches** can use OS
storage outside the root. These cannot be promised folder-contained by this
launcher. Do not distribute `config`, `state` or caches containing credentials,
session history or private project data without reviewing/removing that data.
Codex and Copilot have independent sign-ins and require appropriate account
access; installing them grants no subscription or organization approval.

## Development checks and lock maintenance

`python3 tests/check.py` and `bash tests/check-unix.sh` run offline fixtures.
Windows checks are the `tests/check-*.ps1` scripts. Development tests may use
Python/Git Bash; neither is a native clean-bootstrap dependency.
CI covers offline fixtures and selected real clean bootstraps on supported
hosts; Linux/macOS binaries cannot be runtime-validated on a Windows host.

Maintainer scripts under `tools` regenerate frozen locks. Review version
support, licenses, signed metadata, checksums and dependency changes before
publishing new locks. Installers do not invoke lock generators.
