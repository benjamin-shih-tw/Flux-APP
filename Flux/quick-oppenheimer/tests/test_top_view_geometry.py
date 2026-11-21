"""Synthetic observability checks, not physical accuracy claims."""
import math
import pytest
from top_view_geometry import RingObservation, reconstruct_ring_bounds, water_depth_bounds


def observations(radius=3, distance=15, offsets=(0, 3, 6), pixel_error=0, pose_error=0):
    return [RingObservation(z, 1200 * radius / (distance + z), 1200,
                            pixel_error, pose_error) for z in offsets]


def test_metric_motion_recovers_radius_without_a_ruler():
    result = reconstruct_ring_bounds(observations())
    assert result is not None
    assert result.radius_cm == pytest.approx((3, 3))
    assert result.reference_distance_cm == pytest.approx((15, 15))


def test_stationary_camera_cannot_determine_scale():
    assert reconstruct_ring_bounds(observations(offsets=(0, 0, 0))) is None


def test_multiple_views_reject_inconsistent_boundary():
    frames = observations()
    frames.append(RingObservation(3, 500, 1200, 0, 0))
    assert reconstruct_ring_bounds(frames) is None


def test_declared_pixel_and_pose_errors_contain_true_geometry():
    frames = observations(pixel_error=1, pose_error=0.1)
    result = reconstruct_ring_bounds(frames)
    assert result is not None
    assert result.radius_cm[0] < 3 < result.radius_cm[1]
    assert result.reference_distance_cm[0] < 15 < result.reference_distance_cm[1]


def test_less_camera_motion_widens_uncertainty():
    short = reconstruct_ring_bounds(observations(offsets=(0, 0.5, 1), pixel_error=1))
    long = reconstruct_ring_bounds(observations(offsets=(0, 3, 6), pixel_error=1))
    assert short is not None and long is not None
    assert short.reference_distance_cm[1] - short.reference_distance_cm[0] > (
        long.reference_distance_cm[1] - long.reference_distance_cm[0]
    )


def test_two_rings_recover_depth_but_not_bottle_volume():
    rim = reconstruct_ring_bounds(observations(radius=2, distance=15))
    water = reconstruct_ring_bounds(observations(radius=3, distance=25))
    assert rim is not None and water is not None
    assert water_depth_bounds(rim, water) == pytest.approx((10, 10))


@pytest.mark.parametrize("radius,focal,error", [(math.nan, 1200, 0), (10, 0, 0),
                                               (10, 1200, -1), (10, 1200, 10)])
def test_invalid_input_is_rejected(radius, focal, error):
    frames = observations()
    frames[0] = RingObservation(0, radius, focal, error, 0)
    assert reconstruct_ring_bounds(frames) is None
