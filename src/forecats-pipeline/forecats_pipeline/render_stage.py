"""Stage 3: make the picture.

Two implementations of one `Renderer` contract. `FakeRenderer` writes a
placeholder PNG and is what the suite runs against — the chain is testable with
no GPU and no weights on disk. `SdCliRenderer` is the real one: it runs the
diffusion CLI as a child process, in this container, on the card this container
was placed on.

Nothing here reaches another host. The stage used to SSH to the box with the
cards and scp the PNG back, which asked a pod for a hostname and an SSH key in
order to use the GPU already attached to it, and left that pod holding a card
nothing inside it touched. The weights, the reference photos and the CLI arrive
as mounted volumes and a store path on `PATH`; `RUNBOOK.md` names the claims and
the step that fills them.
"""

import os
import subprocess
from collections.abc import Sequence
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
from struct import Struct
from typing import Protocol
from zlib import crc32, compressobj

from forecats_pipeline.contracts import Caption, PipelineRefusal

__all__ = [
    "FakeRenderer",
    "Rendered",
    "Renderer",
    "SdCliRenderer",
    "SdCliSettings",
]

# sd-cli needs the real `libcuda.so.1` on `LD_LIBRARY_PATH`. Without it CUDA does
# not fail: it initialises against the stub driver in a nix CUDA build closure,
# logs "no GPU devices", and renders on the CPU. Same exit code, same output
# file, a different sampler schedule, roughly ten times the wall time. On a
# NixOS host the real driver sits in this directory; a GPU pod has it on the
# default loader path instead, so the directory is prepended when it exists
# rather than exported unconditionally. Nothing about the picture says so, which
# is why the renderer reads the log instead of trusting the exit status.
GPU_DRIVER_DIRECTORY = "/run/opengl-driver/lib"

# What sd-cli prints when it has quietly given up on the GPU.
CPU_FALLBACK_MARKS = ("CUDA driver is a stub library", "no GPU devices")

# The card a render may use is named from outside this module: a pod carries the
# one it was placed on in this variable, and `--render-gpu` is for a host with no
# such pin. With neither, the child inherits every card on the host — GPU0, the
# owner's live session, included — which is the collision the pin exists to
# prevent, so an absent pin refuses and nothing here may choose a card of its own.
DEVICE_PIN_ENV = "NVIDIA_VISIBLE_DEVICES"

# The directory the weights volume is mounted at, in the pod and on the host that
# fills it. One path for both, so the file names below are the files a render
# opens; `forecats-weights` is the claim that carries them.
MODEL_DIRECTORY = "/var/lib/llama-models/h3image"

# Where the reference-photo volume is mounted, on the same arrangement from the
# read-only `forecats-photos` claim.
PHOTO_DIRECTORY = "/var/lib/forecats/photos"

# The schedule, in one place. The timeout used to be a separate number sized for
# a 6-step run, so moving to 20 steps made every render die at 600 s with a
# message that blamed ssh. Anything that has to agree with the schedule is now
# derived from it.
RENDER_STEPS = 20
CFG_SCALE = 3.5

# Measured on a TITAN RTX at 1024x1024: about 35 s a step once the weights are
# resident. The allowance is for loading 18 GB of weights on a host whose page
# cache is competing with a serving model, which has been observed to cost
# minutes rather than seconds.
SECONDS_PER_STEP = 35.0
WEIGHT_LOAD_ALLOWANCE_SECONDS = 420.0

RENDER_TIMEOUT_SECONDS = RENDER_STEPS * SECONDS_PER_STEP + WEIGHT_LOAD_ALLOWANCE_SECONDS

_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


@dataclass(frozen=True)
class Rendered:
    """A panel that exists, and what it took to draw it.

    `weights` and `reference_photos` are paths, not digests: a provenance field
    must not cost a read of the 18 GB it describes, and the digests of what is on
    the volume are the placement step's job (`stage_inputs.py`), taken when the
    bytes arrived.
    """

    panel_path: Path
    renderer: str
    seed: int
    width_px: int
    height_px: int
    weights: tuple[str, ...]
    reference_photos: tuple[Path, ...]


