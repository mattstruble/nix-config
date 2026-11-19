"""Transport failure classification.

The constraint under test: every way a fetch can fail must arrive as an
`HttpError`, because `ProviderFailure` is the only channel by which a provider
says "I could not look today". A raw exception escaping here becomes a crashed
nightly run with no provenance record.

These are boundary tests against the failure modes of a real HTTP client, not
against the fetcher's internals: the exceptions below are what `urllib` raises
on ordinary bad network nights, and which of them get wrapped is the whole
contract.
"""

import http.client
import socket
import ssl
import urllib.error
import urllib.request

import pytest

from day_context.http_transport import TransportError, UrllibFetcher

URL = "https://calendar.example.invalid/priv.ics"

# urllib raises the first four directly, without wrapping them in URLError.
# A peer that resets mid-response or a failed TLS handshake are ordinary bad
# nights, and each was observed to escape as a raw exception before OSError
# joined the transport's catch list.
FETCH_FAILURES = [
    pytest.param(ConnectionResetError, "reset by peer", id="reset"),
    pytest.param(ConnectionRefusedError, "refused", id="refused"),
    pytest.param(ssl.SSLError, "handshake failed", id="tls-handshake"),
    pytest.param(OSError, "raw os error", id="bare-oserror"),
    pytest.param(socket.timeout, "timed out", id="socket-timeout"),
    pytest.param(urllib.error.URLError, "no route to host", id="urlerror"),
    pytest.param(http.client.RemoteDisconnected, "closed", id="peer-closed"),
]


def _urlopen_raising(monkeypatch, error_type, message):
    def explode(*_args, **_kwargs):
        raise error_type(message)

    monkeypatch.setattr(urllib.request, "urlopen", explode)


@pytest.mark.parametrize(("error_type", "message"), FETCH_FAILURES)
def test_a_failed_fetch_is_classified_not_raised(monkeypatch, error_type, message):
    _urlopen_raising(monkeypatch, error_type, message)

    with pytest.raises(TransportError) as caught:
        UrllibFetcher().get_text(URL)

    assert caught.value.url == URL


def test_the_failure_names_its_cause(monkeypatch):
    """A failure that does not say why is only marginally better than silence."""
    _urlopen_raising(monkeypatch, ConnectionResetError, "reset by peer")

    with pytest.raises(TransportError) as caught:
        UrllibFetcher().get_text(URL)

    assert "reset by peer" in str(caught.value)
