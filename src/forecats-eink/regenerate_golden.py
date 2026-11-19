"""Rewrite the golden reference that `test_golden_panel_reference` compares against.

Run it only after a render change you intend to keep. The test failing first is
the point: a regenerated reference erases the difference rather than explaining
it, so read the diff before running this.
"""

from pathlib import Path

from image_processing import render_derivatives
from test_image_processing import synthetic_source

GOLDEN = Path(__file__).parent / "reference" / "golden-panel.png"

panel, _ = render_derivatives(synthetic_source())
GOLDEN.parent.mkdir(parents=True, exist_ok=True)
panel.save(GOLDEN)
print(GOLDEN)
