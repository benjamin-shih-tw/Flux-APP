import numpy as np
import pytest

import circle_detector


def test_large_photo_detection_is_bounded_and_preserves_pixel_coordinates(monkeypatch):
    shapes = []

    def outer(gray):
        shapes.append(gray.shape)
        return ((gray.shape[1] / 2, gray.shape[0] / 2), gray.shape[0] / 4)

    monkeypatch.setattr(circle_detector, 'detect_outer_circle', outer)
    monkeypatch.setattr(circle_detector, 'detect_inner_circle', lambda gray, center, radius: (center, radius / 2))
    result = circle_detector.detect_circles(np.zeros((3024, 4032, 3), dtype=np.uint8))
    assert max(shapes[0]) <= 768
    assert result.outer_center == pytest.approx((2016, 1512))
    assert result.outer_radius_px == pytest.approx(756)
    assert result.inner_center == pytest.approx((2016, 1512))
    assert result.inner_radius_px == pytest.approx(378)
