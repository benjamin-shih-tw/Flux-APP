from __future__ import annotations

import io
import sys
from pathlib import Path

import cv2
import numpy as np
from fastapi.testclient import TestClient

sys.path.append(str(Path(__file__).resolve().parents[1]))

from main import app  # noqa: E402


client = TestClient(app)


def _build_demo_image() -> bytes:
    """Create a simple concentric-circle bottle photo for the demo test."""
    image = np.full((768, 768, 3), 245, dtype=np.uint8)
    center = (384, 384)

    # Bottle opening rim.
    cv2.circle(image, center, 240, (35, 35, 35), 18, lineType=cv2.LINE_AA)
    cv2.circle(image, center, 222, (225, 225, 225), -1, lineType=cv2.LINE_AA)

    # Water body with a visible surface edge.
    cv2.circle(image, center, 154, (120, 165, 200), -1, lineType=cv2.LINE_AA)
    cv2.circle(image, center, 154, (250, 250, 250), 5, lineType=cv2.LINE_AA)

    ok, encoded = cv2.imencode(".jpg", image, [int(cv2.IMWRITE_JPEG_QUALITY), 95])
    assert ok
    return encoded.tobytes()


def test_estimate_water_volume_returns_mvp_fields() -> None:
    demo_image = _build_demo_image()
    profile_json = (
        '{"heights_cm":[0,5,10,15,20],'
        '"radii_cm":[3.4,2.8,2.1,2.7,3.4]}'
    )

    response = client.post(
        "/api/v2/estimate_water_volume",
        files={"image": ("demo.jpg", demo_image, "image/jpeg")},
        data={
            "bottle_height_cm": "20",
            "bottle_volume_ml": "500",
            "opening_diameter_cm": "6.8",
            "profile_json": profile_json,
            "last_remaining_ml": "250",
            "calibration_outer_radius_px": "240",
            "imu_alignment_score": "0.92",
        },
    )

    assert response.status_code == 200
    payload = response.json()

    assert payload["status"] == "ok"
    assert payload["remaining_volume_ml"] is not None
    assert payload["water_depth_cm"] is not None
    assert 0.0 <= payload["confidence"] <= 1.0
    assert payload["method_used"].startswith("vision")
    assert payload["debug_image_base64"]

    assert 120 <= payload["remaining_volume_ml"] <= 400
    assert 5.0 <= payload["water_depth_cm"] <= 15.0
