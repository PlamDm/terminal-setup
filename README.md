# Terminal setup

Install **Yazi, tmux, fzf, WezTerm, RustifiedGit, Bash, Git, btop, Codex CLI,
GitHub Copilot CLI and VS Code**, plus **Notepad++ and PowerShell 7 on Windows**.
Tools, dependencies, managed configuration, caches and state live under a
user-selected folder. No administrator installation is performed.

By default, installation leaves your shell profiles and persistent PATH alone.
Source one file to add the tools to an existing terminal.

## macOS and Linux

```sh
git clone https://github.com/PlamDm/terminal-setup.git
cd terminal-setup
bash install.sh --dry-run --root "$HOME/my-tools"
bash install.sh --root "$HOME/my-tools"
source "$HOME/my-tools/activate.sh"
```

Use a normal user account and an absolute directory without spaces. The default
is `~/playground`. Bootstrap needs Bash, Git, curl, tar and platform developer
tools: Xcode Command Line Tools on macOS, or a working C/C++ build toolchain on
Linux. These are OS prerequisites; this installer does not install them globally.

Packages and their library dependencies use a separate Homebrew prefix inside
`install/homebrew`; an existing Homebrew installation is not reused. Custom
prefixes can require lengthy source builds. Rustup and Cargo also stay inside
the selected root. Copilot CLI is the standalone distribution, so Node.js is not
required. VS Code uses its official portable archive for the current architecture.

