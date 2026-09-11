"""Bottle profile, vision and quality-gated acoustic fusion."""
from __future__ import annotations

from dataclasses import dataclass, field
import math

from acoustics import AcousticEstimate, AcousticEstimator
from circle_detector import detect_circles, draw_debug_overlay
from volume_engine import ProfilePoint, height_from_water_radius, scaled_volume


def _clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return max(low, min(high, value))


@dataclass
class DepthEstimate:
    remaining_volume_ml: float | None = None
    water_depth_cm: float | None = None
    water_surface_height_cm: float | None = None
    confidence: float = 0.0
    method_used: str = "vision_unavailable"
    outer_radius_px: float | None = None
    inner_radius_px: float | None = None
    used_calibration_baseline: bool = False
    debug_notes: list[str] = field(default_factory=list)
    phone_to_rim_cm: float | None = None
    water_visible_fraction: float = 0.0
    water_contour_inferred: bool = False


@dataclass
class FusionEstimate:
    remaining_volume_ml: float | None = None
    water_depth_cm: float | None = None
    confidence: float = 0.0
    method_used: str = "retake_required"
    debug_notes: list[str] = field(default_factory=list)
    requires_retake: bool = True


def perspective_height(
    profile: list[ProfilePoint],
    bottle_height_cm: float,
    distance_cm: float,
    focal_length_px: float,
    observed_radius_px: float,
    minimum_surface_radius_cm: float | None = None,
) -> float | None:
    """Solve f*r(h)/(d+H-h)=observed pixels for a unique surface height."""
    candidates: list[float] = []
    for first, second in zip(profile, profile[1:]):
        slope = (second.radius_cm - first.radius_cm) / (second.height_cm - first.height_cm)
        intercept = first.radius_cm - slope * first.height_cm
        denominator = focal_length_px * slope + observed_radius_px
        numerator = observed_radius_px * (distance_cm + bottle_height_cm) - focal_length_px * intercept
        if abs(denominator) < 1e-8:
            continue
        height = numerator / denominator
        if first.height_cm - 1e-6 <= height <= second.height_cm + 1e-6:
            radius_at_height = slope * height + intercept
            # Side-photo modelling can accidentally include the cap or a
            # highlight above the actual opening, producing a sharply tapered
            # final profile segment. It cannot describe a water cross-section
            # below an opening that is physically wider than that segment.
            if (
                minimum_surface_radius_cm is not None
                and radius_at_height < minimum_surface_radius_cm
            ):
                continue
            if not candidates or abs(height - candidates[-1]) > 0.1:
                candidates.append(height)
    return candidates[0] if len(candidates) == 1 else None


class DepthEstimator:
    """Estimate surface height from the top-down image and bottle profile."""

    def estimate(
        self,
        image_bgr: np.ndarray,
        profile: list[ProfilePoint],
        bottle_height_cm: float,
        bottle_volume_ml: float,
        opening_diameter_cm: float,
        calibration_outer_radius_px: float = 0.0,
        imu_alignment_score: float = 1.0,
        camera_focal_length_px: float | None = None,
        phone_to_rim_cm: float | None = None,
        surface_mode: str = "auto",
    ) -> tuple[DepthEstimate, np.ndarray]:
        estimate = DepthEstimate(
            used_calibration_baseline=calibration_outer_radius_px > 0,
        )
        try:
            circles = detect_circles(image_bgr)
        except ValueError as exc:
            estimate.debug_notes.append(str(exc))
            return estimate, image_bgr.copy()

        estimate.outer_radius_px = circles.outer_radius_px
        estimate.inner_radius_px = circles.inner_radius_px
        estimate.water_visible_fraction = circles.water_visible_fraction
        estimate.water_contour_inferred = circles.water_contour_inferred
        opening_radius_cm = max(opening_diameter_cm / 2.0, 0.1)
        focal = camera_focal_length_px

        if focal is not None:
            live_distance = focal * opening_radius_cm / max(circles.outer_radius_px, 1e-6)
            if phone_to_rim_cm is not None and abs(phone_to_rim_cm - live_distance) > max(2.0, live_distance * 0.2):
                estimate.debug_notes.append("Camera distance disagrees with the visible rim.")
                return estimate, draw_debug_overlay(
                    image_bgr, circles, None, None, 0.0, estimate.method_used,
                )
            phone_to_rim_cm = live_distance

        estimate.phone_to_rim_cm = phone_to_rim_cm
        if phone_to_rim_cm is not None and not 3.0 <= phone_to_rim_cm <= 40.0:
            estimate.debug_notes.append("A current camera-to-rim distance of 3--40 cm is required.")
            estimate.phone_to_rim_cm = None
            phone_to_rim_cm = None

        if circles.inner_radius_px is None or surface_mode == "opaque":
            estimate.debug_notes.append("No usable visible water surface; use acoustics.")
        elif phone_to_rim_cm is not None:
            effective_focal = focal or circles.outer_radius_px * phone_to_rim_cm / opening_radius_cm
            height = perspective_height(
                profile,
                bottle_height_cm,
                phone_to_rim_cm,
                effective_focal,
                circles.inner_radius_px,
                opening_radius_cm * 0.85,
            )
            if height is None:
                estimate.debug_notes.append("Visible edge has no unique physical water height.")
            elif circles.inner_center is not None and math.dist(circles.inner_center, circles.outer_center) > circles.outer_radius_px * 0.15:
                estimate.debug_notes.append("Inner edge is off-axis; reflection or tilted water suspected.")
            else:
                estimate.water_surface_height_cm = max(0.0, min(bottle_height_cm, height))
                estimate.water_depth_cm = bottle_height_cm - estimate.water_surface_height_cm
                estimate.remaining_volume_ml = scaled_volume(
                    profile, estimate.water_surface_height_cm, bottle_volume_ml,
                )
                estimate.confidence = min(0.9, circles.confidence * _clamp(imu_alignment_score))
                estimate.method_used = "vision_perspective_profile"
        else:
            # Compatibility path for old clients. It is intentionally lower
            # confidence because it ignores the camera-to-bottle perspective.
            observed_radius = circles.inner_radius_px / max(circles.outer_radius_px, 1e-6) * opening_radius_cm
            height = height_from_water_radius(profile, observed_radius)
            if height is not None:
                estimate.water_surface_height_cm = max(0.0, min(bottle_height_cm, height))
                estimate.water_depth_cm = bottle_height_cm - estimate.water_surface_height_cm
                estimate.remaining_volume_ml = scaled_volume(
                    profile, estimate.water_surface_height_cm, bottle_volume_ml,
                )
                estimate.confidence = min(0.6, circles.confidence * 0.65 * _clamp(imu_alignment_score))
                estimate.method_used = "vision_orthographic_profile"
                estimate.debug_notes.append("Camera distance was not supplied; orthographic fallback used.")

        debug = draw_debug_overlay(
            image_bgr,
            circles,
            estimate.water_depth_cm,
            estimate.remaining_volume_ml,
            estimate.confidence,
            estimate.method_used,
        )
        return estimate, debug


