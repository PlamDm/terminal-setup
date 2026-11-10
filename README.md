# Terminal setup

Install your terminal tools with one installer: **Yazi, tmux, fzf, WezTerm,
RustifiedGit, Bash, Git, btop, and Codex CLI**. Supports macOS, Linux, and native
Windows through MSYS2.

## macOS and Linux

```sh
git clone https://github.com/PlamDm/terminal-setup.git
cd terminal-setup
bash install.sh --dry-run
bash install.sh
```

Use a normal user account. Bootstrap requires Bash, Git, curl, and tar. Native
builds require a C compiler and platform developer tools, such as Xcode Command
Line Tools on macOS. The installer keeps its Homebrew prefix and Rust toolchain
inside the chosen installation directory.

Choose a different absolute directory:

```sh
bash install.sh --root "$HOME/tools"
```

Full installs require a directory without spaces. A custom Homebrew prefix may
require packages to compile from source, so a first install can take time.
Existing projects and application configuration are preserved on reruns.

## Native Windows

Clone or download this repository, then run from PowerShell 5.1 or PowerShell 7:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Choose another directory with `-PlaygroundRoot D:\playground`. Windows uses
MSYS2's x64 UCRT64 packages for Bash, tmux, Yazi, fzf, Git, and Rust. RustifiedGit
is compiled into a native `.exe`; MSYS2 supplies the compiler and dependencies.
WezTerm is installed from its portable ZIP. The `btop` command launches
btop4win's build without hardware-monitoring administrator requirements.

The MSYS2 install path must not contain spaces or special characters. Close
other shells using this MSYS2 installation before updating its runtime.
btop4win requires Microsoft's Visual C++ x64 runtime to be installed already.

Both CMD launchers and Bash launchers are generated, so the commands work from
PowerShell, CMD, MSYS2 Bash, and WezTerm. Restart existing terminals and IDEs
when the installer finishes so they receive the updated user PATH.

## Layout

The default root is `~/playground`, including `%USERPROFILE%\playground` on
Windows:

```text
playground/
├── bin/                     user-facing command launchers
├── install/
│   ├── homebrew/             macOS/Linux packages
│   ├── apps/WezTerm.app      macOS terminal application
│   ├── msys2/                native Windows packages and Rust compiler
│   ├── wezterm/              portable Windows terminal
│   ├── btop/                 portable Windows system monitor
│   ├── rust/                 macOS/Linux Rust command shims
│   ├── rustup/               macOS/Linux Rust toolchains
│   ├── rustifiedgit/bin/     compiled Git client
│   └── codex/                standalone CLI and package payload
├── config/                   editable application configuration
├── state/                    installed revisions and shell history
├── cache/                    downloads, Cargo dependencies and build artifacts
└── tmp/                      temporary installation checkouts
```

Only the installer and configuration templates live in this repository.
Application sessions, credentials, downloads, and installed tools stay on the
machine where you run it.

## RustifiedGit installation and updates

RustifiedGit is built from [PlamDm/RustifiedGit](https://github.com/PlamDm/RustifiedGit)
with `cargo build --release --locked`. The default source revision is:

```text
7a2be2ebfa45cfc5be78e788a820ee145953f36b
```

The launcher is `playground/bin/rustifiedgit`, or `rustifiedgit.cmd` on Windows.
It selects `playground/config/rustifiedgit` automatically:

```sh
rustifiedgit -p /path/to/repository
```

To install the latest `main` or a specific commit/tag:

```sh
bash install.sh --rustifiedgit-ref main
```

```powershell
.\install.ps1 -RustifiedGitRef main
```

On macOS/Linux, Rustup installs a minimal toolchain under the setup root, and
Cargo respects RustifiedGit's toolchain file. Windows uses MSYS2's packaged
Rust compiler. Build caches are retained between runs. If a ref resolves to the
already installed commit, its binary is reused. A failed build leaves the
previous executable and recorded revision intact. Close RustifiedGit before
replacing its executable on Windows.

## Configuration and PATH

Launchers keep configuration under `playground/config`:

| Tool | Configuration |
| --- | --- |
| Bash | `bash/bashrc`; history under `state/bash` |
| tmux | `tmux/tmux.conf`, with the managed Bash as its default shell |
| Yazi | `yazi`, selected through `YAZI_CONFIG_HOME` |
| RustifiedGit | `rustifiedgit`, selected with `--use-config-dir` |
| WezTerm | `wezterm/wezterm.lua`; opens the managed Bash |
| btop | `btop`; Windows uses a hard link to its required co-located config |
| Codex CLI | `codex`, selected through its launcher's `CODEX_HOME` |

Application configuration is created only when missing. Generated launchers
and PATH hooks are refreshed on reruns. The installer registers `playground/bin`
in Bash, Zsh, Fish, and the desktop user environment. Windows also receives a
persistent user PATH entry. The system login shell is not changed.

For a process that replaces PATH explicitly, source
`playground/config/shell/env.sh` or invoke an absolute launcher path.
Some Linux desktop sessions need a sign-out/sign-in to refresh their PATH.

Yazi's optional PDF/video preview tools, extra fonts, and shell key bindings
are not installed by this setup.

## Codex CLI only

```sh
bash install.sh --only-codex
```

```powershell
.\install.ps1 -OnlyCodex
```

This uses OpenAI's standalone installer with a scoped installation directory;
Node.js is not required. On Windows, the base MSYS2 environment is also installed
if missing. The managed Codex configuration is separate, so sign in there once:

```sh
codex login
```

## Checks

```sh
python3 tests/check.py
bash install.sh --dry-run --platform macos
bash install.sh --dry-run --platform linux
bash install.sh --dry-run --platform windows
```

The offline tests exercise dry runs without side effects, shell syntax, PATH
registration, quoted launcher arguments, config routing, repeat runs, and
RustifiedGit build caching/failure recovery using fixture tools. They do not
install the full tool suite on your development machine. CI also parses and
previews PowerShell, and builds the pinned RustifiedGit revision with native
MSYS2 Rust on Windows.

## References

- [RustifiedGit](https://github.com/PlamDm/RustifiedGit)
- [Homebrew installation](https://docs.brew.sh/Installation)
- [Rustup installation](https://rust-lang.github.io/rustup/installation/other.html)
- [MSYS2 Rust package](https://packages.msys2.org/packages/mingw-w64-ucrt-x86_64-rust)
- [WezTerm installation](https://wezterm.org/installation.html)
- [Codex installer variables](https://learn.chatgpt.com/docs/config-file/environment-variables)
