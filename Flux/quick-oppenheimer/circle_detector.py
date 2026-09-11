"""Detect bottle opening (outer) and water surface (inner) circles in top-down photos."""

from __future__ import annotations

import math
from dataclasses import dataclass

import cv2
import numpy as np


@dataclass
class DetectedCircles:
    outer_center: tuple[float, float]
    outer_radius_px: float
    inner_center: tuple[float, float] | None
    inner_radius_px: float | None
    confidence: float
    water_visible_fraction: float = 0.0
    water_contour_inferred: bool = False
    water_visible_mask: tuple[bool, ...] | None = None


def _preprocess(gray: np.ndarray) -> np.ndarray:
    clahe = cv2.createCLAHE(clipLimit=2.5, tileGridSize=(8, 8))
    enhanced = clahe.apply(gray)
    return cv2.GaussianBlur(enhanced, (7, 7), 1.5)


def _score_circle(cx: float, cy: float, r: float, w: int, h: int) -> float:
    """Prefer circles near image center with reasonable radius."""
    center_dist = math.hypot(cx - w / 2, cy - h / 2) / (min(w, h) / 2)
    center_score = max(0.0, 1.0 - center_dist)
    size_score = 1.0 if 0.12 * min(w, h) <= r <= 0.45 * min(w, h) else 0.3
    return center_score * 0.7 + size_score * 0.3


def detect_outer_circle(blurred: np.ndarray) -> tuple[tuple[float, float], float] | None:
    h, w = blurred.shape[:2]
    min_r = int(min(w, h) * 0.08)
    max_r = int(min(w, h) * 0.48)

    best = _detect_outer_via_contours(blurred)
    if best is not None:
        return best

    circles = cv2.HoughCircles(
        blurred,
        cv2.HOUGH_GRADIENT,
        dp=1.2,
        minDist=min(w, h) // 4,
        param1=100,
        param2=25,
        minRadius=min_r,
        maxRadius=max_r,
    )

    if circles is None:
        return None

    best_circle = None
    best_score = -1.0
    for c in circles[0]:
        cx, cy, r = float(c[0]), float(c[1]), float(c[2])
        score = _score_circle(cx, cy, r, w, h) * r
        if score > best_score:
            best_score = score
            best_circle = ((cx, cy), r)

    return best_circle


def _detect_outer_via_contours(blurred: np.ndarray) -> tuple[tuple[float, float], float] | None:
    edges = cv2.Canny(blurred, 30, 100)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    edges = cv2.dilate(edges, kernel, iterations=1)

    contours, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE)
    if not contours:
        return None

    h, w = blurred.shape[:2]
    img_center = (w / 2, h / 2)
    best = None
    best_score = -1.0

    for cnt in contours:
        if len(cnt) < 8:
            continue
        area = cv2.contourArea(cnt)
        if area < (w * h * 0.005):
            continue

        (cx, cy), r = cv2.minEnclosingCircle(cnt)
        if r < min(w, h) * 0.08 or r > min(w, h) * 0.5:
            continue

        # Circularity
        perimeter = cv2.arcLength(cnt, True)
        circularity = 4 * math.pi * area / (perimeter * perimeter + 1e-6)
        if circularity < 0.4:
            continue

        center_dist = math.hypot(cx - img_center[0], cy - img_center[1]) / (min(w, h) / 2)
        score = circularity * (1.0 - center_dist * 0.5) * r
        if score > best_score:
            best_score = score
            best = ((float(cx), float(cy)), float(r))

    return best


def detect_inner_circle(
    blurred: np.ndarray,
    outer_center: tuple[float, float],
    outer_radius_px: float,
) -> tuple[tuple[float, float], float] | None:
    """Find a defensible water boundary, or return ``None`` when ambiguous.

    A metal bottle often contains several strong concentric edges from its
    base, neck and specular reflections.  The old implementation selected the
    smallest detected circle, which systematically promoted those edges to a
    water surface.  Here the opening is unwrapped into polar coordinates and a
    candidate must be supported consistently around most of its circumference.
    Multiple similarly convincing rings are treated as ambiguity, not water.
    """
    best = _select_water_candidate(blurred, outer_center, outer_radius_px)
    return (outer_center, best.radius_px) if best is not None else None


