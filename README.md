# terminal-setup

This repository separates installer source from its generated tool bundle:

- `installer/` contains the install scripts, libraries, pinned package locks,
  templates, tests, and full guide.
- `personal-tools/` is created by the installer and ignored by Git. It contains
  installed applications, launchers, configuration, state, caches, and
  activation scripts.

Run the installer from the repository root:

```powershell
.\installer\install.ps1 -Tools bash,tmux,yazi,fzf,copilot
```

```bash
bash ./installer/install.sh --tools bash,tmux,yazi,fzf,copilot
```

With no `-Tools` / `--tools` selection, the installer requests the full
supported set. The default output is `personal-tools/`; see
[the installer guide](installer/README.md) for tool selection, offline
installation, platform support, and relocation.
