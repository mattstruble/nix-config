'''Loading the household from a file a person edits.

Kept separate from `contracts` so the dataclasses stay free of I/O, and separate
from `pipeline` so an n8n node can read the same file without importing the
chain.

The file is plain YAML with no schema language: it holds two cats, and a
validator generator for that is a second file to keep in step. What is checked
here is only what would otherwise fail later and far away — a pet with no
appearance, a photo path that will not survive the trip to the render host.
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
    )


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
