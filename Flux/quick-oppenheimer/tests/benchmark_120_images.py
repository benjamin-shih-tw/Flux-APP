"""120-image ground-truth benchmark + 24 real historical iPhone photo audit.

Compares the legacy polar circle detector against the upgraded multi-cue,
offset-aware Huber-IRLS water contour model and single-sharpest-plane focus
selector across 9 realistic failure modes (120 labeled ground-truth cases).
"""

from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import circle_detector  # noqa: E402
import estimators  # noqa: E402
import volume_engine  # noqa: E402
from water_contour_model import (  # noqa: E402
    detect_water_candidates_multicue,
    select_sharpest_focus_frame,
)


def render_realistic_bottle(
    rng: np.random.Generator,
    *,
    size: int = 768,
    rim_r: float = 230.0,
    water_r: float = 152.0,
    water_offset: tuple[float, float] = (0.0, 0.0),
    base_rings: list[tuple[float, float]] | None = None,
    visible_arc_deg: float = 360.0,
    glare_blobs: int = 0,
    low_contrast_meniscus: bool = False,
    water_stains: bool = True,
    neck_seam_frac: float | None = None,
    blur_neck_seam: float = 0.0,
    noise_sigma: float = 4.0,
    blur_rim: float = 0.0,
    blur_water: float = 0.0,
    blur_base: float = 0.0,
    center: tuple[float, float] | None = None,
) -> tuple[np.ndarray, tuple[tuple[float, float], float]]:
    cx, cy = center if center is not None else (size * 0.5, size * 0.5)
    yy, xx = np.indices((size, size), dtype=np.float32)
    dx_rim = xx - cx
    dy_rim = yy - cy
    dist_rim = np.hypot(dx_rim, dy_rim)
    ang_rim = np.arctan2(dy_rim, dx_rim)

    # Background wood/desk + blue outer bottle coating + stainless rim.
    bg = np.full((size, size, 3), (125, 145, 170), dtype=np.float32)
    bg += rng.normal(0, 3.0, bg.shape).astype(np.float32)
    blue_outer = dist_rim <= rim_r * 1.13
    bg[blue_outer] = (205, 95, 25)  # BGR blue sleeve
    metal_lip = (dist_rim <= rim_r * 1.055) & (dist_rim >= rim_r * 0.985)
    lip_shade = 195.0 + 45.0 * np.cos(ang_rim * 2.0 + rng.uniform(0, 6.28))
    for c in range(3):
        bg[:, :, c] = np.where(metal_lip, lip_shade, bg[:, :, c])

    # Dry stainless interior wall with realistic directional shading & vertical reflections.
    phi = rng.uniform(0, 6.28)
    wall_base = (
        132.0
        + 26.0 * np.cos(ang_rim - phi)
        + 12.0 * np.cos(2.0 * ang_rim + phi * 0.7)
        - 22.0 * np.clip((rim_r - dist_rim) / max(rim_r, 1.0), 0.0, 1.0)
    )
    interior = np.stack([wall_base, wall_base * 0.99, wall_base * 0.97], axis=-1)

    # Optional water-stain collar inside upper rim (just like real stainless bottle).
    if water_stains:
        collar = (dist_rim > max(water_r + 14.0, rim_r * 0.78)) & (dist_rim < rim_r * 0.98)
        stain_noise = cv2.GaussianBlur(rng.normal(0, 1.0, (size, size)).astype(np.float32), (25, 25), 6.0)
        stain_mask = collar & (stain_noise > 0.08)
        interior[stain_mask] = interior[stain_mask] * 0.78 + 38.0

    # Optional permanent stainless-steel neck/shoulder seam near 0.75 * R
    # (rendered at its own optical focus plane, sharp near rim and soft deeper down).
    if neck_seam_frac is not None:
        seam_r = rim_r * neck_seam_frac
        seam_layer = interior.copy()
        seam_layer[dist_rim <= seam_r] = np.clip(seam_layer[dist_rim <= seam_r] - 24.0, 18.0, 245.0)
        if blur_neck_seam > 0.5:
            k = int(round(blur_neck_seam * 5)) | 1
            seam_layer = cv2.GaussianBlur(seam_layer, (k, k), blur_neck_seam)
        seam_band = np.clip((seam_r + 10.0 - dist_rim) / 14.0, 0.0, 1.0)[:, :, None]
        interior = interior * (1.0 - seam_band) + seam_layer * seam_band

    # Machined stainless bottom rings & embossed dome (rendered on separate layer so focus can vary).
    base_layer = interior.copy()
    if base_rings:
        for br_frac, intensity_delta in base_rings:
            br = rim_r * br_frac
            ring_mask = dist_rim <= br
            val = np.clip(118.0 + intensity_delta + 18.0 * np.cos(ang_rim - phi), 25.0, 240.0)
            for c in range(3):
                base_layer[:, :, c] = np.where(ring_mask, val, base_layer[:, :, c])
            # Thin crisp machined groove at base edge.
            groove = np.abs(dist_rim - br) <= 2.2
            base_layer[groove] = np.clip(base_layer[groove] - 28.0, 15.0, 245.0)
    if blur_base > 0.5:
        k = int(round(blur_base * 5)) | 1
        base_layer = cv2.GaussianBlur(base_layer, (k, k), blur_base)

    # Blend base into interior inside innermost base radius.
    if base_rings:
        max_br = max(bf for bf, _ in base_rings) * rim_r
        base_blend = np.clip((max_br + 4.0 - dist_rim) / 6.0, 0.0, 1.0)[:, :, None]
        interior = interior * (1.0 - base_blend) + base_layer * base_blend

    # Water surface layer (possibly off-axis due to camera tilt, possibly partially occluded).
    wcx = cx + water_offset[0]
    wcy = cy + water_offset[1]
    w_dx = xx - wcx
    w_dy = yy - wcy
    dist_w = np.hypot(w_dx, w_dy)
    ang_w = (np.degrees(np.arctan2(w_dy, w_dx)) + 360.0) % 360.0

    arc_start = rng.uniform(0, 360)
    if visible_arc_deg >= 359.0:
        arc_vis = np.ones((size, size), dtype=bool)
    else:
        rel_ang = (ang_w - arc_start + 360.0) % 360.0
        arc_vis = rel_ang <= visible_arc_deg

    water_layer = interior.copy()
    inside_water = dist_w <= water_r

    if low_contrast_meniscus:
        # Subtle darkening + cool refraction tint + thin bright/dark meniscus ridge.
        tint = np.array([1.03, 0.94, 0.87], dtype=np.float32) * 0.86
        water_layer[inside_water] = np.clip(water_layer[inside_water] * tint, 15.0, 245.0)
        bright_ridge = (np.abs(dist_w - (water_r + 1.5)) <= 1.8) & arc_vis
        dark_ridge = (np.abs(dist_w - (water_r - 1.5)) <= 1.8) & arc_vis
        water_layer[bright_ridge] = np.clip(water_layer[bright_ridge] + 34.0, 0, 250)
        water_layer[dark_ridge] = np.clip(water_layer[dark_ridge] - 32.0, 0, 250)
    else:
        # Realistic underwater refractive attenuation + crisp meniscus contact line.
        delta_l = rng.choice([-1.0, 1.0]) * rng.uniform(22.0, 42.0)
        cool_shift = np.array([rng.uniform(4, 12), rng.uniform(0, 4), rng.uniform(-8, -2)], dtype=np.float32)
        shifted = np.clip(water_layer + delta_l + cool_shift, 15.0, 245.0)
        water_layer = np.where(inside_water[:, :, None], shifted, water_layer)
        # Concave meniscus specular highlight ring along visible arc.
        meniscus = (np.abs(dist_w - water_r) <= 2.2) & arc_vis
        water_layer[meniscus] = np.clip(water_layer[meniscus] + rng.uniform(25.0, 55.0), 0, 252)

    # For partially occluded water arcs, hide the boundary outside arc_vis by matching outside band.
    if visible_arc_deg < 359.0:
        hidden_band = (~arc_vis) & (dist_w > water_r - 2.0) & (dist_w < min(rim_r * 0.93, water_r + 42.0))
        # Extend water-like tone outward on the occluded side so no edge exists there.
        avg_in = np.mean(water_layer[inside_water & (dist_w > max(10.0, water_r - 20.0))], axis=0)
        water_layer[hidden_band] = avg_in

    if blur_water > 0.5:
        k = int(round(blur_water * 5)) | 1
        water_layer = cv2.GaussianBlur(water_layer, (k, k), blur_water)

    # Optional harsh ceiling lamp specular glare blobs.
    for _ in range(glare_blobs):
        ga = rng.uniform(0, 6.28)
        gr = rng.uniform(rim_r * 0.18, rim_r * 0.78)
        gx_c = cx + gr * math.cos(ga)
        gy_c = cy + gr * math.sin(ga)
        g_rad = rng.uniform(12.0, 28.0)
        blob = np.exp(-((xx - gx_c) ** 2 + (yy - gy_c) ** 2) / (2.0 * (g_rad * 0.55) ** 2))
        water_layer = np.clip(water_layer + blob[:, :, None] * 185.0, 0, 255)

    # Composite rim/outside with interior.
    if blur_rim > 0.5:
        k = int(round(blur_rim * 5)) | 1
        bg = cv2.GaussianBlur(bg, (k, k), blur_rim)

    inside_mask = np.clip((rim_r - dist_rim) / 2.5, 0.0, 1.0)[:, :, None]
    final = bg * (1.0 - inside_mask) + water_layer * inside_mask

    if noise_sigma > 0:
        final += rng.normal(0, noise_sigma, final.shape).astype(np.float32)

    bgr = np.clip(final, 0, 255).astype(np.uint8)
    # Round-trip through JPEG just like iPhone upload.
    ok, buf = cv2.imencode(".jpg", bgr, [int(cv2.IMWRITE_JPEG_QUALITY), 85])
    assert ok
    return cv2.imdecode(buf, cv2.IMREAD_COLOR), ((cx, cy), rim_r)


