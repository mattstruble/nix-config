"""The renderer is the one stage with a GPU behind it, so it is the one with a fake."""

import os
import subprocess
from dataclasses import replace
from pathlib import Path
from struct import Struct

import pytest
from forecats_pipeline import render_stage
from forecats_pipeline.contracts import Caption, PipelineRefusal
from forecats_pipeline.render_stage import FakeRenderer, SdCliRenderer, SdCliSettings

CAPTION = Caption(text="a rainy street", template_hash="abc", style="risograph")
CLI = "/nix/store/x/bin/sd-cli"


def png_size(path: Path) -> tuple[int, int]:
    body = path.read_bytes()
    assert body[:8] == b"\x89PNG\r\n\x1a\n"
    width, height = Struct(">II").unpack(body[16:24])
    return width, height


class FakeProcesses:
    """Records the processes the renderer started, and answers them."""

    def __init__(self, returncode: int = 0, stderr: str = "", output: str = "") -> None:
        self.calls: list[list[str]] = []
        self.environments: list[dict[str, str]] = []
        self._returncode = returncode
        self._stderr = stderr
        self._output = output

    def __call__(self, argv, *args, **kwargs) -> subprocess.CompletedProcess:
        command = list(argv)
        self.calls.append(command)
        self.environments.append(kwargs.get("env") or {})
        return subprocess.CompletedProcess(command, self._returncode, self._output, self._stderr)

    @property
    def started(self) -> list[str]:
        """The program of every process the render started, in order."""
        return [command[0] for command in self.calls]


def weights(root: Path) -> SdCliSettings:
    """The four weight files a render opens, as files that exist under `root`."""
    settings = SdCliSettings(
        diffusion_model=str(root / "model.gguf"),
        vae=str(root / "vae.safetensors"),
        text_encoder=str(root / "text-encoder.safetensors"),
        tokenizer=str(root / "tokenizer.json"),
    )
    root.mkdir(parents=True, exist_ok=True)
    for name in settings.files:
        Path(name).write_bytes(b"weights")
    return settings


def photos(root: Path, *names: str) -> list[Path]:
    """Reference photos that exist, because a render refuses ones that do not."""
    root.mkdir(parents=True, exist_ok=True)
    placed = [root / name for name in names]
    for path in placed:
        path.write_bytes(b"\xff\xd8\xff\xe0")
    return placed


def test_the_fake_renderer_draws_a_panel_of_the_size_it_claims(tmp_path: Path):
    rendered = FakeRenderer().render(
        CAPTION, seed=1, reference_photos=[], destination=tmp_path / "panel.png"
    )

    assert png_size(rendered.panel_path) == (rendered.width_px, rendered.height_px)
    assert rendered.renderer == "fake"


def test_the_real_renderer_runs_the_cli_with_the_named_weights(tmp_path: Path, monkeypatch):
    processes = FakeProcesses()
    monkeypatch.setattr(render_stage.subprocess, "run", processes)
    settings = weights(tmp_path / "weights")

    SdCliRenderer(CLI, settings).render(
        CAPTION, seed=20260308, reference_photos=[], destination=tmp_path / "panel.png"
    )

    command = processes.calls[0]
    assert "--diffusion-model" in command and settings.diffusion_model in command
    assert settings.vae in command
    assert settings.text_encoder in command
    assert settings.tokenizer in command
    # 20 steps at CFG 3.5, and no named sigma schedule: at 6 the weather gauge
    # was unreadable, and the distilled schedule is what the CPU fallback used
    # to be mistaken for.
    assert "--sigmas" not in command
    assert command[command.index("--steps") + 1] == str(render_stage.RENDER_STEPS)
    assert command[command.index("--cfg-scale") + 1] == str(render_stage.CFG_SCALE)
    assert command[command.index("--seed") + 1] == "20260308"


def test_the_render_is_one_local_process_and_no_remote_shell(tmp_path: Path, monkeypatch):
    """A pod has no host to SSH to and no key, and the card is already here.

    The stage used to start `ssh` for the render and `scp` for the picture; one
    process, named by the binary the caller was given, is the whole contract.
    """
    processes = FakeProcesses()
    monkeypatch.setattr(render_stage.subprocess, "run", processes)

    SdCliRenderer(CLI, weights(tmp_path / "weights")).render(
        CAPTION, seed=1, reference_photos=[], destination=tmp_path / "panel.png"
    )

    assert processes.started == [CLI]
    assert not [word for command in processes.calls for word in command if word in ("ssh", "scp")]


