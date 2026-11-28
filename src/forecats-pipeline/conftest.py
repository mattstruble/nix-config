"""Doubles shared by the stage suites.

Nothing here opens a socket, starts a process or touches a GPU. The weather
providers are replaced by stubs because their own translation is what is under
test; the calendar is the real `IcsCalendarProvider` over the real fixture,
because recurrence expansion is exactly where a pipeline integration breaks.
"""

from datetime import UTC, date, datetime
from io import BytesIO
from pathlib import Path

import pytest
from day_context import Location
from forecats_pipeline.contracts import Household, Pet
from PIL import Image

DAY_ICS = Path(__file__).parents[1] / "forecats-day-context" / "fixtures" / "day.ics"
FEED_URL = "https://example.invalid/ics/day.ics"
DAY = date(2026, 3, 8)
MORNING = datetime(2026, 3, 8, 7, 30, tzinfo=UTC)

# The inbox a viewer reports a panel to, published in every provenance sidecar.
# A fixture address on a domain reserved for documentation, because the real one
# is personal data and the sidecar carrying it is served beside the picture.
REPORT_INBOX = "owner@example.invalid"


def gradient_png(size: int) -> bytes:
    """A decodable PNG whose every row differs from the row above it.

    The publish step cuts the banner and the thumbnail out of a panel's own bytes,
    so a stand-in for a rendered panel has to be a picture Pillow can open, and a
    flat field could not tell a crop of it from a redraw of something else.
    """
    buffer = BytesIO()
    Image.linear_gradient("L").resize((size, size)).convert("RGB").save(buffer, format="PNG")
    return buffer.getvalue()


class StubFeed:
    """An `HttpFetcher` for a feed whose text was written down beforehand."""

    def __init__(self, text: str | None = None, error: Exception | None = None) -> None:
        self._text = text
        self._error = error

    def get_text(self, url: str, headers: dict | None = None) -> str:
        if self._error is not None:
            raise self._error
        assert self._text is not None, "this stub was asked for text it does not hold"
        return self._text

    def get_json(self, url: str, headers: dict | None = None) -> dict:
        raise AssertionError("a calendar feed is read as text, never as json")


class StubWeatherProvider:
    """A `WeatherProvider` whose answer was written down before the test ran."""

    def __init__(self, name: str, answer: object) -> None:
        self.name = name
        self._answer = answer

    def fetch_weather(self, location: Location, day: date) -> object:
        return self._answer


@pytest.fixture
def new_york() -> Location:
    return Location("New York", 40.7128, -74.006, "America/New_York")


def two_pets() -> Household:
    """The two subjects, in the order the prompt numbers them.

    Both ginger, because that is what they are: an earlier version of this
    fixture called Mochi a tuxedo, matching the invented description that was
    breaking the renders, and the fixture then agreed with the bug.
    """
    return Household(
        pets=(
            Pet(
                "Milo",
                "cat",
                "orange-and-white tabby, white muzzle, chest and paws, copper eyes",
                Path("/refs/milo.jpg"),
                personality="Brave, curious, protective of Mochi.",
                signature_details=(
                    "Carries a sparkling ball toy everywhere.",
                    "Investigates a strange noise with an intensely curious stare.",
                    "Sleeps curled against his brother.",
                ),
            ),
            Pet(
                "Mochi",
                "cat",
                "ginger-orange tabby, no white markings, huge dilated copper eyes",
                Path("/refs/mochi.jpg"),
                personality="Playful, talkative, timid.",
                signature_details=(
                    "Rolls onto his back for belly rubs.",
                    "Hangs upside down off a ledge to look at the camera.",
                ),
            ),
        ),
        relationship=("Biological brothers who sleep snuggled together.",),
        consistency_rules=("Never give Mochi Milo's white facial and chest markings.",),
        # Three, so that a month of days is a rotation and not one style wearing
        # three names. The shipped list is longer than this one.
        art_styles=(
            "flat cartoon, bold outlines, saturated colour",
            "risograph print, two-colour grain, offset edges",
            "ukiyo-e woodblock, flat planes of colour, firm outlines",
        ),
    )
