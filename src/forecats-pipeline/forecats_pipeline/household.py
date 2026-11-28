'''Loading the household from a file a person edits.

Kept separate from `contracts` so the dataclasses stay free of I/O, and separate
from `pipeline` so an n8n node can read the same file without importing the
chain.

The file is plain YAML with no schema language: it holds two cats, and a
validator generator for that is a second file to keep in step. What is checked
here is only what would otherwise fail later and far away — a pet with no
appearance, a pet with no photo named for it.
'''

from pathlib import Path

import yaml

from forecats_pipeline.contracts import Household, Pet

__all__ = ["load_household"]


def load_household(path: Path) -> Household:
    """Read `household.yaml` into a `Household`.

    Raises:
        ValueError: if the file names no pets, or a pet is missing the fields
            that make it recognisable.
    """
    document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    entries = document.get("pets") or ()
    if not entries:
        raise ValueError(f"{path}: no pets listed; a panel with no subjects draws a street")

    pets = tuple(_pet(entry) for entry in entries)
    return Household(
        pets=pets,
        relationship=tuple(document.get("relationship") or ()),
        consistency_rules=tuple(document.get("consistency_rules") or ()),
        art_styles=_art_styles(document),
    )


def _art_styles(document: dict) -> tuple[str, ...]:
    """The styles the panel rotates through, in the order the file lists them.

    An entry that is not a line of text is refused rather than read: a style
    written as `art_styles: risograph` instead of a list would otherwise be
    iterated character by character, and a day would ask to be drawn in `r`.
    """
    listed = document.get("art_styles")
    if listed is None:
        return ()
    if not isinstance(listed, list):
        raise ValueError("art_styles: wants a list with one style per line, not one line")
    styles = tuple(listed)
    if any(not isinstance(style, str) or not style.strip() for style in styles):
        raise ValueError("art_styles: an entry that is not a line of text names no style")
    return tuple(style.strip() for style in styles)


def _pet(entry: dict) -> Pet:
    photo = entry.get("reference_photo")
    if not photo:
        raise ValueError(f"{entry.get('name', '?')}: no reference_photo; the model cannot invent a face")
    return Pet(
        name=entry["name"],
        kind=entry.get("type", "cat"),
        visual_description=entry.get("visual_description", ""),
        reference_photo=Path(photo),
        personality=entry.get("personality", ""),
        signature_details=tuple(entry.get("signature_details") or ()),
    )
