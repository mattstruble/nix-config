"""The placement step is run by a person, so what it prints and leaves behind is the contract.

Every test here drives `python3 -m forecats_pipeline.stage_inputs` the way the
runbook does, because the module form is the command that is documented — and
the one that can exit 0 having done nothing.
"""

import json
import os
import subprocess
import sys
from hashlib import sha256
from pathlib import Path

import day_context
import forecats_pipeline
from forecats_pipeline.render_stage import (
    MODEL_DIRECTORY_ENV,
    PHOTO_DIRECTORY_ENV,
    WEIGHT_FILE_NAMES,
)

# The four files a render opens; placement refuses a manifest that leaves one out.
REQUIRED = list(WEIGHT_FILE_NAMES)

# The two source trees, as the running interpreter found them. `-m` imports the
# package, and the package imports the day-context layer.
SOURCE_ROOTS = os.pathsep.join(
    str(Path(module.__file__).parent.parent) for module in (day_context, forecats_pipeline)
)


def run_module(
    *arguments: str,
    environment: dict[str, str] | None = None,
    unset: tuple[str, ...] = (),
) -> subprocess.CompletedProcess:
    """One placement, in a child whose environment this test names.

    `unset` takes an exported volume directory away, which is the state of a shell
    the wrapper was not run from; `environment` stands in for the one the wrapper
    did export.
    """
    child = {
        **os.environ,
        "PYTHONPATH": SOURCE_ROOTS,
        "PYTHONDONTWRITEBYTECODE": "1",
        **(environment or {}),
    }
    for name in unset:
        child.pop(name, None)
    return subprocess.run(
        [sys.executable, "-m", "forecats_pipeline.stage_inputs", *arguments],
        capture_output=True,
        text=True,
        env=child,
        check=False,
    )


def sha256_of(path: Path) -> str:
    return sha256(path.read_bytes()).hexdigest()


def weight_files(root: Path) -> list[str]:
    root.mkdir(parents=True, exist_ok=True)
    for name in REQUIRED:
        root.joinpath(name).write_bytes(f"the bytes of {name}".encode())
    return REQUIRED


def manifest(tmp_path: Path, digests: dict[str, str]) -> Path:
    path = tmp_path / "weights-manifest.json"
    path.write_text(json.dumps(digests), encoding="utf-8")
    return path


def household(tmp_path: Path, directory: Path, *photo_names: str) -> Path:
    entries = "".join(
        f"  - name: Pet{index}\n"
        "    visual_description: an animal with a look\n"
        f"    reference_photo: {directory / name}\n"
        for index, name in enumerate(photo_names, start=1)
    )
    path = tmp_path / "household.yaml"
    path.write_text(f"pets:\n{entries}", encoding="utf-8")
    return path


def place_weights(tmp_path: Path) -> tuple[Path, Path, Path]:
    """A download directory, the volume directory to fill, and a correct manifest."""
    source = tmp_path / "download"
    names = weight_files(source)
    destination = tmp_path / "h3image"
    listed = manifest(tmp_path, {name: sha256_of(source / name) for name in names})
    return source, destination, listed


def test_the_module_form_places_every_weight_and_prints_its_digest(tmp_path: Path):
    source, destination, listed = place_weights(tmp_path)

    run = run_module(
        "weights", "--from", str(source), "--to", str(destination), "--manifest", str(listed)
    )

    assert run.returncode == 0, run.stderr
    assert [name for name in REQUIRED if (destination / name).is_file()] == REQUIRED
    assert sha256_of(destination / REQUIRED[0]) in run.stdout


def test_the_placement_step_reruns_without_copying_anything(tmp_path: Path):
    """17.9 GB that stops halfway is retried, and a retry must not start over."""
    source, destination, listed = place_weights(tmp_path)
    arguments = ("weights", "--from", str(source), "--to", str(destination), "--manifest", str(listed))
    run_module(*arguments)
    written = {name: (destination / name).stat().st_mtime_ns for name in REQUIRED}

    second = run_module(*arguments)

    assert second.returncode == 0, second.stderr
    assert "already placed" in second.stdout
    assert second.stdout.endswith("0 copied\n")
    assert {name: (destination / name).stat().st_mtime_ns for name in REQUIRED} == written