class FusionEngine:
    """Prefer clear image evidence, then acoustic evidence, with hard gates."""

    def fuse(
        self,
        depth_estimate: DepthEstimate,
        acoustic_estimate: AcousticEstimate | None = None,
        *,
        profile: list[ProfilePoint] | None = None,
        bottle_height_cm: float = 20.0,
        bottle_volume_ml: float = 500.0,
        imu_alignment_score: float = 1.0,
        last_remaining_ml: float | None = None,
        seconds_since_last_scan: float | None = None,
        allow_large_change: bool = False,
        acoustic_present: bool = False,
    ) -> FusionEstimate:
        vision = depth_estimate
        audio = acoustic_estimate or AcousticEstimate()
        notes = list(vision.debug_notes) + list(audio.debug_notes)

        def retake(reason: str) -> FusionEstimate:
            return FusionEstimate(debug_notes=notes + [reason])

        if imu_alignment_score < 0.82:
            return retake("Phone moved or tilted during capture. Hold steady and retry.")

        vision_valid = (
            vision.remaining_volume_ml is not None
            and vision.water_depth_cm is not None
            and vision.confidence >= 0.45
        )
        acoustic_valid = (
            not audio.requires_retake
            and audio.remaining_volume_ml is not None
            and audio.water_depth_cm is not None
            and audio.confidence >= 0.55
        )

        if vision_valid and acoustic_valid:
            depth_difference = abs(vision.water_depth_cm - audio.water_depth_cm)
            volume_difference = abs(vision.remaining_volume_ml - audio.remaining_volume_ml)
            if depth_difference > max(3.0, bottle_height_cm * 0.18) or volume_difference > max(40.0, bottle_volume_ml * 0.18):
                return retake("Image and sound disagree. Do not average; repeat the scan.")

            vision_weight = vision.confidence * (2.0 if vision.confidence >= 0.75 else 1.0)
            acoustic_weight = audio.confidence
            depth = (vision.water_depth_cm * vision_weight + audio.water_depth_cm * acoustic_weight) / (vision_weight + acoustic_weight)
            volume = scaled_volume(profile, bottle_height_cm - depth, bottle_volume_ml) if profile else vision.remaining_volume_ml
            confidence = min(
                0.95,
                (vision.confidence * vision_weight + audio.confidence * acoustic_weight)
                / (vision_weight + acoustic_weight) + 0.03,
            )
            method = "fusion_vision_echo"
        elif vision_valid:
            depth = vision.water_depth_cm
            volume = vision.remaining_volume_ml
            confidence = vision.confidence
            method = vision.method_used
            if acoustic_present:
                notes.append("Acoustic evidence was insufficient; clear image estimate retained.")
        elif acoustic_valid:
            depth = audio.water_depth_cm
            volume = audio.remaining_volume_ml
            confidence = audio.confidence
            method = audio.method_used
            notes.append("Visible water surface was unavailable; acoustic estimate used.")
        else:
            reason = (
                "No reliable water surface or echo. Reposition and retry."
                if acoustic_present
                else "No reliable visible water surface. Reposition and retry."
            )
            return retake(reason)

        if (
            not allow_large_change
            and last_remaining_ml is not None
            and seconds_since_last_scan is not None
            and 0 <= seconds_since_last_scan <= 60
            and abs(volume - last_remaining_ml) > max(80.0, bottle_volume_ml * 0.35)
        ):
            return retake("Large change since the recent scan. Retry, or confirm a refill/large drink.")

        return FusionEstimate(volume, depth, confidence, method, notes, False)
