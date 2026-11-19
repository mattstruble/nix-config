"""One entry point: today's panel, or the reason there isn't one.

Running this twice for the same date is not a bug and not a re-render. The
second run finds the panel that is already published and stops, because the
file is named by date and a second render would replace the only record of the
first — the provenance sidecar would describe a picture that no longer exists.

Everything that touches the outside world is constructed here and nowhere
else: the providers, the fetcher, the renderer, the calendar feed URL. The
stages take their collaborators, so the chain runs end to end in a test with a
stub feed and a fake renderer and no GPU in sight.
"""

import argparse
import os
from collections.abc import Sequence
from dataclasses import dataclass, replace
from datetime import UTC, date, datetime
from pathlib import Path

from day_context import CalendarProvider, Location, UrllibFetcher, WeatherProvider
from day_context import WeatherCondition
from day_context.weather_open_meteo import OpenMeteoWeatherProvider

from forecats_pipeline.activity_stage import ActivityGenerator
from forecats_pipeline.calendar_feeds import MultiFeedCalendarProvider
from forecats_pipeline.caption_stage import draft_caption, table_scene
from forecats_pipeline.contracts import Household, PipelineRefusal, Published
from forecats_pipeline.day_context_stage import PayloadLog, RecordingFetcher, build_day_context
from forecats_pipeline.fixed_weather import FixedWeatherProvider
from forecats_pipeline.household import load_household
from forecats_pipeline.occasion_research import OccasionResearcher
from forecats_pipeline.overlay_stage import overlay_forecast
from forecats_pipeline.publish_stage import FRESHNESS_NAME, existing_panel, publish_panel
from forecats_pipeline.render_stage import FakeRenderer, Renderer, SdCliRenderer, SdCliSettings

__all__ = [
    "CALENDAR_FEEDS_ENV",
    "HOUSEHOLD_FILE_ENV",
    "Skipped",
    "main",
    "run_nightly",
]

# The calendars the panel reads, as `label=url` pairs. Required on the nightly
# path, and never at import: a suite that imports the package must not need a
# calendar. Labels rather than bare URLs because a URL is a credential and a
# refusal that quotes one would publish it.
CALENDAR_FEEDS_ENV = "FORECATS_CALENDAR_FEEDS"

# Where the cats are described. Not a secret, so a plain file rather than a
# decrypted unit; the secret half of the configuration is the feed addresses.
HOUSEHOLD_FILE_ENV = "FORECATS_HOUSEHOLD_FILE"

# The gateway key, which is what lets the pipeline ask a local model what a
# calendar entry looks like. Absent it, the panel still renders — it just cannot
# say what Diwali looks like, and says so by saying less rather than guessing.
GATEWAY_KEY_ENV = "LITELLM_API_KEY"
RESEARCH_MODEL_ENV = "FORECATS_RESEARCH_MODEL"

# Where to ask. Through the gateway this needs the key above; pointed straight
# at a llama-server pod it needs nothing, which is how a one-off render can be
# tested without minting a credential. Either one turns research on; neither
# turns it off more decisively than the other.
RESEARCH_ENDPOINT_ENV = "FORECATS_RESEARCH_ENDPOINT"
DEFAULT_GATEWAY_ENDPOINT = "http://mjolnir:8000/v1/chat/completions"

# The font the forecast box is drawn in, resolved by nix rather than by a path
# that happens to exist on the render host.
PANEL_FONT_ENV = "FORECATS_PANEL_FONT"


@dataclass(frozen=True)
class Skipped:
    """The panel for this date already exists, so nothing was drawn."""

    for_day: date
    panel_path: str
    reason: str


