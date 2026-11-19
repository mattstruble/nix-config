"""The renderer is the one stage with a GPU behind it, so it is the one with a fake."""

import shlex
import subprocess
from pathlib import Path
from struct import Struct

import pytest
from forecats_pipeline import render_stage
from forecats_pipeline.contracts import PipelineRefusal
from forecats_pipeline.contracts import Caption
from forecats_pipeline.render_stage import FakeRenderer, SdCliRenderer, SdCliSettings

CAPTION = Caption(text="a rainy street", template_hash="abc", style="risograph")
WEIGHTS = SdCliSettings(host="mjolnir")


def png_size(path: Path) -> tuple[int, int]:
    body = path.read_bytes()
    assert body[:8] == b"\x89PNG\r\n\x1a\n"
    width, height = Struct(">II").unpack(body[16:24])
    return width, height


class FakeProcesses:
    """Records the commands the renderer asked for, and answers them."""

    def __init__(self, returncode: int = 0, stderr: str = "", output: str = "") -> None:
        self.calls: list[list[str]] = []
        self._returncode = returncode
        self._stderr = stderr
        self._output = output

    def __call__(self, argv, *args, **kwargs) -> subprocess.CompletedProcess:
        command = list(argv)
        self.calls.append(command)
        if command[0] == "scp":
            destination = Path(command[-1])
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(b"\x89PNG\r\n\x1a\n")
        return subprocess.CompletedProcess(command, self._returncode, self._output, self._stderr)

    def remote(self) -> list[str]:
        return shlex.split(self.calls[0][-1])


def test_the_fake_renderer_draws_a_panel_of_the_size_it_claims(tmp_path: Path):
    rendered = FakeRenderer().render(
        CAPTION, seed=1, reference_photos=[], destination=tmp_path / "panel.png"
    )

    assert png_size(rendered.panel_path) == (rendered.width_px, rendered.height_px)
    assert rendered.renderer == "fake"


def test_the_real_renderer_asks_for_gpu1_and_the_named_weights(tmp_path: Path, monkeypatch):
    processes = FakeProcesses()
    monkeypatch.setattr(render_stage.subprocess, "run", processes)

    SdCliRenderer("/nix/store/x/bin/sd-cli", WEIGHTS).render(
        CAPTION, seed=20260308, reference_photos=[], destination=tmp_path / "panel.png"
    )

    remote = processes.remote()
    # LD_LIBRARY_PATH is not decoration: without the opengl driver path sd-cli
    # drops --sigmas and samples 80 default steps, silently.
    assert remote[:3] == [
        "env",
        "CUDA_VISIBLE_DEVICES=1",
        f"LD_LIBRARY_PATH={render_stage.RENDER_LIBRARY_PATH}",
    ]
    assert "--diffusion-model" in remote and WEIGHTS.diffusion_model in remote
    # 20 steps at CFG 3.5, and no named sigma schedule: at 6 the weather gauge
    # was unreadable, and the distilled schedule is what the CPU fallback used
    # to be mistaken for.
    assert "--sigmas" not in remote
    assert remote[remote.index("--steps") + 1] == str(render_stage.RENDER_STEPS)
    assert remote[remote.index("--cfg-scale") + 1] == str(render_stage.CFG_SCALE)
    assert remote[remote.index("--seed") + 1] == "20260308"


def test_the_reference_photos_travel_by_path_and_switch_on_index(tmp_path: Path, monkeypatch):
    processes = FakeProcesses()
    monkeypatch.setattr(render_stage.subprocess, "run", processes)
    photos = [Path("/var/lib/forecats/refs/owner.png"), Path("/var/lib/forecats/refs/desk.png")]

    SdCliRenderer("sd-cli", WEIGHTS).render(
        CAPTION, seed=1, reference_photos=photos, destination=tmp_path / "panel.png"
    )

    remote = processes.remote()
    assert remote.count("-r") == 2
    assert "--increase-ref-index" in remote
    assert "Picture" not in " ".join(remote)


def test_no_photos_means_no_reference_flags(tmp_path: Path, monkeypatch):
    processes = FakeProcesses()
    monkeypatch.setattr(render_stage.subprocess, "run", processes)

    SdCliRenderer("sd-cli", WEIGHTS).render(
        CAPTION, seed=1, reference_photos=[], destination=tmp_path / "panel.png"
    )

    assert "-r" not in processes.remote()
    assert "--increase-ref-index" not in processes.remote()


def test_a_render_that_dies_is_a_refusal_naming_the_exit_and_the_cause(tmp_path: Path, monkeypatch):
    processes = FakeProcesses(returncode=139, stderr="CUDA out of memory on device 1")
    monkeypatch.setattr(render_stage.subprocess, "run", processes)

    refusal = SdCliRenderer("sd-cli", WEIGHTS).render(
        CAPTION, seed=1, reference_photos=[], destination=tmp_path / "panel.png"
    )

    assert refusal.stage == "render"
    assert "exited 139" in refusal.reason
    assert "out of memory" in refusal.reason


def test_a_render_that_outlives_its_budget_is_a_refusal(tmp_path: Path, monkeypatch):
    def hang(argv, *args, **kwargs):
        raise subprocess.TimeoutExpired(list(argv), kwargs["timeout"])

    monkeypatch.setattr(render_stage.subprocess, "run", hang)

    refusal = SdCliRenderer("sd-cli", WEIGHTS, timeout_seconds=600.0).render(
        CAPTION, seed=1, reference_photos=[], destination=tmp_path / "panel.png"
    )

    assert "exceeded 600s" in refusal.reason


@pytest.mark.parametrize("binary", ["", "   "])
def test_the_renderer_refuses_to_guess_where_the_cli_is(binary: str):
    with pytest.raises(ValueError, match="path to the diffusion CLI"):
        SdCliRenderer(binary, WEIGHTS)


def test_a_cpu_fallback_is_refused_rather_than_rendered(tmp_path, monkeypatch):
    """sd-cli exits 0 and writes a picture when CUDA is a stub library.

    The only sign is a line in its log, and the picture it drew used a
    different schedule on the wrong device at ten times the cost.
    """
    processes = FakeProcesses(output="ggml_cuda_init: CUDA driver is a stub library\n"
                                      "[W] auto-fit: no GPU devices; using the default backend")
    monkeypatch.setattr(render_stage.subprocess, "run", processes)
    renderer = SdCliRenderer("/nix/store/x/bin/sd-cli", WEIGHTS)
    (tmp_path / "panel.png").write_bytes(b"\x89PNG\r\n\x1a\n")

    outcome = renderer.render(CAPTION, seed=1, reference_photos=[], destination=tmp_path / "panel.png")

    assert isinstance(outcome, PipelineRefusal)
    assert "fell back to the CPU" in outcome.reason
    assert render_stage.RENDER_LIBRARY_PATH in outcome.reason


def test_the_timeout_covers_the_schedule_it_is_given():
    """A timeout sized for another schedule blames ssh for arithmetic."""
    sampling = render_stage.RENDER_STEPS * render_stage.SECONDS_PER_STEP

    assert render_stage.RENDER_TIMEOUT_SECONDS > sampling
    assert render_stage.RENDER_TIMEOUT_SECONDS < sampling * 2, "not a licence to hang forever"
