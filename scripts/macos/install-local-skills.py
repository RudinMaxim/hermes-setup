#!/usr/bin/env python3
"""Install enabled local skills into a native Hermes home."""

from __future__ import annotations

import argparse
import filecmp
import os
import shutil
import tempfile
import tomllib
from datetime import datetime, timezone
from pathlib import Path


def same_tree(left: Path, right: Path) -> bool:
    if not right.is_dir():
        return False
    comparison = filecmp.dircmp(left, right)
    if comparison.left_only or comparison.right_only or comparison.funny_files:
        return False
    if any(
        not filecmp.cmp(left / name, right / name, shallow=False)
        for name in comparison.common_files
    ):
        return False
    return all(same_tree(left / name, right / name) for name in comparison.common_dirs)


def resolve_source(repo_root: Path, value: str) -> Path:
    source = Path(value)
    if source.is_absolute() or ".." in source.parts:
        raise ValueError(f"unsafe local skill source: {value}")
    resolved = (repo_root / source).resolve()
    if resolved != repo_root and repo_root not in resolved.parents:
        raise ValueError(f"local skill source escapes repository: {value}")
    if not (resolved / "SKILL.md").is_file():
        raise ValueError(f"local skill source has no SKILL.md: {value}")
    for path in resolved.rglob("*"):
        if path.is_symlink():
            target = path.resolve()
            if target != repo_root and repo_root not in target.parents:
                raise ValueError(f"local skill symlink escapes repository: {path}")
    return resolved


def install_skill(source: Path, target: Path, backup_root: Path) -> str:
    if same_tree(source, target):
        return "unchanged"

    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        backup = backup_root / target.name / timestamp
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(target, backup)

    with tempfile.TemporaryDirectory(dir=target.parent) as temp_dir:
        staged = Path(temp_dir) / target.name
        shutil.copytree(source, staged)
        if target.exists():
            shutil.rmtree(target)
        os.replace(staged, target)
    return "installed"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--hermes-home", type=Path, required=True)
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    config = tomllib.loads(args.config.read_text(encoding="utf-8"))
    skills_root = args.hermes_home / "skills"
    backup_root = args.hermes_home / "backups" / "skills"

    for name, settings in config.items():
        if not isinstance(settings, dict):
            continue
        if not settings.get("enabled") or settings.get("type") != "local":
            continue
        source = resolve_source(repo_root, str(settings.get("source", "")))
        status = install_skill(source, skills_root / source.name, backup_root)
        print(f"{status}: skill.{name}")


if __name__ == "__main__":
    main()
