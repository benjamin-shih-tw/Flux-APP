"""Bottle profile integration and water volume calculation."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from typing import Iterable


@dataclass
class ProfilePoint:
    height_cm: float
    radius_cm: float


def parse_profile_json(profile_json: str) -> list[ProfilePoint]:
    """Parse iOS-sent JSON: {"heights_cm": [...], "radii_cm": [...]}."""
    data = json.loads(profile_json)
    heights = data.get("heights_cm") or data.get("profile_height_cm") or []
    radii = data.get("radii_cm") or data.get("profile_radius_cm") or []
    if len(heights) < 2 or len(heights) != len(radii):
        raise ValueError("profile must contain matching heights_cm and radii_cm arrays (>= 2 points)")
    points = sorted(
        [ProfilePoint(float(h), max(0.001, float(r))) for h, r in zip(heights, radii)],
        key=lambda p: p.height_cm,
    )
    return points


def build_cylinder_profile(height_cm: float, opening_radius_cm: float, steps: int = 20) -> list[ProfilePoint]:
    r = max(0.001, opening_radius_cm)
    h = max(0.1, height_cm)
    return [ProfilePoint(height_cm=h * i / steps, radius_cm=r) for i in range(steps + 1)]


def _trapezoid_slice(r0: float, r1: float, dh: float) -> float:
    a0 = math.pi * r0 * r0
    a1 = math.pi * r1 * r1
    return (a0 + a1) / 2.0 * dh


def _interpolate_radius(height: float, profile: list[ProfilePoint]) -> float:
    for i in range(len(profile) - 1):
        h0, r0 = profile[i].height_cm, profile[i].radius_cm
        h1, r1 = profile[i + 1].height_cm, profile[i + 1].radius_cm
        if h0 <= height <= h1:
            if abs(h1 - h0) < 1e-9:
                return r0
            t = (height - h0) / (h1 - h0)
            return r0 + t * (r1 - r0)
    return profile[-1].radius_cm


def radius_at_height(profile: list[ProfilePoint], height_cm: float) -> float:
    """Return the interpolated bottle radius at a given height."""
    if len(profile) < 2:
        return 0.0
    clamped_h = min(max(height_cm, profile[0].height_cm), profile[-1].height_cm)
    return _interpolate_radius(clamped_h, profile)


def volume_below_height(profile: list[ProfilePoint], water_height_cm: float) -> float:
    """Volume in ml (cm³) below water_height_cm."""
    if len(profile) < 2 or water_height_cm <= 0:
        return 0.0

    clamped_h = min(water_height_cm, profile[-1].height_cm)
    volume = 0.0

    for i in range(len(profile) - 1):
        h0, r0 = profile[i].height_cm, profile[i].radius_cm
        h1, r1 = profile[i + 1].height_cm, profile[i + 1].radius_cm

        if h1 > clamped_h:
            r_at = _interpolate_radius(clamped_h, profile)
            volume += _trapezoid_slice(r0, r_at, clamped_h - h0)
            return volume

        volume += _trapezoid_slice(r0, r1, h1 - h0)

    return volume


def height_from_water_radius(profile: list[ProfilePoint], water_radius_cm: float) -> float | None:
    """Find height h where profile radius ≈ water_radius_cm."""
    if len(profile) < 2:
        return None

    best_h: float | None = None
    best_diff = float("inf")

    for i in range(len(profile) - 1):
        r0, h0 = profile[i].radius_cm, profile[i].height_cm
        r1, h1 = profile[i + 1].radius_cm, profile[i + 1].height_cm
        lo, hi = min(r0, r1), max(r0, r1)

        if water_radius_cm >= lo - 0.08 and water_radius_cm <= hi + 0.08:
            if abs(r1 - r0) < 1e-6:
                return (h0 + h1) / 2.0
            t = (water_radius_cm - r0) / (r1 - r0)
            return h0 + t * (h1 - h0)

        for pt in (profile[i], profile[i + 1]):
            diff = abs(pt.radius_cm - water_radius_cm)
            if diff < best_diff:
                best_diff = diff
                best_h = pt.height_cm

    return best_h


def total_volume_ml(profile: list[ProfilePoint]) -> float:
    if not profile:
        return 0.0
    return volume_below_height(profile, profile[-1].height_cm)
