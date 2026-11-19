"""Crop and Spectra6 render pass, ported from jwardbond/forecats `image_processing.py`.

Upstream calls this from Home Assistant; the module itself never imported Home
Assistant, so it runs unchanged for any Python caller. Two upstream behaviours
are deliberately not preserved: an unknown display profile and an unparsable
target size each returned the input untouched, which ships an un-dithered image
to a 6-colour panel. Both raise here.
"""

from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageOps

__all__ = [
    "DISPLAY_PROFILES",
    "PANEL_SIZE",
    "SPECTRA6",
    "TargetSize",
    "recolor_image",
    "render_derivatives",
    "resize_image",
    "rgb_to_hex",
    "write_derivatives",
]

SPECTRA6 = "spectra6"


@dataclass(frozen=True)
class TargetSize:
    """Pixel dimensions of a render target.

    Parsing the `"WIDTHxHEIGHT"` form is a separate step so a size that cannot
    be parsed fails where the string enters the program.
    """

    width: int
    height: int

    def __post_init__(self) -> None:
        if self.width <= 0 or self.height <= 0:
            raise ValueError(
                f"target size must have positive width and height, got {self.width}x{self.height}"
            )

    @classmethod
    def parse(cls, text: str) -> "TargetSize":
        """Parse `"WIDTHxHEIGHT"`, e.g. `"800x480"`."""
        parts = text.strip().split("x")
        if len(parts) != 2:
            raise ValueError(f'target size must be "WIDTHxHEIGHT", got {text!r}')
        try:
            width, height = (int(part) for part in parts)
        except ValueError:
            raise ValueError(
                f'target size must be "WIDTHxHEIGHT" with integer parts, got {text!r}'
            ) from None
        return cls(width, height)


# reTerminal E1002: Spectra6 panel, 800x480.
PANEL_SIZE = TargetSize(800, 480)


def resize_image(image: Image.Image, size: TargetSize) -> Image.Image:
    """Crop then resize to `size`, centred.

    `ImageOps.fit` forces the aspect ratio by cropping; it never letterboxes.
    """
    return ImageOps.fit(
        image,
        size=(size.width, size.height),
        method=Image.Resampling.LANCZOS,
        centering=(0.5, 0.5),
    )


def recolor_image(image: Image.Image, profile: str) -> Image.Image:
    """Quantise `image` to the profile's palette and write the device colours.

    Floyd-Steinberg runs against the TRUE colours the source asks for; the
    indices it chooses are then re-pointed at the DEVICE colours the panel is
    driven with. Collapsing that into one step ships true-palette pixels to a
    6-colour panel, which is what this pass exists to prevent.

    Raises:
        ValueError: If the profile is not one of `DISPLAY_PROFILES`.

    """
    if profile not in DISPLAY_PROFILES:
        accepted = ", ".join(sorted(DISPLAY_PROFILES))
        raise ValueError(f"display profile {profile!r} not found, accepted profiles: {accepted}")

    if image.mode != "RGB":
        image = image.convert("RGB")

    color_map = DISPLAY_PROFILES[profile]["color_map"]

    # `putpalette` below remaps by index, so both palettes take the colour-map
    # rows in the same order and are padded to the same 256-entry width.
    true_palette: list[int] = []
    device_palette: list[int] = []
    for true_color, device_color in color_map.items():
        true_palette.extend(_hex_to_rgb(true_color))
        device_palette.extend(_hex_to_rgb(device_color))
    true_palette.extend([0] * (256 * 3 - len(true_palette)))
    device_palette.extend([0] * (256 * 3 - len(device_palette)))

    # Dither based on palette
    palette_image = Image.new("P", (1, 1))
    palette_image.putpalette(true_palette)
    quantized = image.quantize(palette=palette_image, dither=Image.Dither.FLOYDSTEINBERG)

    # Convert to device palette
    quantized.putpalette(device_palette)
    image = quantized.convert("RGB")

    return image


def render_derivatives(
    image: Image.Image,
    profile: str = SPECTRA6,
    panel_size: TargetSize = PANEL_SIZE,
) -> tuple[Image.Image, Image.Image]:
    """Return the `(panel, full)` renders of `image`: one at `panel_size`, one at source size.

    Each pass quantises the same RGB source. Floyd-Steinberg error is already
    committed in any rendered output, so re-quantising a crop of one derivative
    compounds it into the other.
    """
    panel = recolor_image(resize_image(image, panel_size), profile)
    full = recolor_image(image, profile)
    return panel, full


def write_derivatives(
    image: Image.Image,
    out_dir: str | Path,
    stem: str,
    profile: str = SPECTRA6,
    panel_size: TargetSize = PANEL_SIZE,
) -> tuple[Path, Path]:
    """Write `<stem>-panel.png` and `<stem>-full.png` into `out_dir`."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    panel, full = render_derivatives(image, profile, panel_size)
    panel_path = out_dir / f"{stem}-panel.png"
    full_path = out_dir / f"{stem}-full.png"
    panel.save(panel_path)
    full.save(full_path)
    return panel_path, full_path


def _hex_to_rgb(hex_color):
    hex_color = hex_color.lstrip("#")
    lv = len(hex_color)
    return tuple(int(hex_color[i : i + lv // 3], 16) for i in range(0, lv, lv // 3))


def rgb_to_hex(rgb):
    return "#{:02x}{:02x}{:02x}".format(*rgb)


DISPLAY_PROFILES = {
    "spectra6": {
        # Keyed by the true colour a caller asks for; the value is the colour
        # that drives the Spectra6 inks, measured on the panel.
        "color_map": {
            "#000000": "#191E21",  # Black
            "#FFFFFF": "#E8E8E8",  # White
            "#0000FF": "#2157BA",  # Blue
            "#00FF00": "#125F20",  # Green
            "#FF0000": "#B21318",  # Red
            "#FFFF00": "#EFDE44",  # Yellow
        },
    },
}
