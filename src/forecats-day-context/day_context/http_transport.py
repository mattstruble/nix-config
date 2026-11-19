"""The one place this module opens a socket.

Providers take an `HttpFetcher` rather than calling urllib themselves so that
every provider test runs against a recorded payload, and so that "no test
requires credentials" is a property of the design rather than of the fixtures.
"""

import http.client
import json
import urllib.error
import urllib.request
from collections.abc import Mapping
from typing import Protocol, runtime_checkable

from .contracts import FailureKind, ProviderFailure

__all__ = [
    "HttpError",
    "HttpFetcher",
    "MalformedPayload",
    "TransportError",
    "UrllibFetcher",
    "as_failure",
    "as_malformed_failure",
]

DEFAULT_TIMEOUT_SECONDS = 15.0
DEFAULT_USER_AGENT = "nix-config-forecats-day-context"


class HttpError(Exception):
    """Base for anything that went wrong between us and a provider."""


class TransportError(HttpError):
    """The request did not produce a body worth parsing.

    `status` is present only when a server answered; its absence means nothing
    answered at all, which is a different thing to tell an operator.
    """

    def __init__(self, url: str, reason: str, status: int | None = None) -> None:
        super().__init__(f"{url}: {reason}")
        self.url = url
        self.reason = reason
        self.status = status


class MalformedPayload(HttpError):
    """Something answered, but not in the shape the provider expects."""

    def __init__(self, url: str, reason: str) -> None:
        super().__init__(f"{url}: {reason}")
        self.url = url
        self.reason = reason


def as_failure(source: str, error: HttpError) -> ProviderFailure:
    """Turn a transport error into the reason a provider could not answer.

    A 401 is not worth retrying and a refused connection is; the distinction
    is only recoverable if it survives the trip into the returned value.
    """
    if isinstance(error, MalformedPayload):
        return ProviderFailure(source, FailureKind.MALFORMED, error.reason)
    status = error.status
    if status in (401, 403):
        kind = FailureKind.UNAUTHORIZED
    elif status is not None:
        kind = FailureKind.REJECTED
    else:
        kind = FailureKind.UNREACHABLE
    return ProviderFailure(source, kind, error.reason)


def as_malformed_failure(source: str, reason: str) -> ProviderFailure:
    return ProviderFailure(source, FailureKind.MALFORMED, reason)


@runtime_checkable
class HttpFetcher(Protocol):
    def get_json(self, url: str, headers: Mapping[str, str] | None = None) -> dict[str, object]: ...

    def get_text(self, url: str, headers: Mapping[str, str] | None = None) -> str: ...


class UrllibFetcher:
    """`HttpFetcher` over the standard library.

    The weather and calendar providers deliberately depend on this instead of
    on `requests`: the whole standard-library route costs zero extra packages,
    and a bearer token in a header is not a reason to take on a dependency.
    """

    def __init__(
        self, timeout: float = DEFAULT_TIMEOUT_SECONDS, user_agent: str = DEFAULT_USER_AGENT
    ) -> None:
        self._timeout = timeout
        self._user_agent = user_agent

    def get_json(self, url: str, headers: Mapping[str, str] | None = None) -> dict[str, object]:
        body = self.get_text(url, headers)
        try:
            payload = json.loads(body)
        except json.JSONDecodeError as error:
            raise MalformedPayload(url, f"body is not JSON: {error}") from error
        if not isinstance(payload, dict):
            raise MalformedPayload(url, f"expected a JSON object, got {type(payload).__name__}")
        return payload

    def get_text(self, url: str, headers: Mapping[str, str] | None = None) -> str:
        request = urllib.request.Request(
            url, headers={"User-Agent": self._user_agent, **(headers or {})}
        )
        try:
            with urllib.request.urlopen(request, timeout=self._timeout) as response:
                return response.read().decode("utf-8")
        except urllib.error.HTTPError as error:
            raise TransportError(
                url, error.reason or "server rejected the request", error.code
            ) from error
        # OSError is required and not redundant with URLError: urllib raises bare
        # ConnectionResetError, ConnectionRefusedError and ssl.SSLError — all OSError
        # subclasses — when a peer resets mid-response or the handshake fails, and
        # does not wrap them in URLError. Without OSError in this tuple those escape
        # as exceptions instead of a ProviderFailure, so a nightly run would crash
        # rather than record that the calendar was unreachable.
        except (urllib.error.URLError, OSError, http.client.HTTPException) as error:
            raise TransportError(url, f"no usable response: {error}") from error
