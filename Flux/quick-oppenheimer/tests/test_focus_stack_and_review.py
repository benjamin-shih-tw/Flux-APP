from __future__ import annotations

import json
import sys
from pathlib import Path

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient

sys.path.append(str(Path(__file__).resolve().parents[1]))

from focus_stack import FocusFrame, align_frame_to_rim, fuse_focus_stack  # noqa: E402
from main import app  # noqa: E402


client = TestClient(app)


def _encode_jpg(bgr: np.ndarray, quality: int = 92) -> bytes:
    ok, buf = cv2.imencode(".jpg", bgr, [int(cv2.IMWRITE_JPEG_QUALITY), quality])
    assert ok
    return buf.tobytes()


def _synthetic_rim_and_water(
    size: int = 768,
    center: tuple[int, int] = (384, 384),
    rim_r: int = 230,
    water_r: int = 152,
    base_r: int | None = None,
    blur_rim: float = 0.0,
    blur_interior: float = 0.0,
) -> np.ndarray:
    """Render a top-down bottle with independent rim and interior defocus."""
    rim_layer = np.full((size, size, 3), 235, dtype=np.uint8)
    cv2.circle(rim_layer, center, rim_r + 14, (40, 40, 40), -1, lineType=cv2.LINE_AA)
    cv2.circle(rim_layer, center, rim_r, (205, 205, 205), -1, lineType=cv2.LINE_AA)

    interior_layer = np.full((size, size, 3), 205, dtype=np.uint8)
    cv2.circle(interior_layer, center, water_r, (118, 152, 185), -1, lineType=cv2.LINE_AA)
    cv2.circle(interior_layer, center, water_r, (240, 240, 240), 3, lineType=cv2.LINE_AA)
    if base_r is not None:
        cv2.circle(interior_layer, center, base_r, (220, 220, 220), -1, lineType=cv2.LINE_AA)

    if blur_rim > 0:
        k = int(round(blur_rim * 6)) | 1
        rim_layer = cv2.GaussianBlur(rim_layer, (k, k), blur_rim)
    if blur_interior > 0:
        k = int(round(blur_interior * 6)) | 1
        interior_layer = cv2.GaussianBlur(interior_layer, (k, k), blur_interior)

    yy, xx = np.ogrid[:size, :size]
    dist = np.hypot(xx - center[0], yy - center[1])
    mask = (dist < rim_r - 6).astype(np.float32)
    mask = cv2.GaussianBlur(mask, (9, 9), 2.0)[:, :, None]
    composite = rim_layer.astype(np.float32) * (1.0 - mask) + interior_layer.astype(np.float32) * mask
    return np.clip(composite, 0, 255).astype(np.uint8)


def test_focus_stack_recovers_blurred_water_despite_drift_and_breathing() -> None:
    # Frame 0: sharp rim, badly defocused water surface (reproduces real iPhone 16 issue).
    base_bgr = _synthetic_rim_and_water(blur_rim=0.0, blur_interior=16.0)

    # Frame 1: slightly shifted & scaled (focus breathing + micro hand drift),
    # defocused rim, razor-sharp water surface.
    sharp_interior = _synthetic_rim_and_water(blur_rim=10.0, blur_interior=0.0)
    shift_x, shift_y, breath = 14.0, -9.0, 1.035
    M = np.array(
        [
            [breath, 0.0, (384.0 + shift_x) - breath * 384.0],
            [0.0, breath, (384.0 + shift_y) - breath * 384.0],
        ],
        dtype=np.float32,
    )
    frame1_bgr = cv2.warpAffine(sharp_interior, M, (768, 768), borderMode=cv2.BORDER_REPLICATE)
    frame1_rim = ((384.0 + shift_x, 384.0 + shift_y), 230.0 * breath)

    # Verify alignment round-trip works.
    assert align_frame_to_rim(frame1_bgr, frame1_rim, ((384.0, 384.0), 230.0), (768, 768)) is not None

    stacked = fuse_focus_stack(
        base_bgr,
        ((384.0, 384.0), 230.0),
        [FocusFrame(image_bgr=frame1_bgr, rim=frame1_rim, lens_position=0.52)],
        base_lens_position=0.10,
    )
    assert stacked.frame_count == 2
    assert stacked.sharpness_gain > 3.0

    # End-to-end API test with focus_frames uploaded.
    meta = {
        "base_lens_position": 0.10,
        "frames": [
            {
                "rim": [frame1_rim[0][0], frame1_rim[0][1], frame1_rim[1]],
                "lens_position": 0.52,
            }
        ],
    }
    response = client.post(
        "/api/v2/estimate_water_volume",
        files=[
            ("image", ("base.jpg", _encode_jpg(base_bgr), "image/jpeg")),
            ("focus_frames", ("focus_0.jpg", _encode_jpg(frame1_bgr), "image/jpeg")),
        ],
        data={
            "bottle_height_cm": "20",
            "bottle_volume_ml": "500",
            "opening_diameter_cm": "6.8",
            "profile_json": '{"heights_cm":[0,20],"radii_cm":[3.4,3.4]}',
            "imu_alignment_score": "0.96",
            "camera_focal_length_px": "1200",
            "guided_rim_json": "[384,384,230]",
            "focus_metadata_json": json.dumps(meta),
            "return_candidates": "true",
        },
    )
    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] in ("ok", "review")
    assert payload["focus_stack_count"] == 2
    assert payload["selected_focus_index"] == 1
    assert payload["selected_lens_position"] == pytest.approx(0.52, abs=0.01)
    assert payload["sharpness_gain"] > 3.0
    assert payload["review_image_base64"]
    assert payload["water_candidates"]
    assert payload["recommended_candidate_index"] == 0
    assert payload["water_candidates"][0]["recommended"] is True
    assert payload["water_candidates"][0]["radius_px"] == pytest.approx(152.0 * breath, abs=7.0)


