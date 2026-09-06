"""Flux image + bottle geometry + phone acoustic fusion API."""
from __future__ import annotations

import base64
import io
import json
import math
from dataclasses import asdict

import cv2
import numpy as np
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from PIL import Image

from acoustics import AcousticEstimate, AcousticEstimator, PROBE_VERSION, read_pcm_wav
from estimators import DepthEstimator, FusionEngine
from volume_engine import build_cylinder_profile, parse_profile_json


app = FastAPI(title="Flux Water Volume API", version="2.2.0")
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
    raw = image.file.read(20_000_001)
    if len(raw) > 20_000_000:
        raise ValueError("Image exceeds 20 MB.")
    pil = Image.open(io.BytesIO(raw))
    if pil.width * pil.height > 20_000_000:
        raise ValueError("Image exceeds 20 megapixels.")
    return cv2.cvtColor(np.asarray(pil.convert("RGB")), cv2.COLOR_RGB2BGR)


def _encode_debug(image: np.ndarray) -> str:
    if max(image.shape[:2]) > 1024:
        scale = 1024 / max(image.shape[:2])
        image = cv2.resize(image, (round(image.shape[1] * scale), round(image.shape[0] * scale)))
    ok, buffer = cv2.imencode(".jpg", image, [int(cv2.IMWRITE_JPEG_QUALITY), 80])
    return base64.b64encode(buffer.tobytes()).decode("ascii") if ok else ""


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
        "inner_radius_px": None,
        "phone_to_rim_cm": None,
        "requires_retake": True,
        "debug_image_base64": debug_image_base64,
    }


def _finite(name: str, value: float | None, low: float, high: float) -> None:
    if value is not None and (not math.isfinite(value) or not low <= value <= high):
        raise ValueError(f"{name} must be between {low} and {high}.")


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "probe_version": PROBE_VERSION}


