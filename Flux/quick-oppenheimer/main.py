"""Flux image + bottle geometry + phone acoustic fusion API."""
from __future__ import annotations

import base64
import io
import json
import math
import os
from pathlib import Path
from dataclasses import asdict

import cv2
import numpy as np
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from PIL import Image

from acoustics import AcousticEstimate, AcousticEstimator, PROBE_VERSION, read_pcm_wav
from estimators import DepthEstimator, FusionEngine, perspective_height
from volume_engine import (
    ProfilePoint,
    build_cylinder_profile,
    parse_profile_json,
    scaled_volume,
)
from water_contour_model import (
    FocusSelectionResult,
    RefinedWaterCandidate,
    detect_water_candidates_multicue,
    select_sharpest_focus_frame,
)


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
_diagnostic_dir = Path(os.environ.get("FLUX_DIAGNOSTIC_DIR", "/tmp/flux-water-api"))
# Diagnostic dumps write every uploaded photo to disk, so they stay off unless a
# developer asks for them. The previous filename check was not a switch: the iOS
# client always uploads the part as "capture.jpg".
_diagnostic_dump = os.environ.get("FLUX_DIAGNOSTIC_DUMP", "").strip().lower() in {"1", "true", "yes", "on"}


def _write_diagnostic(name: str, image: np.ndarray) -> None:
    if not _diagnostic_dump:
        return
    try:
        _diagnostic_dir.mkdir(parents=True, exist_ok=True)
        cv2.imwrite(str(_diagnostic_dir / name), image)
    except (OSError, cv2.error):
        pass


def _read_image(image: UploadFile) -> np.ndarray:
    raw = image.file.read(20_000_001)
    if len(raw) > 20_000_000:
        raise ValueError("Image exceeds 20 MB.")
    pil = Image.open(io.BytesIO(raw))
    if pil.width * pil.height > 20_000_000:
        raise ValueError("Image exceeds 20 megapixels.")
    return cv2.cvtColor(np.asarray(pil.convert("RGB")), cv2.COLOR_RGB2BGR)


def _encode_debug(image: np.ndarray, *, max_edge: int = 1024, quality: int = 80) -> str:
    if max(image.shape[:2]) > max_edge:
        scale = max_edge / max(image.shape[:2])
        image = cv2.resize(image, (round(image.shape[1] * scale), round(image.shape[0] * scale)))
    ok, buffer = cv2.imencode(".jpg", image, [int(cv2.IMWRITE_JPEG_QUALITY), quality])
    return base64.b64encode(buffer.tobytes()).decode("ascii") if ok else ""