def run_nightly(
    day: date,
    location: Location,
    *,
    weather_providers: Sequence[WeatherProvider],
    calendar_provider: CalendarProvider,
    renderer: Renderer,
    output_dir: Path,
    household: Household,
    overlay_font: Path | None = None,
    researcher: OccasionResearcher | None = None,
    generator: ActivityGenerator | None = None,
    payloads: PayloadLog | None = None,
    published_at: datetime | None = None,
) -> Published | Skipped | PipelineRefusal:
    """Gather the day, draw it, publish it — or stop and say why."""
    # The renderer scp's into this directory, so it has to exist before anything
    # is drawn; a first run on a fresh host otherwise spends two minutes on a
    # render and then loses it to a missing directory.
    output_dir.mkdir(parents=True, exist_ok=True)

    already = existing_panel(day, output_dir)
    if already is not None:
        return Skipped(
            for_day=day,
            panel_path=str(already),
            reason=(
                f"{already.name} is already published for {day}; a second render would "
                "overwrite the only panel that date has"
            ),
        )

    context = build_day_context(
        day,
        location,
        weather_providers=weather_providers,
        calendar_provider=calendar_provider,
        assembled_at=published_at,
    )
    if isinstance(context, PipelineRefusal):
        return context

    if researcher is not None:
        # A calendar title is not an image. This is the only place a festival's
        # appearance enters the pipeline, and it is optional: no researcher
        # means an honest plain panel, not an invented one.
        context = replace(
            context,
            occasions=tuple(researcher.research(o, day) for o in context.occasions),
        )

    caption = draft_caption(
        context,
        household,
        (generator.scene_for(context, household) if generator else None)
        or table_scene(context, household),
        location=location.name,
    )
    # The seed is the date: re-running a date would reproduce the same picture,
    # and a provenance file that names a seed names the day it belongs to.
    seed = int(day.strftime("%Y%m%d"))
    rendered = renderer.render(
        caption,
        seed=seed,
        # Derived from the pets, not passed separately: the prompt numbers the
        # reference images by position, so a list that could be reordered apart
        # from the caption would point `<Picture 1>` at the wrong animal.
        reference_photos=[pet.reference_photo for pet in household.pets],
        destination=output_dir / f"render-{day.isoformat()}.png",
    )
    if isinstance(rendered, PipelineRefusal):
        return rendered

    # The overlay is opt-in: pass a font and the numbers are drawn by us and
    # cannot be wrong, pass nothing and the model paints the gauge itself, in
    # the style of the drawing. Owner chose the model, having seen both.
    if overlay_font is not None and context.weather is not None:
        rendered.panel_path.write_bytes(
            overlay_forecast(
                rendered.panel_path,
                context.weather,
                day,
                context.occasions,
                font_path=overlay_font,
            )
        )

    return publish_panel(
        context,
        caption,
        rendered,
        payloads.bodies() if payloads else {},
        output_dir=output_dir,
        published_at=published_at,
    )


def parse_pets(specimens: Sequence[str]) -> tuple[Pet, ...]:
    """`name|kind|description|photo` into pets, in the order the panel numbers them."""
    pets = []
    for specimen in specimens:
        fields = specimen.split("|")
        if len(fields) != 4:
            raise ValueError(
                f"a pet is name|kind|description|photo, got {specimen!r} with {len(fields)} parts"
            )
        name, kind, description, photo = fields
        pets.append(Pet(name, kind, description, Path(photo)))
    return tuple(pets)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    location = Location(
        name=args.location,
        latitude=args.latitude,
        longitude=args.longitude,
        timezone=args.timezone,
    )
    day = date.fromisoformat(args.day) if args.day else datetime.now(location.zone).date()
    output_dir = Path(args.output_dir)

    feeds = _calendar_feeds()
    # The font env says where a font is; only the flag says to use it. The
    # devShell exports the font unconditionally, so keying the plate off the
    # environment would re-hang the pasted-on box the owner rejected.
    font = Path(os.environ[PANEL_FONT_ENV]) if args.draw_forecast_plate else None
    try:
        household = load_household(Path(args.household_file))
    except (OSError, ValueError, KeyError) as problem:
        return _report(
            PipelineRefusal(stage="config", reason=f"{args.household_file}: {problem}"), output_dir
        )

    if not feeds:
        outcome: Published | Skipped | PipelineRefusal = PipelineRefusal(
            stage="config",
            reason=(
                f"{CALENDAR_FEEDS_ENV} is not set; it holds comma-separated label=url pairs, "
                "is required on the nightly path, and is read from the environment, never "
                "from a file in this repository"
            ),
        )
    else:
        outcome = run_nightly(
            day,
            location,
            **_nightly_collaborators(args, feeds, PayloadLog()),
            output_dir=output_dir,
            household=household,
            overlay_font=font,
            researcher=_researcher(output_dir),
            generator=_generator(output_dir),
            published_at=datetime.now(UTC),
        )

    return _report(outcome, output_dir)


def _report(outcome: Published | Skipped | PipelineRefusal, output_dir: Path) -> int:
    if isinstance(outcome, PipelineRefusal):
        print(f"refused at {outcome.stage}: {outcome.reason}")
        return 1
    if isinstance(outcome, Skipped):
        print(f"skipped {outcome.for_day}: {outcome.reason}")
        return 0
    print(
        f"published {outcome.panel_path} "
        f"(provenance {outcome.provenance_path}, freshness {output_dir / FRESHNESS_NAME})"
    )
    return 0


def _model_endpoint() -> tuple[str, str | None] | None:
    """Where to ask a model, and with what key — or None when nothing is configured.

    One reader for both stages that need a model, so "is a model available?" has
    exactly one answer in this file. The key is read here, at call time, never at
    import, so importing the pipeline does not require a credential.
    """
    key = os.environ.get(GATEWAY_KEY_ENV)
    endpoint = os.environ.get(RESEARCH_ENDPOINT_ENV, DEFAULT_GATEWAY_ENDPOINT if key else "")
    if not endpoint:
        return None
    return endpoint, key


