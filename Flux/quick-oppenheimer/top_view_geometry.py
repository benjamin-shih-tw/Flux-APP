"""Research-only axial multi-view geometry; not an automatic water detector.

Assumptions: same stationary horizontal circular boundary in every frame,
optical axes vertical, known metric camera-height changes, no refractive
boundary, and declared error bounds that actually contain all input errors.
No internal bottle shape or volume is inferred from an unobserved surface.
"""
from dataclasses import dataclass
import math
from scipy.optimize import linprog


@dataclass(frozen=True)
class RingObservation:
    camera_offset_cm: float
    radius_px: float
    focal_length_px: float
    radius_error_px: float
    camera_offset_error_cm: float
    focal_relative_error: float = 0.0


@dataclass(frozen=True)
class RingBounds:
    radius_cm: tuple[float, float]
    reference_distance_cm: tuple[float, float]


def reconstruct_ring_bounds(observations: list[RingObservation]) -> RingBounds | None:
    """Bound R and d in p/f = R/(d + camera_offset) using all frames.

    Each input interval creates two linear half-planes. Return None if inputs
    conflict or if scale/distance is unbounded (e.g. no camera translation).
    Bounds describe only this model and these supplied errors, not confidence.
    """
    if len(observations) < 2:
        return None
    matrix, limits = [], []
    for item in observations:
        values = (item.camera_offset_cm, item.radius_px, item.focal_length_px,
                  item.radius_error_px, item.camera_offset_error_cm,
                  item.focal_relative_error)
        if not all(math.isfinite(value) for value in values):
            return None
        if (item.radius_error_px < 0 or item.camera_offset_error_cm < 0
                or item.radius_px <= item.radius_error_px
                or item.focal_length_px <= 0
                or not 0 <= item.focal_relative_error < 1):
            return None
        q_low = ((item.radius_px - item.radius_error_px)
                 / (item.focal_length_px * (1 + item.focal_relative_error)))
        q_high = ((item.radius_px + item.radius_error_px)
                  / (item.focal_length_px * (1 - item.focal_relative_error)))
        z_low = item.camera_offset_cm - item.camera_offset_error_cm
        z_high = item.camera_offset_cm + item.camera_offset_error_cm
        # Variables [R, d]. Projected circle radius bounds for positive depth.
        matrix.extend([[-1, q_low], [1, -q_high], [0, -1]])
        limits.extend([-q_low * z_low, q_high * z_high, z_low - 1e-6])

    ranges = []
    for axis in (0, 1):
        extrema = []
        for sign in (1, -1):
            objective = [0.0, 0.0]
            objective[axis] = sign
            result = linprog(objective, A_ub=matrix, b_ub=limits,
                             bounds=[(1e-6, None), (1e-6, None)], method="highs")
            if not result.success:
                return None
            extrema.append(float(result.x[axis]))
        if not all(math.isfinite(x) for x in extrema):
            return None
        ranges.append(tuple(extrema))
    return RingBounds(radius_cm=ranges[0], reference_distance_cm=ranges[1])


def water_depth_bounds(rim: RingBounds, surface: RingBounds) -> tuple[float, float] | None:
    """Conservative difference bounds, valid only for a shared camera origin."""
    low = surface.reference_distance_cm[0] - rim.reference_distance_cm[1]
    high = surface.reference_distance_cm[1] - rim.reference_distance_cm[0]
    if high < 0:
        return None
    return max(0.0, low), high