def test_a_weight_that_is_not_the_bytes_upstream_describes_is_refused(tmp_path: Path):
    source = tmp_path / "download"
    names = weight_files(source)
    digests = {name: sha256_of(source / name) for name in names}
    digests[REQUIRED[0]] = "0" * 64
    listed = manifest(tmp_path, digests)
    destination = tmp_path / "h3image"

    run = run_module(
        "weights", "--from", str(source), "--to", str(destination), "--manifest", str(listed)
    )

    assert run.returncode == 1
    assert "staging refused" in run.stdout
    assert REQUIRED[0] in run.stdout
    assert not (destination / REQUIRED[0]).exists()


def test_a_later_weight_that_disagrees_with_the_manifest_places_nothing(tmp_path: Path):
    """A refusal halfway through four weights would leave three on the volume.

    The retry then skips those three and refuses about the fourth, which reads as
    a refusal about a file that was never touched.
    """
    source = tmp_path / "download"
    names = weight_files(source)
    digests = {name: sha256_of(source / name) for name in names}
    last = sorted(digests)[-1]
    digests[last] = "0" * 64
    listed = manifest(tmp_path, digests)
    destination = tmp_path / "h3image"

    run = run_module(
        "weights", "--from", str(source), "--to", str(destination), "--manifest", str(listed)
    )

    assert run.returncode == 1
    assert last in run.stdout
    assert not destination.exists()


def test_a_manifest_that_omits_a_weight_the_render_opens_is_refused(tmp_path: Path):
    source, destination, _ = place_weights(tmp_path)
    incomplete = manifest(tmp_path, {name: sha256_of(source / name) for name in REQUIRED[1:]})

    run = run_module(
        "weights", "--from", str(source), "--to", str(destination), "--manifest", str(incomplete)
    )

    assert run.returncode == 1
    assert REQUIRED[0] in run.stdout
    assert not destination.exists()


def test_the_photos_the_household_names_are_placed(tmp_path: Path):
    destination = tmp_path / "photos"
    source = tmp_path / "camera-roll"
    source.mkdir()
    for name in ("milo.jpg", "mochi.jpg"):
        source.joinpath(name).write_bytes(b"\xff\xd8\xff\xe0")
    listed = household(tmp_path, destination, "milo.jpg", "mochi.jpg")

    run = run_module(
        "photos", "--from", str(source), "--to", str(destination), "--household-file", str(listed)
    )

    assert run.returncode == 0, run.stderr
    assert sorted(path.name for path in destination.iterdir()) == ["milo.jpg", "mochi.jpg"]


def test_a_photo_that_is_not_in_the_source_refuses_the_staging(tmp_path: Path):
    """A pet with no photo renders an invented animal, so the staging stops."""
    destination = tmp_path / "photos"
    source = tmp_path / "camera-roll"
    source.mkdir()
    source.joinpath("milo.jpg").write_bytes(b"\xff\xd8\xff\xe0")
    listed = household(tmp_path, destination, "milo.jpg", "mochi.jpg")

    run = run_module(
        "photos", "--from", str(source), "--to", str(destination), "--household-file", str(listed)
    )

    assert run.returncode == 1
    assert "staging refused" in run.stdout
    assert "mochi.jpg" in run.stdout


def test_photos_staged_where_the_household_does_not_look_are_refused(tmp_path: Path):
    """The household file is what the render reads, so it decides where photos go."""
    source = tmp_path / "camera-roll"
    source.mkdir()
    source.joinpath("milo.jpg").write_bytes(b"\xff\xd8\xff\xe0")
    listed = household(tmp_path, tmp_path / "somewhere-else", "milo.jpg")

    run = run_module(
        "photos",
        "--from",
        str(source),
        "--to",
        str(tmp_path / "photos"),
        "--household-file",
        str(listed),
    )

    assert run.returncode == 1
    assert "somewhere-else" in run.stdout