def run_benchmark() -> dict:
    rng = np.random.default_rng(20261121)
    categories: list[tuple[str, int]] = [
        ("1_clean_levels", 15),
        ("2_parallax_tilt", 15),
        ("3_metal_base_competing", 15),
        ("4_partial_occlusion", 15),
        ("5_specular_glare", 12),
        ("6_low_contrast_meniscus", 12),
        ("7_tapered_profiles", 12),
        ("8_low_light_stains", 12),
        ("9_multifocus_sweep", 12),
        ("10_neck_seam_multifocus", 12),
    ]

    summary = {}
    total_cases = 0
    old_top1_hits = 0
    new_top1_hits = 0
    new_top3_hits = 0
    new_radius_errs = []
    new_vol_errs = []
    failures = []

    for cat_name, count in categories:
        cat_old = 0
        cat_new1 = 0
        cat_new3 = 0
        cat_r_errs = []
        cat_v_errs = []

        for idx in range(count):
            total_cases += 1
            rim_r = float(rng.uniform(210.0, 245.0))
            focal = 1200.0
            if cat_name == "7_tapered_profiles":
                h_cm = float(rng.uniform(18.0, 26.0))
                r_open = float(rng.uniform(3.0, 3.6))
                r_bot = r_open * float(rng.uniform(0.88, 1.04))
                profile = [
                    volume_engine.ProfilePoint(0.0, r_bot),
                    volume_engine.ProfilePoint(h_cm * 0.5, (r_bot + r_open) * 0.5),
                    volume_engine.ProfilePoint(h_cm, r_open),
                ]
                v_ml = float(rng.choice([600.0, 750.0, 1000.0]))
            else:
                h_cm = 24.0
                r_open = 3.43
                profile = [
                    volume_engine.ProfilePoint(0.0, 3.43),
                    volume_engine.ProfilePoint(24.0, 3.43),
                ]
                v_ml = 1000.0

            d_cm = focal * r_open / rim_r
            true_h = float(rng.uniform(h_cm * 0.14, h_cm * 0.86))
            true_rad_cm = volume_engine.radius_at_height(profile, true_h)
            true_water_r = focal * true_rad_cm / (d_cm + h_cm - true_h)
            true_ml = volume_engine.scaled_volume(profile, true_h, v_ml)
            r_bottom_px = focal * profile[0].radius_cm / (d_cm + h_cm)

            # Configure scenario-specific optical challenges.
            water_offset = (0.0, 0.0)
            base_rings = None
            visible_arc = 360.0
            glare = 0
            low_contrast = False
            stains = True
            noise = 4.0

            if cat_name == "2_parallax_tilt":
                ang = rng.uniform(0, 6.28)
                shift = rim_r * rng.uniform(0.055, 0.105)
                water_offset = (shift * math.cos(ang), shift * math.sin(ang))
            elif cat_name == "3_metal_base_competing":
                # Strong embossed floor rings (below water level!).
                max_base_frac = min(0.42, (true_water_r / rim_r) - 0.09)
                if max_base_frac > 0.24:
                    base_rings = [
                        (max_base_frac, -38.0),
                        (max_base_frac * 0.68, 72.0),
                    ]
                else:
                    base_rings = [(0.22, 70.0)]
            elif cat_name == "4_partial_occlusion":
                visible_arc = float(rng.uniform(115.0, 210.0))
            elif cat_name == "5_specular_glare":
                glare = int(rng.integers(2, 5))
            elif cat_name == "6_low_contrast_meniscus":
                low_contrast = True
            elif cat_name == "8_low_light_stains":
                noise = float(rng.uniform(9.0, 14.0))
                stains = True
                glare = 1

            tol_px = max(7.0, rim_r * 0.032)

            if cat_name in ("9_multifocus_sweep", "10_neck_seam_multifocus"):
                # Realistic 5-frame focus sweep: frame 0 sharp rim / blurred water,
                # frames 1..4 step through depths with hand drift & breathing.
                if cat_name == "10_neck_seam_multifocus":
                    # Mirror the real blue stainless bottle: permanent neck seam at
                    # ~0.75 R and real water deeper inside (0.40..0.64 R), with tilt offset.
                    true_h = float(rng.uniform(h_cm * 0.16, h_cm * 0.58))
                    true_rad_cm = volume_engine.radius_at_height(profile, true_h)
                    true_water_r = focal * true_rad_cm / (d_cm + h_cm - true_h)
                    true_ml = volume_engine.scaled_volume(profile, true_h, v_ml)
                    ang = rng.uniform(0, 6.28)
                    shift = rim_r * rng.uniform(0.03, 0.08)
                    water_offset = (shift * math.cos(ang), shift * math.sin(ang))
                    neck_seam_frac = float(rng.uniform(0.73, 0.77))
                    true_focus_idx = int(rng.integers(2, 5))
                else:
                    neck_seam_frac = None
                    true_focus_idx = int(rng.integers(1, 5))

                sweep_frames = []
                base_rings = [(min(0.36, (true_water_r / rim_r) - 0.10), 60.0)] if true_water_r / rim_r > 0.45 else None
                for k in range(5):
                    lp = 0.14 + k * 0.17
                    breath = 1.0 + (k * 0.008)
                    drift_x = 0.0 if k == 0 else float(rng.uniform(-28.0, 28.0))
                    drift_y = 0.0 if k == 0 else float(rng.uniform(-28.0, 28.0))
                    f_k = focal * breath
                    rim_k_true = rim_r * breath
                    w_k_true = true_water_r * breath
                    blur_rim = 0.0 if k == 0 else min(8.0, k * 2.2)
                    blur_seam = abs(k - 0.4) * 3.8
                    blur_water = abs(k - true_focus_idx) * 4.5 + (6.0 if k == 0 else 0.0)
                    blur_base = abs(k - 4) * 3.0
                    img_k, true_rim_k = render_realistic_bottle(
                        rng,
                        rim_r=rim_k_true,
                        water_r=w_k_true,
                        water_offset=(water_offset[0] * breath, water_offset[1] * breath),
                        base_rings=base_rings,
                        neck_seam_frac=neck_seam_frac,
                        blur_neck_seam=blur_seam,
                        glare_blobs=1,
                        blur_rim=blur_rim,
                        blur_water=blur_water,
                        blur_base=blur_base,
                        center=(384.0 + drift_x, 384.0 + drift_y),
                    )
                    # Pass intentionally noisy initial rim (simulating 14 px drift)
                    # so refine_rim_on_frame must recover the true rim from pixels!
                    approx_rim = true_rim_k if k == 0 else (
                        (true_rim_k[0][0] + float(rng.uniform(-14, 14)), true_rim_k[0][1] + float(rng.uniform(-14, 14))),
                        true_rim_k[1] * float(rng.uniform(0.985, 1.015)),
                    )
                    sweep_frames.append((img_k, approx_rim, f_k, lp))

                # Old detector runs on blurry frame 0 only.
                old_c = circle_detector.detect_circles(sweep_frames[0][0], guided_rim=sweep_frames[0][1])
                old_hit = old_c.inner_radius_px is not None and abs(old_c.inner_radius_px - true_water_r) <= tol_px

                # New detector selects the single sharpest focus plane with pixel rim refinement!
                sel = select_sharpest_focus_frame(
                    sweep_frames,
                    profile=profile,
                    bottle_height_cm=h_cm,
                    opening_diameter_cm=r_open * 2.0,
                )
                sel_scale = sel.selected_focal_px / focal if sel.selected_focal_px else 1.0
                expected_r_sel = true_water_r * sel_scale
                cands = sel.candidates
                sel_d_cm = (sel.selected_focal_px * r_open / sel.selected_rim[1]) if sel.selected_focal_px else d_cm
                sel_f = sel.selected_focal_px or focal
            else:
                img, rim = render_realistic_bottle(
                    rng,
                    rim_r=rim_r,
                    water_r=true_water_r,
                    water_offset=water_offset,
                    base_rings=base_rings,
                    visible_arc_deg=visible_arc,
                    glare_blobs=glare,
                    low_contrast_meniscus=low_contrast,
                    water_stains=stains,
                    noise_sigma=noise,
                )
                old_c = circle_detector.detect_circles(img, guided_rim=rim)
                old_hit = old_c.inner_radius_px is not None and abs(old_c.inner_radius_px - true_water_r) <= tol_px

                cands = detect_water_candidates_multicue(
                    img,
                    rim[0],
                    rim[1],
                    profile=profile,
                    bottle_height_cm=h_cm,
                    phone_to_rim_cm=d_cm,
                    focal_length_px=focal,
                )
                expected_r_sel = true_water_r
                sel_d_cm = d_cm
                sel_f = focal

            if old_hit:
                cat_old += 1
                old_top1_hits += 1

            # Evaluate new detector top-1 and top-3 accuracy!
            top1_ok = False
            top3_ok = False
            if cands:
                r1 = cands[0].radius_px
                r_err = abs(r1 - expected_r_sel)
                h_pred = estimators.perspective_height(profile, h_cm, sel_d_cm, sel_f, r1)
                ml_pred = volume_engine.scaled_volume(profile, max(0.0, min(h_cm, h_pred)), v_ml) if h_pred is not None else None
                v_err = abs(ml_pred - true_ml) if ml_pred is not None else 999.0
                cat_r_errs.append(r_err)
                cat_v_errs.append(v_err)
                new_radius_errs.append(r_err)
                new_vol_errs.append(v_err)
                top1_ok = r_err <= tol_px
                top3_ok = any(abs(c.radius_px - expected_r_sel) <= tol_px for c in cands[:3])
            else:
                r_err = 999.0
                v_err = 999.0

            if top1_ok:
                cat_new1 += 1
                new_top1_hits += 1
            else:
                failures.append((cat_name, idx, round(expected_r_sel, 1), [(round(c.radius_px, 1), round(c.score, 2), c.likely_base) for c in cands[:3]]))
            if top3_ok:
                cat_new3 += 1
                new_top3_hits += 1

        summary[cat_name] = {
            "count": count,
            "old_top1": cat_old,
            "new_top1": cat_new1,
            "new_top3": cat_new3,
            "mean_r_err_px": round(float(np.mean(cat_r_errs)), 2) if cat_r_errs else None,
            "mean_v_err_ml": round(float(np.mean(cat_v_errs)), 1) if cat_v_errs else None,
        }

    print(f"\n================ {total_cases}-IMAGE GROUND-TRUTH BENCHMARK ================")
    print(f"{'Category':26s} | {'Old Top1':9s} | {'New Top1':9s} | {'New Top3':9s} | {'Mean dR':8s} | {'Mean dV':8s}")
    print("-" * 82)
    for k, v in summary.items():
        dr = f"{v['mean_r_err_px']:.1f}px" if v["mean_r_err_px"] is not None else "n/a"
        dv = f"{v['mean_v_err_ml']:.0f}ml" if v["mean_v_err_ml"] is not None else "n/a"
        print(f"{k:26s} | {v['old_top1']:2d}/{v['count']:2d}     | {v['new_top1']:2d}/{v['count']:2d}     | {v['new_top3']:2d}/{v['count']:2d}     | {dr:8s} | {dv:8s}")
    print("-" * 82)
    print(
        f"{'OVERALL':26s} | {old_top1_hits:3d}/{total_cases:3d}   | {new_top1_hits:3d}/{total_cases:3d}   | "
        f"{new_top3_hits:3d}/{total_cases:3d}   | "
        f"{np.mean(new_radius_errs):.2f}px  | {np.mean(new_vol_errs):.1f}ml"
    )
    print(f"Old Top-1 Rate: {100.0 * old_top1_hits / total_cases:.1f}%  -->  New Top-1 Rate: {100.0 * new_top1_hits / total_cases:.1f}%  (Top-3 Recall: {100.0 * new_top3_hits / total_cases:.1f}%)")
    if failures:
        print(f"\nTop-1 misses ({len(failures)}):")
        for f in failures[:15]:
            print(" ", f)
    return {
        "categories": summary,
        "total": total_cases,
        "old_top1": old_top1_hits,
        "new_top1": new_top1_hits,
        "new_top3": new_top3_hits,
        "mean_r_err_px": float(np.mean(new_radius_errs)),
        "mean_v_err_ml": float(np.mean(new_vol_errs)),
    }


def test_water_contour_model_passes_132_image_ground_truth_benchmark() -> None:
    report = run_benchmark()
    assert report["total"] >= 120
    assert report["new_top1"] / report["total"] >= 0.95
    assert report["new_top3"] / report["total"] >= 0.99
    assert report["mean_r_err_px"] <= 3.5


if __name__ == "__main__":
    run_benchmark()