def _select_water_candidate(
    blurred: np.ndarray,
    outer_center: tuple[float, float],
    outer_radius_px: float,
) -> _WaterCircleCandidate | None:
    candidates = _radial_water_candidates(blurred, outer_center, outer_radius_px)
    if not candidates:
        return None

    candidates.sort(key=lambda candidate: candidate.score, reverse=True)
    best = candidates[0]

    # A very small circle is much more likely to be a bottle-base feature. It
    # is accepted only with exceptionally clean, unambiguous circumference
    # evidence.
    if best.radius_px < outer_radius_px * 0.38:
        return None

    # A perfectly complete, razor-stable inner circle in the lower half of a
    # metal bottle is characteristic of an embossed base plate or tooling
    # seam. A real low water meniscus cannot be distinguished from it in one
    # still frame, so reject it instead of reporting a confident false level.
    radius_ratio = best.radius_px / outer_radius_px
    if (
        radius_ratio < 0.55
        and best.coverage >= 0.92
        and best.persistence >= 0.90
        and best.scatter <= 0.012
    ):
        return None

    # Do not guess between multiple bottle-bottom/reflection rings. Candidates
    # closer than 5% of the opening radius are the same physical edge and were
    # already merged by `_radial_water_candidates`.
    competitors = [
        candidate for candidate in candidates[1:]
        if abs(candidate.radius_px - best.radius_px) > outer_radius_px * 0.07
        # A transparent surface can reveal several strong physical rings at
        # the bottle base. The water identity is ambiguous even when one ring
        # scores somewhat higher, so retain strong secondary region steps as
        # competitors instead of blindly taking the top score.
        and candidate.score >= best.score - 0.22
        and candidate.coverage >= 0.50
        and candidate.persistence >= 0.55
    ]
    if competitors:
        return None

    return best


@dataclass(frozen=True)
class _WaterCircleCandidate:
    radius_px: float
    score: float
    coverage: float
    polarity: float
    scatter: float
    persistence: float
    longest_arc: float
    visible_mask: tuple[bool, ...]


def _longest_cyclic_run(mask: np.ndarray) -> float:
    """Return the longest contiguous true arc as a fraction of a circle."""
    if mask.size == 0 or not np.any(mask):
        return 0.0
    if np.all(mask):
        return 1.0
    doubled = np.concatenate((mask, mask))
    longest = current = 0
    for value in doubled:
        current = current + 1 if value else 0
        longest = max(longest, current)
    return min(longest, mask.size) / mask.size


