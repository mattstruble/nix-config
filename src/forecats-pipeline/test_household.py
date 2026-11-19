"""The household file is hand-edited, so a typo should fail here and not on a wall."""

from pathlib import Path

import pytest

from forecats_pipeline.household import load_household

REPO = Path(__file__).parents[2]


def write(tmp_path: Path, body: str) -> Path:
    path = tmp_path / "household.yaml"
    path.write_text(body, encoding="utf-8")
    return path


def test_the_shipped_household_loads_and_keeps_both_brothers_distinct():
    household = load_household(REPO / "src/forecats-pipeline/household.yaml")

    names = [pet.name for pet in household.pets]
    assert names == ["Milo", "Mochi"]
    assert all(pet.signature_details for pet in household.pets)
    assert household.consistency_rules, "the negatives are what stop the two merging"
    # The invented descriptions that broke the first renders called these two a
    # grey tabby and a tuxedo. Neither word may come back.
    joined = " ".join(pet.visual_description for pet in household.pets).lower()
    assert "tuxedo" not in joined and "grey" not in joined


def test_a_pet_with_no_photo_is_refused_before_the_render(tmp_path):
    with pytest.raises(ValueError, match="no reference_photo"):
        load_household(write(tmp_path, "pets:\n  - name: Nobody\n"))


def test_an_empty_household_is_refused_rather_than_rendering_an_empty_street(tmp_path):
    with pytest.raises(ValueError, match="no pets"):
        load_household(write(tmp_path, "pets: []\n"))