class Renderer(Protocol):
    """Answers "draw this caption" and says which picture it drew."""

    name: str

    def render(
        self,
        caption: Caption,
        *,
        seed: int,
        reference_photos: Sequence[Path],
        destination: Path,
    ) -> Rendered | PipelineRefusal: ...


class FakeRenderer:
    """A `Renderer` that writes a flat-colour PNG and never asks for a GPU.

    The placeholder is a real, decodable PNG at the requested size so that
    everything downstream — copying, sidecars, the e-ink conversion — sees a
    panel shaped like the real thing.
    """

    name = "fake"

    def __init__(self, weights: Sequence[str] = ()) -> None:
        self._weights = tuple(weights)

    def render(
        self,
        caption: Caption,
        *,
        seed: int,
        reference_photos: Sequence[Path],
        destination: Path,
    ) -> Rendered:
        width, height = 64, 64
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(_placeholder_png(width, height, caption.text))
        return Rendered(
            panel_path=destination,
            renderer=self.name,
            seed=seed,
            width_px=width,
            height_px=height,
            weights=self._weights,
            reference_photos=tuple(reference_photos),
        )


@dataclass(frozen=True)
class SdCliSettings:
    """Which weight files a render opens, and which card it opens them on.

    Paths, not a directory listing: the model directory holds 17 GB and the four
    files that matter are named here on purpose. They are the defaults rather
    than a setting because the volume they mount from is fixed by the claim, and
    a render that looked elsewhere would find an empty directory.
    """

    diffusion_model: str = f"{MODEL_DIRECTORY}/minimax_h3_image_pruned-Q3_K_M.gguf"
    vae: str = f"{MODEL_DIRECTORY}/vae_diffusion_pytorch_model.safetensors"
    text_encoder: str = f"{MODEL_DIRECTORY}/p-h3-image_text_encoder_int8_convrot.safetensors"
    tokenizer: str = f"{MODEL_DIRECTORY}/p-h3-image_tokenizer.json"
    gpu_device: str | None = None

    @property
    def weights(self) -> tuple[str, ...]:
        return (self.diffusion_model, self.vae, self.text_encoder)

    @property
    def files(self) -> tuple[str, ...]:
        """Every weight-side file the CLI is handed, tokenizer included."""
        return (*self.weights, self.tokenizer)

    @classmethod
    def for_directory(cls, directory: str | Path, gpu_device: str | None = None) -> "SdCliSettings":
        """The same four files, read out of another directory.

        The defaults are the mount point of the weights volume, which is what a
        pod has; a host that keeps the weights anywhere else names its own.
        """
        defaults = cls()
        root = Path(directory)
        return cls(
            diffusion_model=str(root / Path(defaults.diffusion_model).name),
            vae=str(root / Path(defaults.vae).name),
            text_encoder=str(root / Path(defaults.text_encoder).name),
            tokenizer=str(root / Path(defaults.tokenizer).name),
            gpu_device=gpu_device,
        )