def test_a_relative_photo_path_is_refused(tmp_path: Path):
    """A relative photo is opened relative to wherever the render happens to run."""
    source = tmp_path / "camera-roll"
    source.mkdir()
    source.joinpath("milo.jpg").write_bytes(b"\xff\xd8\xff\xe0")
    listed = tmp_path / "household.yaml"
    listed.write_text(
        "pets:\n  - name: Milo\n    visual_description: a ginger tabby\n    reference_photo: milo.jpg\n",
        encoding="utf-8",
    )

    run = run_module(
        "photos",
        "--from",
        str(source),
        "--to",
        str(tmp_path / "photos"),
        "--household-file",
        str(listed),
    )

    assert run.returncode == 1
    assert "relative path" in run.stdout
    assert not (tmp_path / "photos").exists()


def test_a_household_file_that_stopped_parsing_is_refused_not_traced(tmp_path: Path):
    listed = tmp_path / "household.yaml"
    listed.write_text(
        "pets:\n  - name: Milo\n   reference_photo: /var/lib/forecats/photos/milo.jpg\n",
        encoding="utf-8",
    )

    run = run_module(
        "photos",
        "--from",
        str(tmp_path),
        "--to",
        str(tmp_path / "photos"),
        "--household-file",
        str(listed),
    )

    assert run.returncode == 1
    assert "staging refused" in run.stdout
    assert "Traceback" not in run.stderr


def test_the_exported_weights_directory_is_the_destination_nothing_named(tmp_path: Path):
    """The wrapper exports the directory the storage declaration created.

    The placement step and the render then agree on one path written in one
    language: what this test puts in the environment is what the weights land in.
    """
    source, _, listed = place_weights(tmp_path)
    volume = tmp_path / "var-lib-llama-models"

    run = run_module(
        "weights",
        "--from",
        str(source),
        "--manifest",
        str(listed),
        environment={MODEL_DIRECTORY_ENV: str(volume)},
    )

    assert run.returncode == 0, run.stderr
    assert sorted(path.name for path in volume.iterdir()) == sorted(REQUIRED)


def test_a_weights_directory_neither_named_nor_exported_is_refused(tmp_path: Path):
    """No path here is a second answer to a question the declaration answers.

    With neither `--to` nor the exported directory there is nothing to stage into,
    and a literal default would have staged into a directory the declaration may
    have moved — the drift that leaves a render reading an empty volume.
    """
    source, destination, listed = place_weights(tmp_path)

    run = run_module(
        "weights",
        "--from",
        str(source),
        "--manifest",
        str(listed),
        unset=(MODEL_DIRECTORY_ENV,),
    )

    assert run.returncode == 1
    assert MODEL_DIRECTORY_ENV in run.stdout
    assert not destination.exists()


def test_a_photo_directory_neither_named_nor_exported_is_refused(tmp_path: Path):
    source = tmp_path / "camera-roll"
    source.mkdir()
    source.joinpath("milo.jpg").write_bytes(b"\xff\xd8\xff\xe0")
    listed = household(tmp_path, tmp_path / "photos", "milo.jpg")

    run = run_module(
        "photos",
        "--from",
        str(source),
        "--household-file",
        str(listed),
        unset=(PHOTO_DIRECTORY_ENV,),
    )

    assert run.returncode == 1
    assert PHOTO_DIRECTORY_ENV in run.stdout
    assert not (tmp_path / "photos").exists()


def test_the_module_answers_a_bare_invocation_with_what_it_takes():
    """A command that exits 0 having parsed nothing is a silent no-op."""
    run = run_module()

    assert run.returncode != 0
    assert "weights" in run.stderr and "photos" in run.stderr
