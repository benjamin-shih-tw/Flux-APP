"""Flux water volume API v2.

The MVP keeps the current FastAPI service, but replaces the old "dual circle"
entry point with a cleaner depth-estimation pipeline:

- vision detects the bottle rim and water surface
- bottle profile supplies the shape prior
- iOS sends an IMU alignment score
- acoustic sensing is stubbed through a dedicated interface for later work
"""

from __future__ import annotations

import base64
import io

import cv2
import numpy as np
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from PIL import Image

from estimators import AcousticEstimator, DepthEstimator, FusionEngine
from volume_engine import build_cylinder_profile, parse_profile_json

app = FastAPI(title="Flux Water Volume API", version="2.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

_depth_estimator = DepthEstimator()
_acoustic_estimator = AcousticEstimator()
_fusion_engine = FusionEngine()


def _read_image(image: UploadFile) -> np.ndarray:
    raw = image.file.read()
    pil = Image.open(io.BytesIO(raw)).convert("RGB")
    arr = np.array(pil)
    return cv2.cvtColor(arr, cv2.COLOR_RGB2BGR)


def _encode_debug(image_bgr: np.ndarray) -> str:
    ok, buf = cv2.imencode(".jpg", image_bgr, [int(cv2.IMWRITE_JPEG_QUALITY), 85])
    if not ok:
        return ""
    return base64.b64encode(buf.tobytes()).decode("ascii")


def _safe_profile(
    profile_json: str,
    bottle_height_cm: float,
    opening_diameter_cm: float,
) -> list:
    if profile_json and profile_json.strip() not in ("", "{}"):
        return parse_profile_json(profile_json)
    return build_cylinder_profile(bottle_height_cm, opening_diameter_cm / 2.0)


def _base_error_response(message: str, debug_image_base64: str | None = None) -> dict:
    return {
        "status": "error",
        "message": message,
        "remaining_volume_ml": None,
        "water_depth_cm": None,
        "water_height_cm": None,
        "confidence": 0.0,
        "method_used": "error",
        "consumed_volume_ml": None,
        "outer_radius_px": None,
        "debug_image_base64": debug_image_base64,
    }


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/api/v2/estimate_water_volume")
@app.post("/api/v1/calculate_water_volume")
def estimate_water_volume(
    image: UploadFile = File(...),
    bottle_height_cm: float = Form(20.0),
    bottle_volume_ml: float = Form(500.0),
    opening_diameter_cm: float = Form(7.0),
    profile_json: str = Form("{}"),
    last_remaining_ml: float = Form(0.0),
    calibration_outer_radius_px: float = Form(0.0),
    imu_alignment_score: float = Form(1.0),
):
    """Estimate remaining volume and water depth from a single top-down image."""

    try:
        bgr = _read_image(image)
    except Exception as exc:
        return _base_error_response(f"Invalid image: {exc}")

    try:
        profile = _safe_profile(profile_json, bottle_height_cm, opening_diameter_cm)
    except ValueError as exc:
        return _base_error_response(str(exc), _encode_debug(bgr))

    try:
        depth_estimate, debug = _depth_estimator.estimate(
            image_bgr=bgr,
            profile=profile,
            bottle_height_cm=bottle_height_cm,
            bottle_volume_ml=bottle_volume_ml,
            opening_diameter_cm=opening_diameter_cm,
            calibration_outer_radius_px=calibration_outer_radius_px,
            imu_alignment_score=imu_alignment_score,
        )
    except Exception as exc:
        return _base_error_response(f"Depth estimation failed: {exc}", _encode_debug(bgr))

    acoustic_estimate = _acoustic_estimator.estimate()
    fused = _fusion_engine.fuse(depth_estimate, acoustic_estimate)

    remaining_ml = round(min(fused.remaining_volume_ml, bottle_volume_ml), 1)
    water_depth_cm = round(max(0.0, fused.water_depth_cm), 2)
    water_height_cm = round(max(0.0, bottle_height_cm - water_depth_cm), 2)

    consumed_ml = None
    if last_remaining_ml > 0:
        delta = last_remaining_ml - remaining_ml
        if delta > 0:
            consumed_ml = round(delta, 1)

    debug_overlay = _encode_debug(debug)

    return {
        "status": "ok",
        "message": "Flux v2 depth estimate complete",
        "remaining_volume_ml": remaining_ml,
        "water_depth_cm": water_depth_cm,
        "water_height_cm": water_height_cm,
        "confidence": round(fused.confidence, 3),
        "method_used": fused.method_used,
        "consumed_volume_ml": consumed_ml,
        "outer_radius_px": depth_estimate.outer_radius_px,
        "inner_radius_px": depth_estimate.inner_radius_px,
        "debug_image_base64": debug_overlay,
    }
