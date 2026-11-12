#!/usr/bin/env python3
"""Offline checks. Full-flow checks use fixture executables, never real installers."""
import os
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import tarfile
import zipfile
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("TEST_BASH") or shutil.which("bash") or "/bin/bash"


def executable(path, source):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source)
    path.chmod(0o755)

def shell_path(path):
    value = str(path)
    if os.name == "nt":
        if len(value) >= 3 and value[0] == "/" and value[1].isalpha() and value[2] == "/":
            return value
        value = Path(path).resolve().as_posix()
        return "/" + value[0].lower() + value[2:]
    return value


def launcher_command(path, *args):
    if os.name == "nt":
        return [BASH, shell_path(path), *args]
    return [str(path), *args]


class PlaygroundChecks(unittest.TestCase):
    def test_shell_syntax(self):
        for shell in {BASH, "/bin/bash"}:
            if Path(shell).is_file():
                for script in ("install.sh", "lib/environment.sh", "lib/rustifiedgit.sh", "lib/portable.sh",
                               "lib/yazi.sh", "lib/msys2.sh", "lib/interactive.sh", "lib/packages.sh", "lib/unix.sh"):
                    subprocess.run([shell, "-n", str(ROOT / script)], check=True)

    def test_interactive_catalog_and_selected_msys2_packages(self):
        catalog = {}
        for line in (ROOT / "lib/interactive-tools.tsv").read_text().splitlines():
            if not line or line.startswith("#"):
                continue
            tool, _label, platforms = line.split("\t")
            catalog[tool] = set(platforms.split(","))
        self.assertIn("notepadpp", catalog)
        self.assertEqual(catalog["notepadpp"], {"windows"})
        self.assertEqual(catalog["pwsh"], {"windows"})
        self.assertEqual(catalog["yazi"], {"macos", "linux", "windows"})

        with tempfile.TemporaryDirectory(prefix="pd-interactive-") as directory:
            base = Path(directory)
            msys = base / "msys2"
            pacman = msys / "usr" / "bin" / "pacman.exe"
            log = base / "pacman-args"
            pacman.parent.mkdir(parents=True)
            executable(pacman, "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + shlex.quote(str(log)) + "\n")
            script = (
                'set -euo pipefail\n'
                'PD_MSYS2_ROOT="$1"\n'
                'PD_SELECTION_MODE=explicit\n'
                'PD_SELECTED_TOOLS=yazi,wezterm\n'
                'PD_MSYS2_PRESERVE_INSTALLED=0\n'
                'PD_MSYS2_READ_ONLY=0\n'
                '. "$2/lib/msys2.sh"\n'
                'pd_install_msys2_packages\n'
            )
            subprocess.run([BASH, "-c", script, "fixture", shell_path(msys), shell_path(ROOT)], check=True)
            packages = log.read_text().splitlines()
            self.assertEqual(packages[:3], ["-S", "--needed", "--noconfirm"])
            self.assertIn("bash", packages)
            self.assertIn("git", packages)
            self.assertIn("mingw-w64-ucrt-x86_64-rust", packages)
            self.assertIn("mingw-w64-ucrt-x86_64-ffmpeg", packages)
            self.assertNotIn("tmux", packages)
            self.assertNotIn("mingw-w64-ucrt-x86_64-fzf", packages)

    def test_previews_never_call_installers_or_create_root(self):
        with tempfile.TemporaryDirectory(prefix="pd-check-") as directory:
            base = Path(directory)
            marker = base / "forbidden"
            guards = base / "guards"
            guards.mkdir()
            for name in ("sudo", "brew", "git", "curl", "pacman", "powershell.exe"):
                executable(guards / name, "#!/bin/sh\ntouch " + shlex.quote(str(marker)) + "\nexit 99\n")
            environment = dict(os.environ, PATH=str(guards) + os.pathsep + os.environ["PATH"])
            for platform in ("macos", "linux", "windows"):
                result = subprocess.run(
                    [BASH, str(ROOT / "install.sh"), "--dry-run", "--interactive", "--platform", platform,
                     "--root", shell_path(base / "must-not-exist")],
                    env=environment, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Interactive selection is required", result.stdout)
                self.assertIn("/install", result.stdout)
                self.assertIn("/config", result.stdout)
                self.assertIn("/bin", result.stdout)
                self.assertFalse(marker.exists())
                self.assertFalse((base / "must-not-exist").exists())
                selected = subprocess.run(
                    [BASH, str(ROOT / "install.sh"), "--dry-run", "--platform", platform,
                     "--tools", "bash,tmux,yazi,fzf,codex", "--root", shell_path(base / "must-not-exist")],
                    env=environment, capture_output=True, text=True,
                )
                self.assertEqual(selected.returncode, 0, selected.stderr)
                self.assertIn("Selected tools: bash,tmux,yazi,fzf,codex", selected.stdout)
                self.assertFalse(marker.exists())
                self.assertFalse((base / "must-not-exist").exists())

    def test_codex_only_preview_skips_other_installs(self):
        result = subprocess.run(
            [BASH, str(ROOT / "install.sh"), "--dry-run", "--only-codex"],
            capture_output=True, text=True, check=True,
        )
        self.assertIn("Codex", result.stdout)
        self.assertNotIn("Create an isolated Homebrew", result.stdout)
        self.assertNotIn("Build https://", result.stdout)

    def test_msys2_read_only_preview_is_windows_only(self):
        result = subprocess.run(
            [BASH, str(ROOT / "install.sh"), "--dry-run", "--platform", "windows", "--msys2-read-only"],
            capture_output=True, text=True, check=True,
        )
        self.assertIn("Read-only reuse fails explicitly", result.stdout)
        invalid = subprocess.run(
            [BASH, str(ROOT / "install.sh"), "--dry-run", "--platform", "linux", "--msys2-read-only"],
            capture_output=True, text=True,
        )
        self.assertNotEqual(invalid.returncode, 0)

    def test_manual_activation_preview_leaves_root_absent(self):
        with tempfile.TemporaryDirectory(prefix="terminal-preview-") as directory:
            target = Path(directory) / "not-installed"
            result = subprocess.run([BASH, str(ROOT / "install.sh"), "--dry-run", "--no-activate",
                                     "--root", shell_path(target)], capture_output=True, text=True, check=True)
            self.assertIn("Leave profiles and persistent PATH unchanged", result.stdout)
            self.assertNotIn("Register " + shell_path(target), result.stdout)
            self.assertFalse(target.exists())

    def test_default_is_source_only_and_registration_is_explicit(self):
        result = subprocess.check_output([BASH, str(ROOT / "install.sh"), "--dry-run"], text=True)
        self.assertIn("Leave profiles and persistent PATH unchanged", result)
        activated = subprocess.check_output([BASH, str(ROOT / "install.sh"), "--dry-run", "--activate"], text=True)
        self.assertIn("Opt in to registering ", activated)

    def test_invalid_arguments_fail(self):
        for arguments in (
            ["--wat"], ["--root"], ["--root", "relative"],
            ["--root", "/"], ["--platform", "windows"],
            ["--dry-run", "--platform", "unknown"],
            ["--dry-run", "--rustifiedgit-ref", "main; touch /tmp/forbidden"],
        ):
            result = subprocess.run([BASH, str(ROOT / "install.sh")] + arguments,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, arguments)

    def test_native_windows_only(self):
        for name in ("install.sh", "install.ps1", "wezterm.lua", "lib/environment.sh"):
            self.assertNotRegex(ROOT.joinpath(name).read_text().lower(), r"\bwsl(?:\.exe)?\b")

    def test_environment_and_launchers_handle_spaces_and_quotes(self):
        with tempfile.TemporaryDirectory(prefix=".check-environment-", dir=ROOT) as directory:
            base = Path(directory)
            playground = base / "play ground's"
            user = base / "user"
            target = playground / "install/mock/bin/codex"
            executable(target, '#!/bin/sh\nprintf "%s\\n" "$CODEX_HOME" "$@"\n')
            script = """
set -eu
die() { printf '%s' "$*" >&2; exit 1; }
PD_ROOT=$1
PD_USER_HOME=$2
PD_OS=macos
PD_SKIP_DESKTOP_PATH=1
mkdir -p "$PD_ROOT/bin" "$PD_ROOT/tmp" "$PD_USER_HOME"
. "$3/lib/environment.sh"
pd_write_environment
pd_write_launcher codex "$PD_ROOT/install/mock/bin/codex"
pd_register_path
pd_register_path
"""
            environment = dict(os.environ, XDG_CONFIG_HOME=shell_path(user / ".config"))
            subprocess.run([BASH, "-c", script, "check", shell_path(playground), shell_path(user), shell_path(ROOT)],
                           env=environment, check=True)
            for name in (".bashrc", ".bash_profile", ".profile", ".zshrc", ".zprofile"):
                content = (user / name).read_text()
                self.assertEqual(content.count("# >>> pd-playground PATH >>>"), 1)
            argument = "one argument; $(must-not-run)"
            result = subprocess.run(launcher_command(playground / "bin/codex", argument),
                                    env=environment, check=True, capture_output=True, text=True)
            codex_home = (playground / "config/codex").as_posix() if os.name == "nt" else str(playground / "config/codex")
            self.assertEqual(result.stdout.splitlines(),
                             [codex_home, argument])
            if shutil.which("zsh"):
                probe = '. ' + shlex.quote(shell_path(playground / "config/shell/env.sh")) + '; command -v codex'
                result = subprocess.run(["zsh", "-f", "-c", probe],
                                        check=True, capture_output=True, text=True)
                self.assertEqual(result.stdout.strip(), shell_path(playground / "bin/codex"))

    def test_refuses_launcher_target_outside_playground(self):
        with tempfile.TemporaryDirectory(prefix=".check-launcher-", dir=ROOT) as directory:
            script = 'die() { exit 9; }; PD_ROOT=$1; . "$2/lib/environment.sh"; pd_write_launcher codex /usr/bin/codex'
            result = subprocess.run([BASH, "-c", script, "check", shell_path(directory), shell_path(ROOT)])
            self.assertEqual(result.returncode, 9)

    def test_ai_editor_and_yazi_launchers_isolate_data_and_preserve_arguments(self):
        if os.name == "nt":
            self.skipTest("Git Bash does not model native Unix process and path semantics.")
        with tempfile.TemporaryDirectory(prefix="terminal-apps-") as directory:
            playground = Path(directory) / "tool root's"
            for name in ("copilot", "code", "yazi", "git"):
                target = playground / "install/fixture" / name
                source = 'import json,os,sys; print(json.dumps({"env":dict(os.environ),"args":sys.argv[1:]}))'
                if os.name == "nt":
                    executable(target, "#!/bin/sh\nexec " + shlex.quote(shell_path(sys.executable)) +
                               " -c " + shlex.quote(source) + ' "$@"\n')
                else:
                    executable(target, '#!' + sys.executable + '\n' + source.replace("; ", "\n") + "\n")
            generate = '''
set -eu
PD_ROOT=$1
PD_OS=macos
mkdir -p "$PD_ROOT/bin"
. "$2/lib/environment.sh"
pd_write_environment
for name in copilot code yazi git; do pd_write_launcher "$name" "$PD_ROOT/install/fixture/$name"; done
'''
            subprocess.run([BASH, "-c", generate, "check", shell_path(playground), shell_path(ROOT)], check=True)
            argument = "file's name; $(must-not-run).txt"
            for name in ("copilot", "code", "yazi", "git"):
                actual = json.loads(subprocess.check_output(
                    launcher_command(playground / "bin" / name, argument), text=True))
                self.assertEqual(actual["args"][-1], argument)
                for variable, relative in (("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"),
                    ("XDG_STATE_HOME", "state"), ("TMPDIR", "tmp")):
                    if name == "git":
                        self.assertEqual(actual["env"].get(variable), os.environ.get(variable))
                    else:
                        self.assertEqual(shell_path(actual["env"][variable]), shell_path(playground / relative))
                self.assertEqual(actual["env"].get("GIT_CONFIG_GLOBAL"), os.environ.get("GIT_CONFIG_GLOBAL"))
                self.assertFalse((playground / "config/git").exists())
                if name == "copilot":
                    self.assertEqual(shell_path(actual["env"]["COPILOT_HOME"]), shell_path(playground / "config/copilot"))
                    self.assertEqual(shell_path(actual["env"]["COPILOT_CACHE_HOME"]), shell_path(playground / "cache/copilot"))
                    self.assertEqual(actual["env"]["COPILOT_AUTO_UPDATE"], "false")
                if name == "code":
                    self.assertEqual(shell_path(actual["env"]["VSCODE_PORTABLE"]), shell_path(playground / "config/vscode"))
                    self.assertEqual(actual["args"][0], "--user-data-dir")
                    self.assertEqual(actual["args"][2], "--extensions-dir")
                    self.assertEqual(shell_path(actual["args"][1]), shell_path(playground / "config/vscode/user-data"))
                    self.assertEqual(shell_path(actual["args"][3]), shell_path(playground / "config/vscode/extensions"))
                if name == "yazi":
                    self.assertEqual(shell_path(actual["env"]["YAZI_CONFIG_HOME"]),
                                     shell_path(playground / "config/yazi"))

    def test_rustifiedgit_launcher_selects_its_config_and_preserves_arguments(self):
        with tempfile.TemporaryDirectory(prefix=".check-rustifiedgit-launcher-", dir=ROOT) as directory:
            playground = Path(directory) / "play ground's"
            user = Path(directory) / "user"
            executable(playground / "install/rustifiedgit/bin/rustifiedgit",
                       '#!/bin/sh\nprintf "%s\\n" "$@"\n')
            script = '''
set -eu
die() { printf '%s' "$*" >&2; exit 1; }
PD_ROOT=$1
mkdir -p "$PD_ROOT/bin"
. "$2/lib/environment.sh"
pd_write_environment
pd_write_launcher rustifiedgit "$PD_ROOT/install/rustifiedgit/bin/rustifiedgit"
'''
            subprocess.run([BASH, "-c", script, "check", shell_path(playground), shell_path(ROOT)], check=True)
            argument = "repo's directory; $(must-not-run)"
            output = subprocess.check_output(launcher_command(playground / "bin/rustifiedgit", "-p", argument), text=True)
            self.assertEqual(output.splitlines(), ["--use-config-dir", shell_path(playground / "config/rustifiedgit"), "-p", argument])

    def test_extra_activation_keeps_existing_commands_first_and_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix=".check-extra-activation-", dir=ROOT) as directory:
            base = Path(directory)
            playground = base / "play ground's"
            existing = base / "existing"
            executable(existing / "yazi", "#!/bin/sh\nexit 0\n")
            executable(playground / "bin/yazi", "#!/bin/sh\nexit 0\n")
            executable(playground / "bin/terminal-extra-fixture", "#!/bin/sh\nexit 0\n")
            generate = 'set -eu; PD_ROOT=$1; . "$2/lib/environment.sh"; pd_write_environment'
            subprocess.run([BASH, "-c", generate, "check", shell_path(playground), shell_path(ROOT)], check=True)
            probe = '. "$1"; . "$1"; command -v yazi; command -v terminal-extra-fixture; printf "%s\\n" "$PATH"'
            environment = dict(os.environ, PATH=str(existing) + os.pathsep + str(playground / "bin") + os.pathsep + os.environ["PATH"])
            shells = {BASH, "/bin/bash"}
            if shutil.which("zsh"):
                shells.add(shutil.which("zsh"))
            for shell in shells:
                if not Path(shell).is_file():
                    continue
                result = subprocess.check_output([shell, "-c", probe, "check", shell_path(playground / "config/shell/env-extra.sh")],
                                                 env=environment, text=True).splitlines()
                self.assertEqual(result[0], shell_path(existing / "yazi"))
                self.assertEqual(result[1], shell_path(playground / "bin/terminal-extra-fixture"))
                entries = result[2].split(":")
                self.assertEqual(entries[-1], shell_path(playground / "bin"))
                self.assertEqual(entries.count(shell_path(playground / "bin")), 1)
            powershell = shutil.which("pwsh")
            if powershell:
                subprocess.run([powershell, "-NoProfile", "-File", str(ROOT / "tests/check-activation.ps1"),
                                "-ActivationFile", str(playground / "config/shell/env-extra.ps1"),
                                "-ExpectedDirectory", str(playground / "bin")], check=True)

    @unittest.skipUnless(shutil.which("tmux"), "tmux is unavailable")
    def test_tmux_template_keeps_system_shell_unless_managed_bash_exists(self):
        with tempfile.TemporaryDirectory(prefix=".check-tmux-shell-", dir=ROOT) as directory:
            playground = Path(directory) / "root space's"
            generate = 'set -eu; PD_ROOT=$1; . "$2/lib/environment.sh"; pd_write_environment'
            subprocess.run([BASH, "-c", generate, "check", shell_path(playground), shell_path(ROOT)], check=True)
            environment = dict(os.environ, PD_PLAYGROUND_ROOT=shell_path(playground),
                               HOME=shell_path(playground / "state/home"), BASH_ENV="", ENV="")
            environment.pop("TMUX", None)
            for managed_bash in (False, True):
                with self.subTest(managed_bash=managed_bash):
                    if managed_bash:
                        executable(playground / "bin/bash", "#!/bin/sh\nexec " + shlex.quote(shell_path(BASH)) + ' "$@"\n')
                    command = [shutil.which("tmux"), "-S", str(Path(directory) / ("s1" if managed_bash else "s0"))]
                    try:
                        subprocess.run([*command, "-f", os.devnull, "new-session", "-d", "-s", "fixture", "sleep 60"],
                                       env=environment, check=True, capture_output=True, text=True, timeout=10)
                        baseline = subprocess.check_output([*command, "show-options", "-gqv", "default-shell"],
                                                           env=environment, text=True, timeout=10).strip()
                        subprocess.run([*command, "source-file", str(playground / "config/tmux/tmux.conf")],
                                       env=environment, check=True, capture_output=True, text=True, timeout=10)
                        chosen = subprocess.check_output([*command, "show-options", "-gqv", "default-shell"],
                                                         env=environment, text=True, timeout=10).strip()
                        self.assertEqual(chosen, shell_path(playground / "bin/bash") if managed_bash else baseline)
                    finally:
                        subprocess.run([*command, "kill-server"], env=environment,
                                       capture_output=True, timeout=10)

    @unittest.skipUnless(shutil.which("lua") or shutil.which("luajit"), "Lua runtime is unavailable")
    def test_wezterm_template_uses_default_shell_unless_managed_bash_exists(self):
        with tempfile.TemporaryDirectory(prefix=".check-wezterm-shell-", dir=ROOT) as directory:
            playground = Path(directory) / "root space's"
            config_file = playground / "config/wezterm/wezterm.lua"
            config_file.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / "wezterm.lua", config_file)
            probe = Path(directory) / "probe.lua"
            probe.write_text("""
package.preload.wezterm = function()
  return {
    config_file = arg[1],
    target_triple = 'x86_64-unknown-linux-gnu',
    font = function(name) return name end,
  }
end
local config = dofile(arg[1])
assert(config.default_cwd == arg[2])
if arg[3] == 'managed' then
  assert(config.default_prog[1] == arg[2] .. '/bin/bash')
  assert(config.default_prog[2] == '-i')
else
  assert(config.default_prog == nil)
end
""")
            for managed_bash in (False, True):
                with self.subTest(managed_bash=managed_bash):
                    if managed_bash:
                        executable(playground / "bin/bash", "#!/bin/sh\nexit 0\n")
                    subprocess.run([shutil.which("lua") or shutil.which("luajit"), str(probe),
                                    config_file.as_posix(), playground.as_posix(),
                                    "managed" if managed_bash else "default"],
                                   check=True, capture_output=True, text=True, timeout=10)

    def test_folder_relocation_preserves_templates_activation_and_launcher_arguments(self):
        with tempfile.TemporaryDirectory(prefix=".check-relocation-", dir=ROOT) as directory:
            base = Path(directory)
            playground = base / "original root's"
            moved = base / "moved root's"
            existing = base / "existing"
            executable(existing / "codex", "#!/bin/sh\nexit 0\n")
            executable(playground / "bin/terminal-relocation-fixture", "#!/bin/sh\nexit 0\n")
            executable(playground / "install/fixture/bin/codex",
                       '#!/bin/sh\nprintf "%s\\n" "$CODEX_HOME" "$@"\n')
            executable(playground / "install/fixture/bin/bash",
                       "#!/bin/sh\nexec " + shlex.quote(shell_path(BASH)) + ' "$@"\n')
            executable(playground / "install/fixture/bin/git",
                       '#!/bin/sh\nprintf "%s\\n" "${HOME-}" "${XDG_CONFIG_HOME-}" "${GIT_CONFIG_GLOBAL-}" "$@"\n')
            executable(playground / "lib/relocate.sh",
                       '#!/bin/bash\nprintf "%s\\n" "$1" >> "$1/state/relocations"\n')
            generate = """
set -eu
die() { printf '%s\\n' "$*" >&2; exit 1; }
PD_ROOT=$1
PD_OS=macos
. "$2/lib/environment.sh"
pd_write_environment
for name in codex bash git; do pd_write_launcher "$name" "$PD_ROOT/install/fixture/bin/$name"; done
"""
            subprocess.run([BASH, "-c", generate, "check", shell_path(playground), shell_path(ROOT)], check=True)
            template = playground / "templates/yazi/yazi.toml"
            template.write_text(template.read_text() + "\n# customized template\n")
            yazi_config = playground / "config/yazi/yazi.toml"
            yazi_config.unlink()
            wezterm_config = playground / "config/wezterm/wezterm.lua"
            wezterm_config.write_text(wezterm_config.read_text() + "\n-- customized config\n")
            bashrc = playground / "config/bash/bashrc"
            bashrc.write_text(bashrc.read_text() + "\n# customized bashrc\n")
            before = {path.relative_to(playground): path.read_bytes()
                      for path in (template, wezterm_config, bashrc)}
            subprocess.run([BASH, "-c", generate, "check", shell_path(playground), shell_path(ROOT)], check=True)
            self.assertIn("# customized template", yazi_config.read_text())
            for relative, content in before.items():
                self.assertEqual((playground / relative).read_bytes(), content)
            self.assertFalse((playground / "config/git").exists())
            for relative in ("activate.sh", "config/shell/env.sh", "config/shell/env-extra.sh",
                             "config/shell/env-extra.ps1", "config/shell/env.fish",
                             "config/bash/bashrc", "config/tmux/tmux.conf", "bin/codex"):
                self.assertNotIn(shell_path(playground), (playground / relative).read_text())
            shutil.move(str(playground), str(moved))
            for relative, content in before.items():
                self.assertEqual((moved / relative).read_bytes(), content)
            argument = 'file\'s name "double quote"; $(must-not-run)'
            output = subprocess.check_output(launcher_command(moved / "bin/codex", argument), text=True)
            codex_home = (moved / "config/codex").as_posix() if os.name == "nt" else str(moved / "config/codex")
            self.assertEqual(output.splitlines(), [codex_home, argument])
            self.assertEqual((moved / "state/relocations").read_text().strip(), shell_path(moved))
            history = subprocess.check_output(launcher_command(moved / "bin/bash", "-c", 'printf "%s\\n" "$HISTFILE"'), text=True)
            self.assertEqual(history.strip(), shell_path(moved / "state/bash/history"))
            environment = dict(os.environ, HOME=shell_path(base / "user"),
                               XDG_CONFIG_HOME=shell_path(base / "user-config"),
                               GIT_CONFIG_GLOBAL=shell_path(base / "user-git"),
                               PD_PLAYGROUND_ROOT=shell_path(playground),
                               PATH=str(existing) + os.pathsep + os.environ["PATH"])
            output = subprocess.check_output(launcher_command(moved / "bin/git", argument),
                                             env=environment, text=True).splitlines()
            self.assertEqual(output, [environment["HOME"], environment["XDG_CONFIG_HOME"],
                                      environment["GIT_CONFIG_GLOBAL"], argument])
            probe = """
. "$1" || exit
. "$1" || exit
command -v codex
command -v terminal-relocation-fixture
printf '%s\\n' "$PD_PLAYGROUND_ROOT" "$HOME" "$XDG_CONFIG_HOME" "$GIT_CONFIG_GLOBAL"
"""
            shells = {BASH}
            if shutil.which("zsh"):
                shells.add(shutil.which("zsh"))
            for shell in shells:
                for relative in ("activate.sh", "config/shell/env-extra.sh"):
                    output = subprocess.check_output(
                        [shell, "-c", probe, "check", shell_path(moved / relative)],
                        env=environment, text=True).splitlines()
                    self.assertEqual(output, [shell_path(existing / "codex"),
                                              shell_path(moved / "bin/terminal-relocation-fixture"), shell_path(moved),
                                              environment["HOME"], environment["XDG_CONFIG_HOME"],
                                              environment["GIT_CONFIG_GLOBAL"]])
            powershell = shutil.which("pwsh") or shutil.which("powershell")
            if powershell:
                subprocess.run([powershell, "-NoProfile", "-File", str(ROOT / "tests/check-activation.ps1"),
                                "-ActivationFile", str(moved / "config/shell/env-extra.ps1"),
                                "-ExpectedDirectory", str(moved / "bin")], check=True)
            executable(moved / "lib/relocate.sh", "#!/bin/bash\nexit 23\n")
            failed = subprocess.run(launcher_command(moved / "bin/codex", argument),
                                    capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(failed.stdout, "")

    def test_posix_activation_requires_an_explicit_resolvable_root(self):
        with tempfile.TemporaryDirectory(prefix=".check-posix-", dir=ROOT) as directory:
            playground = Path(directory) / "root space's"
            generate = 'PD_ROOT=$1; . "$2/lib/environment.sh"; pd_write_environment'
            subprocess.run([BASH, "-c", generate, "check", shell_path(playground), shell_path(ROOT)], check=True)
            posix = shutil.which("dash")
            prefix = "" if posix else "unset BASH_VERSION ZSH_VERSION; "
            shell = [posix] if posix else [BASH, "--posix"]
            source = prefix + '. "$1"'
            for root in ("", shell_path(playground / "missing")):
                result = subprocess.run([*shell, "-c", source, "check",
                                         shell_path(playground / "config/shell/env-extra.sh")],
                                        env=dict(os.environ, PD_PLAYGROUND_ROOT=root), capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("terminal-setup:", result.stderr)
            output = subprocess.check_output(
                [*shell, "-c", source + '; printf "%s\\n" "$PD_PLAYGROUND_ROOT"', "check",
                 shell_path(playground / "config/shell/env-extra.sh")],
                env=dict(os.environ, PD_PLAYGROUND_ROOT=shell_path(playground)), text=True)
            self.assertEqual(output.strip(), shell_path(playground))

    def test_windows_shell_launchers_relocate_private_msys2_but_keep_external_msys2(self):
        with tempfile.TemporaryDirectory(prefix=".check-msys-relocation-", dir=ROOT) as directory:
            base = Path(directory)
            for external in (False, True):
                with self.subTest(external=external):
                    playground = base / ("external tools root" if external else "private tools root")
                    moved = base / ("moved external tools root" if external else "moved private tools root")
                    msys2 = base / "reused-msys2" if external else playground / "install/msys2"
                    executable(msys2 / "usr/bin/fixture.exe",
                               '#!/bin/sh\nprintf "%s\\n" "$PD_PLAYGROUND_MSYS2_ROOT" "$@"\n')
                    generate = """
set -eu
die() { printf '%s\\n' "$*" >&2; exit 1; }
PD_ROOT=$1
PD_MSYS2_ROOT=$2
PD_OS=windows
if ! command -v cygpath >/dev/null 2>&1; then cygpath() { printf '%s\\n' "$2"; }; fi
. "$3/lib/environment.sh"
pd_write_environment
pd_write_launcher fixture "$PD_MSYS2_ROOT/usr/bin/fixture.exe"
"""
                    subprocess.run([BASH, "-c", generate, "check", shell_path(playground),
                                    shell_path(msys2), shell_path(ROOT)], check=True)
                    marker = (playground / "config/path/msys2-root.txt").read_text().strip()
                    expected = (msys2.as_posix() if os.name == "nt" else str(msys2)) if external else "install/msys2"
                    self.assertEqual(marker, expected)
                    self.assertNotIn(shell_path(playground), (playground / "bin/fixture").read_text())
                    shutil.move(str(playground), str(moved))
                    output = subprocess.check_output(launcher_command(moved / "bin/fixture", "one argument"),
                                                     text=True).splitlines()
                    runtime = msys2 if external else moved / "install/msys2"
                    self.assertEqual(output, [shell_path(runtime), "one argument"])

    def test_rustifiedgit_build_cache_and_failed_update_keep_the_previous_binary(self):
        with tempfile.TemporaryDirectory(prefix="terminal-build-") as directory:
            base = Path(directory)
            playground = base / "playground"
            source = base / "source"
            source.mkdir()
            git = shutil.which("git")
            environment = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")

            def source_git(*args):
                return subprocess.check_output([git, "-C", str(source), *args], env=environment, text=True).strip()

            source_git("init", "-qb", "main")
            source_git("config", "user.name", "Installer Test")
            source_git("config", "user.email", "fixture@example.invalid")
            source_git("config", "commit.gpgsign", "false")
            source_git("config", "core.hooksPath", ".test-hooks")
            (source / "Cargo.toml").write_text("fixture")
            source_git("add", ".")
            source_git("commit", "-qm", "first")
            first = source_git("rev-parse", "HEAD")
            executable(playground / "install/rust/bin/rustc", "#!/bin/sh\nexit 0\n")
            executable(playground / "install/rust/bin/cargo", r'''#!/bin/sh
set -eu
printf '%s\n' "$*" "$CARGO_HOME" "$RUSTUP_HOME" "$RUSTC" >> "$PD_ROOT/state/build-calls"
[ "${PD_TEST_BUILD_FAIL:-0}" != 1 ] || exit 23
while [ "$1" != --target-dir ]; do shift; done
shift
mkdir -p "$1/release"
printf '#!/bin/sh\nprintf "rustifiedgit fixture\\n"\n' > "$1/release/rustifiedgit"
''')
            script = '''
set -eu
PD_ROOT=$1
PD_INSTALL="$PD_ROOT/install"
PD_TEMP="$PD_ROOT/tmp"
PD_REPO=$2
PD_REF=$3
PD_OS=macos
export PD_ROOT
mkdir -p "$PD_ROOT/state" "$PD_TEMP"
log() { :; }
die() { printf '%s' "$*" >&2; exit 1; }
fetch() { exit 91; }
. "$4/lib/rustifiedgit.sh"
install_rustifiedgit
'''

            def install(ref, fail=False):
                # Each real installation gets a fresh temporary source checkout.
                shutil.rmtree(playground / "tmp", ignore_errors=True)
                return subprocess.run([BASH, "-c", script, "check", shell_path(playground), shell_path(source),
                                       ref, shell_path(ROOT)],
                                      env=dict(environment, PD_TEST_BUILD_FAIL=str(int(fail))), capture_output=True, text=True)

            result = install(first)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            binary = playground / "install/rustifiedgit/bin/rustifiedgit"
            previous = binary.read_bytes()
            build_calls = playground / "state/build-calls"
            calls = build_calls.read_text()
            self.assertIn("build --release --locked --target-dir", calls)
            self.assertIn(shell_path(playground / "cache/cargo"), calls)
            self.assertIn(shell_path(playground / "install/rustup"), calls)
            for ref in (first, "main"):
                result = install(ref)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(build_calls.read_text(), calls)
            (source / "Cargo.toml").write_text("updated fixture")
            source_git("commit", "-qam", "second")
            result = install("main", fail=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(binary.read_bytes(), previous)
            self.assertEqual((playground / "state/rustifiedgit.commit").read_text().strip(), first)

    def test_codex_packages_are_moved_into_install_and_relinked(self):
        if os.name == "nt":
            self.skipTest("Git Bash does not model Unix directory symlink semantics.")
        with tempfile.TemporaryDirectory(prefix="pd-check-") as directory:
            playground = Path(directory) / "playground"
            payload = playground / "config/codex/packages/standalone/payload"
            payload.parent.mkdir(parents=True)
            payload.write_text("existing package")
            script = '''
set -eu
die() { printf '%s' "$*" >&2; exit 1; }
PD_ROOT=$1
. "$2/lib/environment.sh"
pd_codex_packages
pd_codex_packages
'''
            subprocess.run([BASH, "-c", script, "check", shell_path(playground), shell_path(ROOT)], check=True)
            moved = playground / "install/codex/packages/standalone/payload"
            self.assertEqual(moved.read_text(), "existing package")
            self.assertEqual(payload.resolve(), moved.resolve())
            self.assertTrue((playground / "config/codex/packages").is_symlink())

    def test_full_flow_uses_only_rooted_fixture_installers(self):
        result = subprocess.run([BASH, str(ROOT / "tests/check-unix.sh")],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
