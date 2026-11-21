"""Reproduce analytic diagnostics: python accuracy_experiment.py (JSON stdout)."""
import json
from dataclasses import asdict
from top_view_geometry import RingObservation, reconstruct_ring_bounds, water_depth_bounds
from volume_engine import ProfilePoint, scaled_volume, volume_below_height


def ring(radius, distance, travel, pixel_error, pose_error):
    return reconstruct_ring_bounds([
        RingObservation(z, 1200 * radius / (distance + z), 1200,
                        pixel_error, pose_error, 0.002)
        for z in (0, travel / 2, travel)
    ])


def main():
    trials = []
    for travel in (0, 1, 3, 6, 10):
        rim = ring(2, 15, travel, 1, 0.1)
        surface = ring(3, 25, travel, 1, 0.1)
        trials.append({
            "camera_travel_cm": travel,
            "rim": asdict(rim) if rim else None,
            "surface": asdict(surface) if surface else None,
            "water_depth_cm": water_depth_bounds(rim, surface) if rim and surface else None,
        })
    # Same total capacity, height, opening and upper half, different lower
    # interior shape: even a known h=5 does not establish V(h).
    a = [ProfilePoint(h, r) for h, r in [(0, 2), (2, 4), (8, 2), (10, 2), (20, 2)]]
    b = [ProfilePoint(h, r) for h, r in [(0, 2), (2, 2), (8, 4), (10, 2), (20, 2)]]
    print(json.dumps({
        "scope": "synthetic geometry only; supplied errors are assumptions, not device calibration",
        "assumptions": {"focal_px": 1200, "focal_relative_error": 0.002,
                        "radius_error_px": 1, "camera_offset_error_cm": 0.1},
        "multiframe_trials": trials,
        "capacity_does_not_identify_interior": {
            "model_a_total_cm3": volume_below_height(a, 20),
            "model_b_total_cm3": volume_below_height(b, 20),
            "label_capacity_ml": 500, "known_height_cm": 5,
            "model_a_remaining_ml": scaled_volume(a, 5, 500),
            "model_b_remaining_ml": scaled_volume(b, 5, 500),
        },
    }, indent=2))


if __name__ == "__main__":
    main()
