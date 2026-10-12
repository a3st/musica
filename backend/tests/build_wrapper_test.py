"""Проверяет повторное использование пакетов и передачу ошибок без компиляции backend."""

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "musica_build",
    Path(__file__).resolve().parents[1] / "build.py",
)
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class BuildWrapperTests(unittest.TestCase):
    """Изолирует процессы Zig и файловые операции во временном каталоге."""

    def test_cached_packages_do_not_start_network_fetch(self):
        """Готовое дерево проверяется только в режиме без сетевого скачивания."""
        with patch.object(
            build.subprocess, "run", return_value=subprocess.CompletedProcess([], 0),
        ) as run:
            self.assertEqual(build.prepare_dependencies(), 0)
            self.assertEqual(run.call_count, 1)
            self.assertIn("--system", run.call_args.args[0])

    def test_fetch_failure_prevents_compilation(self):
        """Ошибка загрузчика возвращается вызывающему процессу без запуска сборки."""
        results = [subprocess.CompletedProcess([], 1), subprocess.CompletedProcess([], 7)]
        with patch.object(build.subprocess, "run", side_effect=results) as run:
            self.assertEqual(build.main(["test"]), 7)
            self.assertEqual(run.call_count, 2)

    def test_fetched_sources_are_saved_for_offline_builds(self):
        """Распакованный пакет сохраняется с файлами перед проверкой локального дерева."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "zig-pkg" / "fixture-hash"
            package.mkdir(parents=True)
            (package / "source.zig").write_text("const value = 1;\n", encoding="utf-8")
            packages = root / "3rdparty"
            results = [
                subprocess.CompletedProcess([], 1),
                subprocess.CompletedProcess([], 0),
                subprocess.CompletedProcess([], 0),
            ]
            with (
                patch.object(build, "BACKEND", root),
                patch.object(build, "DEPENDENCY_CACHE", root / ".zig-cache" / "downloads"),
                patch.object(build, "PACKAGES", packages),
                patch.object(build.subprocess, "run", side_effect=results),
            ):
                self.assertEqual(build.prepare_dependencies(), 0)

            self.assertEqual(
                (packages / "fixture-hash" / "source.zig").read_text(encoding="utf-8"),
                "const value = 1;\n",
            )

    def test_build_preserves_steps_and_arguments(self):
        """Шаг и параметры передаются без shell и без потери отдельных аргументов."""
        arguments = ["test", "-Dtest-filter=HLS publication", "--summary", "all"]
        with (
            patch.object(build, "prepare_dependencies", return_value=0),
            patch.object(build.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run,
        ):
            self.assertEqual(build.main(arguments), 0)
            self.assertEqual(
                run.call_args.args[0],
                ["zig", "build", "--system", str(build.PACKAGES), *arguments],
            )


if __name__ == "__main__":
    unittest.main()