def _researcher(output_dir: Path) -> OccasionResearcher | None:
    """The occasion researcher, or None when nothing was configured to ask.

    Optional by design: a panel that names the day plainly is honest, and only
    the props need a model.

    The cache sits beside the panels because the model and the image renderer
    want the same GPU: research once, then every later render of that day draws
    on the cached line without waking a second tenant onto the card.
    """
    configured = _model_endpoint()
    if configured is None:
        return None
    endpoint, key = configured
    return OccasionResearcher(
        endpoint=endpoint,
        api_key=key,
        model=os.environ.get(RESEARCH_MODEL_ENV, "gemma-4-26b-a4b"),
        cache_path=output_dir / "research-cache.json",
    )


def _generator(output_dir: Path) -> ActivityGenerator | None:
    """The activity inventor, or None when no model is configured to ask.

    Without it the panel falls back to `table_scene`, which is a rotation of a
    few dozen ideas rather than an invention. That is a deliberate degradation: a
    panel with a recycled pose is worse than one with a plain one, but it is not
    a day with no panel.
    """
    configured = _model_endpoint()
    if configured is None:
        return None
    endpoint, key = configured
    return ActivityGenerator(
        endpoint=endpoint,
        api_key=key,
        model=os.environ.get(RESEARCH_MODEL_ENV, "gemma-4-26b-a4b"),
        history_path=output_dir / "activity-history.json",
        cache_path=output_dir / "activity-cache.json",
    )


def _calendar_feeds() -> tuple[tuple[str, str], ...]:
    """`label=url,label=url` from the environment, or empty when it is unset."""
    raw = os.environ.get(CALENDAR_FEEDS_ENV, "")
    feeds = []
    for pair in raw.split(","):
        if not pair.strip():
            continue
        label, _, url = pair.partition("=")
        if not _ or not url.strip():
            raise ValueError(f"a calendar feed is label=url, got {pair!r}")
        feeds.append((label.strip(), url.strip()))
    return tuple(feeds)


def _nightly_collaborators(
    args: argparse.Namespace, feeds: tuple[tuple[str, str], ...], payloads: PayloadLog
) -> dict[str, object]:
    fetcher = RecordingFetcher(UrllibFetcher(), payloads)
    renderer: Renderer = (
        FakeRenderer()
        if args.renderer == "fake"
        else SdCliRenderer(args.sd_cli_binary, SdCliSettings(host=args.render_host))
    )
    return {
        # Home Assistant is the named fallback where an instance already runs
        # one; this host has no credentials for it, so the nightly path asks
        # Open-Meteo alone rather than pretending to have a second opinion.
        # `--weather` replaces the question entirely, which is the only way to
        # draw a season outside the 92-days-back / 16-days-ahead window.
        "weather_providers": (
            [FixedWeatherProvider(args.weather, temperature_high_c=args.high, temperature_low_c=args.low)]
            if args.weather
            else [OpenMeteoWeatherProvider(fetcher)]
        ),
        "calendar_provider": MultiFeedCalendarProvider(fetcher, feeds),
        "renderer": renderer,
        "payloads": payloads,
    }


def _parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="forecats-pipeline",
        description="Gather today, draw it, publish it, or say why not.",
    )
    parser.add_argument("--day", help="ISO date to render; defaults to today where --timezone says")
    parser.add_argument("--location", default="home")
    parser.add_argument("--timezone", required=True)
    parser.add_argument("--latitude", type=float, required=True)
    parser.add_argument("--longitude", type=float, required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument(
        "--household-file",
        default="src/forecats-pipeline/household.yaml",
        help="YAML naming the pets, their appearances, and the rules that keep them apart",
    )
    parser.add_argument(
        "--draw-forecast-plate",
        action="store_true",
        help=(
            "draw the forecast box with Pillow instead of asking the model to "
            "paint one; the numbers then cannot be wrong, but they are not part "
            "of the drawing either"
        ),
    )
    parser.add_argument("--renderer", choices=("fake", "sd-cli"), default="fake")
    parser.add_argument("--render-host", default="mjolnir")
    parser.add_argument(
        "--weather",
        choices=tuple(condition.value for condition in WeatherCondition),
        help="draw this sky instead of asking Open-Meteo, for days outside its window",
    )
    parser.add_argument("--high", type=float, help="override the high temperature --weather implies")
    parser.add_argument("--low", type=float, help="override the low temperature --weather implies")
    parser.add_argument(
        "--sd-cli-binary",
        default="sd-cli",
        help="path to the diffusion CLI on the render host; required with --renderer sd-cli",
    )
    return parser.parse_args(argv)
