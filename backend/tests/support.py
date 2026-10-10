"""Общие помощники интеграционных тестов без обращения к пользовательским сервисам."""

import socket
import time


def available_port():
    """Выбирает свободный локальный порт; сервер должен занять его после возврата."""
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def wait_for(read_value, is_ready, *, timeout_seconds=20, description="condition"):
    """Ожидает состояние с ограниченным таймаутом и возвращает последнее подходящее значение."""
    deadline = time.monotonic() + timeout_seconds
    last_value = None

    while time.monotonic() < deadline:
        last_value = read_value()
        if is_ready(last_value):
            return last_value
        time.sleep(0.1)

    raise AssertionError(f"Timed out waiting for {description}; last value: {last_value!r}")
