"""Stage 3: make the picture.

Two implementations of one `Renderer` contract. `FakeRenderer` writes a
placeholder PNG and is what the suite runs against — the chain is testable
with no GPU, no SSH and no weights on disk. `SdCliRenderer` is the real one:
it SSHes to the box that owns the cards and runs the diffusion CLI there.

The real renderer takes GPU1. GPU0 is the owner's live interactive session and
a nightly job that stole it would be noticed within seconds, so the device is
pinned here rather than left to whatever `CUDA_VISIBLE_DEVICES` the login shell
happens to carry.
"""

import shlex
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

# GPU0 is the owner's session. Nothing in this module may choose it.
GPU_DEVICE = "1"

# sd-cli on this host needs the opengl driver directory on LD_LIBRARY_PATH. With
# it absent, CUDA does not fail — it initialises against a stub driver, logs
# "no GPU devices", and renders on the CPU. Same exit code, same output file, a
# different sampler schedule and roughly ten times the wall time. Nothing about
# the result says so, which is why the renderer checks the log rather than
# trusting the exit status.
RENDER_LIBRARY_PATH = "/run/opengl-driver/lib"

# What sd-cli prints when it has quietly given up on the GPU.
CPU_FALLBACK_MARKS = ("CUDA driver is a stub library", "no GPU devices")

# A 6-step 1024² render on the 3B measures about 143 s; the rest of the budget
# is SSH setup and model load. A render that exceeds it is hung, not slow.
# The schedule, in one place. The timeout used to be a separate number sized
# for a 6-step run, so moving to 20 steps made every render die at 600 s with a
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

MODEL_DIRECTORY = "/var/lib/llama-models/h3image"

_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


@dataclass(frozen=True)
class Rendered:
    """A panel that exists, and what it took to draw it.

    `weights` are paths, not digests: the diffusion model is 10 GB on a box
    that is about to render with it, and a provenance field must not cost a
    read of the thing it describes.
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
    """Where the weights live on the render host, and what the box is called.

    Paths, not a directory listing: the model directory holds 17 GB and the
    three files that matter are named here on purpose.
    """

    host: str
    diffusion_model: str = f"{MODEL_DIRECTORY}/minimax_h3_image_pruned-Q3_K_M.gguf"
    vae: str = f"{MODEL_DIRECTORY}/vae_diffusion_pytorch_model.safetensors"
    text_encoder: str = f"{MODEL_DIRECTORY}/p-h3-image_text_encoder_int8_convrot.safetensors"
    tokenizer: str = f"{MODEL_DIRECTORY}/p-h3-image_tokenizer.json"

    @property
    def weights(self) -> tuple[str, ...]:
        return (self.diffusion_model, self.vae, self.text_encoder)


class SdCliRenderer:
    """The real renderer: the diffusion CLI, on the GPU box, on GPU1."""

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
            raise ValueError("binary must be the path to the diffusion CLI on the render host")
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
        # The CLI writes where it is told, on its own host; the panel is then
        # copied back so that `destination` means the same thing for both
        # renderers.
        remote_path = f"/tmp/forecats-{seed}.png"
        argv = self._command(caption, seed=seed, reference_photos=reference_photos, remote_path=remote_path)
        run = self._run(["ssh", "-o", "BatchMode=yes", self._settings.host, shlex.join(argv)])
        if isinstance(run, PipelineRefusal):
            return run
        if any(mark in run for mark in CPU_FALLBACK_MARKS):
            # It exited 0 and wrote a picture. It drew that picture on the CPU,
            # on a different schedule, in ten times the time.
            return PipelineRefusal(
                stage="render",
                reason=(
                    f"{self.name}: the render host had no usable GPU and fell back to "
                    f"the CPU ({next(m for m in CPU_FALLBACK_MARKS if m in run)}); "
                    f"LD_LIBRARY_PATH={RENDER_LIBRARY_PATH} must be exported on that host"
                ),
            )

        fetch = self._run(
            ["scp", "-o", "BatchMode=yes", f"{self._settings.host}:{remote_path}", str(destination)]
        )
        if isinstance(fetch, PipelineRefusal):
            return fetch
        if not destination.is_file():
            return PipelineRefusal(
                stage="render",
                reason=f"{self.name}: {remote_path} came back but is not at {destination}",
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

    def _command(
        self,
        caption: Caption,
        *,
        seed: int,
        reference_photos: Sequence[Path],
        remote_path: str,
    ) -> list[str]:
        settings = self._settings
        argv = [
            "env",
            f"CUDA_VISIBLE_DEVICES={GPU_DEVICE}",
            f"LD_LIBRARY_PATH={RENDER_LIBRARY_PATH}",
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
            remote_path,
        ]
        for photo in reference_photos:
            argv += ["-r", str(photo)]
        if reference_photos:
            argv.append("--increase-ref-index")
        return argv

    def _run(self, argv: Sequence[str]) -> str | PipelineRefusal:
        command = list(argv)
        try:
            completed = subprocess.run(
                command, capture_output=True, text=True, timeout=self._timeout_seconds, check=False
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
        return completed.stdout


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