def test_the_picture_lands_where_the_pipeline_said_it_would(tmp_path: Path, monkeypatch):
    def draw(argv, *args, **kwargs):
        command = list(argv)
        Path(command[command.index("-o") + 1]).write_bytes(b"\x89PNG\r\n\x1a\n")
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(render_stage.subprocess, "run", draw)
    destination = tmp_path / "out" / "render-2026-03-08.png"

    rendered = SdCliRenderer(CLI, weights(tmp_path / "weights")).render(
        CAPTION, seed=1, reference_photos=[], destination=destination
    )

    assert rendered.panel_path == destination
    assert destination.is_file()


def test_the_reference_photos_travel_by_path_and_switch_on_index(tmp_path: Path, monkeypatch):
    processes = FakeProcesses()
    monkeypatch.setattr(render_stage.subprocess, "run", processes)
    pictures = photos(tmp_path / "photos", "milo.jpg", "mochi.jpg")

    SdCliRenderer(CLI, weights(tmp_path / "weights")).render(
        CAPTION, seed=1, reference_photos=pictures, destination=tmp_path / "panel.png"
    )

    command = processes.calls[0]
    assert command.count("-r") == 2
    assert all(str(picture) in command for picture in pictures)
    assert "--increase-ref-index" in command
    assert "Picture" not in " ".join(command)


def test_no_photos_means_no_reference_flags(tmp_path: Path, monkeypatch):
    processes = FakeProcesses()
    monkeypatch.setattr(render_stage.subprocess, "run", processes)

    SdCliRenderer(CLI, weights(tmp_path / "weights")).render(
        CAPTION, seed=1, reference_photos=[], destination=tmp_path / "panel.png"
    )

    assert "-r" not in processes.calls[0]
    assert "--increase-ref-index" not in processes.calls[0]


def test_a_missing_reference_photo_refuses_rather_than_inventing_a_cat(tmp_path, monkeypatch):
    """sd-cli renders an invented animal and exits 0 when a `-r` file is absent.

    The panel then shows a cat that does not live here, and nothing downstream
    can tell. Refusing is the only check that can see it.
    """
    processes = FakeProcesses()
    monkeypatch.setattr(render_stage.subprocess, "run", processes)
    absent = tmp_path / "photos" / "mochi.jpg"

    refusal = SdCliRenderer(CLI, weights(tmp_path / "weights")).render(
        CAPTION, seed=1, reference_photos=[absent], destination=tmp_path / "panel.png"
    )

    assert isinstance(refusal, PipelineRefusal)
    assert str(absent) in refusal.reason
    assert render_stage.PHOTO_DIRECTORY in refusal.reason
    assert processes.started == []


def test_a_weight_the_volume_does_not_carry_is_refused_before_the_cli(tmp_path, monkeypatch):
    processes = FakeProcesses()
    monkeypatch.setattr(render_stage.subprocess, "run", processes)
    settings = weights(tmp_path / "weights")
    Path(settings.diffusion_model).unlink()

    refusal = SdCliRenderer(CLI, settings).render(
        CAPTION, seed=1, reference_photos=[], destination=tmp_path / "panel.png"
    )

    assert settings.diffusion_model in refusal.reason
    assert render_stage.MODEL_DIRECTORY in refusal.reason
    assert processes.started == []


def test_a_render_that_dies_is_a_refusal_naming_the_exit_and_the_cause(tmp_path: Path, monkeypatch):
    processes = FakeProcesses(returncode=139, stderr="CUDA out of memory on device 1")
    monkeypatch.setattr(render_stage.subprocess, "run", processes)

    refusal = SdCliRenderer(CLI, weights(tmp_path / "weights")).render(
        CAPTION, seed=1, reference_photos=[], destination=tmp_path / "panel.png"
    )

    assert refusal.stage == "render"
    assert "exited 139" in refusal.reason
    assert "out of memory" in refusal.reason


def test_a_render_that_outlives_its_budget_is_a_refusal(tmp_path: Path, monkeypatch):
    def hang(argv, *args, **kwargs):
        raise subprocess.TimeoutExpired(list(argv), kwargs["timeout"])

    monkeypatch.setattr(render_stage.subprocess, "run", hang)

    refusal = SdCliRenderer(CLI, weights(tmp_path / "weights"), timeout_seconds=600.0).render(
        CAPTION, seed=1, reference_photos=[], destination=tmp_path / "panel.png"
    )

    assert "exceeded 600s" in refusal.reason


