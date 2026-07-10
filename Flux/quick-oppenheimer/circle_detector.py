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
    """Find water surface circle inside the bottle opening."""
    h, w = blurred.shape[:2]
    cx, cy = outer_center

    mask = np.zeros((h, w), dtype=np.uint8)
    cv2.circle(mask, (int(cx), int(cy)), int(outer_radius_px * 0.95), 255, -1)
    roi = cv2.bitwise_and(blurred, blurred, mask=mask)

    # Method 1: Hough on masked ROI
    inner = _hough_inner_circle(roi, outer_center, outer_radius_px)
    if inner is not None:
        return inner

    # Method 2: radial gradient profile
    inner_r = _detect_inner_via_radial_profile(roi, outer_center, outer_radius_px)
    if inner_r is not None:
        return (outer_center, inner_r)

    # Method 3: find circular contours inside outer radius
    return _inner_via_contours(roi, outer_center, outer_radius_px)


def _hough_inner_circle(
    roi: np.ndarray,
    outer_center: tuple[float, float],
    outer_radius_px: float,
) -> tuple[tuple[float, float], float] | None:
    cx, cy = outer_center
    min_r = max(8, int(outer_radius_px * 0.12))
    max_r = int(outer_radius_px * 0.90)

    circles = cv2.HoughCircles(
        roi,
        cv2.HOUGH_GRADIENT,
        dp=1.2,
        minDist=int(outer_radius_px * 0.3),
        param1=80,
        param2=16,
        minRadius=min_r,
        maxRadius=max_r,
    )

    if circles is None:
        return None

    candidates: list[tuple[tuple[float, float], float, float]] = []
    for c in circles[0]:
        icx, icy, ir = float(c[0]), float(c[1]), float(c[2])
        if ir >= outer_radius_px * 0.96 or ir < outer_radius_px * 0.12:
            continue
        dist = math.hypot(icx - cx, icy - cy)
        if dist > outer_radius_px * 0.35:
            continue
        candidates.append(((icx, icy), ir, ir))

    return _pick_innermost_circle(candidates, outer_radius_px)


def _pick_innermost_circle(
    candidates: list[tuple[tuple[float, float], float, float]],
    outer_radius_px: float,
) -> tuple[tuple[float, float], float] | None:
    """Prefer the smallest valid inner circle (water meniscus, not inner wall)."""
    if not candidates:
        return None
    # Sort by radius ascending — water surface is the innermost distinct edge
    candidates.sort(key=lambda c: c[1])
    for center, radius, _score in candidates:
        if radius < outer_radius_px * 0.92:
            return (center, radius)
    return (candidates[0][0], candidates[0][1])


def _inner_via_contours(
    roi: np.ndarray,
    outer_center: tuple[float, float],
    outer_radius_px: float,
) -> tuple[tuple[float, float], float] | None:
    edges = cv2.Canny(roi, 25, 80)
    contours, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE)
    cx, cy = outer_center
    candidates: list[tuple[tuple[float, float], float, float]] = []

    for cnt in contours:
        if len(cnt) < 8:
            continue
        (icx, icy), ir = cv2.minEnclosingCircle(cnt)
        if ir >= outer_radius_px * 0.95 or ir < outer_radius_px * 0.12:
            continue
        dist = math.hypot(icx - cx, icy - cy)
        if dist > outer_radius_px * 0.35:
            continue
        area = cv2.contourArea(cnt)
        perimeter = cv2.arcLength(cnt, True)
        circularity = 4 * math.pi * area / (perimeter * perimeter + 1e-6)
        if circularity < 0.35:
            continue
        candidates.append(((float(icx), float(icy)), float(ir), circularity * ir))

    return _pick_innermost_circle(candidates, outer_radius_px)


