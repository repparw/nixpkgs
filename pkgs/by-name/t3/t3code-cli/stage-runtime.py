#!/usr/bin/env python3
"""Stage the pnpm closure of T3 Code's externally loaded CLI dependencies.

The roots come from upstream's selectCliRuntimeExternalDependencies.
Preserve each pnpm virtual-store context: multiple versions of the same
package may be required by different consumers.
"""
import json
import os
from pathlib import Path
import shutil
import sys


class RuntimeStager:
    def __init__(self, source: Path, output: Path):
        self.source = source.resolve()
        self.store = self.source / "node_modules/.pnpm"
        self.output = output
        self.target_store = output / "node_modules/.pnpm"
        self.visited = set()

    def link(self, destination: Path, target: Path):
        destination.parent.mkdir(parents=True, exist_ok=True)
        relative = os.path.relpath(target, destination.parent)
        if destination.is_symlink():
            if os.readlink(destination) != relative:
                raise ValueError(f"conflicting dependency symlink: {destination}")
        elif destination.exists():
            raise ValueError(f"dependency link collides with real file: {destination}")
        else:
            destination.symlink_to(relative)

    def package(self, installed: Path, destination: Path):
        if not installed.exists():
            raise FileNotFoundError(f"runtime package is not installed: {installed}")
        resolved = installed.resolve(strict=True)
        try:
            parts = resolved.relative_to(self.store).parts
        except ValueError as exc:
            raise ValueError(f"unexpected non-pnpm runtime package: {resolved}") from exc
        if len(parts) < 3 or parts[1] != "node_modules":
            raise ValueError(f"unexpected pnpm package layout: {resolved}")

        staged = self.target_store.joinpath(*parts)
        self.link(destination, staged)
        if resolved in self.visited:
            return
        self.visited.add(resolved)
        if not staged.exists():
            staged.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(resolved, staged, symlinks=True)

        manifest = json.loads((resolved / "package.json").read_text())
        dependencies = dict(manifest.get("dependencies", {}))
        dependencies.update(manifest.get("optionalDependencies", {}))
        dependencies.update(manifest.get("peerDependencies", {}))
        context = self.store / parts[0] / "node_modules"
        target_context = self.target_store / parts[0] / "node_modules"
        optional = set(manifest.get("optionalDependencies", {})) | set(
            manifest.get("peerDependenciesMeta", {})
        )
        for name in sorted(dependencies):
            child = context / name
            if not child.exists():
                if name in optional or name in manifest.get("peerDependencies", {}):
                    continue
                raise FileNotFoundError(f"{manifest['name']} needs missing {name} at {child}")
            self.package(child, target_context / name)

    def run(self, roots: list[str]):
        for name in roots:
            self.package(
                self.source / "apps/server/node_modules" / name,
                self.output / "node_modules" / name,
            )
        print(f"staged {len(self.visited)} runtime packages for {len(roots)} upstream roots")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: stage-runtime.py SOURCE_DIR OUTPUT_DIR ROOTS_JSON")
    RuntimeStager(Path(sys.argv[1]), Path(sys.argv[2])).run(
        json.loads(Path(sys.argv[3]).read_text())
    )
