'''Stage 3b: draw the forecast into the panel's lower-left corner.

forecats asks its image model to paint the weather box, and asks hard: three
words, the high, the low, styled to match, kept off the edges. That works when
the model is a hosted product that will render text legibly most of the time.

Here the box is drawn from the `DayContext` instead, for one reason: a model
that can render `16°` can render `86°`, and a wrong temperature on a wall
nobody is watching is a wrong temperature forever, with no log that says so.
The render supplies the art; the numbers come from the forecast.

The plate behind the text is not decoration. Text over an arbitrary cartoon is
text over an arbitrary background, and contrast cannot be negotiated after the
fact — the render is already finished by the time this stage runs.
'''

from dataclasses import dataclass
from datetime import date
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from forecats_pipeline.contracts import Occasion, WeatherToday

__all__ = ["ForecastBox", "overlay_forecast"]

# Sized against the panel, not in points, so the box is the same fraction of
# the picture whatever the render resolution turns out to be.
_BOX_WIDTH_FRACTION = 0.42
_MARGIN_FRACTION = 0.035
_LINE_FRACTION = 0.032
_PLATE_ALPHA = 178


@dataclass(frozen=True)
class ForecastBox:
    """The words that go in the corner, decided before any pixel is drawn.

    Split out so a test can assert on the text without rasterising anything.
    """

    weather_words: str
    high: str
    low: str
    date_line: str
    occasion: str | None

    def lines(self) -> tuple[str, ...]:
        head = f"{self.high}  /  {self.low}"
        rest = (self.weather_words, head, self.date_line)
        return rest + ((self.occasion,) if self.occasion else ())


def forecast_box(
    weather: WeatherToday, for_day: date, occasions: tuple[Occasion, ...] = ()
) -> ForecastBox:
    """Compose the corner text from the forecast, never from the render."""
    return ForecastBox(
        weather_words=weather.forecast_words,
        high=f"Hi {weather.temperature_high_c:g}°",
        low=f"Lo {weather.temperature_low_c:g}°",
        date_line=for_day.strftime("%a %-d %b"),
        occasion=occasions[0].title if occasions else None,
    )


def overlay_forecast(
    panel: Path,
    weather: WeatherToday,
    for_day: date,
    occasions: tuple[Occasion, ...] = (),
    font_path: Path | None = None,
) -> bytes:
    """Return the panel with the forecast plate composited into its lower-left.

    `font_path` must be a file in the nix store: a font resolved from a system
    path is a pipeline that works until the host changes.
    """
    with Image.open(panel) as source:
        canvas = source.convert("RGBA")
    box = forecast_box(weather, for_day, occasions)
    _draw_plate(canvas, box, _font(font_path, canvas.height))
    return _as_png(canvas)


def _font(font_path: Path | None, panel_height: int):
    size = max(16, int(panel_height * _LINE_FRACTION))
    if font_path is None:
        return ImageFont.load_default(size=size)
    return ImageFont.truetype(str(font_path), size=size)


def _draw_plate(canvas: Image.Image, box: ForecastBox, font) -> None:
    width, height = canvas.size
    margin = int(height * _MARGIN_FRACTION)
    line_height = int(height * _LINE_FRACTION * 1.35)
    lines = box.lines()

    plate = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(plate)
    text_w = max(draw.textlength(line, font=font) for line in lines)
    box_w = int(max(text_w + 2 * margin, width * _BOX_WIDTH_FRACTION))
    box_h = len(lines) * line_height + 2 * margin
    corner = (margin, height - margin - box_h)
    draw.rounded_rectangle(
        (*corner, corner[0] + box_w, corner[1] + box_h),
        radius=int(margin * 0.6),
        fill=(12, 12, 16, _PLATE_ALPHA),
    )
    for offset, line in enumerate(lines):
        draw.text(
            (corner[0] + margin, corner[1] + margin + offset * line_height),
            line,
            font=font,
            fill=(252, 250, 245, 255),
        )
    canvas.alpha_composite(plate)


def _as_png(canvas: Image.Image) -> bytes:
    from io import BytesIO

    buffer = BytesIO()
    canvas.convert("RGB").save(buffer, format="PNG")
    return buffer.getvalue()
