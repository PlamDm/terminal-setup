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


class PlaygroundChecks(unittest.TestCase):
    def test_shell_syntax(self):
        for shell in {BASH, "/bin/bash"}:
            if Path(shell).is_file():
                for script in ("install.sh", "lib/environment.sh", "lib/rustifiedgit.sh", "lib/portable.sh",
                               "lib/yazi.sh", "lib/msys2.sh", "lib/interactive.sh"):
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
            subprocess.run([BASH, "-c", script, "fixture", str(msys), str(ROOT)], check=True)
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
                     "--root", str(base / "must-not-exist")],
                    env=environment, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                for name in ("Codex", "btop", "fzf", "Copilot", "VS Code", "Nerd Font", "/install", "/config", "/bin"):
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

    def test_msys2_read_only_preview_is_windows_only(self):
        result = subprocess.run(
            [BASH, str(ROOT / "install.sh"), "--dry-run", "--platform", "windows", "--msys2-read-only"],
            capture_output=True, text=True, check=True,
        )
        self.assertIn("Use --msys2-read-only to use installed MSYS2 packages only", result.stdout)
        invalid = subprocess.run(
            [BASH, str(ROOT / "install.sh"), "--dry-run", "--platform", "linux", "--msys2-read-only"],
            capture_output=True, text=True,
        )
        self.assertNotEqual(invalid.returncode, 0)

    def test_manual_activation_preview_leaves_root_absent(self):
        with tempfile.TemporaryDirectory(prefix="terminal-preview-") as directory:
            target = Path(directory) / "not-installed"
            result = subprocess.run([BASH, str(ROOT / "install.sh"), "--dry-run", "--no-activate",
                                     "--root", str(target)], capture_output=True, text=True, check=True)
            self.assertIn("Leave profiles and persistent PATH unchanged", result.stdout)
            self.assertNotIn("Register " + str(target), result.stdout)
            self.assertFalse(target.exists())

    def test_default_is_source_only_and_registration_is_explicit(self):
        result = subprocess.check_output([BASH, str(ROOT / "install.sh"), "--dry-run"], text=True)
        self.assertIn("Leave profiles and persistent PATH unchanged", result)
        activated = subprocess.check_output([BASH, str(ROOT / "install.sh"), "--dry-run", "--activate"], text=True)
        self.assertIn("Register ", activated)

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

    def test_ai_editor_and_yazi_launchers_isolate_data_and_preserve_arguments(self):
        with tempfile.TemporaryDirectory(prefix="terminal-apps-") as directory:
            playground = Path(directory) / "tool root's"
            for name in ("copilot", "code", "yazi", "git"):
                executable(playground / "install/fixture" / name,
                    '#!' + sys.executable + '\nimport json,os,sys\nprint(json.dumps({"env":dict(os.environ),"args":sys.argv[1:]}))\n')
            generate = '''
set -eu
PD_ROOT=$1
PD_OS=macos
mkdir -p "$PD_ROOT/bin"
. "$2/lib/environment.sh"
pd_write_environment
for name in copilot code yazi git; do pd_write_launcher "$name" "$PD_ROOT/install/fixture/$name"; done
'''
            subprocess.run([BASH, "-c", generate, "check", str(playground), str(ROOT)], check=True)
            argument = "file's name; $(must-not-run).txt"
            for name in ("copilot", "code", "yazi", "git"):
                actual = json.loads(subprocess.check_output([str(playground / "bin" / name), argument], text=True))
                self.assertEqual(actual["args"][-1], argument)
                for variable, relative in (("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"),
                    ("XDG_STATE_HOME", "state"), ("TMPDIR", "tmp"), ("GIT_CONFIG_GLOBAL", "config/git/config")):
                    self.assertEqual(actual["env"][variable], str(playground / relative))
                if name == "copilot":
                    self.assertEqual(actual["env"]["COPILOT_HOME"], str(playground / "config/copilot"))
                    self.assertEqual(actual["env"]["COPILOT_CACHE_HOME"], str(playground / "cache/copilot"))
                    self.assertEqual(actual["env"]["COPILOT_AUTO_UPDATE"], "false")
                if name == "code":
                    self.assertEqual(actual["env"]["VSCODE_PORTABLE"], str(playground / "config/vscode"))
                    self.assertEqual(actual["args"][:-1], ["--user-data-dir", str(playground / "config/vscode/user-data"),
                        "--extensions-dir", str(playground / "config/vscode/extensions")])
                if name == "yazi":
                    self.assertEqual(actual["env"]["YAZI_CONFIG_HOME"], str(playground / "config/yazi"))

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

    def test_extra_activation_keeps_existing_commands_first_and_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix="terminal-extra-") as directory:
            base = Path(directory)
            playground = base / "play ground's"
            existing = base / "existing"
            executable(existing / "yazi", "#!/bin/sh\nexit 0\n")
            executable(playground / "bin/yazi", "#!/bin/sh\nexit 0\n")
            executable(playground / "bin/terminal-extra-fixture", "#!/bin/sh\nexit 0\n")
            generate = 'set -eu; PD_ROOT=$1; . "$2/lib/environment.sh"; pd_write_environment'
            subprocess.run([BASH, "-c", generate, "check", str(playground), str(ROOT)], check=True)
            probe = '. "$1"; . "$1"; command -v yazi; command -v terminal-extra-fixture; printf "%s\\n" "$PATH"'
            environment = dict(os.environ, PATH=str(existing) + os.pathsep + str(playground / "bin") + os.pathsep + os.environ["PATH"])
            shells = {BASH, "/bin/bash"}
            if shutil.which("zsh"):
                shells.add(shutil.which("zsh"))
            for shell in shells:
                result = subprocess.check_output([shell, "-c", probe, "check", str(playground / "config/shell/env-extra.sh")],
                                                 env=environment, text=True).splitlines()
                self.assertEqual(result[0], str(existing / "yazi"))
                self.assertEqual(result[1], str(playground / "bin/terminal-extra-fixture"))
                entries = result[2].split(os.pathsep)
                self.assertEqual(entries[-1], str(playground / "bin"))
                self.assertEqual(entries.count(str(playground / "bin")), 1)
            powershell = shutil.which("pwsh")
            if powershell:
                subprocess.run([powershell, "-NoProfile", "-File", str(ROOT / "tests/check-activation.ps1"),
                                "-ActivationFile", str(playground / "config/shell/env-extra.ps1"),
                                "-ExpectedDirectory", str(playground / "bin")], check=True)

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
for name in bash tmux yazi ya git file btop fzf ffmpeg ffprobe 7zz pdftoppm pdftotext pdfinfo fd rg zoxide resvg magick; do
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
            executable(fixtures / "uname", '#!/bin/sh\nif [ "$1" = -m ]; then echo arm64; else echo Darwin; fi\n')
            # Real archives and published hashes exercise extraction and integrity
            # handling without network access or a desktop application install.
            artifacts = base / "artifacts"
            artifacts.mkdir()
            copilot = artifacts / "copilot"
            executable(copilot, '#!/bin/sh\nprintf "copilot fixture\\n"\n')
            copilot_archive = artifacts / "copilot-darwin-arm64.tar.gz"
            with tarfile.open(copilot_archive, "w:gz") as archive:
                archive.add(copilot, arcname="copilot")
            font = artifacts / "fixture.ttf"
            font.write_text("fixture font")
            font_archive = artifacts / "JetBrainsMono.tar.xz"
            with tarfile.open(font_archive, "w:xz") as archive:
                archive.add(font, arcname="fixture.ttf")
            code = artifacts / "code"
            executable(code, '#!/bin/sh\nprintf "code fixture\\n"\n')
            code_archive = artifacts / "vscode.zip"
            with zipfile.ZipFile(code_archive, "w") as archive:
                archive.write(code, "Visual Studio Code.app/Contents/Resources/app/bin/code")
            downloads = {}
            for repo, asset in (("github/copilot-cli", copilot_archive), ("ryanoasis/nerd-fonts", font_archive)):
                url = "https://fixture.invalid/" + asset.name
                metadata = artifacts / (asset.name + ".json")
                metadata.write_text(json.dumps({"assets": [{"name": asset.name, "browser_download_url": url,
                    "digest": "sha256:" + hashlib.sha256(asset.read_bytes()).hexdigest()}]}))
                downloads["https://api.github.com/repos/" + repo + "/releases/latest"] = str(metadata)
                downloads[url] = str(asset)
            vscode_metadata = artifacts / "vscode.json"
            vscode_metadata.write_text(json.dumps({"version": "a" * 40, "url": "https://fixture.invalid/vscode.zip",
                "sha256hash": hashlib.sha256(code_archive.read_bytes()).hexdigest()}))
            downloads["https://update.code.visualstudio.com/api/update/darwin-arm64/stable/latest"] = str(vscode_metadata)
            downloads["https://fixture.invalid/vscode.zip"] = str(code_archive)
            downloads["https://chatgpt.com/codex/install.sh"] = str(base / "codex-installer.stub")
            curl_source = '#!' + sys.executable + '\nimport sys,shutil\nroutes=' + repr(downloads) + '\n'
            curl_source += 'url=next(a for a in sys.argv[1:] if a.startswith("https://"))\nshutil.copyfile(routes[url],sys.argv[-1])\n'
            executable(fixtures / "curl", curl_source)
            jq = shutil.which("jq")
            self.assertIsNotNone(jq, "jq is required for the portable archive fixture test")
            executable(playground / "install/homebrew/bin/jq", '#!/bin/sh\nexec ' + shlex.quote(jq) + ' "$@"\n')
            codex_stub = base / "codex-installer.stub"
            executable(codex_stub, r"""#!/bin/sh
case ":$PATH:" in
  *":$CODEX_INSTALL_DIR:"*) ;;
  *) printf '# delegated installer PATH hook\n' >> "$PD_USER_HOME/.zshrc" ;;
esac
existing="$(command -v codex || true)"
if [ -n "$existing" ] && [ "$existing" != "$CODEX_INSTALL_DIR/codex" ]; then
  printf '# delegated conflict PATH hook\n' >> "$PD_USER_HOME/.zshrc"
fi
mkdir -p "$CODEX_INSTALL_DIR"
printf '#!/bin/sh\nprintf "codex-cli fixture\\n"\n' > "$CODEX_INSTALL_DIR/codex"
chmod +x "$CODEX_INSTALL_DIR/codex"
""")
            environment = dict(
                os.environ, PATH=str(fixtures) + os.pathsep + os.defpath,
                PD_USER_HOME=str(user), XDG_CONFIG_HOME=str(user / ".config"),
                PD_SKIP_DESKTOP_PATH="1", PD_FIXTURE_CODEX_INSTALLER=str(codex_stub),
            )
            for _ in range(2):
                result = subprocess.run(
                    [BASH, str(ROOT / "install.sh"), "--activate", "--root", str(playground)],
                    env=environment, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(sentinel.read_text(), "keep my project\n")
            content = (user / ".zshrc").read_text()
            self.assertIn("# existing customization", content)
            self.assertEqual(content.count("# >>> pd-playground PATH >>>"), 1)
            for name in ("bash", "tmux", "yazi", "rustifiedgit", "codex", "btop", "fzf", "wezterm", "copilot", "code", "rg", "fd", "7zz", "ffmpeg", "pdftoppm"):
                self.assertTrue(os.access(playground / "bin" / name, os.X_OK), name)
            calls = (playground / "state/brew-calls").read_text()
            self.assertIn("install bash tmux yazi git file btop fzf", calls)
            self.assertIn("--appdir=" + str(playground / "install/apps"), calls)
            self.assertEqual((playground / "config/codex/packages").resolve(),
                             (playground / "install/codex/packages").resolve())
            self.assertEqual((playground / ("install/vscode/" + "a" * 40 + "/code-portable-data")).resolve(), (playground / "config/vscode").resolve())
            yazi_config = playground / "config/yazi/yazi.toml"
            self.assertIn("rustifiedgit-file", yazi_config.read_text())
            yazi_config.write_text(yazi_config.read_text() + "\n# keep my customization\n")
            # A PC with an existing terminal can install without any home hooks.
            manual_user = base / "manual-user"
            manual_user.mkdir()
            existing_profile = manual_user / ".zshrc"
            existing_profile.write_bytes(b"# keep this profile exactly\n")
            before = {str(path.relative_to(manual_user)): path.read_bytes()
                      for path in manual_user.rglob("*") if path.is_file()}
            result = subprocess.run(
                [BASH, str(ROOT / "install.sh"), "--no-activate", "--root", str(playground)],
                env=dict(environment, PD_USER_HOME=str(manual_user), XDG_CONFIG_HOME=str(manual_user / ".config")),
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            after = {str(path.relative_to(manual_user)): path.read_bytes()
                     for path in manual_user.rglob("*") if path.is_file()}
            self.assertEqual(after, before)
            self.assertFalse((manual_user / ".config").exists())
            self.assertIn("env-extra.sh", result.stdout)
            for name in ("env-extra.sh", "env-extra.fish", "env-extra.ps1"):
                self.assertTrue((playground / "config/shell" / name).is_file())
            self.assertIn("# keep my customization", yazi_config.read_text())
            existing_bin = base / "existing-codex"
            executable(existing_bin / "codex", "#!/usr/bin/env node\n// existing installation\n")
            existing_codex_before = (existing_bin / "codex").read_bytes()
            result = subprocess.run(
                [BASH, str(ROOT / "install.sh"), "--no-activate", "--root", str(playground)],
                env=dict(environment, PD_USER_HOME=str(manual_user),
                         XDG_CONFIG_HOME=str(manual_user / ".config"),
                         PATH=str(existing_bin) + os.pathsep + environment["PATH"]),
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((existing_bin / "codex").read_bytes(), existing_codex_before)
            self.assertEqual(existing_profile.read_bytes(), before[".zshrc"])
            # Fresh managed Codex coexists with an existing npm command, with no
            # delegated profile hook and no modification of the existing CLI.
            fresh_root = base / "fresh-root"
            result = subprocess.run([BASH, str(ROOT / "install.sh"), "--only-codex", "--root", str(fresh_root)],
                env=dict(environment, PD_USER_HOME=str(manual_user), PATH=str(existing_bin) + os.pathsep + environment["PATH"]),
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((fresh_root / "bin/codex").is_file())
            self.assertEqual(existing_profile.read_bytes(), before[".zshrc"])
            # A corrupt portable download must fail instead of installing it.
            copilot_archive.write_bytes(b"corrupt archive")
            result = subprocess.run([BASH, str(ROOT / "install.sh"), "--root", str(playground)],
                                    env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("SHA-256 verification failed", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