def _detect_inner_via_radial_profile(
    roi: np.ndarray,
    center: tuple[float, float],
    outer_r: float,
) -> float | None:
    """Scan outward from center; water meniscus often appears as inner brightness transition."""
    cx, cy = center
    h, w = roi.shape[:2]

    angles = np.linspace(0, 2 * math.pi, 36, endpoint=False)
    radii_samples: list[list[float]] = []

    for angle in angles:
        samples = []
        for r in np.linspace(outer_r * 0.05, outer_r * 0.9, 40):
            x = int(cx + r * math.cos(angle))
            y = int(cy + r * math.sin(angle))
            if 0 <= x < w and 0 <= y < h:
                samples.append(float(roi[y, x]))
        if len(samples) >= 10:
            radii_samples.append(samples)

    if not radii_samples:
        return None

    mean_profile = np.mean(radii_samples, axis=0)
    r_axis = np.linspace(outer_r * 0.05, outer_r * 0.92, len(mean_profile))

    grad = np.abs(np.gradient(mean_profile))
    if len(grad) < 5 or grad.max() < 2.0:
        return None

    # Find all local maxima in gradient (edges)
    peaks: list[tuple[float, float]] = []
    for i in range(2, len(grad) - 2):
        if grad[i] > grad[i - 1] and grad[i] > grad[i + 1] and grad[i] > grad.max() * 0.25:
            peaks.append((r_axis[i], grad[i]))

    if not peaks:
        peak_idx = int(np.argmax(grad))
        return float(r_axis[peak_idx])

    # Prefer innermost significant peak (water surface); skip outermost (bottle wall)
    peaks.sort(key=lambda p: p[0])
    if len(peaks) >= 2:
        return float(peaks[-2][0])  # second-outermost = water meniscus
    return float(peaks[0][0])


def detect_circles(image_bgr: np.ndarray) -> DetectedCircles:
    gray = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY)
    blurred = _preprocess(gray)

    outer = detect_outer_circle(blurred)
    if outer is None:
        raise ValueError("Could not detect bottle opening. Centre the rim in the guide circle.")

    outer_center, outer_r = outer
    inner = detect_inner_circle(blurred, outer_center, outer_r)

    confidence = 0.85 if inner else 0.5

    if inner:
        inner_center, inner_r = inner
        return DetectedCircles(
            outer_center=outer_center,
            outer_radius_px=outer_r,
            inner_center=inner_center,
            inner_radius_px=inner_r,
            confidence=confidence,
        )

    return DetectedCircles(
        outer_center=outer_center,
        outer_radius_px=outer_r,
        inner_center=None,
        inner_radius_px=None,
        confidence=confidence,
    )


def draw_debug_overlay(
    image_bgr: np.ndarray,
    circles: DetectedCircles,
    water_height_cm: float | None,
    remaining_ml: float,
    consumed_ml: float | None,
) -> np.ndarray:
    out = image_bgr.copy()
    oc = circles.outer_center
    cv2.circle(out, (int(oc[0]), int(oc[1])), int(circles.outer_radius_px), (0, 255, 0), 2)
    cv2.putText(out, "bottle rim", (int(oc[0]) + 10, int(oc[1]) - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)

    if circles.inner_radius_px and circles.inner_center:
        ic = circles.inner_center
        cv2.circle(out, (int(ic[0]), int(ic[1])), int(circles.inner_radius_px), (255, 120, 0), 2)
        cv2.putText(out, "water surface", (int(ic[0]) + 10, int(ic[1]) + 20), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 120, 0), 1)

    y = 28
    cv2.putText(out, f"remaining: {remaining_ml:.0f} ml", (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (255, 255, 255), 2)
    y += 26
    if water_height_cm is not None:
        cv2.putText(out, f"water height: {water_height_cm:.1f} cm", (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 2)
        y += 24
    if consumed_ml is not None and consumed_ml > 0:
        cv2.putText(out, f"consumed: {consumed_ml:.0f} ml", (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (100, 220, 255), 2)

    return out
