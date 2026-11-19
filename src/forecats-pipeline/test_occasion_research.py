"""A calendar title is not an image, and an invented tradition is worse than none."""

import json

from forecats_pipeline.contracts import Occasion
from forecats_pipeline.occasion_research import OccasionResearcher, _usable
from datetime import date

DIWALI = Occasion("Diwali/Deepavali", all_day=True)

# A stand-in credential. These tests never reach a network; what they assert is
# that a key is sent when one was configured, not that the value is secret.
FAKE_KEY = "sk-test"  # pragma: allowlist secret


class Gateway:
    def __init__(self, content: str) -> None:
        self._content = content
        self.bodies: list[dict] = []

    def __call__(self, request, timeout=None):
        self.bodies.append(json.loads(request.data))
        payload = {"choices": [{"message": {"content": self._content}}]}

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return json.dumps(payload).encode()

        return Response()


def research(monkeypatch, content: str) -> Occasion:
    monkeypatch.setattr("urllib.request.urlopen", Gateway(content))
    return OccasionResearcher(api_key=FAKE_KEY).research(DIWALI, date(2026, 11, 8))


def test_a_known_occasion_comes_back_with_things_to_draw(monkeypatch):
    described = research(
        monkeypatch,
        "oil lamps set in windows, marigold garlands, a coloured rangoli, plates of sweets.",
    )

    assert described.described_as.startswith("oil lamps")
    assert described.title == "Diwali/Deepavali"


def test_an_unknown_occasion_stays_unknown_rather_than_inventing_a_tradition(monkeypatch):
    described = research(monkeypatch, "UNKNOWN")

    assert described.described_as is None


def test_a_blank_answer_is_not_a_description(monkeypatch):
    assert research(monkeypatch, "   ").described_as is None


def test_a_gateway_that_is_down_still_renders_the_day(monkeypatch):
    def refuse(*args, **kwargs):
        raise OSError("connection refused")

    monkeypatch.setattr("urllib.request.urlopen", refuse)

    assert OccasionResearcher(api_key=FAKE_KEY).research(DIWALI, date(2026, 11, 8)).described_as is None


def test_the_key_is_sent_and_the_title_is_the_question(monkeypatch):
    gateway = Gateway("diyas")
    monkeypatch.setattr("urllib.request.urlopen", gateway)

    OccasionResearcher(api_key=FAKE_KEY).research(DIWALI, date(2026, 11, 8))

    messages = gateway.bodies[0]["messages"]
    assert messages[-1]["content"] == "2026-11-08: Diwali/Deepavali"


def test_the_instructions_are_actually_sent(monkeypatch):
    """A constant nobody puts in the request is a policy nobody follows."""
    gateway = Gateway("diyas")
    monkeypatch.setattr("urllib.request.urlopen", gateway)

    OccasionResearcher(api_key=FAKE_KEY).research(DIWALI, date(2026, 11, 8))

    system = gateway.bodies[0]["messages"][0]
    assert system["role"] == "system"
    # The refusal instruction is the part that stops an invented tradition, so
    # it has to be the part that travels.
    assert "UNKNOWN" in system["content"]


def test_usable_strips_the_trailing_period_a_model_always_adds():
    assert _usable("diyas, sweets.") == "diyas, sweets"
    assert _usable("Unknown.") == ""


class CountingGateway(Gateway):
    """Answers, and keeps a tally: not calling the model is the behaviour here."""

    def __init__(self, content: str) -> None:
        super().__init__(content)
        self.calls = 0

    def __call__(self, request, timeout=None):
        self.calls += 1
        return super().__call__(request, timeout)


def cached_against(tmp_path, gateway, monkeypatch) -> Occasion:
    monkeypatch.setattr("urllib.request.urlopen", gateway)
    researcher = OccasionResearcher(api_key=FAKE_KEY, cache_path=tmp_path / "cache.json")
    return researcher.research(DIWALI, date(2026, 11, 8))


def test_a_cached_occasion_needs_no_model(tmp_path, monkeypatch):
    """The model and the image renderer want the same GPU; only one can have it."""
    gateway = CountingGateway("oil lamps, marigold garlands")
    first = cached_against(tmp_path, gateway, monkeypatch)
    assert gateway.calls == 1

    second = cached_against(tmp_path, gateway, monkeypatch)

    assert gateway.calls == 1, "the second render must not wake the model"
    assert second.described_as == "oil lamps, marigold garlands"


def test_a_day_it_could_not_place_stays_plain_without_re_asking(tmp_path, monkeypatch):
    gateway = CountingGateway("UNKNOWN")
    plain = cached_against(tmp_path, gateway, monkeypatch)
    assert plain.described_as is None

    assert cached_against(tmp_path, gateway, monkeypatch).described_as is None
    assert gateway.calls == 1, "an occasion it does not know is not worth re-asking"


def test_a_dead_endpoint_is_not_remembered_as_an_answer(tmp_path, monkeypatch):
    """Connection refused is not evidence that a festival looks like nothing."""

    def down(request, timeout=None):
        raise OSError("connection refused")

    monkeypatch.setattr("urllib.request.urlopen", down)
    unreachable = OccasionResearcher(api_key=FAKE_KEY, cache_path=tmp_path / "cache.json")
    assert unreachable.research(DIWALI, date(2026, 11, 8)).described_as is None

    recovered = cached_against(tmp_path, CountingGateway("oil lamps"), monkeypatch)

    assert recovered.described_as == "oil lamps"