@pytest.mark.parametrize("binary", ["", "   "])
def test_the_renderer_refuses_to_guess_where_the_cli_is(binary: str):
    with pytest.raises(ValueError, match="diffusion CLI to run"):
        SdCliRenderer(binary, SdCliSettings())


def test_a_cpu_fallback_is_refused_rather_than_rendered(tmp_path: Path, monkeypatch):
    """sd-cli exits 0 and writes a picture when CUDA is a stub library.

    The only sign is a line in its log, and the picture it drew used a
    different schedule on the wrong device at ten times the cost.
    """
    processes = FakeProcesses(
        output="ggml_cuda_init: CUDA driver is a stub library\n"
        "[W] auto-fit: no GPU devices; using the default backend"
    )
    monkeypatch.setattr(render_stage.subprocess, "run", processes)
    (tmp_path / "panel.png").write_bytes(b"\x89PNG\r\n\x1a\n")

    outcome = SdCliRenderer(CLI, weights(tmp_path / "weights")).render(
        CAPTION, seed=1, reference_photos=[], destination=tmp_path / "panel.png"
    )

    assert isinstance(outcome, PipelineRefusal)
    assert "fell back to the CPU" in outcome.reason
    assert render_stage.GPU_DRIVER_DIRECTORY in outcome.reason


def test_a_zero_exit_that_wrote_no_picture_is_a_refusal(tmp_path: Path, monkeypatch):
    processes = FakeProcesses()
    monkeypatch.setattr(render_stage.subprocess, "run", processes)

    outcome = SdCliRenderer(CLI, weights(tmp_path / "weights")).render(
        CAPTION, seed=1, reference_photos=[], destination=tmp_path / "panel.png"
    )

    assert isinstance(outcome, PipelineRefusal)
    assert "without writing" in outcome.reason


def test_the_cli_inherits_the_card_this_process_was_given(tmp_path: Path, monkeypatch):
    """A pod is pinned by `NVIDIA_VISIBLE_DEVICES`; a card named here is a lie.

    The driver directory is the one thing added to the environment, and only
    when it exists: a GPU pod has libcuda on the default loader path and no
    `/run/opengl-driver`.
    """
    processes = FakeProcesses()
    monkeypatch.setattr(render_stage.subprocess, "run", processes)
    monkeypatch.setenv("NVIDIA_VISIBLE_DEVICES", "1")
    monkeypatch.delenv("CUDA_VISIBLE_DEVICES", raising=False)
    monkeypatch.setenv("LD_LIBRARY_PATH", "/somewhere/else")
    monkeypatch.setattr(render_stage, "GPU_DRIVER_DIRECTORY", str(tmp_path))

    SdCliRenderer(CLI, weights(tmp_path / "weights")).render(
        CAPTION, seed=1, reference_photos=[], destination=tmp_path / "panel.png"
    )

    environment = processes.environments[0]
    assert environment["NVIDIA_VISIBLE_DEVICES"] == "1"
    assert "CUDA_VISIBLE_DEVICES" not in environment
    assert environment["LD_LIBRARY_PATH"] == f"{tmp_path}{os.pathsep}/somewhere/else"


def test_a_card_is_named_only_when_the_caller_asks_for_one(tmp_path: Path, monkeypatch):
    processes = FakeProcesses()
    monkeypatch.setattr(render_stage.subprocess, "run", processes)
    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
    monkeypatch.setattr(render_stage, "GPU_DRIVER_DIRECTORY", str(tmp_path / "no-such-driver"))
    settings = replace(weights(tmp_path / "weights"), gpu_device="1")

    SdCliRenderer(CLI, settings).render(
        CAPTION,
        seed=1,
        reference_photos=photos(tmp_path / "photos", "milo.jpg"),
        destination=tmp_path / "panel.png",
    )

    environment = processes.environments[0]
    assert environment["CUDA_VISIBLE_DEVICES"] == "1"
    assert "LD_LIBRARY_PATH" not in environment


def test_the_default_weights_are_the_files_the_weights_volume_carries():
    """A default outside the mounted directory is a file no pod can open."""
    settings = SdCliSettings()

    assert all(Path(name).is_relative_to(render_stage.MODEL_DIRECTORY) for name in settings.files)


def test_the_timeout_covers_the_schedule_it_is_given():
    """A timeout sized for another schedule blames the transport for arithmetic."""
    sampling = render_stage.RENDER_STEPS * render_stage.SECONDS_PER_STEP

    assert render_stage.RENDER_TIMEOUT_SECONDS > sampling
    assert render_stage.RENDER_TIMEOUT_SECONDS < sampling * 2, "not a licence to hang forever"