def test_review_mode_returns_ranked_candidates_when_metal_base_competes() -> None:
    # Water ring at r=152 and strong lower internal metal step/base plate at r=116
    # (both lie within physically reachable cylinder radii: bottom is ~108 px).
    multi_ring = _synthetic_rim_and_water(water_r=152, base_r=116)
    common = {
        "bottle_height_cm": "20",
        "bottle_volume_ml": "500",
        "opening_diameter_cm": "6.8",
        "profile_json": '{"heights_cm":[0,20],"radii_cm":[3.4,3.4]}',
        "imu_alignment_score": "0.95",
        "camera_focal_length_px": "1200",
        "guided_rim_json": "[384,384,230]",
    }

    # Strict backward-compatible default rejects ambiguous dual rings.
    strict = client.post(
        "/api/v2/estimate_water_volume",
        files={"image": ("dual.jpg", _encode_jpg(multi_ring), "image/jpeg")},
        data=common,
    ).json()
    assert strict["status"] == "retake"

    # Interactive review mode returns the clean photo and ranked candidates
    # with the real water surface ahead of the likely bottle base.
    review = client.post(
        "/api/v2/estimate_water_volume",
        files={"image": ("dual.jpg", _encode_jpg(multi_ring), "image/jpeg")},
        data={**common, "return_candidates": "true"},
    ).json()
    assert review["status"] == "review"
    assert review["requires_retake"] is False
    assert review["review_image_base64"]
    assert review["outer_center_x"] == pytest.approx(384.0)
    assert review["outer_radius_px"] == pytest.approx(230.0)
    candidates = review["water_candidates"]
    assert len(candidates) >= 2
    rec_idx = review["recommended_candidate_index"]
    assert rec_idx == 0
    assert candidates[0]["radius_px"] == pytest.approx(152.0, abs=7.0)
    assert candidates[0]["likely_base"] is False
    assert any(c["likely_base"] for c in candidates[1:])

    # An embossed disc smaller than the physical bottle bottom (~108 px) is
    # filtered out by perspective_height rather than polluting review options.
    tiny_disc = _synthetic_rim_and_water(water_r=152, base_r=74)
    review_tiny = client.post(
        "/api/v2/estimate_water_volume",
        files={"image": ("tiny.jpg", _encode_jpg(tiny_disc), "image/jpeg")},
        data={**common, "return_candidates": "true"},
    ).json()
    assert review_tiny["status"] == "review"
    assert len(review_tiny["water_candidates"]) == 1
    assert review_tiny["water_candidates"][0]["radius_px"] == pytest.approx(152.0, abs=7.0)


def test_manual_circle_confirmation_with_reconcile_lip_matches_guided_profile() -> None:
    img = _synthetic_rim_and_water(water_r=152)
    profile = {
        "heights_cm": [0, 18.5, 19.0, 19.5, 20.0],
        "radii_cm": [3.4, 3.4, 3.4, 3.4, 1.5],
    }
    response = client.post(
        "/api/v2/estimate_water_volume",
        files={"image": ("confirm.jpg", _encode_jpg(img), "image/jpeg")},
        data={
            "bottle_height_cm": "20",
            "bottle_volume_ml": "500",
            "opening_diameter_cm": "6.8",
            "profile_json": json.dumps(profile),
            "imu_alignment_score": "0.96",
            "camera_focal_length_px": "1200",
            "reconcile_lip": "true",
            "manual_circles_json": json.dumps(
                {
                    "outer_center_x": 384,
                    "outer_center_y": 384,
                    "outer_radius_px": 230,
                    "inner_center_x": 384,
                    "inner_center_y": 384,
                    "inner_radius_px": 152,
                }
            ),
        },
    ).json()
    assert response["status"] == "ok"
    assert response["method_used"] == "vision_manual_circles_profile"
    assert response["remaining_volume_ml"] is not None
    assert any("silhouette tip" in note for note in response["debug_notes"])


def test_132_image_ground_truth_water_contour_benchmark() -> None:
    from tests.benchmark_120_images import run_benchmark

    report = run_benchmark()
    assert report["total"] == 132
    assert report["new_top1"] / report["total"] >= 0.95
    assert report["new_top3"] / report["total"] >= 0.99
    assert report["mean_r_err_px"] <= 3.5
