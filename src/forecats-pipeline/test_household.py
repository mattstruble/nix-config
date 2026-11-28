"""The household file is hand-edited, so a typo should fail here and not on a wall."""

import os
from pathlib import Path

import pytest

from forecats_pipeline.household import load_household
from forecats_pipeline.render_stage import PHOTO_DIRECTORY_ENV

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


@pytest.mark.skipif(
    PHOTO_DIRECTORY_ENV not in os.environ,
    reason=(
        f"{PHOTO_DIRECTORY_ENV} is exported by the render wrapper, not by a checkout, so "
        "there is no photo volume for the household file to agree with here. Set it to "
        "the directory the storage declaration creates to run this assertion."
    ),
)
def test_the_shipped_photos_are_the_ones_the_photo_volume_carries():
    """A photo path outside the mounted directory is a pet no pod can render.

    The directory is the one the storage declaration creates and the wrapper
    exports; the household file is the third thing that has to name it, so it is
    checked against that export rather than against a copy of the path here. It
    skips when that export is absent rather than failing, because a suite that is
    red in a clean checkout is a suite that gets ignored, and nothing in CI runs
    this suite to tell anyone it went red.
    """
    household = load_household(REPO / "src/forecats-pipeline/household.yaml")
    photo_directory = os.environ[PHOTO_DIRECTORY_ENV]

    assert {str(pet.reference_photo.parent) for pet in household.pets} == {photo_directory}


def test_the_shipped_styles_are_a_rotation_and_not_a_repeated_line():
    """A list of one is the fixed string this replaced; a duplicate is a shorter list.

    The list itself is the file's to hold — nothing here restates it, because a
    second copy of a list a person edits is a check that can pass while both are
    wrong.
    """
    styles = load_household(REPO / "src/forecats-pipeline/household.yaml").art_styles

    assert len(styles) > 1, "one style is not a rotation"
    assert len(set(styles)) == len(styles), "a style listed twice is one fewer style"


def test_styles_written_as_one_line_are_refused_rather_than_read_as_letters(tmp_path):
    """`art_styles: risograph` is a string, and a string iterates one letter a day."""
    with pytest.raises(ValueError, match="art_styles"):
        load_household(
            write(
                tmp_path,
                "pets:\n  - name: Milo\n    reference_photo: /r/milo.jpg\n"
                "    visual_description: a tabby\nart_styles: risograph\n",
            )
        )


def test_a_household_naming_no_styles_names_none_rather_than_borrowing_a_default(tmp_path):
    """The fallback style belongs to the caption stage, not to this loader.

    A default here would be a second place a style is written down, and the one
    the shipped file could silently disagree with.
    """
    household = load_household(
        write(
            tmp_path,
            "pets:\n  - name: Milo\n    reference_photo: /r/milo.jpg\n"
            "    visual_description: a tabby\n",
        )
    )

    assert household.art_styles == ()


def test_a_pet_with_no_photo_is_refused_before_the_render(tmp_path):
    with pytest.raises(ValueError, match="no reference_photo"):
        load_household(write(tmp_path, "pets:\n  - name: Nobody\n"))


def test_an_empty_household_is_refused_rather_than_rendering_an_empty_street(tmp_path):
    with pytest.raises(ValueError, match="no pets"):
        load_household(write(tmp_path, "pets: []\n"))