Linux GUI tools also require a supported desktop session and the host libraries
required by [VS Code](https://code.visualstudio.com/docs/setup/linux) and
[WezTerm](https://wezterm.org/install/linux.html). The installer does not change
system packages, display servers, kernel settings or Electron sandbox permissions.
Notepad++ is a Windows application; it is installed and offered in Yazi on Windows.

## Native Windows

From PowerShell 5.1 or newer on x64 Windows 10/11:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -DryRun -PlaygroundRoot D:\my-tools
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -PlaygroundRoot D:\my-tools
. "D:\my-tools\activate.ps1"
```

Choose a user-writable directory without spaces or special characters, on a
filesystem supporting junctions and hard links (normally NTFS).
The default is `%USERPROFILE%\playground`.

The default installer extracts MSYS2's official self-extracting base archive into `install/msys2`, with
no setup registration or Start menu shortcuts. If it finds an existing MSYS2 in
common locations (`%SystemDrive%\msys64`, `C:\msys64`, or `%USERPROFILE%\msys64`),
through `MSYS2_ROOT`, or on `PATH`, PowerShell asks
whether to reuse it. Answer `y` to use it without downloading another MSYS2;
the installer adds the required packages to that installation. Answer `n` to
keep the tools setup self-contained under the selected playground folder.
For unattended installs, pass `-UseExistingMsys2`; use `-Msys2Root C:\msys64`
to select a specific existing installation. The Bash entry point accepts
`--use-existing-msys2` and `--msys2-root /c/msys64` as well. The selected path
is saved in `config/path/msys2-root.txt` for WezTerm and generated launchers.
Its UCRT64 packages supply Git
helpers, Rust and their library dependencies; Bash and tmux use MSYS2. Yazi 26.9.1
is compiled with a small cache/state directory override because the stock Windows
release otherwise uses AppData regardless of XDG settings.
RustifiedGit is built into a native `.exe`. WezTerm, btop4win, Copilot, PowerShell
7, VS Code and Notepad++ use portable archives. PowerShell 7 is included for
Copilot; its .NET runtime is bundled. btop4win uses the release without elevated
hardware-monitoring requirements.

Both Bash and CMD launchers are generated. Commands work from PowerShell, CMD,
MSYS2 Bash and WezTerm after activating the setup. Close processes using this
MSYS2 installation before updating it, and close apps before replacing their
executables. PowerShell's `-Activate` explicitly enables persistent user PATH
registration; it is off by default.

## Dependencies and Yazi defaults

The package managers install transitive library dependencies under the root.
The full setup also includes these Yazi helpers:

| Feature | Included tools |
| --- | --- |
| File types | `file` |
| Video thumbnails | `ffmpeg`, `ffprobe` |
| Archive previews and extraction | Full 7-Zip |
| JSON and PDF previews | `jq`, Poppler |
| File and content searches | `fd`, `rg`, `fzf` |
| Directory history | `zoxide` |
| SVG and other image previews | `resvg`, ImageMagick |
| Linux clipboard and default opening | `xclip`, `wl-clipboard`, GLib's `gio` |
| Icons | JetBrainsMono Nerd Font, loaded privately by WezTerm |

In the managed Yazi, **Enter opens an action chooser**:

- **Open** with the OS default application.
- **RustifiedGit** in the selected directory, or the containing repository of a file.
- **VS Code** with the selected files or directory.
- **Notepad++** for files on Windows.

Use **Right** or **l** to navigate into directories within Yazi. Yazi's regular
selection and multi-file opening remain available. The installed defaults live
in `config/yazi/keymap.toml` and `config/yazi/yazi.toml`; edit them freely. Reruns
preserve existing configuration files. With an older customized Yazi setup,
merge the repository's templates to enable the new chooser.

## Activate in an existing workflow

`activate.sh` works in Bash, Zsh and POSIX shells:

```sh
source "$HOME/my-tools/activate.sh"
# Equivalent:
source "$HOME/my-tools/config/shell/env-extra.sh"
```

For PowerShell:

```powershell
. "D:\my-tools\activate.ps1"
```

For Fish:

```fish
source "$HOME/my-tools/config/shell/env-extra.fish"
```

Activation appends the setup's `bin` directory to the current session's PATH.
Existing commands keep priority. Source it at the end of your profile if you
want it in future terminals. Repeated sourcing does not duplicate the entry.

To use the managed configuration when a tool already exists on PATH, call its
launcher explicitly, for example `~/my-tools/bin/yazi` or
`D:\my-tools\bin\yazi.cmd`. To put all managed commands first in a shell, source
`config/shell/env.sh` instead. Launchers apply the setup's configuration and cache
paths only to their child processes; the activation file does not globally change
your other tools' configuration directories.

For automatic shell and desktop user PATH registration, opt in:

```sh
bash install.sh --root "$HOME/my-tools" --activate
```

```powershell
.\install.ps1 -PlaygroundRoot D:\my-tools -Activate
```

`--no-activate` / `-NoActivate` remain supported. Manual mode does not remove
hooks from an earlier automatically activated installation.

## Layout and isolation

```text
my-tools/
├── activate.sh / activate.ps1    source in an existing terminal
├── bin/                         launchers for tools and Yazi helpers
├── install/
│   ├── homebrew/                macOS/Linux packages and libraries
│   ├── msys2/                   Windows packages, libraries and compiler
│   ├── apps/                    macOS WezTerm application
│   ├── wezterm/ / btop/          Windows portable applications
│   ├── rust/ / rustup/           macOS/Linux compiler toolchain
│   ├── rustifiedgit/             compiled Git client
│   ├── codex/ / copilot/         standalone AI CLIs
│   ├── vscode/ / notepad++/      portable editors (Notepad++ on Windows)
│   ├── powershell/               Windows portable PowerShell 7
│   └── fonts/                    private Nerd Font files
├── config/                      editable managed configuration
├── state/                       history, tmux socket, zoxide data, build revision
├── cache/                       downloads, previews and build artifacts
└── tmp/                         temporary files
```

VS Code's portable data directory points to `config/vscode`, including its
extensions, user data and temporary files. Notepad++ uses a separate instance
and `config/notepad++`. Copilot uses `COPILOT_HOME` and `COPILOT_CACHE_HOME` under
the root, with automatic updates disabled. Codex uses its own `config/codex` and
package payload. tmux uses a private socket, avoiding another setup's server.
Managed Git uses `config/git/config` for its global configuration; configure
your name and email through the managed Git launcher if needed.

This is **directory isolation, not an OS security sandbox**. Programs still run
with your user permissions and can access files you open or repositories you
work on. OS services such as the browser, credential store and desktop may use
their own storage. WezTerm also manages some runtime logs and font caches in its
upstream per-user locations. OS prerequisites are shared. Shell activation is exportable;
a single native tool installation is not a relocatable cross-OS bundle. Rerun the
installer with the desired root on another machine rather than copying binaries
between operating systems or moving an existing Homebrew prefix.

The repository contains only installer code and templates. Do not publish an
installed folder containing credentials or session history.

## Updates and sign-in

Rerun the installer with the same root to update packages and portable tools.
Existing projects and customized configuration are preserved. RustifiedGit is
built from [PlamDm/RustifiedGit](https://github.com/PlamDm/RustifiedGit) at the
pinned revision `7a2be2ebfa45cfc5be78e788a820ee145953f36b`. To update it to `main`:

```sh
bash install.sh --root "$HOME/my-tools" --rustifiedgit-ref main
```

```powershell
.\install.ps1 -PlaygroundRoot D:\my-tools -RustifiedGitRef main
```

Builds use `cargo build --release --locked`. The binary is reused when the source
commit is unchanged; a failed build retains the previous executable. Downloaded
portable archives are verified against published SHA-256 hashes.

The AI CLIs have separate sign-ins. Run the managed `codex login`, and launch
managed `copilot` then use `/login`. Installing Copilot does not purchase a
subscription or grant account access; your GitHub account needs Copilot access.
To install only Codex, use `--only-codex` / `-OnlyCodex`.

## Checks

```sh
# Tests require Python 3 and jq; fixture installs never contact the network.
python3 tests/check.py
bash install.sh --dry-run --platform macos
bash install.sh --dry-run --platform linux
bash install.sh --dry-run --platform windows
```

Tests cover previews, opt-in registration, activation priority, configuration
routing, quoted arguments, repeat installs, preserved settings, verified portable
archive extraction and failed downloads/builds. Windows CI also installs real
portable applications, runs their command launchers, and builds and runs the
pinned RustifiedGit `.exe` using native MSYS2 Rust.

## References

- [Yazi dependencies](https://yazi-rs.github.io/docs/installation/)
- [Yazi opener configuration](https://yazi-rs.github.io/docs/configuration/yazi/)
- [GitHub Copilot CLI installation](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli)
- [Copilot configuration and cache paths](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference)
- [VS Code portable mode](https://code.visualstudio.com/docs/setup/portable)
- [Notepad++ portable distribution](https://github.com/notepad-plus-plus/notepad-plus-plus/releases)
- [Notepad++ settings directory](https://github.com/notepad-plus-plus/npp-usermanual/blob/master/content/docs/command-prompt.md)
- [Homebrew installation prerequisites](https://docs.brew.sh/Installation)
- [Codex installer variables](https://learn.chatgpt.com/docs/config-file/environment-variables)