def _parse_focus_frames(
    base_bgr: np.ndarray,
    guided_rim: tuple[tuple[float, float], float] | None,
    camera_focal_length_px: float | None,
    focus_frames: list[UploadFile] | None,
    focus_metadata_json: str,
) -> tuple[
    list[tuple[np.ndarray, tuple[tuple[float, float], float], float | None, float | None]],
    list[float | None],
]:
    if not guided_rim or not focus_frames:
        return [], []
    if len(focus_frames) > 8 or len(focus_metadata_json) > 10_000:
        return [], []

    base_lens: float | None = None
    frame_metas: list[dict] = []
    if focus_metadata_json.strip() not in ("", "{}"):
        parsed = json.loads(focus_metadata_json)
        if isinstance(parsed, dict):
            raw_base_lens = parsed.get("base_lens_position")
            if isinstance(raw_base_lens, (int, float)) and not isinstance(raw_base_lens, bool) and math.isfinite(raw_base_lens):
                base_lens = float(raw_base_lens)
            raw_frames = parsed.get("frames")
            if isinstance(raw_frames, list):
                frame_metas = [item for item in raw_frames if isinstance(item, dict)]

    all_frames: list[tuple[np.ndarray, tuple[tuple[float, float], float], float | None, float | None]] = [
        (base_bgr, guided_rim, camera_focal_length_px, base_lens)
    ]
    lens_list: list[float | None] = [base_lens]

    for idx, upload in enumerate(focus_frames):
        try:
            frame_bgr = _read_image(upload)
        except (ValueError, OSError):
            continue
        meta = frame_metas[idx] if idx < len(frame_metas) else {}
        rim = guided_rim
        raw_rim = meta.get("rim")
        if (
            isinstance(raw_rim, list)
            and len(raw_rim) == 3
            and all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) for v in raw_rim)
        ):
            fx, fy, fr = float(raw_rim[0]), float(raw_rim[1]), float(raw_rim[2])
            fh, fw = frame_bgr.shape[:2]
            if fr >= 24 and fr <= fx < fw - fr and fr <= fy < fh - fr:
                rim = ((fx, fy), fr)
        lens_pos: float | None = None
        raw_lp = meta.get("lens_position")
        if isinstance(raw_lp, (int, float)) and not isinstance(raw_lp, bool) and math.isfinite(raw_lp):
            lens_pos = float(raw_lp)
        focal_k = camera_focal_length_px
        raw_fk = meta.get("focal_length_px")
        if isinstance(raw_fk, (int, float)) and not isinstance(raw_fk, bool) and math.isfinite(raw_fk) and 50.0 <= raw_fk <= 20_000.0:
            focal_k = float(raw_fk)
        all_frames.append((frame_bgr, rim, focal_k, lens_pos))
        lens_list.append(lens_pos)

    if len(all_frames) <= 1:
        return [], []
    return all_frames, lens_list


