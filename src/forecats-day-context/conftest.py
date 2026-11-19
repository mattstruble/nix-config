"""Test doubles and fixtures shared by the suite.

Nothing here opens a socket or reads a secret. Every provider test drives a
`StubFetcher` with an answer written down in `fixtures/`, which is what makes
"no test requires credentials" true by construction rather than by care.
"""

import json
from collections.abc import Callable
from pathlib import Path

import pytest

from day_context import Location
from day_context.http_transport import TransportError

FIXTURES = Path(__file__).parent / "fixtures"


class StubFetcher:
    """An `HttpFetcher` whose answers were written down before the test ran.

    A fake, not a mock: it answers, and tests assert on what the provider
    made of the answer. It keeps the requests it was given only for the two
    cases where the request is itself the behaviour — the credential a
    provider sends, and the query flags that change what a server expands.
    """

    def __init__(
        self,
        text: str | None = None,
        payload: dict | None = None,
        error: Exception | None = None,
    ) -> None:
        self._text = text
        self._payload = payload
        self._error = error
        self.requests: list[tuple[str, dict | None]] = []

    def get_text(self, url: str, headers: dict | None = None) -> str:
        self.requests.append((url, dict(headers) if headers else None))
        self._raise_if_configured()
        if self._text is None:
            raise AssertionError(f"stub has no text for {url}")
        return self._text

    def get_json(self, url: str, headers: dict | None = None) -> dict:
        self.requests.append((url, dict(headers) if headers else None))
        self._raise_if_configured()
        if self._payload is None:
            raise AssertionError(f"stub has no payload for {url}")
        return self._payload

    def _raise_if_configured(self) -> None:
        if self._error is not None:
            raise self._error


@pytest.fixture
def new_york() -> Location:
    return Location("New York", 40.7128, -74.006, "America/New_York")


@pytest.fixture
def stub_fetcher() -> type[StubFetcher]:
    return StubFetcher


@pytest.fixture
def connection_refused() -> TransportError:
    return TransportError(
        "https://example.invalid/feed", "no usable response: [Errno 61] Connection refused"
    )


@pytest.fixture
def fixture_text() -> Callable[[str], str]:
    def read(name: str) -> str:
        return (FIXTURES / name).read_text(encoding="utf-8")

    return read


@pytest.fixture
def fixture_json(fixture_text: Callable[[str], str]) -> Callable[[str], dict]:
    def read(name: str) -> dict:
        return json.loads(fixture_text(name))

    return read
