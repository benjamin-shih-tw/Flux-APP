from __future__ import annotations

import io
import sys
import wave
from pathlib import Path

import numpy as np

sys.path.append(str(Path(__file__).resolve().parents[1]))

from acoustics import AcousticEstimator, CHIRP_STARTS, chirp  # noqa: E402
from acoustics import AcousticEstimate  # noqa: E402
from estimators import DepthEstimate, FusionEngine  # noqa: E402
from main import app  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402


client = TestClient(app)
from volume_engine import build_cylinder_profile  # noqa: E402


def _synthetic_recording(depth_cm: float = 8.0, rate: int = 48_000) -> np.ndarray:
    phone_to_rim = 15.0
    speaker_offset = 1.0
    microphone_offset = 0.5
    direct_path = 1.5
    sound_speed = (331.3 + 0.606 * 20) * 100
    path = lambda depth: np.hypot(phone_to_rim + depth, speaker_offset) + np.hypot(phone_to_rim + depth, microphone_offset)
    lag = round((path(depth_cm) - direct_path) / sound_speed * rate)

    samples = np.random.default_rng(4).normal(0, 0.002, round(2.1 * rate))
    probe = chirp(rate)
    for start in CHIRP_STARTS:
        direct = round(float(start) * rate)
        samples[direct:direct + len(probe)] += 0.35 * probe
        echo = direct + lag
        samples[echo:echo + len(probe)] += 0.08 * probe
    return samples


def _wav(samples: np.ndarray, rate: int = 48_000) -> bytes:
    encoded = np.clip(samples * 32767, -32768, 32767).astype("<i2").tobytes()
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(encoded)
    return output.getvalue()


def test_repeated_echoes_recover_depth_with_profile_volume() -> None:
    estimate = AcousticEstimator().estimate(
        _synthetic_recording(),
        48_000,
        profile=build_cylinder_profile(20, 3.5),
        bottle_height_cm=20,
        bottle_volume_ml=500,
        phone_to_rim_cm=15,
        opening_diameter_cm=7,
        speaker_offset_cm=1,
        microphone_offset_cm=0.5,
        direct_path_cm=1.5,
    )

    assert estimate.method_used == "acoustic_echo"
    assert estimate.accepted_repeats == 5
    assert 7.0 <= estimate.water_depth_cm <= 9.0
    assert 270 <= estimate.remaining_volume_ml <= 330
    assert estimate.echo_snr_db > 20


def test_wav_is_mono_pcm16_and_within_capture_limit() -> None:
    samples, rate = _synthetic_recording(), 48_000
    decoded = io.BytesIO(_wav(samples, rate))
    with wave.open(decoded, "rb") as wav:
        assert wav.getnchannels() == 1
        assert wav.getsampwidth() == 2
        assert wav.getframerate() == rate


def test_fusion_requests_retake_when_image_and_echo_disagree() -> None:
    vision = DepthEstimate(
        remaining_volume_ml=400,
        water_depth_cm=4,
        confidence=0.85,
        method_used="vision_perspective_profile",
    )
    audio = AcousticEstimate(
        remaining_volume_ml=150,
        water_depth_cm=15,
        confidence=0.8,
        method_used="acoustic_echo",
    )

    fused = FusionEngine().fuse(
        vision,
        audio,
        bottle_height_cm=20,
        bottle_volume_ml=500,
        acoustic_present=True,
    )

    assert fused.requires_retake is True
    assert fused.remaining_volume_ml is None
    assert "disagree" in fused.debug_notes[-1]


def test_api_uses_acoustic_estimate_for_opaque_surface() -> None:
    import cv2

    image = np.full((768, 768, 3), 245, dtype=np.uint8)
    cv2.circle(image, (384, 384), 240, (35, 35, 35), 18, lineType=cv2.LINE_AA)
    ok, encoded = cv2.imencode(".jpg", image)
    assert ok

    profile = '{"heights_cm":[0,5,10,15,20],"radii_cm":[3.5,3.5,3.5,3.5,3.5]}'
    metadata = (
        '{"probe_version":1,"route":"built_in_bottom",'
        '"speaker_offset_cm":1.0,"microphone_offset_cm":0.5,'
        '"direct_path_cm":1.5,"temperature_c":20}'
    )
    response = client.post(
        "/api/v2/estimate_water_volume",
        files={
            "image": ("opaque.jpg", encoded.tobytes(), "image/jpeg"),
            "audio": ("capture.wav", _wav(_synthetic_recording()), "audio/wav"),
        },
        data={
            "bottle_height_cm": "20",
            "bottle_volume_ml": "500",
            "opening_diameter_cm": "7",
            "profile_json": profile,
            "phone_to_rim_cm": "15",
            "surface_mode": "opaque",
            "imu_alignment_score": "0.95",
            "acoustic_metadata_json": metadata,
        },
    )

    payload = response.json()
    assert response.status_code == 200
    assert payload["status"] == "ok"
    assert payload["method_used"] == "acoustic_echo"
    assert payload["acoustic_estimate"]["accepted_repeats"] == 5