class SdCliRenderer:
    """The real renderer: the diffusion CLI, run here, on the card held here."""

    name = "sd-cli"

    def __init__(
        self,
        binary: str,
        settings: SdCliSettings,
        *,
        width_px: int = 1024,
        height_px: int = 1024,
        timeout_seconds: float = RENDER_TIMEOUT_SECONDS,
    ) -> None:
        if not binary.strip():
            raise ValueError("binary must be the diffusion CLI to run")
        self._binary = binary
        self._settings = settings
        self._width_px = width_px
        self._height_px = height_px
        self._timeout_seconds = timeout_seconds

    def render(
        self,
        caption: Caption,
        *,
        seed: int,
        reference_photos: Sequence[Path],
        destination: Path,
    ) -> Rendered | PipelineRefusal:
        if self._pinned_device() is None:
            return PipelineRefusal(stage="render", reason=self._unpinned_reason())

        absent = self._absent_inputs(reference_photos)
        if absent:
            return PipelineRefusal(stage="render", reason=self._absent_reason(absent))

        # The CLI writes the panel itself, so the directory has to exist first
        # and a refusal after this point may leave a partial file behind.
        destination.parent.mkdir(parents=True, exist_ok=True)
        argv = self._command(caption, seed=seed, reference_photos=reference_photos, destination=destination)
        log = self._run(argv)
        if isinstance(log, PipelineRefusal):
            return log
        if any(mark in log for mark in CPU_FALLBACK_MARKS):
            # It exited 0 and wrote a picture. It drew that picture on the CPU,
            # on a different schedule, at ten times the cost.
            return PipelineRefusal(
                stage="render",
                reason=(
                    f"{self.name}: no usable GPU, so the model fell back to the CPU "
                    f"({next(mark for mark in CPU_FALLBACK_MARKS if mark in log)}); the real "
                    f"libcuda must be on LD_LIBRARY_PATH ({GPU_DRIVER_DIRECTORY} on a NixOS host)"
                ),
            )
        if not destination.is_file():
            return PipelineRefusal(
                stage="render",
                reason=f"{self.name}: exited 0 without writing {destination}",
            )

        return Rendered(
            panel_path=destination,
            renderer=self.name,
            seed=seed,
            width_px=self._width_px,
            height_px=self._height_px,
            weights=self._settings.weights,
            reference_photos=tuple(reference_photos),
        )

    def _pinned_device(self) -> str | None:
        """The card this render was told it holds, or `None` when nothing says.

        `--render-gpu` is a caller naming a card on a host with no pod pin; the
        pod's own pin is the environment's, and it is read as it stands — a pin
        of one card must not arrive at the CLI as a pin of two.
        """
        explicit = _named_device(self._settings.gpu_device)
        if explicit is not None:
            return explicit
        return _named_device(os.environ.get(DEVICE_PIN_ENV))

    def _unpinned_reason(self) -> str:
        return (
            f"{self.name}: no card pinned — {DEVICE_PIN_ENV} is unset and no card was named "
            f"with --render-gpu, so the render would inherit every card on the host and may "
            f"take the one the owner is working on; run it in a pod pinned by "
            f"{DEVICE_PIN_ENV}, or pass --render-gpu (SdCliSettings.gpu_device)"
        )

    def _absent_inputs(self, reference_photos: Sequence[Path]) -> tuple[Path, ...]:
        """The files this render was told to open and cannot find.

        A weight that is absent says a volume mounted as an empty directory. A
        photo that is absent is the worse half: sd-cli renders an invented
        animal, exits 0, and the panel shows a cat that does not live here.
        """
        expected = [Path(name) for name in self._settings.files]
        expected.extend(reference_photos)
        return tuple(path for path in expected if not path.is_file())

    def _absent_reason(self, absent: Sequence[Path]) -> str:
        named = ", ".join(str(path) for path in absent)
        return (
            f"{self.name}: no such file — {named}; weights are read from the "
            f"{MODEL_DIRECTORY} volume and reference photos from the {PHOTO_DIRECTORY} one, "
            "so an absent file is a volume that mounted empty (see RUNBOOK.md)"
        )

    def _command(
        self,
        caption: Caption,
        *,
        seed: int,
        reference_photos: Sequence[Path],
        destination: Path,
    ) -> list[str]:
        settings = self._settings
        argv = [
            self._binary,
            "--diffusion-model",
            settings.diffusion_model,
            "--vae",
            settings.vae,
            "--llm",
            settings.text_encoder,
            "--tokenizer",
            settings.tokenizer,
            "-p",
            caption.text,
            "--cfg-scale",
            str(CFG_SCALE),
            # 20 steps, not the 6-step distilled schedule: at 6 the weather
            # gauge came out unreadable. Roughly twelve minutes a panel against
            # two, which a nightly job on an otherwise idle GPU can afford.
            "--steps",
            str(RENDER_STEPS),
            "--sampling-method",
            "euler",
            "--rng",
            "cpu",
            "--seed",
            str(seed),
            "-W",
            str(self._width_px),
            "-H",
            str(self._height_px),
            "-o",
            str(destination),
        ]
        for photo in reference_photos:
            argv += ["-r", str(photo)]
        if reference_photos:
            argv.append("--increase-ref-index")
        return argv

    def _child_environment(self) -> dict[str, str]:
        """This process's environment, plus the one thing the CLI cannot default.

        The card is not chosen here. A pod is pinned by `NVIDIA_VISIBLE_DEVICES`,
        and the nvidia runtime then hides the other cards from inside the
        container, so a device named here would name one the render cannot see.
        `--render-gpu` is for a host with no such pin; there GPU0 is the owner's
        live session and a nightly job that stole it would be noticed in seconds.
        """
        environment = dict(os.environ)
        explicit = _named_device(self._settings.gpu_device)
        if explicit is not None:
            environment["CUDA_VISIBLE_DEVICES"] = explicit
        if Path(GPU_DRIVER_DIRECTORY).is_dir():
            current = environment.get("LD_LIBRARY_PATH", "")
            environment["LD_LIBRARY_PATH"] = (
                GPU_DRIVER_DIRECTORY if not current else f"{GPU_DRIVER_DIRECTORY}{os.pathsep}{current}"
            )
        return environment

    def _run(self, argv: Sequence[str]) -> str | PipelineRefusal:
        command = list(argv)
        try:
            completed = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=self._timeout_seconds,
                env=self._child_environment(),
                check=False,
            )
        except subprocess.TimeoutExpired:
            return PipelineRefusal(
                stage="render",
                reason=f"{self.name}: {command[0]} exceeded {self._timeout_seconds:g}s and was killed",
            )
        except OSError as error:
            return PipelineRefusal(
                stage="render", reason=f"{self.name}: could not run {command[0]}: {error}"
            )

        if completed.returncode != 0:
            detail = (completed.stderr or completed.stdout or "").strip()[-400:]
            return PipelineRefusal(
                stage="render",
                reason=f"{self.name}: {command[0]} exited {completed.returncode}: {detail}",
            )
        # Both streams, because ggml logs to stderr and the CPU-fallback marker is
        # a ggml line: a log made of stdout alone would be a fallback that read as
        # a render. The caller reads this only for those markers.
        return (completed.stdout or "") + (completed.stderr or "")


def _named_device(value: str | None) -> str | None:
    """`value` when it names a card, `None` when it is absent or blank.

    A `--render-gpu ''` from a shell is an unset one, and exporting it as
    `CUDA_VISIBLE_DEVICES` would hide every card rather than name none.
    """
    return value if value is not None and value.strip() else None


def _placeholder_png(width: int, height: int, tint_by: str) -> bytes:
    """A valid PNG of the requested size, coloured by a hash of the caption."""
    digest = sha256(tint_by.encode()).digest()
    tint = bytes(digest[index] for index in range(3))
    row = b"\x00" + tint * width
    raw = row * height
    return (
        _PNG_SIGNATURE
        + _chunk(b"IHDR", Struct(">IIBBBBB").pack(width, height, 8, 2, 0, 0, 0))
        + _chunk(b"IDAT", _deflate(raw))
        + _chunk(b"IEND", b"")
    )


def _deflate(raw: bytes) -> bytes:
    compressor = compressobj()
    return compressor.compress(raw) + compressor.flush()


def _chunk(kind: bytes, body: bytes) -> bytes:
    return (
        Struct(">I").pack(len(body)) + kind + body + Struct(">I").pack(crc32(kind + body) & 0xFFFF_FFFF)
    )
