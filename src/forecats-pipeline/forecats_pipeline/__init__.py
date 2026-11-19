"""Nightly forecats pipeline: day context to published panel.

Public interface, one callable per stage boundary so an n8n node can wrap each
one without reaching inside:

  build_day_context(day, location, ...)  -> DayContext | PipelineRefusal
  draft_caption(context, pets)           -> Caption
  renderer.render(caption, ...)          -> Rendered | PipelineRefusal
  overlay_forecast(panel, weather, ...)  -> bytes
  publish_panel(...)                     -> Published

`run_nightly` is the one entry point that chains them, and it is idempotent per
date: the second run for a date finds the panel and skips.

Nothing here talks to a model or a GPU, and no stage performs a network call at
import time. The caption stage is a deterministic stub; the renderer behind the
`Renderer` protocol has a fake, so the whole chain runs with no GPU.
"""

from forecats_pipeline.calendar_feeds import MultiFeedCalendarProvider
from forecats_pipeline.caption_stage import draft_caption
from forecats_pipeline.contracts import (
    Caption,
    DayContext,
    Household,
    Occasion,
    Pet,
    PipelineRefusal,
    Published,
    Staleness,
    WeatherToday,
)
from forecats_pipeline.day_context_stage import build_day_context
from forecats_pipeline.household import load_household
from forecats_pipeline.overlay_stage import overlay_forecast
from forecats_pipeline.pipeline import Skipped, run_nightly
from forecats_pipeline.publish_stage import publish_panel, read_freshness
from forecats_pipeline.render_stage import FakeRenderer, Renderer, SdCliRenderer

__all__ = [
    "Caption",
    "DayContext",
    "FakeRenderer",
    "Household",
    "MultiFeedCalendarProvider",
    "Occasion",
    "Pet",
    "PipelineRefusal",
    "Published",
    "Renderer",
    "SdCliRenderer",
    "Skipped",
    "Staleness",
    "WeatherToday",
    "build_day_context",
    "draft_caption",
    "load_household",
    "overlay_forecast",
    "publish_panel",
    "read_freshness",
    "run_nightly",
]
