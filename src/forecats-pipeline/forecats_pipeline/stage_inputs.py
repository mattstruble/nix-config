"""Put the two inputs that are not store paths where a render looks for them.

The pipeline reads four weight files and one photo per pet, and neither set is
built by anything in this repository: the weights arrive from a model hub and
the photos from a person's camera roll. They are ordinary host directories
because the store is what a garbage collector visits — a hand-built binary whose
glibc was collected is the failure that settled that — and the volumes the pod
mounts are those directories.

So placement is a step a person runs, and it has to be re-runnable: 17.9 GB
copied to a full volume stops halfway, and the retry must not start again from
nothing. The whole set is digested before the first byte is copied, each file is
written beside its name and renamed, and a file whose bytes already match is
skipped. A digest that disagrees is refused rather than overwritten, because the
alternative is a render that quietly uses the wrong weights.

`python3 -m forecats_pipeline.stage_inputs weights --from <dir> --manifest <file>`
and `... photos --from <dir>` are the two commands; `RUNBOOK.md` says where their
arguments come from. Neither names its destination, because the wrapper exports
both volume directories from the storage declaration that creates them — `--to`
is for the one-off run that stages somewhere else.
"""

import argparse
import json
import os
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
from shutil import copyfileobj

import yaml

from forecats_pipeline.household import load_household
from forecats_pipeline.render_stage import (
    MODEL_DIRECTORY_ENV,
    PHOTO_DIRECTORY_ENV,
    WEIGHT_FILE_NAMES,
)

__all__ = ["StageError", "main"]

# 17.9 GB is read a file at a time; the block size is only about how often the
# digest is updated.
DIGEST_BLOCK_BYTES = 4 * 1024 * 1024
COPY_BLOCK_BYTES = 4 * 1024 * 1024


class StageError(Exception):
    """A placement that will not be attempted, and the reason in one line."""


@dataclass(frozen=True)
class Placement:
    """One file that is now where it was asked to be."""

    destination: Path
    sha256: str
    copied: bool


def stage_files(
    source_dir: Path,
    destination_dir: Path,
    names: Sequence[str],
    expected_digests: Mapping[str, str] | None = None,
    on_place: Callable[[Placement], None] | None = None,
) -> tuple[Placement, ...]:
    """Copy `names` from `source_dir` to `destination_dir`, verified by sha256.

    `expected_digests` is the authority when it is given: a source whose bytes
    are not what upstream says they are must not become the host's copy. Without
    it the source's own digest is what the copy is checked against, which proves
    the copy and nothing about the source.

    Every source is digested before anything is written. Refusing halfway through
    a set of four weights would leave three of them in place, and the retry that
    skips those three reads as a refusal about a file that was never touched.

    `on_place` sees each file as it lands, so a copy that fails partway still
    reports what is already on the volume.

    Raises:
        StageError: if a source is missing, a digest disagrees, or a copy lands
            short. Nothing is put in place when this raises; a copy that fails
            after the first files landed names them in what `on_place` printed.
    """
    expected = expected_digests or {}
    verified = tuple(_verify(source_dir / name, expected.get(name)) for name in names)
    placements = []
    for source, digest in verified:
        placement = _place(source, destination_dir / source.name, digest)
        if on_place is not None:
            on_place(placement)
        placements.append(placement)
    return tuple(placements)


def _verify(source: Path, expected: str | None) -> tuple[Path, str]:
    """The source's digest, refused now rather than after three files copied."""
    if not source.is_file():
        raise StageError(f"{source} is not a file")
    digest = _sha256_of(source)
    if expected is not None and digest != expected:
        raise StageError(f"{source}: sha256 {digest} is not the manifest's {expected}")
    return source, digest


def _place(source: Path, destination: Path, digest: str) -> Placement:
    if destination.is_file() and _sha256_of(destination) == digest:
        return Placement(destination, digest, copied=False)
    _copy_verified(source, destination, digest)
    return Placement(destination, digest, copied=True)


