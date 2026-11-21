"""Analytic geometry regressions; these are not real-bottle accuracy evidence."""
import math

import numpy as np
import pytest

from estimators import DepthEstimator, perspective_height
from volume_engine import ProfilePoint, scaled_volume, volume_below_height


def test_frustum_volume_matches_closed_form():
    profile = [ProfilePoint(0, 4), ProfilePoint(20, 1)]
    assert volume_below_height(profile, 20) == pytest.approx(140 * math.pi)
    # Radius at h=10 is 2.5 cm; integrate only the lower frustum.
    assert volume_below_height(profile, 10) == pytest.approx(
        math.pi * 10 * (16 + 10 + 6.25) / 3
    )


@pytest.mark.parametrize("height", [0, 2, 10, 18, 20])
def test_cylinder_perspective_round_trip(height):
    profile = [ProfilePoint(0, 3), ProfilePoint(20, 3)]
    observed = 800 * 3 / (12 + 20 - height)
    assert perspective_height(profile, 20, 12, 800, observed) == pytest.approx(height)


def test_continuum_of_heights_must_not_be_ignored():
    # h=0..10 all project to 100 px; the upper segment also intersects at h=10.
    # The shared endpoint is not a unique water level.
    profile = [ProfilePoint(0, 3), ProfilePoint(10, 2), ProfilePoint(20, 3)]
    assert perspective_height(profile, 20, 10, 1000, 100) is None


def test_distinct_nearby_roots_are_not_merged():
    # Two roots separated by 0.05 cm are distinct, not a shared segment endpoint.
    profile = [ProfilePoint(0, 2.9), ProfilePoint(9.975, 2.0025),
               ProfilePoint(10, 1.999), ProfilePoint(10.025, 1.9975),
               ProfilePoint(20, 2)]
    observed = 1000 * 2 / (30 - 10)
    assert perspective_height(profile, 20, 10, 1000, observed) is None


def manual_estimate(**kwargs):
    return DepthEstimator().estimate(
        np.zeros((768, 768, 3), dtype=np.uint8),
        [ProfilePoint(0, 3), ProfilePoint(20, 3)],
        20, 500, 6,
        manual_circles={"outer_center_x": 384, "outer_center_y": 384,
                        "outer_radius_px": 240, "inner_center_x": 384,
                        "inner_center_y": 384, "inner_radius_px": 154},
        **kwargs,
    )[0]


def test_missing_camera_geometry_does_not_guess_volume():
    estimate = manual_estimate()
    assert estimate.remaining_volume_ml is None


def test_out_of_range_inferred_distance_does_not_fall_back():
    estimate = manual_estimate(camera_focal_length_px=100)
    assert estimate.remaining_volume_ml is None


def test_manual_circles_do_not_bypass_off_axis_geometry():
    estimate, _ = DepthEstimator().estimate(
        np.zeros((768, 768, 3), dtype=np.uint8),
        [ProfilePoint(0, 3), ProfilePoint(20, 3)], 20, 500, 6,
        camera_focal_length_px=1200,
        manual_circles={"outer_center_x": 384, "outer_center_y": 384,
                        "outer_radius_px": 240, "inner_center_x": 434,
                        "inner_center_y": 384, "inner_radius_px": 154},
    )
    assert estimate.remaining_volume_ml is None
