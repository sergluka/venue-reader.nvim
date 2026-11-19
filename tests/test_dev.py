"""Exercise the development entry point with real Git worktrees and Neovim."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
NVIM = shutil.which("nvim")


@unittest.skipUnless(
    NVIM and shutil.which("git") and shutil.which("make"),
    "Neovim, Git and make required",
)
class DevelopmentLauncher(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="venue reader dev ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repositories = self.root / "repos"
        self.workspaces = self.root / "workspaces"
        self.workspaces.mkdir()
        self.plugin = self.repositories / "venue-reader.nvim"
        (self.plugin / "scripts").mkdir(parents=True)
        shutil.copyfile(PROJECT / "scripts/dev.lua", self.plugin / "scripts/dev.lua")
        shutil.copyfile(PROJECT / "Makefile", self.plugin / "Makefile")
        self.git(self.plugin, "init", "-q", "-b", "main")
        self.git(self.plugin, "add", ".")
        self.git(
            self.plugin,
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "core.hooksPath=/dev/null",
            "commit",
            "-qm",
            "fixture",
        )
        self.server = self.make_server(self.repositories / "venue-reader")
        binary_directory = self.root / "bin"
        binary_directory.mkdir()
        self.report = self.root / "startup.json"
        self.build = self.root / "build.json"
        cargo = binary_directory / "cargo"
        cargo.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path(os.environ['TEST_BUILD']).write_text(json.dumps({'args': sys.argv[1:], 'cwd': os.getcwd()}))
print(json.dumps({'reason': 'compiler-artifact', 'target': {'name': 'venue-reader'},
                  'executable': str(pathlib.Path.cwd() / 'test-server')}))
""")
        cargo.chmod(0o755)
        self.neovim = binary_directory / "nvim"
        self.neovim.write_text(f'#!/bin/sh\nexec "{NVIM}" --headless -i NONE -n "$@"\n')
        self.neovim.chmod(0o755)
        config = self.root / "config" / "nvim"
        config.mkdir(parents=True)
        (config / "init.lua").write_text("""vim.fn.writefile({ vim.json.encode({
  plugin = vim.env.VENUE_READER_DEV_PLUGIN_DIR,
  server = vim.env.VENUE_READER_DEV_SERVER,
}) }, vim.env.TEST_REPORT)
vim.cmd("qa!")
""")
        self.environment = {
            name: value
            for name, value in os.environ.items()
            if not name.startswith(("VENUE_READER_", "GIT_", "NVIM_"))
        }
        self.environment.update(
            {
                "PATH": str(binary_directory) + os.pathsep + os.environ["PATH"],
                "XDG_CONFIG_HOME": str(self.root / "config"),
                "XDG_DATA_HOME": str(self.root / "data"),
                "XDG_STATE_HOME": str(self.root / "state"),
                "XDG_CACHE_HOME": str(self.root / "cache"),
                "TEST_REPORT": str(self.report),
                "TEST_BUILD": str(self.build),
            }
        )

    def git(self, directory, *arguments):
        return subprocess.run(
            ["git", "-C", str(directory), *arguments],
            check=True,
            capture_output=True,
            text=True,
        )

    def make_server(self, directory):
        directory.mkdir(parents=True)
        (directory / "Cargo.toml").write_text(
            '[package]\nname = "venue-reader"\nversion = "0.0.0"\n'
        )
        return directory

    def feature(self, name="plugin feature", detached=False):
        checkout = self.workspaces / name / "venue-reader.nvim"
        arguments = ["worktree", "add", "--quiet"]
        arguments.extend(["--detach"] if detached else ["-b", name.replace(" ", "-")])
        self.git(self.plugin, *arguments, str(checkout))
        return checkout

    def launch(self, plugin, cwd=None, override=None):
        environment = self.environment.copy()
        if cwd is None:
            command = ["make", "dev", "NVIM=" + str(self.neovim)]
            if override is not None:
                command.append("SERVER_DIR=" + str(override))
            cwd = plugin
        else:
            command = [str(self.neovim), "-u", str(plugin / "scripts/dev.lua")]
            if override is not None:
                environment["VENUE_READER_DEV_SERVER_DIR"] = str(override)
        return subprocess.run(
            command,
            check=False,
            cwd=cwd,
            env=environment,
            text=True,
            capture_output=True,
            timeout=15,
        )

    def assert_selected(self, result, plugin, server):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            json.loads(self.report.read_text()),
            {
                "plugin": str(plugin),
                "server": str(server / "test-server"),
            },
        )
        build = json.loads(self.build.read_text())
        self.assertEqual(build["cwd"], str(server))
        self.assertEqual(
            build["args"][build["args"].index("--manifest-path") + 1],
            str(server / "Cargo.toml"),
        )
        self.assertIn("Development plugin: " + str(plugin), result.stderr)
        self.assertIn("Building venue-reader in " + str(server), result.stderr)

    def assert_rejected(self, result, server):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cargo.toml not found in " + str(server), result.stderr)
        self.assertFalse(self.build.exists(), "invalid selection must not invoke Cargo")
        self.assertFalse(
            self.report.exists(), "invalid selection must not load personal init"
        )

    def test_main_checkout(self):
        self.assert_selected(self.launch(self.plugin), self.plugin, self.server)

    def test_plugin_only_uses_permanent_server(self):
        plugin = self.feature()
        self.assert_selected(self.launch(plugin), plugin, self.server)

    def test_paired_worktrees_use_feature_server(self):
        plugin = self.feature()
        server = self.make_server(plugin.parent / "venue-reader")
        self.assert_selected(self.launch(plugin), plugin, server)

    def test_detached_plugin_selects_by_directory(self):
        plugin = self.feature(detached=True)
        server = self.make_server(plugin.parent / "venue-reader")
        self.assert_selected(self.launch(plugin), plugin, server)

    def test_server_only_feature_uses_main_plugin(self):
        server = self.make_server(self.workspaces / "server only" / "venue-reader")
        self.assert_selected(self.launch(self.plugin, cwd=server), self.plugin, server)

    def test_current_feature_precedes_script_feature(self):
        plugin = self.feature()
        self.make_server(plugin.parent / "venue-reader")
        other = self.workspaces / "other feature"
        server = self.make_server(other / "venue-reader")
        cwd = other / "venue-reader.wiki" / "tools"
        cwd.mkdir(parents=True)
        self.assert_selected(self.launch(plugin, cwd=cwd), plugin, server)

    def test_current_feature_without_server_does_not_use_script_feature_server(self):
        plugin = self.feature()
        self.make_server(plugin.parent / "venue-reader")
        other = self.workspaces / "wiki only" / "venue-reader.wiki"
        other.mkdir(parents=True)
        self.assert_selected(self.launch(plugin, cwd=other), plugin, self.server)

    def test_outside_context_uses_script_feature(self):
        plugin = self.feature()
        server = self.make_server(plugin.parent / "venue-reader")
        self.assert_selected(self.launch(plugin, cwd=self.root), plugin, server)

    def test_explicit_override_precedes_feature(self):
        plugin = self.feature()
        self.make_server(plugin.parent / "venue-reader")
        server = self.make_server(self.root / "explicit server")
        self.assert_selected(self.launch(plugin, override=server), plugin, server)

    def test_invalid_explicit_override_does_not_fall_back(self):
        plugin = self.feature()
        server = self.root / "missing override"
        self.assert_rejected(self.launch(plugin, override=server), server)

    def test_invalid_feature_directory_does_not_fall_back(self):
        plugin = self.feature()
        server = plugin.parent / "venue-reader"
        server.mkdir()
        self.assert_rejected(self.launch(plugin), server)

    def test_dangling_feature_symlink_does_not_fall_back(self):
        plugin = self.feature()
        server = plugin.parent / "venue-reader"
        server.symlink_to(self.root / "missing target", target_is_directory=True)
        self.assert_rejected(self.launch(plugin), server)

    def test_missing_permanent_server_fails(self):
        self.server.rename(self.root / "removed server")
        self.assert_rejected(self.launch(self.feature()), self.server)

    def test_ordinary_adjacent_checkouts(self):
        self.plugin.rename(self.root / "venue-reader.nvim")
        plugin = self.root / "venue-reader.nvim"
        self.server.rename(self.root / "venue-reader")
        server = self.root / "venue-reader"
        self.assert_selected(self.launch(plugin), plugin, server)


if __name__ == "__main__":
    result = unittest.main(exit=False).result
    if os.environ.get("CI") == "true" and (result.testsRun == 0 or result.skipped):
        raise SystemExit("CI must execute every launcher test")
    raise SystemExit(0 if result.wasSuccessful() else 1)
