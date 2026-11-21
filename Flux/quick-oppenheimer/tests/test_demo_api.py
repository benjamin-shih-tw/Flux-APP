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
        '{"heights_cm":[0,20],'
        '"radii_cm":[3.4,3.4]}'
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
            "camera_focal_length_px": "1200",
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


def test_stale_baseline_from_larger_bottle_is_ignored() -> None:
    response = client.post(
        "/api/v2/estimate_water_volume",
        files={"image": ("demo.jpg", _build_demo_image(), "image/jpeg")},
        data={
            "bottle_height_cm": "20",
            "bottle_volume_ml": "600",
            "opening_diameter_cm": "6.8",
            "profile_json": (
                '{"heights_cm":[0,20],'
                '"radii_cm":[3.4,3.4]}'
            ),
            # This is valid for a 1,500 ml bottle, but not for this 600 ml
            # bottle. It must not block the image measurement.
            "last_remaining_ml": "1200",
            "imu_alignment_score": "0.92",
            "camera_focal_length_px": "1200",
        },
    )

    payload = response.json()
    assert response.status_code == 200
    assert payload["status"] == "ok"
    assert payload["remaining_volume_ml"] is not None
    assert "baseline ignored" in " ".join(payload["debug_notes"])


def test_manual_circles_are_used_without_running_automatic_detection() -> None:
    response = client.post(
        "/api/v2/estimate_water_volume",
        files={"image": ("demo.jpg", _build_demo_image(), "image/jpeg")},
        data={
            "bottle_height_cm": "20",
            "bottle_volume_ml": "500",
            "opening_diameter_cm": "6.8",
            "profile_json": (
                '{"heights_cm":[0,20],'
                '"radii_cm":[3.4,3.4]}'
            ),
            "imu_alignment_score": "1.0",
            "camera_focal_length_px": "600",
            "manual_circles_json": (
                '{"outer_center_x":384,"outer_center_y":384,'
                '"outer_radius_px":240,"inner_center_x":384,'
                '"inner_center_y":384,"inner_radius_px":154}'
            ),
        },
    )

    payload = response.json()
    assert response.status_code == 200
    assert payload["status"] == "ok"
    assert payload["method_used"] == "vision_manual_circles_profile"
    assert payload["remaining_volume_ml"] is not None


def test_missing_camera_geometry_requires_retake() -> None:
    response = client.post(
        "/api/v2/estimate_water_volume",
        files={"image": ("demo.jpg", _build_demo_image(), "image/jpeg")},
        data={"bottle_height_cm": "20", "bottle_volume_ml": "500",
              "opening_diameter_cm": "6.8",
              "profile_json": '{"heights_cm":[0,20],"radii_cm":[3.4,3.4]}'},
    )
    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "retake"
    assert payload["remaining_volume_ml"] is None
    assert payload["water_depth_cm"] is None
    assert "camera geometry is required" in " ".join(payload["debug_notes"])


def test_guided_rim_is_preserved_at_camera_resolution():
    image = cv2.imdecode(np.frombuffer(_build_demo_image(), np.uint8), cv2.IMREAD_COLOR)
    _, large = cv2.imencode(".jpg", cv2.resize(image, (1536, 1536)))
    response = client.post(
        "/api/v2/estimate_water_volume",
        files={"image": ("guided.jpg", large.tobytes(), "image/jpeg")},
        data={"guided_rim_json": "[768,768,462]", "camera_focal_length_px": "2400"},
    ).json()
    assert response["outer_radius_px"] == 462
    assert response["status"] == "ok"
    assert response["inner_radius_px"] is not None


def test_guided_scan_reconciles_single_tip_only_for_a_consistent_neck():
    import json
    image = _build_demo_image()
    for neck, adjusted in [(3.4, True), (2.5, False)]:
        response = client.post(
            "/api/v2/estimate_water_volume",
            files={"image": ("guided.jpg", image, "image/jpeg")},
            data={
                "guided_rim_json": "[384,384,231]", "camera_focal_length_px": "1200",
                "opening_diameter_cm": "6.8", "bottle_height_cm": "20",
                "profile_json": json.dumps({"heights_cm": [0, 18.5, 19, 19.5, 20],
                                            "radii_cm": [3.4, 3.4, 3.4, neck, 1.5]}),
            },
        ).json()
        assert any("silhouette tip" in note for note in response["debug_notes"]) == adjusted
        if adjusted:
            assert response["status"] == "ok"
        else:
            assert response["status"] == "retake"