def _radial_water_candidates(
    gray: np.ndarray,
    center: tuple[float, float],
    outer_radius_px: float,
) -> list[_WaterCircleCandidate]:
    """Score circular edges using independent angular observations.

    Rows are radii and columns are angles.  For every candidate radius, each
    angle independently searches a narrow neighbourhood for its strongest
    radial transition.  This rejects partial highlights and off-centre arcs,
    both of which can look circular to Hough transforms.
    """
    if outer_radius_px < 24:
        return []

    cx, cy = center
    height, width = gray.shape[:2]
    min_radius = outer_radius_px * 0.22
    max_radius = outer_radius_px * 0.88
    radial_count = max(96, min(320, round(max_radius - min_radius) + 1))
    angular_count = 240
    radii = np.linspace(min_radius, max_radius, radial_count, dtype=np.float32)
    angles = np.linspace(0, 2 * math.pi, angular_count, endpoint=False, dtype=np.float32)
    map_x = cx + radii[:, None] * np.cos(angles)[None, :]
    map_y = cy + radii[:, None] * np.sin(angles)[None, :]
    if (
        float(map_x.min()) < 1 or float(map_x.max()) >= width - 1
        or float(map_y.min()) < 1 or float(map_y.max()) >= height - 1
    ):
        return []

    polar = cv2.remap(
        gray,
        map_x.astype(np.float32),
        map_y.astype(np.float32),
        interpolation=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_REFLECT_101,
    ).astype(np.float32)
    signed_gradient = np.gradient(polar, axis=0)
    absolute_gradient = np.abs(signed_gradient)
    # Smooth only in the radial direction. Angular smoothing would make short
    # highlights appear to cover more of the circumference than they do.
    smoothed = cv2.GaussianBlur(absolute_gradient, (1, 5), 0)
    # Use the upper angular quantile rather than the median.  A meniscus can
    # legitimately disappear behind the near side of the bottle neck, so a
    # useful radius may be visible over only roughly one third of the circle.
    # Candidate acceptance below still requires a long coherent arc and a
    # persistent region transition, which keeps isolated highlights out.
    strength_profile = np.quantile(smoothed, 0.70, axis=1)
    baseline = float(np.median(strength_profile))
    profile_mad = float(1.4826 * np.median(np.abs(strength_profile - baseline)))
    minimum_peak = max(2.8, baseline + 2.4 * max(profile_mad, 0.35))

    peak_rows: list[int] = []
    for row in range(4, radial_count - 4):
        local = strength_profile[row - 3:row + 4]
        if strength_profile[row] >= minimum_peak and strength_profile[row] == float(np.max(local)):
            if not peak_rows or row - peak_rows[-1] >= 4:
                peak_rows.append(row)
            elif strength_profile[row] > strength_profile[peak_rows[-1]]:
                peak_rows[-1] = row

    candidates: list[_WaterCircleCandidate] = []
    radius_step = float(radii[1] - radii[0])
    neighbourhood = max(2, round(outer_radius_px * 0.018 / max(radius_step, 1e-6)))
    gradient_noise = max(1.25, float(np.median(absolute_gradient)))

    for row in peak_rows:
        lo = max(1, row - neighbourhood)
        hi = min(radial_count - 1, row + neighbourhood + 1)
        local = absolute_gradient[lo:hi]
        offsets = np.argmax(local, axis=0)
        columns = np.arange(angular_count)
        strengths = local[offsets, columns]
        rows = lo + offsets
        signed = signed_gradient[rows, columns]
        support_threshold = max(3.5, gradient_noise * 2.7)
        supported = strengths >= support_threshold
        coverage = float(np.mean(supported))
        longest_arc = _longest_cyclic_run(supported)
        if coverage < 0.27 or int(np.sum(supported)) < 64 or longest_arc < 0.20:
            continue

        supported_signed = signed[supported]
        positive = float(np.mean(supported_signed > 0))
        polarity = max(positive, 1.0 - positive)
        if polarity < 0.60:
            continue

        observed_radii = radii[rows[supported]]
        radius = float(np.median(observed_radii))
        radial_scatter = float(
            1.4826 * np.median(np.abs(observed_radii - radius)) / outer_radius_px
        )
        if radial_scatter > 0.040:
            continue

        # A real water boundary separates two regions, so its contrast is
        # still present when sampled farther away from the edge. A thin metal
        # groove or specular ring usually has two opposite edges and returns
        # to nearly the same intensity on both sides. This is the main guard
        # against treating bottle-bottom decoration as a water surface.
        supported_columns = columns[supported]
        supported_rows = rows[supported]
        near_offset = max(2, neighbourhood)
        far_offset = max(6, neighbourhood * 3)
        near_inner = np.clip(supported_rows - near_offset, 0, radial_count - 1)
        near_outer = np.clip(supported_rows + near_offset, 0, radial_count - 1)
        far_inner = np.clip(supported_rows - far_offset, 0, radial_count - 1)
        far_outer = np.clip(supported_rows + far_offset, 0, radial_count - 1)
        near_contrast = (
            polar[near_outer, supported_columns]
            - polar[near_inner, supported_columns]
        )
        far_contrast = (
            polar[far_outer, supported_columns]
            - polar[far_inner, supported_columns]
        )
        persistent = (
            near_contrast * far_contrast > 0
        ) & (
            np.abs(far_contrast) >= np.maximum(2.5, np.abs(near_contrast) * 0.30)
        )
        persistence = float(np.mean(persistent))
        minimum_persistence = 0.58 if coverage < 0.48 else 0.46
        if persistence < minimum_persistence:
            continue

        strength_ratio = float(np.median(strengths[supported])) / max(gradient_noise, 1e-6)
        strength_score = min(1.0, max(0.0, (strength_ratio - 2.5) / 5.0))
        scatter_score = max(0.0, 1.0 - radial_scatter / 0.032)
        # A mild outer preference follows projective geometry: a meniscus is
        # generally outside small base embossing. It is deliberately weak so
        # genuinely low water levels remain detectable.
        ratio = radius / outer_radius_px
        radius_score = min(1.0, max(0.0, (ratio - 0.22) / 0.66))
        arc_score = min(1.0, longest_arc / 0.55)
        score = (
            0.20 * coverage
            + 0.17 * arc_score
            + 0.18 * polarity
            + 0.21 * persistence
            + 0.12 * strength_score
            + 0.08 * scatter_score
            + 0.04 * radius_score
        )
        if score >= 0.60:
            candidates.append(_WaterCircleCandidate(
                radius_px=radius,
                score=score,
                coverage=coverage,
                polarity=polarity,
                scatter=radial_scatter,
                persistence=persistence,
                longest_arc=longest_arc,
                visible_mask=tuple(bool(value) for value in supported),
            ))

    # Merge adjacent rows representing the two sides of one blurred edge.
    merged: list[_WaterCircleCandidate] = []
    for candidate in sorted(candidates, key=lambda item: item.radius_px):
        if merged and candidate.radius_px - merged[-1].radius_px < outer_radius_px * 0.05:
            if candidate.score > merged[-1].score:
                merged[-1] = candidate
        else:
            merged.append(candidate)
    return merged


