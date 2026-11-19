"""Two properties the module must keep, asserted rather than promised.

The first is the host gate: importing this package must not reach the network,
so a machine with no route and no credentials can still import it and run its
own tests. The second is a boundary the module cannot enforce with a type: it
answers "what is today", and a concept from what happens to the answer next
would quietly turn this into a component of that.
"""

import re
import subprocess
import sys
from pathlib import Path

import pytest

import day_context

PACKAGE = Path(__file__).parent / "day_context"

# The vocabulary of everything this module is not. A match is not a style
# complaint; it means a concept from downstream has moved into the answer.
FORBIDDEN_VOCABULARY = re.compile(r"\b(pet|pets|prompt|prompts|image|images)\b", re.IGNORECASE)

SOCKET_GUARD = """
import socket, sys

class NoSockets(socket.socket):
    def __init__(self, *args, **kwargs):
        raise AssertionError("a socket was created at import time")
    def connect(self, *args, **kwargs):
        raise AssertionError("a socket was connected at import time")

socket.socket = NoSockets
socket.create_connection = lambda *a, **k: (_ for _ in ()).throw(
    AssertionError("a socket was opened at import time"))

sys.path.insert(0, {package!r})
import day_context
print(len(day_context.__all__))
"""


def test_importing_the_package_opens_no_socket():
    attempt = subprocess.run(
        [sys.executable, "-c", SOCKET_GUARD.format(package=str(PACKAGE.parent))],
        capture_output=True,
        text=True,
        timeout=120,
    )

    assert attempt.returncode == 0, attempt.stderr
    assert int(attempt.stdout.strip()) == len(day_context.__all__)


def test_no_file_in_the_package_reaches_for_a_downstream_concept():
    offenders = {}
    for path in sorted(PACKAGE.glob("*.py")):
        matches = {
            found.group(0).lower() for found in FORBIDDEN_VOCABULARY.finditer(path.read_text())
        }
        if matches:
            offenders[path.name] = sorted(matches)

    assert offenders == {}


@pytest.mark.parametrize("path", sorted(PACKAGE.glob("*.py")), ids=lambda path: path.name)
def test_every_module_declares_what_it_exports(path):
    assert "__all__" in path.read_text(), f"{path.name} has a public API and no __all__"


def test_no_module_reaches_outside_the_package_for_a_sibling():
    sources = {path.name: path.read_text() for path in PACKAGE.glob("*.py")}

    assert not [
        name for name, source in sources.items() if "from .." in source or "import .." in source
    ]


IMPORTED_GOOGLE_MODULES = """
import sys
sys.path.insert(0, {package!r})
import day_context
print(",".join(sorted(name for name in sys.modules if name.startswith("google"))))
"""


def test_the_chosen_pipeline_does_not_pay_for_the_fallback_it_did_not_pick():
    """`GoogleEventsCalendarProvider` is a fallback, and the only provider in
    this package whose dependency closure is large enough to be a cost. If
    importing the package pulled it in, the closure argument would be prose."""
    attempt = subprocess.run(
        [sys.executable, "-c", IMPORTED_GOOGLE_MODULES.format(package=str(PACKAGE.parent))],
        capture_output=True,
        text=True,
        timeout=120,
    )

    assert attempt.returncode == 0, attempt.stderr
    assert attempt.stdout.strip() == ""
