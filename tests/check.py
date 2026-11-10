#!/usr/bin/env python3
"""Offline checks. Full-flow checks use fixture executables, never real installers."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("TEST_BASH") or shutil.which("bash") or "/bin/bash"


def executable(path, source):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source)
    path.chmod(0o755)


class PlaygroundChecks(unittest.TestCase):
    def test_shell_syntax(self):
        for shell in {BASH, "/bin/bash"}:
            if Path(shell).is_file():
                for script in ("install.sh", "lib/environment.sh", "lib/rustifiedgit.sh"):
                    subprocess.run([shell, "-n", str(ROOT / script)], check=True)

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
                    [BASH, str(ROOT / "install.sh"), "--dry-run", "--platform", platform,
                     "--root", str(base / "must-not-exist")],
                    env=environment, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                for name in ("Codex", "btop", "fzf", "/install", "/config", "/bin"):
                    self.assertIn(name, result.stdout)
                self.assertIn("PlamDm/RustifiedGit.git", result.stdout)
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
        with tempfile.TemporaryDirectory(prefix="pd-check-") as directory:
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
            environment = dict(os.environ, XDG_CONFIG_HOME=str(user / ".config"))
            subprocess.run([BASH, "-c", script, "check", str(playground), str(user), str(ROOT)],
                           env=environment, check=True)
            for name in (".bashrc", ".bash_profile", ".profile", ".zshrc", ".zprofile"):
                content = (user / name).read_text()
                self.assertEqual(content.count("# >>> pd-playground PATH >>>"), 1)
            argument = "one argument; $(must-not-run)"
            result = subprocess.run([str(playground / "bin/codex"), argument],
                                    env=environment, check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout.splitlines(),
                             [str(playground / "config/codex"), argument])
            if shutil.which("zsh"):
                probe = '. ' + shlex.quote(str(playground / "config/shell/env.sh")) + '; command -v codex'
                result = subprocess.run(["zsh", "-f", "-c", probe],
                                        check=True, capture_output=True, text=True)
                self.assertEqual(result.stdout.strip(), str(playground / "bin/codex"))

    def test_refuses_launcher_target_outside_playground(self):
        with tempfile.TemporaryDirectory(prefix="pd-check-") as directory:
            script = 'die() { exit 9; }; PD_ROOT=$1; . "$2/lib/environment.sh"; pd_write_launcher codex /usr/bin/codex'
            result = subprocess.run([BASH, "-c", script, "check", directory, str(ROOT)])
            self.assertEqual(result.returncode, 9)

    def test_rustifiedgit_launcher_selects_its_config_and_preserves_arguments(self):
        with tempfile.TemporaryDirectory(prefix="terminal-launcher-") as directory:
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
            subprocess.run([BASH, "-c", script, "check", str(playground), str(ROOT)], check=True)
            argument = "repo's directory; $(must-not-run)"
            output = subprocess.check_output([str(playground / "bin/rustifiedgit"), "-p", argument], text=True)
            self.assertEqual(output.splitlines(), ["--use-config-dir", str(playground / "config/rustifiedgit"), "-p", argument])

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
                return subprocess.run([BASH, "-c", script, "check", str(playground), str(source), ref, str(ROOT)],
                                      env=dict(environment, PD_TEST_BUILD_FAIL=str(int(fail))), capture_output=True, text=True)

            result = install(first)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            binary = playground / "install/rustifiedgit/bin/rustifiedgit"
            previous = binary.read_bytes()
            build_calls = playground / "state/build-calls"
            calls = build_calls.read_text()
            self.assertIn("build --release --locked --target-dir", calls)
            self.assertIn(str(playground / "cache/cargo"), calls)
            self.assertIn(str(playground / "install/rustup"), calls)
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
            subprocess.run([BASH, "-c", script, "check", str(playground), str(ROOT)], check=True)
            moved = playground / "install/codex/packages/standalone/payload"
            self.assertEqual(moved.read_text(), "existing package")
            self.assertEqual(payload.resolve(), moved.resolve())
            self.assertTrue((playground / "config/codex/packages").is_symlink())

    def test_full_flow_uses_only_rooted_fixture_installers(self):
        with tempfile.TemporaryDirectory(prefix="pd-check-") as directory:
            base = Path(directory)
            playground = base / "playground"
            user = base / "user"
            fixtures = base / "fixtures"
            fixtures.mkdir()
            (playground / "Projects").mkdir(parents=True)
            sentinel = playground / "Projects/keep.txt"
            sentinel.write_text("keep my project\n")
            (user / ".config").mkdir(parents=True)
            (user / ".zshrc").write_text("# existing customization\n")
            (playground / "state").mkdir()
            (playground / "state/rustifiedgit.commit").write_text(
                "7a2be2ebfa45cfc5be78e788a820ee145953f36b\n")
            executable(playground / "install/rustifiedgit/bin/rustifiedgit", "#!/bin/sh\nexit 0\n")
            fake_brew = r"""#!/bin/sh
