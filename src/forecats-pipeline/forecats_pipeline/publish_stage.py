"""Stage 4: put the panel where it is read, and write down how it was made.

Three files, and the third is the one that matters most.

The panel is what the viewer sees. The provenance sidecar is what makes a wrong
picture explainable afterwards — which template, which seed, which weights,
which reference photos, and the raw payload each source actually answered with,
beside the address a viewer writes to when they believe the picture should not
exist. The freshness artefact is what makes a *stopped* pipeline visible: nothing
here keeps history, so a panel that has not been redrawn for nine days looks exactly
like one that was. The only difference a viewer can see is the timestamp beside
it, so the timestamp is published as a separate, always-current file rather
than being something a reader has to trust the PNG about.
"""

import json
from dataclasses import asdict
from datetime import UTC, date, datetime
from pathlib import Path
from shutil import move

from forecats_pipeline.contracts import Caption, DayContext, Published, Staleness
from forecats_pipeline.render_stage import REPORT_ADDRESS_ENV, Rendered

__all__ = [
    "FRESHNESS_NAME",
    "existing_panel",
    "panel_name",
    "provenance_name",
    "publish_panel",
    "read_freshness",
]

FRESHNESS_NAME = "freshness.json"


def panel_name(day: date) -> str:
    return f"panel-{day.isoformat()}.png"


def provenance_name(day: date) -> str:
    return panel_name(day).removesuffix(".png") + ".provenance.json"


def existing_panel(day: date, output_dir: Path) -> Path | None:
    """The panel this run would have written, if it is already there.

    Existence is the whole test: the file is named by date, so a second run for
    a date would overwrite the only record of the first one.
    """
    candidate = output_dir / panel_name(day)
    return candidate if candidate.is_file() else None


def publish_panel(
    context: DayContext,
    caption: Caption,
    rendered: Rendered,
    payloads: dict[str, object],
    *,
    output_dir: Path,
    report_address: str,
    published_at: datetime | None = None,
) -> Published:
    """Write the panel, its provenance, and the freshness artefact."""
    _named_not_addressed(payloads)
    if not report_address.strip():
        # The obligation is on the published picture, so the check sits at the write
        # and not only at the render: a panel nobody can object to is the state the
        # model grant forbids, and it is reached as easily by a caller that forgot an
        # argument as by a configuration that never had one.
        raise ValueError(
            "report_address must name the inbox a viewer reports a suspected violation of "
            f"the model grant to; {REPORT_ADDRESS_ENV} carries it to the pipeline, and "
            "nothing is published beside the panel until it is set"
        )
    rendered_at = published_at or datetime.now(UTC)
    if rendered_at.tzinfo is None or rendered_at.utcoffset() is None:
        raise ValueError("published_at must be timezone-aware; it is what staleness is measured from")

    output_dir.mkdir(parents=True, exist_ok=True)
    staleness = Staleness(rendered_at=rendered_at, age_hours=0.0)
    panel_path = output_dir / panel_name(context.for_day)
    provenance_path = output_dir / provenance_name(context.for_day)
    # The two records are written before the panel appears, and the panel is the
    # last of the three to reach its final name. A panel that got there with no
    # sidecar beside it is a picture nobody can explain and nobody can report —
    # the state the model grant forbids — and the nightly cannot recover from it,
    # because a second run for a date finds the PNG and skips. A sidecar whose
    # panel never arrived is the failure left behind instead: nothing shows, the
    # render is still under its scratch name, and the next run writes both again.
    _write_json(
        provenance_path,
        {
            "for_day": context.for_day.isoformat(),
            "timezone": context.timezone,
            "panel": panel_path.name,
            "renderer": rendered.renderer,
            "seed": rendered.seed,
            "width_px": rendered.width_px,
            "height_px": rendered.height_px,
            "template_hash": caption.template_hash,
            "style": caption.style,
            "caption": caption.text,
            "report_address": report_address.strip(),
            "weights": list(rendered.weights),
            "reference_photos": [str(photo) for photo in rendered.reference_photos],
            "weather": asdict(context.weather) if context.weather else None,
            "occasions": [asdict(occasion) for occasion in context.occasions],
            "weather_refusals": list(context.weather_refusals),
            "calendar_refusals": list(context.calendar_refusals),
            "payloads": payloads,
            "rendered_at": rendered_at.isoformat(),
        },
    )
    _write_json(
        output_dir / FRESHNESS_NAME,
        {
            "for_day": context.for_day.isoformat(),
            "panel": panel_path.name,
            "rendered_at": rendered_at.isoformat(),
            "renderer": rendered.renderer,
            "template_hash": caption.template_hash,
            "age_hours_at_write": staleness.age_hours,
        },
    )
    # Moved, not copied: the scratch name it was drawn under is a renderer
    # detail, and a published directory that keeps both is a directory where a
    # viewer has to guess which PNG is the panel.
    move(rendered.panel_path, panel_path)
    return Published(
        panel_path=str(panel_path),
        provenance_path=str(provenance_path),
        for_day=context.for_day,
        staleness=staleness,
    )


def read_freshness(output_dir: Path, *, now: datetime) -> Staleness:
    """How old the current panel is, as of `now`.

    A viewer calls this instead of trusting the picture. `rendered_at` is the
    fact; the age is derived from it at read time, so the artefact stays true
    however long it sits there.
    """
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("now must be timezone-aware to compare against a render")
    record = json.loads((output_dir / FRESHNESS_NAME).read_text(encoding="utf-8"))
    rendered_at = datetime.fromisoformat(record["rendered_at"])
    age_hours = (now - rendered_at).total_seconds() / 3600
    return Staleness(rendered_at=rendered_at, age_hours=age_hours)


def _named_not_addressed(payloads: dict[str, object]) -> None:
    """Refuse to publish a payload filed under the address it was fetched from.

    This directory is served to whoever can see the panel, and a private feed
    address carries the calendar's read token in its path. The check sits at the
    write rather than in a job that might not have run, and it counts the
    offending entries without naming them: the key is the secret.
    """
    addressed = [name for name in payloads if "://" in name]
    if addressed:
        raise ValueError(
            f"{len(addressed)} of {len(payloads)} payloads are filed under an address "
            "instead of a feed label; the addresses are not repeated here because a feed "
            "address is a credential, and this file is published beside the panel"
        )


def _write_json(path: Path, record: dict[str, object]) -> None:
    text = json.dumps(record, indent=2, sort_keys=True, default=_serialisable)
    path.write_text(text + "\n", encoding="utf-8")


def _serialisable(value: object) -> str:
    # Instants round-trip through `datetime.fromisoformat`, which is what
    # `read_freshness` does to find out how old the panel is.
    return value.isoformat() if isinstance(value, datetime | date) else str(value)
