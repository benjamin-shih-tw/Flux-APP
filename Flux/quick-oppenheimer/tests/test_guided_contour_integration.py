import numpy as np

import estimators
from volume_engine import build_cylinder_profile
from water_contour_model import RefinedWaterCandidate


def candidate(radius, score=0.82, center=(202.0, 198.0), likely_base=False, rmse_ratio=0.002):
    return RefinedWaterCandidate(
        center=center, radius_px=radius, score=score, coverage=0.7,
        longest_arc=0.4, normal_alignment=0.9, region_step=0.7,
        meniscus_strength=0.5, radial_rmse_ratio=rmse_ratio,
        likely_base=likely_base, visible_mask=(True,) * 240,
    )


def estimate(candidates, monkeypatch):
    def old_detector(*args, **kwargs):
        raise AssertionError("Guided scans must use the selected contour model")

    monkeypatch.setattr(estimators, "detect_circles", old_detector)
    result, _ = estimators.DepthEstimator().estimate(
        np.zeros((500, 500, 3), dtype=np.uint8),
        build_cylinder_profile(20, 3.4), 20, 500, 6.8,
        imu_alignment_score=0.92, camera_focal_length_px=800,
        guided_rim=((200, 200), 200), water_candidates=candidates,
    )
    return result


def test_guided_measurement_uses_same_contour_as_review(monkeypatch):
    result = estimate([candidate(100)], monkeypatch)
    assert result.inner_center == (202, 198)
    assert result.inner_radius_px == 100
    assert result.remaining_volume_ml is not None


def test_competing_contours_with_different_volumes_require_review(monkeypatch):
    result = estimate([candidate(100), candidate(120, 0.81)], monkeypatch)
    assert result.remaining_volume_ml is None
    assert any("Competing water contours" in note for note in result.debug_notes)


def test_strong_plausible_base_ring_still_requires_review(monkeypatch):
    result = estimate([candidate(120), candidate(100, 0.9, likely_base=True)], monkeypatch)
    assert result.remaining_volume_ml is None


def test_uncertain_edge_does_not_report_precise_volume(monkeypatch):
    result = estimate([candidate(100, rmse_ratio=0.025)], monkeypatch)
    assert result.remaining_volume_ml is None
    assert any("sensitive to the detected edge" in note for note in result.debug_notes)
