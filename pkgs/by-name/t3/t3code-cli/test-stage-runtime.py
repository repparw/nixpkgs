#!/usr/bin/env python3
"""Exercise scoped pnpm modules, dependency contexts, cycles, and pruning."""
from importlib.machinery import SourceFileLoader
import json
from pathlib import Path
import tempfile
import unittest


Stager = SourceFileLoader(
    "stage_runtime", str(Path(__file__).with_name("stage-runtime.py"))
).load_module().RuntimeStager


class RuntimeStagerTest(unittest.TestCase):
    def test_preserves_dependency_contexts_and_omits_unrelated_packages(self):
        with tempfile.TemporaryDirectory() as work:
            source, output = Path(work) / "source", Path(work) / "output"
            store = source / "node_modules/.pnpm"

            def package(key, name, dependencies=None):
                directory = store / key / "node_modules" / name
                directory.mkdir(parents=True)
                (directory / "package.json").write_text(
                    json.dumps({"name": name, "dependencies": dependencies or {}})
                )
                (directory / "index.js").write_text("module.exports = 1;\n")
                return directory

            root = package("@cursor+sdk@1", "@cursor/sdk", {"dep": "^1"})
            dep1 = package("dep@1", "dep", {"loop": "1"})
            native = package("@cursor+sdk-linux-x64@1", "@cursor/sdk-linux-x64")
            package("dep@2", "dep")
            loop = package("loop@1", "loop", {"dep": "^1"})
            package("unrelated@1", "unrelated")

            def link(src, target):
                src.parent.mkdir(parents=True, exist_ok=True)
                src.symlink_to(target)

            link(store / "@cursor+sdk@1/node_modules/dep", dep1)
            link(store / "@cursor+sdk@1/node_modules/@cursor/sdk-linux-x64", native)
            link(store / "dep@1/node_modules/loop", loop)
            link(store / "loop@1/node_modules/dep", dep1)
            link(source / "apps/server/node_modules/@cursor/sdk", root)

            Stager(source, output).run(["@cursor/sdk"])

            self.assertEqual(
                (output / "node_modules/@cursor/sdk/package.json").read_text(),
                (root / "package.json").read_text(),
            )
            self.assertEqual(
                (output / "node_modules/.pnpm/@cursor+sdk@1/node_modules/dep/package.json").read_text(),
                (dep1 / "package.json").read_text(),
            )
            self.assertTrue(
                (output / "node_modules/.pnpm/dep@1/node_modules/loop").exists()
            )
            self.assertTrue(
                (output / "node_modules/.pnpm/@cursor+sdk@1/node_modules/@cursor/sdk-linux-x64").exists()
            )
            self.assertFalse((output / "node_modules/.pnpm/dep@2").exists())
            self.assertFalse((output / "node_modules/.pnpm/unrelated@1").exists())


if __name__ == "__main__":
    unittest.main()
