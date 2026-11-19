"""Tests for the ported crop and Spectra6 render pass.

Run from anywhere: `pytest src/forecats-eink` (Pillow is required; see README.md).
"""

import re
from pathlib import Path

import pytest
from PIL import Image, ImageOps

from image_processing import (
    DISPLAY_PROFILES,
    PANEL_SIZE,
    SPECTRA6,
    TargetSize,
    recolor_image,
    render_derivatives,
    resize_image,
    rgb_to_hex,
    write_derivatives,
)

GOLDEN = Path(__file__).parent / "reference" / "golden-panel.png"

# One band per spectra6 true colour, so every palette entry is reachable.
BANDS = [
    (0, 0, 0),
    (255, 255, 255),
    (0, 0, 255),
    (0, 255, 0),
    (255, 0, 0),
    (255, 255, 0),
]


def synthetic_source(width: int = 200, height: int = 150) -> Image.Image:
    """Deterministic RGB image: each colour band ramps to its neighbour and
    darkens toward the bottom, so dithering is exercised between and within
    bands. 4:3, so the 800x480 panel pass has to crop."""
    band = width // len(BANDS)
    pixels = bytearray()
    for y in range(height):
        for x in range(width):
            left = BANDS[min(x // band, len(BANDS) - 1)]
            right = BANDS[min(x // band + 1, len(BANDS) - 1)]
            ramp = (x % band) * 255 // (band - 1)
            shade = (height - y) * 255 // height
            channels = (
                ((left[i] * (255 - ramp) + right[i] * ramp) // 255) * shade // 255
                for i in range(3)
            )
            pixels.extend(channels)
    return Image.frombytes("RGB", (width, height), bytes(pixels))


def true_colours(profile: str = SPECTRA6) -> set[str]:
    """The colours the source image is dithered against — the keys of the colour map."""
    return {hex_.upper() for hex_ in DISPLAY_PROFILES[profile]["color_map"]}


def device_colours(profile: str = SPECTRA6) -> set[str]:
    """The colours the panel is driven with — the values of the colour map, and
    the only ones a rendered output may contain."""
    return {hex_.upper() for hex_ in DISPLAY_PROFILES[profile]["color_map"].values()}


def distinct_hexes(image: Image.Image) -> set[str]:
    # getcolors returns None once maxcolors is exceeded; the cap is far above
    # the 6-colour palette rather than exactly it, so an over-palette output is
    # reported as "too many colours" instead of crashing the count.
    colours = image.getcolors(maxcolors=100_000)
    assert colours is not None, f"{image.size} has more colours than the count cap"
    return {rgb_to_hex(rgb).upper() for _, rgb in colours}


def differing_pixels(left: Image.Image, right: Image.Image) -> int:
    raw_left, raw_right = left.tobytes(), right.tobytes()
    return sum(1 for i in range(0, len(raw_left), 3) if raw_left[i : i + 3] != raw_right[i : i + 3])


def test_module_imports_nothing_from_home_assistant():
    assert "homeassistant" not in __import__("sys").modules


def test_write_derivatives_writes_panel_and_full(tmp_path):
    source = synthetic_source()

    panel_path, full_path = write_derivatives(source, tmp_path, "forecast")

    assert panel_path.exists() and full_path.exists()
    with Image.open(panel_path) as panel, Image.open(full_path) as full:
        assert panel.size == (PANEL_SIZE.width, PANEL_SIZE.height)
        assert full.size == source.size


def test_panel_uses_at_most_the_six_device_colours():
    panel, _ = render_derivatives(synthetic_source())

    colours = distinct_hexes(panel)
    assert len(colours) <= 6
    assert colours <= device_colours()


def test_pixels_are_device_colours_not_the_true_colours_they_were_dithered_against():
    panel, full = render_derivatives(synthetic_source())

    for rendered in (panel, full):
        colours = distinct_hexes(rendered)
        assert colours & device_colours(), f"no device colour written: {colours}"
        assert not colours & true_colours(), f"true palette leaked: {colours & true_colours()}"


@pytest.mark.parametrize(
    ("true_rgb", "expected"),
    [((0, 0, 255), "#2157BA"), ((0, 0, 0), "#191E21")],
)
def test_an_exact_true_colour_is_written_as_that_entrys_device_value(true_rgb, expected):
    """An exact palette entry leaves Floyd-Steinberg no error to diffuse, so the
    render is one hex and it is unambiguously that entry's. Quantising against
    the true palette and never remapping writes the true value instead."""
    image = Image.new("RGB", (8, 8), true_rgb)

    recoloured = recolor_image(image, SPECTRA6)

    assert distinct_hexes(recoloured) == {expected}


def test_unknown_profile_names_the_profile_and_the_accepted_set():
    with pytest.raises(ValueError, match=r"spectra9.*spectra6"):
        recolor_image(synthetic_source(), "spectra9")


def test_missing_profile_raises_rather_than_passing_the_image_through():
    with pytest.raises(ValueError, match="accepted profiles"):
        recolor_image(synthetic_source(), None)


@pytest.mark.parametrize(
    "text",
    ["", "800", "wide", "800x", "x480", "800x480x1", "800.0x480", "800 x 480 x", "eight x four"],
)
def test_unparseable_target_size_raises_naming_the_input(text):
    with pytest.raises(ValueError, match=re.escape(repr(text))):
        TargetSize.parse(text)


@pytest.mark.parametrize(
    ("text", "expected"),
    [("800x480", TargetSize(800, 480)), (" 1024x600 ", TargetSize(1024, 600))],
)
def test_target_size_parses_the_string_form(text, expected):
    assert TargetSize.parse(text) == expected


@pytest.mark.parametrize(("width", "height"), [(0, 480), (800, 0), (-800, 480)])
def test_non_positive_target_size_raises(width, height):
    with pytest.raises(ValueError, match="positive width and height"):
        TargetSize(width, height)


def test_resize_crops_the_overshoot_instead_of_padding_it():
    """Magenta bars at the source edges stand in for letterbox padding: the
    2:1 source has to lose its sides to fill a square, and if `fit` padded
    instead of cropped the bars would survive into the output."""
    source = Image.new("RGB", (200, 100), "white")
    bar = Image.new("RGB", (10, 100), (255, 0, 255))
    source.paste(bar, (0, 0))
    source.paste(bar, (190, 0))

    resized = resize_image(source, TargetSize(50, 50))

    assert resized.size == (50, 50)
    assert "#ff00ff" not in distinct_hexes(resized)


def test_golden_panel_reference():
    """Pins the dithering output: a Pillow bump that changes Floyd-Steinberg
    shows up here as a diff instead of as a bad-looking screen."""
    panel, _ = render_derivatives(synthetic_source())

    with Image.open(GOLDEN) as reference:
        assert panel.size == reference.size
        differing = differing_pixels(panel, reference)
        assert differing == 0, (
            f"{differing} of {panel.size[0] * panel.size[1]} pixels differ from {GOLDEN}. "
            "If the change is understood and intended, regenerate with "
            "`python src/forecats-eink/regenerate_golden.py`."
        )
