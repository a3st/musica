"""Проверяет release nginx на изолированном тестовом API без backend и пользовательской БД."""

import argparse
import json
import re
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def docker(*arguments):
    """Выполняет команду Docker, возвращая вывод или диагностическую ошибку."""
    return subprocess.run(
        ["docker", *arguments], check=True, capture_output=True, text=True,
    ).stdout.strip()


def request(base, path, method="GET"):
    """Читает ответ тестового контейнера, включая ответы 404."""
    try:
        response = urlopen(Request(base + path, method=method), timeout=5)
    except HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read(), response.url


def check(image):
    """Запускает собранный образ с тестовым upstream и всегда удаляет только свой контейнер."""
    root = Path(__file__).resolve().parents[2]
    configuration = (root / "docker/nginx/default.conf").read_text(encoding="utf-8")
    upstream = '''
server {
    listen 8080;
    default_type application/json;
    location / {
        return 200 '{"host":"$http_host","uri":"$request_uri","method":"$request_method"}';
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="musica-nginx-") as directory:
        config = Path(directory) / "default.conf"
        config.write_text(configuration + upstream, encoding="utf-8")
        container = docker(
            "run", "-d", "--rm", "--add-host", "backend:127.0.0.1",
            "-p", "127.0.0.1::80", "--mount",
            f"type=bind,source={config},target=/etc/nginx/conf.d/default.conf,readonly",
            image,
        )
        try:
            docker("exec", container, "nginx", "-t")
            address = docker("port", container, "80/tcp").splitlines()[0]
            base = "http://" + address
            for attempt in range(30):
                try:
                    if request(base, "/nginx-health")[0] == 200:
                        break
                except (URLError, TimeoutError):
                    time.sleep(0.1)
            else:
                raise AssertionError("Nginx did not become ready")

            status, headers, player, _ = request(base, "/")
            assert status == 200 and b"Musica" in player
            assert headers["Cache-Control"] == "no-cache"
            status, headers, profile, _ = request(base, "/profile/?page=users")
            assert status == 200 and "Musica · Профиль" in profile.decode("utf-8")
            assert headers["Cache-Control"] == "no-cache"
            assert player != profile, "Profile must have its own shell"
            assert request(base, "/profile/route")[2] == profile
            assert request(base, "/profile?return_to=%2F")[3].endswith("/profile/?return_to=%2F")
            assert request(base, "/profile/icon.svg")[2] == request(base, "/icon.svg")[2]

            for html, prefix in [(player, "/assets/"), (profile, "/profile/assets/")]:
                asset = re.search(r'src="(' + re.escape(prefix) + r'[^\"]+\.js)"', html.decode()).group(1)
                assert request(base, asset)[0] == 200
                assert "immutable" in request(base, asset)[1]["Cache-Control"]
                assert request(base, prefix + "missing.js")[0] == 404

            status, headers, body, _ = request(base, "/api/check?probe=1", "POST")
            assert status == 200 and headers["Cache-Control"] == "no-store"
            assert json.loads(body) == {
                "host": address, "uri": "/api/check?probe=1", "method": "POST",
            }, "API path, method and original Host must be preserved"
            assert request(base, "/sw.js")[1]["Cache-Control"] == "no-cache"
            assert request(base, "/manifest.webmanifest")[0] == 200
            print("PASS: nginx config, both frontend shells, profile redirect/favicon, assets, PWA headers and API Host/path/method.")
        except Exception:
            print(docker("logs", container))
            raise
        finally:
            subprocess.run(["docker", "rm", "-f", container], check=False, capture_output=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", default="musica-frontend:0.4.1")
    check(parser.parse_args().image)
