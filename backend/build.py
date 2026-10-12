#!/usr/bin/env python3
"""Готовит закреплённые пакеты Zig локально и запускает сборку без сетевого скачивания."""

import shutil
import subprocess
import sys
from pathlib import Path


BACKEND = Path(__file__).resolve().parent
DEPENDENCY_CACHE = BACKEND / ".zig-cache" / "downloads"
PACKAGES = BACKEND / "3rdparty"


def prepare_dependencies() -> int:
    """Скачивает отсутствующие пакеты, включая транзитивные, с проверкой хешей Zig."""
    cached = subprocess.run(
        ["zig", "build", "--fetch=all", "--system", str(PACKAGES)],
        cwd=BACKEND,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if cached.returncode == 0:
        print("[build] Using dependencies from 3rdparty; no package download needed.", flush=True)
        return 0

    print("[build] Local dependency tree is incomplete; downloading missing packages.", flush=True)
    result = subprocess.run(
        [
            "zig", "build", "--fetch=all",
            "--global-cache-dir", str(DEPENDENCY_CACHE),
        ],
        cwd=BACKEND,
    ).returncode
    if result != 0:
        return result

    # Zig 0.16 распаковывает архивы в zig-pkg рядом с манифестом.
    # Сохраняем распакованные пакеты для последующей сборки через --system.
    extracted = BACKEND / "zig-pkg"
    if extracted.exists():
        for package in extracted.iterdir():
            if package.is_dir():
                shutil.copytree(package, PACKAGES / package.name, dirs_exist_ok=True)

    return subprocess.run(
        ["zig", "build", "--fetch=all", "--system", str(PACKAGES)],
        cwd=BACKEND,
    ).returncode


def main(arguments: list[str]) -> int:
    """Передаёт шаги и параметры в Zig; --deps-only готовит пакеты без сборки."""
    result = prepare_dependencies()
    if result != 0:
        return result

    if arguments == ["--deps-only"]:
        return 0

    print("[build] Running zig build with local dependencies.", flush=True)
    return subprocess.run(
        ["zig", "build", "--system", str(PACKAGES), *arguments],
        cwd=BACKEND,
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
