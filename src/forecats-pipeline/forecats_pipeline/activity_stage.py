'''Stage 2a: invent what the pets are doing today.

The template was ported from jwardbond/forecats and the backgrounds matched its
control render. The activities did not, and the reason is that upstream does not
keep a list. It asks a model for one each day and shows it the twenty it already
used, under the rule "must not be similar to any of the last 20".

A table cannot compete with that. Forty-odd plays across eleven skies is a
rotation with a short period, and it drifts towards the passive end — "bathe in a
rectangle of winter sun", "press their faces to the glass" — because those are the
easy ones to write. The owner's comparison said it plainly: the control had cats
rolling snowballs and wearing sunglasses, ours had cats sitting.

So this stage asks, and the table in `caption_stage` becomes what a table is for:
the fallback when nobody was asked.
'''

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path

from forecats_pipeline.contracts import DayContext, Household, Scene

__all__ = ["ActivityGenerator", "ACTIVITY_INSTRUCTIONS"]


# Upstream's heuristics, kept because they are the part that produces variety
# rather than merely producing text. The indoor/outdoor split by season and the
# mundane/exciting split are what stop every day becoming a greeting card.
ACTIVITY_INSTRUCTIONS = (
    "You are writing the composition brief for one panel of a daily illustrated "
    "weather card starring the pets named below. Choose one thing they do together.\n"
    "\n"
    "Answer in exactly this form, on one line:\n"
    "Activity: <three words at most>, Foreground: <what they are doing, including "
    "any clothing or accessories they are wearing>, Background: <where they are, "
    "with named objects and places>\n"
    "\n"
    "Heuristics:\n"
    "- The pets may do human-like activities, or occasionally pet-like ones.\n"
    "- The activity must involve all of them at once, not each on their own.\n"
    "- Prefer hands-on: carrying, building, pulling, digging, wearing, stealing, "
    "chasing. Name what they are holding or wearing, because props are what make "
    "a pose readable.\n"
    "- A quiet day is allowed: watching the rain from a window ledge is a fine "
    "answer. Most days, though, have something in their paws.\n"
    "- Weave in at most one of their habits below, and as a detail rather than "
    "the activity itself: the cat who carries a ball everywhere still carries it "
    "to a snowball fight. Their personalities are seasoning, not the meal.\n"
    "- Half the days are mundane (waiting, shopping, commuting, tidying) and half "
    "are exciting (snowball fights, festivals, games).\n"
    "- Match the season: summer leans outdoors, winter splits between indoors and "
    "outdoors.\n"
    "- Do not describe the weather itself, and do not describe what the pets look "
    "like apart from what they are wearing for the activity.\n"
    "- The activity must not be similar to any you gave in the last twenty days."
)

_ANSWER = re.compile(
    r"Activity:\s*(?P<activity>.*?),\s*Foreground:\s*(?P<foreground>.*?),\s*Background:\s*(?P<background>.*)",
    re.DOTALL,
)


class ActivityGenerator:
    """Asks a local model for the day's scene, and remembers what it already said.

    The history file is the whole mechanism: without it a model asked the same
    question about snow on consecutive days answers the same way, which is the
    behaviour the table has and is the thing being replaced.
    """

    def __init__(
        self,
        endpoint: str,
        *,
        model: str = "gemma-4-26b-a4b",
        api_key: str | None = None,
        timeout: float = 120.0,
        history_path: Path | None = None,
        cache_path: Path | None = None,
        history_length: int = 20,
    ) -> None:
        self._endpoint = endpoint
        self._model = model
        self._api_key = api_key
        self._timeout = timeout
        self._history_path = history_path
        self._cache_path = cache_path
        self._history_length = history_length
        self._history = _read_json(history_path, [])
        self._cache = _read_json(cache_path, {})

    def scene_for(self, context: DayContext, household: Household) -> Scene | None:
        """A scene for the day, or None when the model could not be asked.

        None is the honest answer and the caller has a fallback for it. A
        generated scene is cached against the date, so re-rendering a date
        reproduces the picture its own provenance describes instead of drawing a
        new one under the same seed.
        """
        key = context.for_day.isoformat()
        if self._cache_path and key in self._cache:
            return Scene(**self._cache[key])

        scene = self._ask(context, household)
        if scene is None:
            return None

        self._remember(context.for_day, scene)
        return scene

    def _ask(self, context: DayContext, household: Household) -> Scene | None:
        weather = context.weather
        request = f"{_brief(context, household, weather)}\n\nAlready used:\n{self._recent()}"
        body = {
            "model": self._model,
            "messages": [
                {"role": "system", "content": ACTIVITY_INSTRUCTIONS},
                {"role": "user", "content": request},
            ],
            "max_tokens": 220,
            "temperature": 0.9,
        }
        try:
            with urllib.request.urlopen(
                urllib.request.Request(
                    self._endpoint,
                    data=json.dumps(body).encode(),
                    headers=self._headers(),
                    method="POST",
                ),
                timeout=self._timeout,
            ) as response:
                payload = json.load(response)
            answer = payload["choices"][0]["message"]["content"]
        except (urllib.error.URLError, TimeoutError, OSError, ValueError, KeyError):
            return None
        return _parse(answer)

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self._api_key:
            headers["Authorization"] = f"Bearer {self._api_key}"
        return headers

    def _recent(self) -> str:
        return "\n".join(self._history[-self._history_length :]) or "(none yet)"

    def _remember(self, for_day: date, scene: Scene) -> None:
        line = f"{for_day.isoformat()} Activity: {scene.activity}, Foreground: {scene.foreground}, Background: {scene.background}"
        self._history.append(line)
        self._history = self._history[-self._history_length :]
        _write_json(self._history_path, self._history)
        if self._cache_path:
            self._cache[for_day.isoformat()] = {
                "activity": scene.activity,
                "foreground": scene.foreground,
                "background": scene.background,
            }
            _write_json(self._cache_path, self._cache)


def _brief(context: DayContext, household: Household, weather) -> str:
    lines = [
        f"The pets are: {', '.join(f'{pet.name} ({pet.kind})' for pet in household.pets)}.",
        f"The date is {context.for_day.isoformat()}.",
    ]
    if weather is not None:
        lines.append(f"The forecast is: {weather.summary.replace('-', ' ')}.")
    occasions = ", ".join(occasion.title for occasion in context.occasions[:2])
    if occasions:
        lines.append(f"The day is also: {occasions}.")
    habits = _habits(household)
    if habits:
        lines.append(f"Their habits:\n{habits}")
    return "\n".join(lines)


def _habits(household: Household) -> str:
    """Personality and signature details, one line each, offered as seasoning.

    These used to be the composition, which is why one cat was always on his back
    and the other always standing beside a ball. Here they are an offer the model
    may take once, and the instruction says so.
    """
    return "\n".join(
        f"- {pet.name}: {detail.strip().rstrip('.')}"
        for pet in household.pets
        for detail in pet.signature_details
    )


def _parse(answer: str) -> Scene | None:
    """The three-part answer, or None.

    Deliberately strict. A half-answer with no Foreground is a panel of cats
    standing in a named room, which is the failure this stage exists to fix, so
    it is better to fall back to the table than to render a partial brief.
    """
    match = _ANSWER.search(" ".join(answer.split()))
    if not match:
        return None
    parts = {key: value.strip(" .") for key, value in match.groupdict().items()}
    if not all(parts.values()):
        return None
    return Scene(**parts)


def _read_json(path: Path | None, default):
    if path is None:
        return default
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def _write_json(path: Path | None, value) -> None:
    if path is None:
        return
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2))
    except OSError:
        pass