def _build_review_candidates(
    analysis_bgr: np.ndarray,
    depth,
    profile: list[ProfilePoint],
    bottle_height_cm: float,
    bottle_volume_ml: float,
    opening_diameter_cm: float,
    camera_focal_length_px: float | None,
    last_remaining_ml: float | None,
    auto_accepted: bool,
    precomputed_candidates: list[RefinedWaterCandidate] | None,
) -> tuple[list[dict], int | None, bool]:
    if (
        depth.outer_center is None
        or depth.outer_radius_px is None
        or depth.phone_to_rim_cm is None
    ):
        return [], None, False

    outer_center = depth.outer_center
    outer_r = float(depth.outer_radius_px)
    opening_r_cm = max(opening_diameter_cm / 2.0, 0.1)
    effective_focal = camera_focal_length_px or (outer_r * depth.phone_to_rim_cm / opening_r_cm)

    def make_entry(
        entry_id: int,
        center: tuple[float, float],
        radius_px: float,
        score: float,
        coverage: float,
        likely_base: bool,
        recommended: bool,
        peak_lens: float | None = None,
    ) -> dict | None:
        height = perspective_height(
            profile,
            bottle_height_cm,
            depth.phone_to_rim_cm,
            effective_focal,
            radius_px,
        )
        if height is None:
            return None
        clamped_h = max(0.0, min(bottle_height_cm, float(height)))
        depth_cm = bottle_height_cm - clamped_h
        vol_ml = round(float(scaled_volume(profile, clamped_h, bottle_volume_ml)), 1)
        cons_ml = (
            round(last_remaining_ml - vol_ml, 1)
            if (last_remaining_ml is not None and last_remaining_ml > vol_ml)
            else None
        )
        return {
            "id": entry_id,
            "center_x": round(float(center[0]), 2),
            "center_y": round(float(center[1]), 2),
            "radius_px": round(float(radius_px), 2),
            "radius_ratio": round(float(radius_px / max(outer_r, 1e-6)), 4),
            "remaining_volume_ml": vol_ml,
            "consumed_volume_ml": cons_ml,
            "water_height_cm": round(clamped_h, 2),
            "water_depth_cm": round(depth_cm, 2),
            "score": round(float(score), 3),
            "coverage": round(float(coverage), 3),
            "likely_base": bool(likely_base),
            "recommended": bool(recommended),
            "peak_lens_position": round(peak_lens, 3) if peak_lens is not None else None,
        }

    # Primary ranked candidates come from the upgraded offset-aware multi-cue
    # Huber-IRLS contour detector.
    multicue = (
        precomputed_candidates
        if precomputed_candidates is not None
        else detect_water_candidates_multicue(
            analysis_bgr,
            outer_center,
            outer_r,
            profile=profile,
            bottle_height_cm=bottle_height_cm,
            phone_to_rim_cm=depth.phone_to_rim_cm,
            focal_length_px=effective_focal,
            max_candidates=6,
        )
    )

    entries: list[dict] = []
    for obs in multicue:
        if any(abs(existing["radius_px"] - obs.radius_px) <= outer_r * 0.045 for existing in entries):
            continue
        entry = make_entry(
            len(entries),
            obs.center,
            obs.radius_px,
            score=obs.score,
            coverage=obs.coverage,
            likely_base=obs.likely_base,
            recommended=False,
            peak_lens=obs.focus_lens_position,
        )
        if entry is not None:
            entries.append(entry)
        if len(entries) >= 5:
            break

    # Include strict auto-accepted circle if it differs from multi-cue candidates.
    auto_matches_top = False
    if auto_accepted and depth.inner_radius_px is not None and depth.inner_center is not None:
        if entries and (
            abs(entries[0]["radius_px"] - float(depth.inner_radius_px)) <= outer_r * 0.045
            and math.dist(
                (entries[0]["center_x"], entries[0]["center_y"]), depth.inner_center,
            ) <= outer_r * 0.035
            and depth.remaining_volume_ml is not None
            and entries[0]["remaining_volume_ml"] is not None
            and abs(entries[0]["remaining_volume_ml"] - depth.remaining_volume_ml)
            <= max(10.0, bottle_volume_ml * 0.02)
        ):
            auto_matches_top = True
        elif not any(abs(existing["radius_px"] - float(depth.inner_radius_px)) <= outer_r * 0.045 for existing in entries):
            auto_entry = make_entry(
                len(entries),
                depth.inner_center,
                float(depth.inner_radius_px),
                score=max(float(depth.confidence), 0.70),
                coverage=float(depth.water_visible_fraction),
                likely_base=False,
                recommended=False,
            )
            if auto_entry is not None:
                if not entries:
                    auto_matches_top = True
                entries.append(auto_entry)

    recommended_index: int | None = None
    if entries:
        non_base = next((i for i, item in enumerate(entries) if not item["likely_base"]), None)
        recommended_index = non_base if non_base is not None else 0
        entries[recommended_index]["recommended"] = True
        if recommended_index != 0:
            auto_matches_top = False

    return entries[:5], recommended_index, auto_matches_top


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
        "water_visible_fraction": 0.0,
        "water_contour_inferred": False,
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
    manual_circles_json: str = Form("{}"),
    guided_rim_json: str = Form(""),
    return_candidates: bool = Form(False),
    reconcile_lip: bool = Form(False),
    focus_frames: list[UploadFile] | None = File(default=None),
    focus_metadata_json: str = Form(""),
) -> dict:
    baseline_note: str | None = None
    manual_circles: dict[str, object] | None = None
    try:
        # A persisted baseline can outlive a bottle switch on the client. It
        # must not prevent a fresh image from being measured just because it
        # was recorded for a different capacity (for example 1,500 ml ->
        # 600 ml). Treat it as unavailable; the current scan then establishes
        # a new baseline.
        if last_remaining_ml is not None and (
            not math.isfinite(last_remaining_ml)
            or not 0.0 <= last_remaining_ml <= bottle_volume_ml
        ):
            baseline_note = "Previous scan baseline ignored because it does not match this bottle capacity."
            last_remaining_ml = None
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
        if len(manual_circles_json) > 10_000:
            raise ValueError("Manual circle selection is too large.")
        if manual_circles_json.strip() not in ("", "{}"):
            parsed_manual = json.loads(manual_circles_json)
            if not isinstance(parsed_manual, dict):
                raise ValueError("Manual circle selection must be a JSON object.")
            manual_circles = parsed_manual
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
        guided_rim = None
        if guided_rim_json:
            if len(guided_rim_json) > 256 or manual_circles is not None:
                raise ValueError("Invalid guided rim.")
            values = json.loads(guided_rim_json)
            if not isinstance(values, list) or len(values) != 3 or not all(
                type(v) in (int, float) and math.isfinite(v) for v in values
            ):
                raise ValueError("Invalid guided rim coordinates.")
            x, y, r = values
            h, w = bgr.shape[:2]
            if r < 24 or not (r <= x < w-r and r <= y < h-r):
                raise ValueError("Guided rim is outside the photo.")
            guided_rim = ((x, y), r)
        _write_diagnostic("last-capture.jpg", bgr)
        parsed_focus_frames, per_frame_lenses = _parse_focus_frames(
            bgr, guided_rim, camera_focal_length_px, focus_frames, focus_metadata_json
        )
    except (ValueError, TypeError, KeyError, AttributeError, OSError) as exc:
        return _base_error_response(str(exc))

    # The last row of a side silhouette can measure a short chord across
    # the curved lip. Reconcile only this isolated tip with the opening
    # used by the guided scan, when three nearby neck samples agree.
    adjusted_lip = False
    if (guided_rim or reconcile_lip) and len(profile) >= 4:
        rim = opening_diameter_cm / 2
        tip = profile[-1]
        neck = profile[-4:-1]
        if (tip.radius_cm < 0.7 * rim and
                tip.height_cm - neck[0].height_cm <= bottle_height_cm * 0.08 and
                all(abs(point.radius_cm - rim) <= 0.05 * rim for point in neck)):
            profile[-1] = ProfilePoint(tip.height_cm, rim)
            adjusted_lip = True

    # Select the single sharpest unblended focus plane (eliminating handheld
    # multi-frame ghosting while refining each frame's rim directly on pixels).
    focus_selection: FocusSelectionResult | None = None
    analysis_bgr = bgr
    active_rim = guided_rim
    active_focal = camera_focal_length_px
    if parsed_focus_frames:
        focus_selection = select_sharpest_focus_frame(
            parsed_focus_frames,
            profile=profile,
            bottle_height_cm=bottle_height_cm,
            opening_diameter_cm=opening_diameter_cm,
        )
        analysis_bgr = focus_selection.selected_bgr
        active_rim = focus_selection.selected_rim
        active_focal = focus_selection.selected_focal_px or camera_focal_length_px
        _write_diagnostic("last-selected-focus.jpg", analysis_bgr)

    analysis_candidates = focus_selection.candidates if focus_selection is not None else None
    if active_rim is not None and manual_circles is None and analysis_candidates is None:
        candidate_distance = (
            active_focal * (opening_diameter_cm / 2) / active_rim[1]
            if active_focal is not None else phone_to_rim_cm
        )
        analysis_candidates = detect_water_candidates_multicue(
            analysis_bgr, active_rim[0], active_rim[1],
            profile=profile, bottle_height_cm=bottle_height_cm,
            phone_to_rim_cm=candidate_distance, focal_length_px=active_focal,
        )

    depth, debug = _depth_estimator.estimate(
        analysis_bgr,
        profile,
        bottle_height_cm,
        bottle_volume_ml,
        opening_diameter_cm,
        calibration_outer_radius_px,
        imu_alignment_score,
        active_focal,
        phone_to_rim_cm,
        surface_mode,
        manual_circles,
        active_rim,
        analysis_candidates,
    )
    if focus_selection is not None and focus_selection.frame_count > 1:
        lp_note = (
            f", lens={focus_selection.selected_lens_position:.2f}"
            if focus_selection.selected_lens_position is not None
            else ""
        )
        depth.debug_notes.append(
            f"Selected sharpest focus frame #{focus_selection.selected_index + 1}/{focus_selection.frame_count}"
            f"{lp_note} (interior sharpness {focus_selection.sharpness_gain:.2f}x)."
        )
    if adjusted_lip:
        depth.debug_notes.append("Isolated silhouette tip fitted to the model opening and adjacent neck.")
    if baseline_note:
        depth.debug_notes.append(baseline_note)

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
    _write_diagnostic("last-overlay.jpg", debug)

    response_status = "retake" if retake else "ok"
    response_requires_retake = retake
    water_candidates: list[dict] = []
    recommended_candidate_index: int | None = None
    review_image_b64: str | None = None
    reconciled_profile_payload: dict | None = None

    if return_candidates:
        review_ready = (
            imu_alignment_score >= 0.82
            and depth.outer_center is not None
            and depth.outer_radius_px is not None
            and depth.phone_to_rim_cm is not None
            and 3.0 <= depth.phone_to_rim_cm <= 40.0
        )
        if review_ready:
            water_candidates, recommended_candidate_index, auto_matches_top = _build_review_candidates(
                analysis_bgr,
                depth,
                profile,
                bottle_height_cm,
                bottle_volume_ml,
                opening_diameter_cm,
                active_focal,
                last_remaining_ml,
                auto_accepted=not retake,
                precomputed_candidates=analysis_candidates,
            )
            review_image_b64 = _encode_debug(analysis_bgr, max_edge=1280, quality=88)
            reconciled_profile_payload = {
                "heights_cm": [round(p.height_cm, 5) for p in profile],
                "radii_cm": [round(p.radius_cm, 5) for p in profile],
            }
            if retake or not auto_matches_top:
                response_status = "review"
                response_requires_retake = False

    img_h, img_w = analysis_bgr.shape[:2]
    return {
        "status": response_status,
        "message": fused.debug_notes[-1] if retake else (
            "Image and acoustic analysis complete" if acoustic_present else "Image analysis complete"
        ),
        "remaining_volume_ml": remaining,
        "consumed_volume_ml": consumed,
        "water_depth_cm": None if retake else round(float(fused.water_depth_cm), 2),
        "water_height_cm": None if retake else round(bottle_height_cm - float(fused.water_depth_cm), 2),
        "confidence": round(fused.confidence, 3),
        "method_used": fused.method_used,
        "requires_retake": response_requires_retake,
        "image_width": img_w,
        "image_height": img_h,
        "outer_center_x": depth.outer_center[0] if depth.outer_center else None,
        "outer_center_y": depth.outer_center[1] if depth.outer_center else None,
        "outer_radius_px": depth.outer_radius_px,
        "inner_center_x": depth.inner_center[0] if depth.inner_center else None,
        "inner_center_y": depth.inner_center[1] if depth.inner_center else None,
        "inner_radius_px": depth.inner_radius_px,
        "water_visible_fraction": round(depth.water_visible_fraction, 3),
        "water_contour_inferred": depth.water_contour_inferred,
        "phone_to_rim_cm": depth.phone_to_rim_cm,
        "focus_stack_count": focus_selection.frame_count if focus_selection is not None else 1,
        "selected_focus_index": focus_selection.selected_index if focus_selection is not None else 0,
        "selected_focal_length_px": active_focal,
        "selected_lens_position": (
            round(focus_selection.selected_lens_position, 3)
            if focus_selection is not None and focus_selection.selected_lens_position is not None
            else None
        ),
        "per_frame_lens_positions": [
            round(lp, 3) if lp is not None else None for lp in per_frame_lenses
        ],
        "sharpness_gain": round(focus_selection.sharpness_gain, 2) if focus_selection is not None else 1.0,
        "water_candidates": water_candidates,
        "recommended_candidate_index": recommended_candidate_index,
        "review_image_base64": review_image_b64,
        "reconciled_profile": reconciled_profile_payload,
        "vision_estimate": asdict(depth),
        "acoustic_estimate": asdict(acoustic),
        "debug_notes": fused.debug_notes,
        "debug_image_base64": _encode_debug(debug),
    }
