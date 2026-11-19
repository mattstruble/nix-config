'''Stage 2b: ask a language model what a calendar entry actually looks like.

A calendar says `Diwali/Deepavali`. An image model needs `oil lamps set in
windows, marigold garlands across the doorframe, a coloured rangoli swept flat
on the floor, small plates of sweets, warm low golden light`. Nothing connects
those two sentences without somebody knowing the festival, and the pipeline
does not.

This is the difference between a panel that is *about* an occasion and one that
merely names it. The first attempt at fixing the empty panels was to write
"surrounded by what it looks like" into the prompt, which is an abstraction
pointing at nothing: the image model drew cats in a field, correctly, because
that is what it was given. Concrete nouns came from a person who knew what
Diwali is; this stage is how that knowledge gets here without being tabulated
festival by festival in a file nobody will keep current.

The answer is cached into `Occasion.described_as`, which is the field the
contract already had for it, and which stays `None` — not `""`, not `False` —
when nobody asked.
'''

from __future__ import annotations

import json
import urllib.request
from dataclasses import replace
from datetime import date
from pathlib import Path

from forecats_pipeline.contracts import Occasion

__all__ = ["OccasionResearcher", "RESEARCH_INSTRUCTIONS"]

# What to ask for, and what to refuse to guess. The refusal matters: a festival
# this model has never heard of should come back empty and render as an ordinary
# day, not as an invented tradition attributed to a real one.
RESEARCH_INSTRUCTIONS = (
    "You are writing the visual brief for a daily illustrated weather card that "
    "shows two pet cats taking part in whatever is on the calendar today. "
    "Given one calendar entry, describe only what would be SEEN if the household "
    "were celebrating it: the objects, colours, lights, food, decorations and "
    "setting. Four to six concrete noun phrases, comma separated, no sentences, "
    "no names of the cats, no weather, no text or lettering. "
    "If you are not confident you know what this occasion looks like, reply with "
    "the single word UNKNOWN rather than inventing a tradition."
)


class OccasionResearcher:
    """Fills in `described_as` by asking a local model what an occasion looks like.

    Talks to an OpenAI-compatible endpoint, which is how everything on this host
    reaches a model. The key is read at call time, never at import, so importing
    the pipeline does not require a credential.
    """

    name = "occasion-research"

    def __init__(
        self,
        endpoint: str = "http://mjolnir:8000/v1/chat/completions",
        *,
        model: str = "gemma-4-26b-a4b",
        api_key: str | None = None,
        timeout: float = 60.0,
        cache_path: Path | None = None,
    ) -> None:
        self._endpoint = endpoint
        self._model = model
        self._api_key = api_key
        self._timeout = timeout
        self._cache_path = cache_path
        self._cache = _read_cache(cache_path) if cache_path else {}

    def research(self, occasion: Occasion, for_day: date) -> Occasion:
        """Return the occasion with `described_as` filled, or unchanged.

        Never raises. A research failure is a panel without festival props, not
        a day with no panel — the same rule the weather providers follow.

        A refusal is remembered as the empty string and not re-asked; an error
        is not an answer, so it is not remembered.
        """
        key = f"{for_day.isoformat()}|{occasion.title}"
        if key in self._cache:
            return self._fill(occasion, self._cache[key])
        try:
            described = self._ask(occasion, for_day)
        except (OSError, ValueError, KeyError, json.JSONDecodeError):
            return occasion
        self._remember(key, described)
        return self._fill(occasion, described)

    @staticmethod
    def _fill(occasion: Occasion, described: str) -> Occasion:
        return replace(occasion, described_as=described) if described else occasion

    def _remember(self, key: str, described: str) -> None:
        if self._cache_path is None:
            return
        self._cache[key] = described
        try:
            self._cache_path.parent.mkdir(parents=True, exist_ok=True)
            self._cache_path.write_text(json.dumps(self._cache, indent=2, sort_keys=True))
        except OSError:
            pass  # an unwritable cache costs a re-ask, nothing more

    def _ask(self, occasion: Occasion, for_day: date) -> str:
        body = {
            "model": self._model,
            "messages": [
                {"role": "system", "content": RESEARCH_INSTRUCTIONS},
                {"role": "user", "content": f"{for_day.isoformat()}: {occasion.title}"},
            ],
            "max_tokens": 120,
            "temperature": 0.4,
        }
        request = urllib.request.Request(
            self._endpoint,
            data=json.dumps(body).encode(),
            headers=self._headers(),
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=self._timeout) as response:
            payload = json.load(response)
        return _usable(payload["choices"][0]["message"]["content"])

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self._api_key:
            headers["Authorization"] = f"Bearer {self._api_key}"
        return headers


def _usable(answer: str) -> str:
    """The answer, if it is a description; empty if it is a refusal or noise."""
    text = " ".join(answer.split()).strip().strip(".")
    if not text or text.upper().startswith("UNKNOWN"):
        return ""
    return text


def _read_cache(path: Path) -> dict[str, str]:
    """The cache, or empty. A cache that cannot be read is not an error."""
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