@app.post("/api/v2/estimate_water_volume")
@app.post("/api/v1/calculate_water_volume")
def estimate_water_volume(
    image: UploadFile = File(...),
    bottle_height_cm: float = Form(20.0),
    bottle_volume_ml: float = Form(500.0),
    opening_diameter_cm: float = Form(7.0),
    profile_json: str = Form("{}"),
    last_remaining_ml: float | None = Form(None),
    calibration_outer_radius_px: float = Form(0.0),
    imu_alignment_score: float = Form(1.0),
    camera_focal_length_px: float | None = Form(None),
    phone_to_rim_cm: float | None = Form(None),
    surface_mode: str = Form("auto"),
    seconds_since_last_scan: float | None = Form(None),
    allow_large_change: bool = Form(False),
    audio: UploadFile | None = File(None),
    acoustic_metadata_json: str = Form("{}"),
) -> dict:
    try:
        for name, value, low, high in [
            ("bottle height", bottle_height_cm, 3.0, 60.0),
            ("capacity", bottle_volume_ml, 10.0, 10_000.0),
            ("opening diameter", opening_diameter_cm, 0.5, 20.0),
            ("IMU score", imu_alignment_score, 0.0, 1.0),
            ("calibration radius", calibration_outer_radius_px, 0.0, 20_000.0),
            ("focal length", camera_focal_length_px, 50.0, 20_000.0),
            ("phone distance", phone_to_rim_cm, 3.0, 40.0),
            ("last remaining", last_remaining_ml, 0.0, bottle_volume_ml),
            ("scan age", seconds_since_last_scan, 0.0, 1e9),
        ]:
            _finite(name, value, low, high)
        if surface_mode not in ("auto", "opaque"):
            raise ValueError("surface_mode must be auto or opaque.")
        if len(profile_json) > 100_000:
            raise ValueError("Profile is too large.")
        profile = (
            parse_profile_json(profile_json)
            if profile_json.strip() not in ("", "{}")
            else build_cylinder_profile(bottle_height_cm, opening_diameter_cm / 2)
        )
        if abs(profile[-1].height_cm - bottle_height_cm) > 0.1:
            raise ValueError("Profile height differs from the measured bottle height.")
        bgr = _read_image(image)
    except (ValueError, TypeError, KeyError, AttributeError, OSError) as exc:
        return _base_error_response(str(exc))

    depth, debug = _depth_estimator.estimate(
        bgr,
        profile,
        bottle_height_cm,
        bottle_volume_ml,
        opening_diameter_cm,
        calibration_outer_radius_px,
        imu_alignment_score,
        camera_focal_length_px,
        phone_to_rim_cm,
        surface_mode,
    )

    acoustic_present = audio is not None
    acoustic = AcousticEstimate(
        debug_notes=["No acoustic recording supplied."] if not acoustic_present else [],
    )
    if audio is not None:
        try:
            if len(acoustic_metadata_json) > 10_000:
                raise ValueError("Acoustic metadata is too large.")
            metadata = json.loads(acoustic_metadata_json)
            if not isinstance(metadata, dict) or metadata.get("probe_version") != PROBE_VERSION:
                raise ValueError("Unsupported probe version.")
            if metadata.get("route") != "built_in_bottom":
                raise ValueError("Use the built-in speaker and bottom microphone.")

            geometry: dict[str, float] = {}
            for key, low, high in [
                ("speaker_offset_cm", 0.0, 25.0),
                ("microphone_offset_cm", 0.0, 25.0),
                ("direct_path_cm", 0.0, 10.0),
            ]:
                value = float(metadata[key])
                _finite(key, value, low, high)
                geometry[key] = value

            neck = metadata.get("neck_length_cm")
            if neck is not None:
                neck = float(neck)
                _finite("neck length", neck, 0.1, bottle_height_cm)
            temperature = float(metadata.get("temperature_c", 20.0))
            _finite("temperature", temperature, 0.0, 40.0)
            samples, rate = read_pcm_wav(audio.file.read(2_000_001))
            acoustic = _acoustic_estimator.estimate(
                samples,
                rate,
                profile=profile,
                bottle_height_cm=bottle_height_cm,
                bottle_volume_ml=bottle_volume_ml,
                phone_to_rim_cm=depth.phone_to_rim_cm or phone_to_rim_cm,
                opening_diameter_cm=opening_diameter_cm,
                neck_length_cm=neck,
                temperature_c=temperature,
                **geometry,
            )
        except (ValueError, KeyError, TypeError, OSError) as exc:
            acoustic = AcousticEstimate(
                debug_notes=[f"Audio unavailable: {exc}"],
                requires_retake=True,
            )

    fused = _fusion_engine.fuse(
        depth,
        acoustic,
        profile=profile,
        bottle_height_cm=bottle_height_cm,
        bottle_volume_ml=bottle_volume_ml,
        imu_alignment_score=imu_alignment_score,
        last_remaining_ml=last_remaining_ml,
        seconds_since_last_scan=seconds_since_last_scan,
        allow_large_change=allow_large_change,
        acoustic_present=acoustic_present,
    )
    retake = fused.requires_retake
    remaining = None if retake else round(float(fused.remaining_volume_ml), 1)
    consumed = None
    if remaining is not None and last_remaining_ml is not None and last_remaining_ml > remaining:
        consumed = round(last_remaining_ml - remaining, 1)

    cv2.putText(
        debug,
        "Retake required" if retake else f"{remaining:.0f} ml ({fused.method_used})",
        (20, 45),
        cv2.FONT_HERSHEY_SIMPLEX,
        1,
        (0, 200, 255),
        2,
    )
    return {
        "status": "retake" if retake else "ok",
        "message": fused.debug_notes[-1] if retake else "Image and acoustic analysis complete",
        "remaining_volume_ml": remaining,
        "consumed_volume_ml": consumed,
        "water_depth_cm": None if retake else round(float(fused.water_depth_cm), 2),
        "water_height_cm": None if retake else round(bottle_height_cm - float(fused.water_depth_cm), 2),
        "confidence": round(fused.confidence, 3),
        "method_used": fused.method_used,
        "requires_retake": retake,
        "outer_radius_px": depth.outer_radius_px,
        "inner_radius_px": depth.inner_radius_px,
        "phone_to_rim_cm": depth.phone_to_rim_cm,
        "vision_estimate": asdict(depth),
        "acoustic_estimate": asdict(acoustic),
        "debug_notes": fused.debug_notes,
        "debug_image_base64": _encode_debug(debug),
    }
