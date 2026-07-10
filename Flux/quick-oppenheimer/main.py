"""Flux water volume API — dual-circle detection + profile integration."""

from __future__ import annotations

import base64
import io
from typing import Optional

import cv2
import numpy as np
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from PIL import Image

from circle_detector import detect_circles, draw_debug_overlay
from volume_engine import (
    build_cylinder_profile,
    height_from_water_radius,
    parse_profile_json,
    volume_below_height,
)

app = FastAPI(title="Flux Water Volume API", version="2.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


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


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/api/v1/calculate_water_volume")
async def calculate_water_volume(
    image: UploadFile = File(...),
    bottle_height: float = Form(20.0),
    bottle_volume: float = Form(500.0),
    opening_diameter_cm: float = Form(7.0),
    profile_json: str = Form("{}"),
    last_remaining_ml: float = Form(0.0),
    calibration_outer_radius_px: float = Form(0.0),
):
    """
    Detect bottle rim + water surface from a top-down photo.

    Returns remaining volume, optional consumed volume (vs last scan), and debug overlay.
    """
    try:
        bgr = _read_image(image)
    except Exception as exc:
        return {
            "status": "error",
            "message": f"Invalid image: {exc}",
            "remaining_volume_ml": None,
            "consumed_volume_ml": None,
            "water_height_cm": None,
            "outer_radius_px": None,
            "debug_image_base64": None,
        }

    opening_radius_cm = opening_diameter_cm / 2.0

    # Build profile from iOS calibration or fallback cylinder
    try:
        if profile_json and profile_json.strip() not in ("", "{}"):
            profile = parse_profile_json(profile_json)
        else:
            profile = build_cylinder_profile(bottle_height, opening_radius_cm)
    except ValueError as exc:
        return {
            "status": "error",
            "message": str(exc),
            "remaining_volume_ml": None,
            "consumed_volume_ml": None,
            "water_height_cm": None,
            "outer_radius_px": None,
            "debug_image_base64": None,
        }

    try:
        circles = detect_circles(bgr)
    except ValueError as exc:
        return {
            "status": "error",
            "message": str(exc),
            "remaining_volume_ml": None,
            "consumed_volume_ml": None,
            "water_height_cm": None,
            "outer_radius_px": None,
            "debug_image_base64": _encode_debug(bgr),
        }

    outer_r_px = circles.outer_radius_px

    # Scale: pixels → cm using known opening radius
    if outer_r_px <= 0:
        return {
            "status": "error",
            "message": "Invalid outer circle radius",
            "remaining_volume_ml": None,
            "consumed_volume_ml": None,
            "water_height_cm": None,
            "outer_radius_px": None,
            "debug_image_base64": _encode_debug(bgr),
        }

    px_per_cm = outer_r_px / opening_radius_cm

    water_height_cm: Optional[float] = None
    remaining_ml: float

    if circles.inner_radius_px is not None:
        water_radius_cm = circles.inner_radius_px / px_per_cm
        water_height_cm = height_from_water_radius(profile, water_radius_cm)

        if water_height_cm is None:
            # Cylindrical neck: water fills to top, use inner/outer area ratio as fill fraction
            fill_fraction = (circles.inner_radius_px / outer_r_px) ** 2
            remaining_ml = bottle_volume * min(1.0, max(0.0, fill_fraction))
        else:
            remaining_ml = volume_below_height(profile, water_height_cm)
    else:
        # No inner circle — assume full if we can't see water surface
        remaining_ml = bottle_volume * 0.5
        return {
            "status": "error",
            "message": "Could not detect water surface. Try coloured water or better lighting.",
            "remaining_volume_ml": round(remaining_ml, 1),
            "consumed_volume_ml": None,
            "water_height_cm": None,
            "outer_radius_px": round(outer_r_px, 1),
            "debug_image_base64": _encode_debug(
                draw_debug_overlay(bgr, circles, None, remaining_ml, None)
            ),
        }

    remaining_ml = round(min(remaining_ml, bottle_volume), 1)

    consumed_ml: Optional[float] = None
    if last_remaining_ml > 0:
        delta = last_remaining_ml - remaining_ml
        if delta > 0:
            consumed_ml = round(delta, 1)

    debug = draw_debug_overlay(bgr, circles, water_height_cm, remaining_ml, consumed_ml)

    return {
        "status": "ok",
        "message": "Calculation complete",
        "remaining_volume_ml": remaining_ml,
        "consumed_volume_ml": consumed_ml,
        "water_height_cm": round(water_height_cm, 2) if water_height_cm else None,
        "outer_radius_px": round(outer_r_px, 1),
        "debug_image_base64": _encode_debug(debug),
    }