prefix="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
root="$(CDPATH= cd -- "$prefix/../.." && pwd)"
if [ "$1" = --prefix ]; then printf '%s\n' "$prefix"; exit 0; fi
printf '%s\n' "$*" >> "$root/state/brew-calls"
for name in bash tmux yazi ya git file btop fzf; do
  printf '#!/bin/sh\nexit 0\n' > "$prefix/bin/$name"
  chmod +x "$prefix/bin/$name"
done
app="$root/install/apps/WezTerm.app/Contents/MacOS"
mkdir -p "$app"
printf '#!/bin/sh\nexit 0\n' > "$app/wezterm"
chmod +x "$app/wezterm"
"""
            executable(playground / "install/homebrew/bin/brew", fake_brew)
            executable(fixtures / "brew", "#!/bin/sh\nexit 91\n")
            executable(fixtures / "git", "#!/bin/sh\nexit 92\n")
            executable(fixtures / "uname", "#!/bin/sh\nprintf 'Darwin\\n'\n")
            executable(fixtures / "curl", """#!/bin/sh
for value do destination="$value"; done
cp "$PD_FIXTURE_CODEX_INSTALLER" "$destination"
""")
            codex_stub = base / "codex-installer.stub"
            executable(codex_stub, r"""#!/bin/sh
mkdir -p "$CODEX_INSTALL_DIR"
printf '#!/bin/sh\nprintf "codex-cli fixture\\n"\n' > "$CODEX_INSTALL_DIR/codex"
chmod +x "$CODEX_INSTALL_DIR/codex"
""")
            environment = dict(
                os.environ, PATH=str(fixtures) + os.pathsep + os.environ["PATH"],
                PD_USER_HOME=str(user), XDG_CONFIG_HOME=str(user / ".config"),
                PD_SKIP_DESKTOP_PATH="1", PD_FIXTURE_CODEX_INSTALLER=str(codex_stub),
            )
            for _ in range(2):
                result = subprocess.run(
                    [BASH, str(ROOT / "install.sh"), "--root", str(playground)],
                    env=environment, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(sentinel.read_text(), "keep my project\n")
            content = (user / ".zshrc").read_text()
            self.assertIn("# existing customization", content)
            self.assertEqual(content.count("# >>> pd-playground PATH >>>"), 1)
            for name in ("bash", "tmux", "yazi", "rustifiedgit", "codex", "btop", "fzf", "wezterm"):
                self.assertTrue(os.access(playground / "bin" / name, os.X_OK), name)
            calls = (playground / "state/brew-calls").read_text()
            self.assertIn("install bash tmux yazi git file btop fzf", calls)
            self.assertIn("--appdir=" + str(playground / "install/apps"), calls)
            self.assertEqual((playground / "config/codex/packages").resolve(),
                             (playground / "install/codex/packages").resolve())


if __name__ == "__main__":
    unittest.main(verbosity=2)