def detect_circles(image_bgr: np.ndarray) -> DetectedCircles:
    height, width = image_bgr.shape[:2]
    if max(height, width) > 768:
        scale = 768 / max(height, width)
        resized = cv2.resize(image_bgr, (round(width * scale), round(height * scale)), interpolation=cv2.INTER_AREA)
        circles = detect_circles(resized)
        # Keep calibration radii and debug overlays in original photo pixels.
        circles.outer_center = tuple(value / scale for value in circles.outer_center)
        circles.outer_radius_px /= scale
        if circles.inner_center is not None:
            circles.inner_center = tuple(value / scale for value in circles.inner_center)
        if circles.inner_radius_px is not None:
            circles.inner_radius_px /= scale
        return circles

    gray = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY)
    blurred = _preprocess(gray)

    outer = detect_outer_circle(blurred)
    if outer is None:
        raise ValueError("Could not detect bottle opening. Centre the rim in the guide circle.")

    outer_center, outer_r = outer
    water = _select_water_candidate(blurred, outer_center, outer_r)

    if water is not None:
        # Partial contours are useful, but must never be presented with the
        # same certainty as a directly observed circumference.
        confidence = min(0.88, 0.38 + 0.35 * water.score + 0.20 * water.coverage)
        return DetectedCircles(
            outer_center=outer_center,
            outer_radius_px=outer_r,
            inner_center=outer_center,
            inner_radius_px=water.radius_px,
            confidence=confidence,
            water_visible_fraction=water.coverage,
            water_contour_inferred=water.coverage < 0.82,
            water_visible_mask=water.visible_mask,
        )

    return DetectedCircles(
        outer_center=outer_center,
        outer_radius_px=outer_r,
        inner_center=None,
        inner_radius_px=None,
        confidence=0.5,
    )


def draw_debug_overlay(
    image_bgr: np.ndarray,
    circles: DetectedCircles,
    water_depth_cm: float | None,
    remaining_ml: float | None,
    confidence: float,
    method_used: str,
    consumed_ml: float | None = None,
) -> np.ndarray:
    out = image_bgr.copy()
    oc = circles.outer_center
    cv2.circle(out, (int(oc[0]), int(oc[1])), int(circles.outer_radius_px), (0, 255, 0), 2)
    cv2.putText(out, "bottle rim", (int(oc[0]) + 10, int(oc[1]) - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)

    if circles.inner_radius_px and circles.inner_center:
        ic = circles.inner_center
        radius = circles.inner_radius_px
        visible = circles.water_visible_mask
        if visible and circles.water_contour_inferred:
            count = len(visible)
            for index in range(count):
                angle0 = 2 * math.pi * index / count
                angle1 = 2 * math.pi * (index + 1) / count
                p0 = (int(ic[0] + radius * math.cos(angle0)), int(ic[1] + radius * math.sin(angle0)))
                p1 = (int(ic[0] + radius * math.cos(angle1)), int(ic[1] + radius * math.sin(angle1)))
                if visible[index]:
                    cv2.line(out, p0, p1, (0, 140, 255), 3, cv2.LINE_AA)
                elif index % 8 < 4:
                    cv2.line(out, p0, p1, (0, 95, 210), 2, cv2.LINE_AA)
            water_label = "water surface (inferred)"
        else:
            cv2.circle(out, (int(ic[0]), int(ic[1])), int(radius), (0, 140, 255), 2)
            water_label = "water surface"
        cv2.putText(out, water_label, (int(ic[0]) + 10, int(ic[1]) + 20), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 140, 255), 1)

    y = 28
    label = f"remaining: {remaining_ml:.0f} ml" if remaining_ml is not None else "remaining: unavailable - retake"
    cv2.putText(out, label, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (255, 255, 255), 2)
    y += 26
    cv2.putText(out, f"confidence: {confidence:.2f}", (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 2)
    y += 24
    cv2.putText(out, f"method: {method_used}", (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
    y += 24
    if water_depth_cm is not None:
        cv2.putText(out, f"water depth: {water_depth_cm:.1f} cm", (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 2)
        y += 24
    if consumed_ml is not None and consumed_ml > 0:
        cv2.putText(out, f"consumed: {consumed_ml:.0f} ml", (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (100, 220, 255), 2)

    return out
