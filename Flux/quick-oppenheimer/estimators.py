"""Depth, acoustic, and fusion stubs for the Flux v2 MVP."""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from circle_detector import DetectedCircles, detect_circles, draw_debug_overlay
from volume_engine import ProfilePoint, height_from_water_radius, radius_at_height, volume_below_height


def _clamp(value: float, lower: float = 0.0, upper: float = 1.0) -> float:
    return max(lower, min(upper, value))


@dataclass
class DepthEstimate:
    remaining_volume_ml: float
    water_depth_cm: float
    water_surface_height_cm: float
    confidence: float
    method_used: str
    outer_radius_px: float
    inner_radius_px: float | None
    used_calibration_baseline: bool
    debug_notes: list[str] = field(default_factory=list)


@dataclass
class AcousticEstimate:
    remaining_volume_ml: float | None
    water_depth_cm: float | None
    confidence: float
    method_used: str = "acoustic_stub"
    debug_notes: list[str] = field(default_factory=lambda: [
        "Acoustic sensing is reserved for the next hardware-backed iteration.",
    ])


@dataclass
class FusionEstimate:
    remaining_volume_ml: float
    water_depth_cm: float
    confidence: float
    method_used: str
    debug_notes: list[str] = field(default_factory=list)


class AcousticEstimator:
    """Placeholder for the future acoustic pipeline."""

    def estimate(self, *_args, **_kwargs) -> AcousticEstimate:
        return AcousticEstimate(
            remaining_volume_ml=None,
            water_depth_cm=None,
            confidence=0.0,
        )


class DepthEstimator:
    """Vision-first MVP: rim detection + profile matching + IMU confidence."""

    def estimate(
        self,
        image_bgr: np.ndarray,
        profile: list[ProfilePoint],
        bottle_height_cm: float,
        bottle_volume_ml: float,
        opening_diameter_cm: float,
        calibration_outer_radius_px: float = 0.0,
        imu_alignment_score: float = 1.0,
    ) -> tuple[DepthEstimate, np.ndarray]:
        circles = detect_circles(image_bgr)
        opening_radius_cm = max(opening_diameter_cm / 2.0, 0.1)
        baseline_radius_px = calibration_outer_radius_px if calibration_outer_radius_px > 0 else circles.outer_radius_px
        px_per_cm = max(baseline_radius_px / opening_radius_cm, 1e-6)
        alignment_score = _clamp(imu_alignment_score)

        notes: list[str] = []
        if calibration_outer_radius_px > 0:
            notes.append("Using stored one-time rim calibration.")
        else:
            notes.append("Using live rim detection as the scale baseline.")

        if circles.inner_radius_px is None:
            water_surface_height_cm = bottle_height_cm * 0.5
            water_depth_cm = bottle_height_cm - water_surface_height_cm
            remaining_ml = bottle_volume_ml * 0.5
            confidence = _clamp(0.28 + 0.35 * circles.confidence + 0.22 * alignment_score)
            notes.append("Water surface not visible; returned midpoint fallback.")
            method_used = "vision_fallback_midpoint"
            debug = draw_debug_overlay(
                image_bgr,
                circles,
                water_depth_cm,
                remaining_ml,
                confidence,
                method_used,
            )
            return (
                DepthEstimate(
                    remaining_volume_ml=round(remaining_ml, 1),
                    water_depth_cm=round(water_depth_cm, 2),
                    water_surface_height_cm=round(water_surface_height_cm, 2),
                    confidence=round(confidence, 3),
                    method_used=method_used,
                    outer_radius_px=round(circles.outer_radius_px, 2),
                    inner_radius_px=None,
                    used_calibration_baseline=calibration_outer_radius_px > 0,
                    debug_notes=notes,
                ),
                debug,
            )

        water_surface_radius_cm = circles.inner_radius_px / px_per_cm
        water_surface_height_cm = height_from_water_radius(profile, water_surface_radius_cm)
        profile_confidence = 0.45

        if water_surface_height_cm is None:
            fill_fraction = _clamp((circles.inner_radius_px / max(circles.outer_radius_px, 1e-6)) ** 2)
            water_surface_height_cm = bottle_height_cm * (1.0 - fill_fraction)
            remaining_ml = bottle_volume_ml * fill_fraction
            notes.append("Profile match fell back to a cylindrical fill fraction.")
        else:
            matched_radius_cm = radius_at_height(profile, water_surface_height_cm)
            radius_error = abs(matched_radius_cm - water_surface_radius_cm) / max(opening_radius_cm, 1e-6)
            profile_confidence = _clamp(1.0 - radius_error * 3.0, 0.25, 1.0)
            remaining_ml = volume_below_height(profile, water_surface_height_cm)

        water_depth_cm = max(0.0, bottle_height_cm - water_surface_height_cm)
        method_used = "vision_profile_mvp"
        confidence = _clamp(0.32 + 0.38 * circles.confidence + 0.18 * profile_confidence + 0.12 * alignment_score)
        debug = draw_debug_overlay(
            image_bgr,
            circles,
            water_depth_cm,
            remaining_ml,
            confidence,
            method_used,
        )

        return (
            DepthEstimate(
                remaining_volume_ml=round(min(remaining_ml, bottle_volume_ml), 1),
                water_depth_cm=round(water_depth_cm, 2),
                water_surface_height_cm=round(water_surface_height_cm, 2),
                confidence=round(confidence, 3),
                method_used=method_used,
                outer_radius_px=round(circles.outer_radius_px, 2),
                inner_radius_px=round(circles.inner_radius_px, 2),
                used_calibration_baseline=calibration_outer_radius_px > 0,
                debug_notes=notes,
            ),
            debug,
        )


class FusionEngine:
    """Minimal fusion layer that will accept acoustic data later."""

    def fuse(
        self,
        depth_estimate: DepthEstimate,
        acoustic_estimate: AcousticEstimate | None = None,
    ) -> FusionEstimate:
        if acoustic_estimate is None or acoustic_estimate.remaining_volume_ml is None or acoustic_estimate.water_depth_cm is None:
            return FusionEstimate(
                remaining_volume_ml=depth_estimate.remaining_volume_ml,
                water_depth_cm=depth_estimate.water_depth_cm,
                confidence=depth_estimate.confidence,
                method_used=depth_estimate.method_used,
                debug_notes=list(depth_estimate.debug_notes),
            )

        depth_weight = max(0.05, depth_estimate.confidence)
        acoustic_weight = max(0.05, acoustic_estimate.confidence)
        total_weight = depth_weight + acoustic_weight

        fused_remaining = (
            depth_estimate.remaining_volume_ml * depth_weight
            + acoustic_estimate.remaining_volume_ml * acoustic_weight
        ) / total_weight
        fused_depth = (
            depth_estimate.water_depth_cm * depth_weight
            + acoustic_estimate.water_depth_cm * acoustic_weight
        ) / total_weight
        fused_confidence = _clamp((depth_weight + acoustic_weight) / 2.0)

        return FusionEstimate(
            remaining_volume_ml=round(fused_remaining, 1),
            water_depth_cm=round(fused_depth, 2),
            confidence=round(fused_confidence, 3),
            method_used=f"{depth_estimate.method_used}+{acoustic_estimate.method_used}",
            debug_notes=list(depth_estimate.debug_notes) + list(acoustic_estimate.debug_notes),
        )