def _copy_verified(source: Path, destination: Path, expected: str) -> None:
    """Copy, then read back what landed, then rename.

    The read-back is the whole point: a copy that filled the volume and stopped
    at zero bytes exits 0, and the file that fails at 04:00 is the one nobody
    checked.
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = destination.with_name(f".{destination.name}.part")
    try:
        with source.open("rb") as reader, staging.open("wb") as writer:
            copyfileobj(reader, writer, COPY_BLOCK_BYTES)
        written = _sha256_of(staging)
        if written != expected:
            raise StageError(
                f"{destination}: wrote {written}, expected {expected}; the partial copy was discarded"
            )
        os.replace(staging, destination)
    finally:
        staging.unlink(missing_ok=True)


def _sha256_of(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(DIGEST_BLOCK_BYTES), b""):
            digest.update(block)
    return digest.hexdigest()


def _stage_weights(args: argparse.Namespace) -> int:
    manifest = _read_manifest(Path(args.manifest))
    required = list(WEIGHT_FILE_NAMES)
    missing = [name for name in required if name not in manifest]
    if missing:
        raise StageError(
            f"{args.manifest} does not name {', '.join(missing)}; the render opens all four, "
            "so placing three of them is a render that fails on the GPU"
        )
    destination = Path(_volume_directory(MODEL_DIRECTORY_ENV, args.destination))
    placements = stage_files(
        Path(args.source_dir), destination, sorted(manifest), manifest, on_place=_announce
    )
    return _summary("weights", destination, placements)


def _stage_photos(args: argparse.Namespace) -> int:
    # Absolute on both sides: a photo path is opened by the render wherever it
    # runs, so a relative one means nothing until a directory is named for it —
    # and comparing one against `--to` would answer relative to this shell's
    # directory rather than to anything the render will see.
    destination = Path(os.path.abspath(_volume_directory(PHOTO_DIRECTORY_ENV, args.destination)))
    household = load_household(Path(args.household_file))
    names: list[str] = []
    for pet in household.pets:
        photo = pet.reference_photo
        if not photo.is_absolute():
            raise StageError(
                f"{pet.name}'s reference photo is {photo}, a relative path; the render opens "
                f"it as written, so name it inside {destination}"
            )
        if Path(os.path.abspath(photo)).parent != destination:
            raise StageError(
                f"{pet.name}'s reference photo is {photo}, outside {destination}; the render "
                "reads the household file, so photos staged anywhere else are photos it will "
                "never open"
            )
        if photo.name not in names:
            names.append(photo.name)
    placements = stage_files(Path(args.source_dir), destination, names, on_place=_announce)
    return _summary("photos", destination, placements)


def _volume_directory(env_name: str, destination: str | None) -> str:
    """The volume to stage into, from `--to` or from the environment nix exports.

    The storage declaration that creates the directory is what names it, so this
    module holds no path of its own; a run with neither is refused rather than
    aimed at a directory nothing mounts.
    """
    directory = destination or os.environ.get(env_name, "")
    if not directory.strip():
        raise StageError(
            f"no destination: --to is not given and {env_name} is not set; the storage "
            "declaration that mounts the volume names the directory, and the wrapper exports it"
        )
    return directory


def _read_manifest(path: Path) -> dict[str, str]:
    """`{"<file>": "<sha256>"}`, the digests upstream publishes for the files."""
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as problem:
        raise StageError(f"{path}: not valid JSON: {problem}") from problem
    if not isinstance(document, dict) or not document:
        raise StageError(f"{path}: expected a JSON object of file name to sha256")
    return {str(name): str(digest) for name, digest in document.items()}


def _announce(placement: Placement) -> None:
    """One line per file, as it lands, so a failure names what is already there."""
    print(
        f"{'copied' if placement.copied else 'already placed'} {placement.destination} "
        f"sha256={placement.sha256}"
    )


def _summary(kind: str, destination: Path, placements: Sequence[Placement]) -> int:
    copied = sum(1 for placement in placements if placement.copied)
    print(f"{kind}: {len(placements)} files verified at {destination}, {copied} copied")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        return _STAGES[args.command](args)
    except (StageError, OSError, ValueError, yaml.YAMLError) as problem:
        # The whole output of a refused placement is the one line a person reads
        # in a job log; a frame dump puts the cause under a screen of frames.
        # `yaml.YAMLError` is here because a household file that stopped parsing
        # is refused staging, not a crash to debug, and `ValueError` because it
        # is what `load_household` documents for a file that parses into a
        # household that cannot be rendered.
        print(f"staging refused: {problem}")
        return 1


def _parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="forecats-stage-inputs",
        description="Place the weights and the reference photos on the host volumes.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    weights = commands.add_parser("weights", help="the diffusion weights, digest-verified")
    weights.add_argument("--from", dest="source_dir", required=True, help="downloaded weight files")
    weights.add_argument(
        "--to",
        dest="destination",
        help=f"the weights directory; the default is what {MODEL_DIRECTORY_ENV} holds",
    )
    weights.add_argument(
        "--manifest",
        required=True,
        help="JSON object of file name to the sha256 upstream publishes for it",
    )

    photos = commands.add_parser("photos", help="one reference photo per pet, by the household file")
    photos.add_argument("--from", dest="source_dir", required=True, help="the photo files to place")
    photos.add_argument(
        "--to",
        dest="destination",
        help=f"the photo directory; the default is what {PHOTO_DIRECTORY_ENV} holds",
    )
    photos.add_argument(
        "--household-file",
        default="src/forecats-pipeline/household.yaml",
        help="the file the render reads; it names the photos and where they must be",
    )

    return parser.parse_args(argv)


_STAGES = {"weights": _stage_weights, "photos": _stage_photos}

if __name__ == "__main__":
    sys.exit(main())
