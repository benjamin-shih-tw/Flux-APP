import numpy as np
import pytest

import circle_detector
from estimators import perspective_height
from volume_engine import ProfilePoint


def test_large_photo_detection_is_bounded_and_preserves_pixel_coordinates(monkeypatch):
    shapes = []

    def outer(gray):
        shapes.append(gray.shape)
        return ((gray.shape[1] / 2, gray.shape[0] / 2), gray.shape[0] / 4)

    monkeypatch.setattr(circle_detector, 'detect_outer_circle', outer)
    monkeypatch.setattr(
        circle_detector,
        '_select_water_candidate',
        lambda gray, center, radius: circle_detector._WaterCircleCandidate(
            radius_px=radius / 2,
            score=0.8,
            coverage=0.75,
            polarity=0.9,
            scatter=0.01,
            persistence=0.9,
            longest_arc=0.6,
            visible_mask=tuple([True] * 180 + [False] * 60),
        ),
    )
    result = circle_detector.detect_circles(np.zeros((3024, 4032, 3), dtype=np.uint8))
    assert max(shapes[0]) <= 768
    assert result.outer_center == pytest.approx((2016, 1512))
    assert result.outer_radius_px == pytest.approx(756)
    assert result.inner_center == pytest.approx((2016, 1512))
    assert result.inner_radius_px == pytest.approx(378)
    assert result.water_contour_inferred is True
    assert result.water_visible_fraction == pytest.approx(0.75)


def _blurred_ring_scene(*, water_radius=None, offset=(0, 0), partial=False, arc=(20, 190)):
    size = 640
    center = (size // 2, size // 2)
    image = np.full((size, size), 225, dtype=np.uint8)
    cv2 = pytest.importorskip("cv2")
    cv2.circle(image, center, 220, 35, -1, lineType=cv2.LINE_AA)
    cv2.circle(image, center, 220, 245, 7, lineType=cv2.LINE_AA)
    if water_radius is not None:
        water_center = (center[0] + offset[0], center[1] + offset[1])
        if partial:
            cv2.ellipse(
                image, water_center, (water_radius, water_radius), 0,
                arc[0], arc[1], 145, 7, lineType=cv2.LINE_AA,
            )
        else:
            cv2.circle(image, water_center, water_radius, 112, -1, lineType=cv2.LINE_AA)
    return circle_detector._preprocess(image), center, 220


def test_complete_concentric_meniscus_is_detected():
    blurred, center, outer_radius = _blurred_ring_scene(water_radius=154)
    inner = circle_detector.detect_inner_circle(blurred, center, outer_radius)
    assert inner is not None
    assert inner[0] == pytest.approx(center)
    assert inner[1] == pytest.approx(154, abs=5)


def test_off_axis_round_reflection_is_not_called_water():
    blurred, center, outer_radius = _blurred_ring_scene(
        water_radius=145, offset=(34, -26),
    )
    assert circle_detector.detect_inner_circle(blurred, center, outer_radius) is None


def test_partial_specular_arc_is_not_called_water():
    blurred, center, outer_radius = _blurred_ring_scene(
        water_radius=150, partial=True, arc=(20, 75),
    )
    assert circle_detector.detect_inner_circle(blurred, center, outer_radius) is None


def test_long_visible_meniscus_arc_completes_occluded_circle():
    cv2 = pytest.importorskip("cv2")
    size = 640
    center = (size // 2, size // 2)
    image = np.full((size, size), 225, dtype=np.uint8)
    cv2.circle(image, center, 220, 35, -1, lineType=cv2.LINE_AA)
    cv2.circle(image, center, 220, 245, 7, lineType=cv2.LINE_AA)

    # The water region reaches the bottle wall, but only its far-side boundary
    # is visible. The detector should infer the hidden remainder of the circle
    # from the long, coherent region transition.
    yy, xx = np.indices(image.shape)
    radius = np.hypot(xx - center[0], yy - center[1])
    angle = (np.degrees(np.arctan2(yy - center[1], xx - center[0])) + 360) % 360
    image[radius <= 154] = 118
    hidden_side = (angle > 205) | (angle < 35)
    image[hidden_side & (radius > 154) & (radius < 195)] = 118
    blurred = circle_detector._preprocess(image)
    inner = circle_detector.detect_inner_circle(blurred, center, 220)
    assert inner is not None
    assert inner[0] == pytest.approx(center)
    assert inner[1] == pytest.approx(154, abs=6)


def test_single_small_base_ring_is_not_called_low_water():
    blurred, center, outer_radius = _blurred_ring_scene(water_radius=68)
    assert circle_detector.detect_inner_circle(blurred, center, outer_radius) is None


def test_multiple_equally_strong_base_rings_are_ambiguous():
    blurred, center, outer_radius = _blurred_ring_scene()
    cv2 = pytest.importorskip("cv2")
    for radius, level in [(72, 115), (108, 45), (148, 115)]:
        cv2.circle(blurred, center, radius, level, 6, lineType=cv2.LINE_AA)
    blurred = cv2.GaussianBlur(blurred, (5, 5), 1.0)
    assert circle_detector.detect_inner_circle(blurred, center, outer_radius) is None


def test_large_bottle_base_step_with_inner_disc_is_ambiguous():
    cv2 = pytest.importorskip("cv2")
    size = 640
    center = (size // 2, size // 2)
    image = np.full((size, size), 225, dtype=np.uint8)
    cv2.circle(image, center, 220, 32, -1, lineType=cv2.LINE_AA)
    cv2.circle(image, center, 220, 245, 7, lineType=cv2.LINE_AA)
    # Strong wall-to-base transition plus a bright embossed bottom disc. This
    # matches the nested structure in the supplied metal-bottle photographs;
    # neither ring alone proves the presence of a water surface.
    cv2.circle(image, center, 150, 82, -1, lineType=cv2.LINE_AA)
    cv2.circle(image, center, 67, 180, -1, lineType=cv2.LINE_AA)
    blurred = circle_detector._preprocess(image)
    assert circle_detector.detect_inner_circle(blurred, center, 220) is None


def test_single_perfect_central_base_plate_is_not_water():
    cv2 = pytest.importorskip("cv2")
    size = 640
    center = (size // 2, size // 2)
    image = np.full((size, size), 225, dtype=np.uint8)
    cv2.circle(image, center, 220, 35, -1, lineType=cv2.LINE_AA)
    cv2.circle(image, center, 220, 245, 7, lineType=cv2.LINE_AA)
    cv2.circle(image, center, 120, 175, -1, lineType=cv2.LINE_AA)
    blurred = circle_detector._preprocess(image)
    assert circle_detector.detect_inner_circle(blurred, center, 220) is None


def test_perspective_height_ignores_impossible_cap_taper_branch():
    profile = [
        ProfilePoint(0.0, 3.7),
        ProfilePoint(20.0, 3.7),
        ProfilePoint(26.0, 2.65),
        ProfilePoint(27.0, 2.9),
        ProfilePoint(29.1, 2.05),
        ProfilePoint(29.7, 0.65),
    ]
    height = perspective_height(
        profile,
        bottle_height_cm=29.7,
        distance_cm=7.5,
        focal_length_px=3_200,
        observed_radius_px=820,
        minimum_surface_radius_cm=2.85 * 0.85,
    )
    assert height is not None
    assert 25.0 < height < 28.0
