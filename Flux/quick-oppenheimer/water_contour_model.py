"""High-accuracy multi-cue water-surface contour detection and focus selection.

Addresses three physical failure modes observed in real top-down bottle photos:
1. Parallax offset: even a 2-5 deg camera tilt shifts the water surface centre
   by 15-50 px relative to the bottle rim, smearing fixed-centre polar profiles.
2. Subtle meniscus edges & specular glare: real water boundaries inside metal
   bottles often appear as thin bright/dark meniscus ridges plus subtle CIELAB
   luminance/chroma/texture steps alongside strong machined bottom rings.
3. Handheld multi-focus ghosting: blending multiple handheld focus frames into
   one composite causes double-layered blur when camera pose drifts. Instead,
   each focus frame has its own rim fitted directly on pixels, and we select
   the single sharpest unblended focus plane for the water surface.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
from typing import Sequence

import cv2
import numpy as np

from volume_engine import ProfilePoint


@dataclass(frozen=True)
class RefinedWaterCandidate:
    center: tuple[float, float]
    radius_px: float
    score: float
    coverage: float
    longest_arc: float
    normal_alignment: float
    region_step: float
    meniscus_strength: float
    radial_rmse_ratio: float
    likely_base: bool
    visible_mask: tuple[bool, ...]
    focus_frame_index: int = 0
    focus_lens_position: float | None = None


@dataclass
class FocusSelectionResult:
    selected_index: int
    selected_bgr: np.ndarray
    selected_rim: tuple[tuple[float, float], float]
    selected_focal_px: float | None
    selected_lens_position: float | None
    candidates: list[RefinedWaterCandidate]
    frame_count: int
    base_interior_sharpness: float
    selected_interior_sharpness: float
    per_frame_sharpness: list[float]

    @property
    def sharpness_gain(self) -> float:
        if self.base_interior_sharpness <= 1e-6:
            return 1.0
        return float(self.selected_interior_sharpness / self.base_interior_sharpness)


def _longest_cyclic_run(mask: np.ndarray) -> float:
    if mask.size == 0 or not np.any(mask):
        return 0.0
    if np.all(mask):
        return 1.0
    doubled = np.concatenate((mask, mask))
    longest = current = 0
    for val in doubled:
        current = current + 1 if val else 0
        if current > longest:
            longest = current
    return min(longest, mask.size) / mask.size


def compute_physical_radius_bounds(
    profile: Sequence[ProfilePoint] | None,
    bottle_height_cm: float,
    phone_to_rim_cm: float | None,
    focal_length_px: float | None,
    outer_radius_px: float,
) -> tuple[float, float]:
    """Compute the pixel radius range physically reachable by water in this bottle."""
    default_lo = outer_radius_px * 0.22
    default_hi = outer_radius_px * 0.90
    if not profile or phone_to_rim_cm is None or focal_length_px is None or phone_to_rim_cm <= 0 or focal_length_px <= 0:
        return default_lo, default_hi

    projected = [
        focal_length_px * pt.radius_cm / max(phone_to_rim_cm + bottle_height_cm - pt.height_cm, 0.5)
        for pt in profile
        if pt.height_cm <= bottle_height_cm + 0.05
    ]
    if not projected:
        return default_lo, default_hi

    # Ignore only an artificially pinched bottom-most tip (h=0) if the nearby
    # lower wall is substantially wider, while keeping genuine low-water radii.
    r_lo = min(projected)
    if len(profile) >= 3 and profile[0].radius_cm < 0.65 * profile[2].radius_cm:
        r_lo = min(projected[1:])
    r_hi = max(projected)

    lo = max(outer_radius_px * 0.20, min(r_lo * 0.94, outer_radius_px * 0.75))
    hi = min(outer_radius_px * 0.91, max(r_hi * 0.96, lo + outer_radius_px * 0.15))
    return float(lo), float(hi)


def refine_rim_on_frame(
    image_bgr: np.ndarray,
    initial_rim: tuple[tuple[float, float], float],
    search_shift_frac: float = 0.12,
    search_radius_frac: float = 0.06,
) -> tuple[tuple[float, float], float]:
    """Refine a bottle rim directly on ``image_bgr`` pixels without VIO drift.

    Even when the camera is focused deeper inside the bottle, the bottle rim
    remains a high-contrast circular boundary whose symmetric radial gradient
    peak stays centered on the true physical rim.
    """
    h, w = image_bgr.shape[:2]
    (cx0, cy0), r0 = initial_rim
    scale = min(1.0, 640.0 / max(h, w))
    gray = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY)
    if scale < 1.0:
        gray = cv2.resize(gray, (round(w * scale), round(h * scale)), interpolation=cv2.INTER_AREA)
    gray_f = cv2.GaussianBlur(gray, (5, 5), 1.0).astype(np.float32)

    cx_s, cy_s, r_s = cx0 * scale, cy0 * scale, r0 * scale
    gh, gw = gray_f.shape[:2]
    if r_s < 16:
        return initial_rim

    # Precompute gradient magnitude and direction.
    gx = cv2.Scharr(gray_f, cv2.CV_32F, 1, 0) / 16.0
    gy = cv2.Scharr(gray_f, cv2.CV_32F, 0, 1) / 16.0

    angles = np.linspace(0.0, 2.0 * math.pi, 64, endpoint=False, dtype=np.float32)
    cos_a = np.cos(angles)
    sin_a = np.sin(angles)

    best_cx, best_cy, best_r = cx_s, cy_s, r_s
    best_score = -1e18

    # Coarse-to-fine search: 2 passes (coarse then 1px fine).
    for step_px, n_xy, n_r in (
        (max(2.0, r_s * search_shift_frac / 3.0), 3, 3),
        (1.0, 2, 2),
    ):
        r_step = max(1.0, r_s * search_radius_frac / 3.0) if step_px > 1.0 else 0.75
        cur_cx, cur_cy, cur_r = best_cx, best_cy, best_r
        for ix in range(-n_xy, n_xy + 1):
            tx = cur_cx + ix * step_px
            for iy in range(-n_xy, n_xy + 1):
                ty = cur_cy + iy * step_px
                for ir in range(-n_r, n_r + 1):
                    tr = cur_r + ir * r_step
                    if tr < 14 or tx - tr < 2 or tx + tr >= gw - 2 or ty - tr < 2 or ty + tr >= gh - 2:
                        continue
                    xs = np.rint(tx + tr * cos_a).astype(np.int32)
                    ys = np.rint(ty + tr * sin_a).astype(np.int32)
                    radial_g = gx[ys, xs] * cos_a + gy[ys, xs] * sin_a
                    pos_sum = float(np.sum(np.maximum(radial_g, 0.0)))
                    neg_sum = float(np.sum(np.maximum(-radial_g, 0.0)))
                    # Strong consistent polarity around the full circle, mild prior toward initial estimate.
                    prior = 0.05 * (math.hypot(tx - cx_s, ty - cy_s) + 1.5 * abs(tr - r_s))
                    score = max(pos_sum, neg_sum) / 64.0 - prior
                    if score > best_score:
                        best_score = score
                        best_cx, best_cy, best_r = tx, ty, tr

    return ((best_cx / scale, best_cy / scale), best_r / scale)


def measure_interior_sharpness(
    image_bgr: np.ndarray,
    rim: tuple[tuple[float, float], float],
    r_lo: float | None = None,
    r_hi: float | None = None,
) -> float:
    """Measure edge sharpness in the bottle's interior water band.

    Caps the upper radius at 0.74 * R by default so water-stains or machined
    scratches on the dry upper lip collar (0.75-0.95 * R) do not fool focus
    selection into preferring a rim-focused frame over an interior-focused one.
    """
    (cx, cy), r = rim
    h, w = image_bgr.shape[:2]
    scale = min(1.0, 768.0 / max(h, w))
    gray = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY)
    if scale < 1.0:
        gray = cv2.resize(gray, (round(w * scale), round(h * scale)), interpolation=cv2.INTER_AREA)
    cx_s, cy_s, r_s = cx * scale, cy * scale, r * scale
    lo = (r_lo * scale) if r_lo is not None else r_s * 0.28
    hi = min(r_s * 0.74, (r_hi * scale) if r_hi is not None else r_s * 0.74)
    if hi <= lo + 8.0:
        lo, hi = r_s * 0.26, r_s * 0.78

    gh, gw = gray.shape[:2]
    yy, xx = np.ogrid[:gh, :gw]
    dist = np.hypot(xx - cx_s, yy - cy_s)
    # Exclude saturated white glare highlights so specular blobs don't bias sharpness.
    mask = (dist >= lo) & (dist <= hi) & (gray < 248)
    if int(np.sum(mask)) < 64:
        return 0.0

    lap = cv2.Laplacian(gray, cv2.CV_32F, ksize=3)
    gx = cv2.Scharr(gray, cv2.CV_32F, 1, 0) / 16.0
    gy = cv2.Scharr(gray, cv2.CV_32F, 0, 1) / 16.0
    grad_energy = float(np.mean(gx[mask] ** 2 + gy[mask] ** 2))
    lap_var = float(np.var(lap[mask]))
    return lap_var + 0.15 * grad_energy


def _ring_radial_sharpness(
    image_bgr: np.ndarray,
    center: tuple[float, float],
    radius_px: float,
    outer_radius_px: float,
) -> float:
    """Measure local radial gradient sharpness specifically on a candidate ring."""
    h, w = image_bgr.shape[:2]
    scale = min(1.0, 768.0 / max(h, w))
    gray = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY)
    if scale < 1.0:
        gray = cv2.resize(gray, (round(w * scale), round(h * scale)), interpolation=cv2.INTER_AREA)
    cx, cy, rad, orad = center[0] * scale, center[1] * scale, radius_px * scale, outer_radius_px * scale
    gh, gw = gray.shape[:2]
    band = max(3.0, orad * 0.024)
    y0 = max(0, int(math.floor(cy - rad - band - 2)))
    y1 = min(gh, int(math.ceil(cy + rad + band + 2)))
    x0 = max(0, int(math.floor(cx - rad - band - 2)))
    x1 = min(gw, int(math.ceil(cx + rad + band + 2)))
    if y1 - y0 < 8 or x1 - x0 < 8:
        return 0.0
    patch = gray[y0:y1, x0:x1]
    yy, xx = np.ogrid[y0:y1, x0:x1]
    dist = np.hypot(xx - cx, yy - cy)
    mask = (dist >= max(2.0, rad - band)) & (dist <= rad + band) & (patch < 248)
    if int(np.sum(mask)) < 24:
        return 0.0
    lap = cv2.Laplacian(patch, cv2.CV_32F, ksize=3)
    return float(np.var(lap[mask]))


def _huber_circle_fit(
    xs: np.ndarray,
    ys: np.ndarray,
    init_cx: float,
    init_cy: float,
    init_r: float,
    max_shift_from_init: float,
) -> tuple[float, float, float, float]:
    """Sub-pixel robust Huber-IRLS circle fit (Gauss-Newton) on boundary points."""
    cx, cy, r = float(init_cx), float(init_cy), float(init_r)
    if xs.size < 12:
        return cx, cy, r, 0.05

    delta = max(1.5, init_r * 0.02)
    for _ in range(8):
        dx = xs - cx
        dy = ys - cy
        d = np.hypot(dx, dy)
        valid = d > 1e-3
        if int(np.sum(valid)) < 12:
            break
        dx, dy, d = dx[valid], dy[valid], d[valid]
        res = d - r
        abs_res = np.abs(res)
        weights = np.where(abs_res <= delta, 1.0, delta / np.maximum(abs_res, 1e-6))

        # Jacobian of f(cx, cy, r) = hypot(x - cx, y - cy) - r
        j0 = -dx / d
        j1 = -dy / d
        j2 = -np.ones_like(d)
        J = np.stack((j0, j1, j2), axis=1)
        JW = J * weights[:, None]
        H = JW.T @ J + np.diag([1e-4, 1e-4, 1e-4])
        g = JW.T @ res
        try:
            step = -np.linalg.solve(H, g)
        except np.linalg.LinAlgError:
            break

        new_cx = cx + float(step[0])
        new_cy = cy + float(step[1])
        new_r = r + float(step[2])

        # Clamp drift so partial arcs cannot run away to an absurd huge circle.
        shift = math.hypot(new_cx - init_cx, new_cy - init_cy)
        if shift > max_shift_from_init:
            ratio = max_shift_from_init / shift
            new_cx = init_cx + (new_cx - init_cx) * ratio
            new_cy = init_cy + (new_cy - init_cy) * ratio
        if abs(new_r - init_r) > init_r * 0.14:
            new_r = init_r + math.copysign(init_r * 0.14, new_r - init_r)

        cx, cy, r = new_cx, new_cy, new_r
        if float(np.max(np.abs(step))) < 0.05:
            break

    final_res = np.abs(np.hypot(xs - cx, ys - cy) - r)
    rmse = float(np.sqrt(np.mean(np.minimum(final_res, delta * 3.0) ** 2)))
    return cx, cy, r, rmse


def _build_multicue_maps(bgr: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Compute edge-preserving luminance, Lab channels, Scharr gradients and glare mask."""
    lab = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB)
    l_chan = lab[:, :, 0]
    a_chan = lab[:, :, 1].astype(np.float32)
    b_chan = lab[:, :, 2].astype(np.float32)

    clahe = cv2.createCLAHE(clipLimit=2.2, tileGridSize=(8, 8))
    l_eq = clahe.apply(l_chan)
    # Bilateral filtering preserves crisp 2-px meniscus ridges while denoising flat metal walls.
    l_smooth = cv2.bilateralFilter(l_eq, d=5, sigmaColor=24, sigmaSpace=5).astype(np.float32)
    a_smooth = cv2.GaussianBlur(a_chan, (5, 5), 1.0)
    b_smooth = cv2.GaussianBlur(b_chan, (5, 5), 1.0)

    gx_l = cv2.Scharr(l_smooth, cv2.CV_32F, 1, 0) / 16.0
    gy_l = cv2.Scharr(l_smooth, cv2.CV_32F, 0, 1) / 16.0
    gx_a = cv2.Scharr(a_smooth, cv2.CV_32F, 1, 0) / 16.0
    gy_a = cv2.Scharr(a_smooth, cv2.CV_32F, 0, 1) / 16.0
    gx_b = cv2.Scharr(b_smooth, cv2.CV_32F, 1, 0) / 16.0
    gy_b = cv2.Scharr(b_smooth, cv2.CV_32F, 0, 1) / 16.0

    # Combine luminance and chromatic gradients into one directional edge field.
    grad_mag = np.sqrt(gx_l * gx_l + gy_l * gy_l + 1.5 * (gx_a * gx_a + gy_a * gy_a + gx_b * gx_b + gy_b * gy_b))

    # Saturated white specular glare spots are down-weighted.
    glare = cv2.dilate((l_chan >= 248).astype(np.uint8), np.ones((5, 5), np.uint8)) > 0
    return l_smooth, a_smooth, b_smooth, gx_l, gy_l, np.where(glare, grad_mag * 0.2, grad_mag)


def detect_water_candidates_multicue(
    image_bgr: np.ndarray,
    outer_center: tuple[float, float],
    outer_radius_px: float,
    *,
    profile: Sequence[ProfilePoint] | None = None,
    bottle_height_cm: float = 20.0,
    phone_to_rim_cm: float | None = None,
    focal_length_px: float | None = None,
    max_candidates: int = 5,
    focus_frame_index: int = 0,
    focus_lens_position: float | None = None,
) -> list[RefinedWaterCandidate]:
    """Detect and sub-pixel-refine ranked water-surface candidates.

    Handles off-axis tilt parallax up to +/-10% of rim radius, partial occlusion
    down to ~95 deg visible arcs, thin meniscus refraction ridges, and strong
    competing metal-bottom circles.
    """
    if outer_radius_px < 24:
        return []

    height, width = image_bgr.shape[:2]
    scale = min(1.0, 960.0 / max(height, width))
    if scale < 1.0:
        work = cv2.resize(
            image_bgr,
            (round(width * scale), round(height * scale)),
            interpolation=cv2.INTER_AREA,
        )
    else:
        work = image_bgr

    wh, ww = work.shape[:2]
    ocx, ocy = outer_center[0] * scale, outer_center[1] * scale
    orad = outer_radius_px * scale

    r_lo_orig, r_hi_orig = compute_physical_radius_bounds(
        profile, bottle_height_cm, phone_to_rim_cm, focal_length_px, outer_radius_px,
    )
    r_lo = max(orad * 0.22, r_lo_orig * scale)
    r_hi = min(orad * 0.90, r_hi_orig * scale)
    if r_hi <= r_lo + 8:
        return []

    l_smooth, a_smooth, b_smooth, gx_l, gy_l, grad_mag = _build_multicue_maps(work)
    g_total = np.hypot(gx_l, gy_l) + 1e-4

    radial_count = max(110, min(320, round(r_hi - r_lo) + 1))
    angular_count = 180
    radii = np.linspace(r_lo, r_hi, radial_count, dtype=np.float32)
    radius_step = float(radii[1] - radii[0])
    angles = np.linspace(0.0, 2.0 * math.pi, angular_count, endpoint=False, dtype=np.float32)
    cos_a = np.cos(angles)[None, :]
    sin_a = np.sin(angles)[None, :]

    # Coarse offset grid covering up to +/-8% of rim radius (handles up to ~5 deg camera tilt).
    offset_steps = (-0.075, -0.0375, 0.0, 0.0375, 0.075)
    raw_peaks: list[tuple[float, float, float, float]] = []

    for ox_f in offset_steps:
        for oy_f in offset_steps:
            if math.hypot(ox_f, oy_f) > 0.095:
                continue
            cx = ocx + ox_f * orad
            cy = ocy + oy_f * orad
            map_x = cx + radii[:, None] * cos_a
            map_y = cy + radii[:, None] * sin_a
            if (
                float(map_x.min()) < 1 or float(map_x.max()) >= ww - 1
                or float(map_y.min()) < 1 or float(map_y.max()) >= wh - 1
            ):
                continue

            p_gx = cv2.remap(gx_l, map_x, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
            p_gy = cv2.remap(gy_l, map_x, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
            p_mag = cv2.remap(grad_mag, map_x, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
            p_gtot = cv2.remap(g_total, map_x, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)

            # Directional radial gradient: only edges tangent to the circle vote!
            radial_signed = p_gx * cos_a + p_gy * sin_a
            normal_align = np.abs(radial_signed) / p_gtot
            directional = p_mag * np.power(np.clip(normal_align, 0.0, 1.0), 1.5)
            directional = cv2.GaussianBlur(directional, (1, 3), 0)

            # Upper-quantile profile supports partially occluded water arcs (~28%+).
            profile_70 = np.quantile(directional, 0.72, axis=1)
            med = float(np.median(profile_70))
            mad = float(1.4826 * np.median(np.abs(profile_70 - med)))
            min_peak = max(3.0, med + 2.2 * max(mad, 0.45))

            for row in range(3, radial_count - 3):
                val = float(profile_70[row])
                if val >= min_peak and val == float(np.max(profile_70[row - 3:row + 4])):
                    raw_peaks.append((cx, cy, float(radii[row]), val))

    if not raw_peaks:
        return []

    # Group coarse peaks by approximate radius and evaluate top distinct seeds.
    raw_peaks.sort(key=lambda item: item[3], reverse=True)
    seeds: list[tuple[float, float, float]] = []
    for cx, cy, rad, _ in raw_peaks:
        if any(abs(rad - s_r) < orad * 0.045 and math.hypot(cx - s_x, cy - s_y) < orad * 0.06 for s_x, s_y, s_r in seeds):
            continue
        seeds.append((cx, cy, rad))
        if len(seeds) >= 14:
            break

    # Refine each seed with Huber-IRLS circle fit and multi-cue physical scoring.
    refined_list: list[RefinedWaterCandidate] = []
    fine_angles = np.linspace(0.0, 2.0 * math.pi, 240, endpoint=False, dtype=np.float32)
    f_cos = np.cos(fine_angles)
    f_sin = np.sin(fine_angles)
    band_half = max(4.0, orad * 0.032)
    band_steps = max(13, int(round(band_half * 2)) + 1)
    band_offsets = np.linspace(-band_half, band_half, band_steps, dtype=np.float32)

    global_grad_noise = max(1.2, float(np.median(grad_mag[
        max(0, int(ocy - orad * 0.85)):min(wh, int(ocy + orad * 0.85)),
        max(0, int(ocx - orad * 0.85)):min(ww, int(ocx + orad * 0.85)),
    ])))

    for s_cx, s_cy, s_r in seeds:
        # Step 1: Collect radial peaks around the seed to run Huber circle fit.
        sample_r = np.clip(s_r + band_offsets[:, None], 4.0, orad * 0.94)
        mx = (s_cx + sample_r * f_cos[None, :]).astype(np.float32)
        my = (s_cy + sample_r * f_sin[None, :]).astype(np.float32)
        if float(mx.min()) < 1 or float(mx.max()) >= ww - 1 or float(my.min()) < 1 or float(my.max()) >= wh - 1:
            continue

        p_gx = cv2.remap(gx_l, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
        p_gy = cv2.remap(gy_l, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
        p_mag = cv2.remap(grad_mag, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
        p_gtot = cv2.remap(g_total, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)

        rad_signed = p_gx * f_cos[None, :] + p_gy * f_sin[None, :]
        align = np.abs(rad_signed) / p_gtot
        dir_strength = p_mag * np.power(np.clip(align, 0.0, 1.0), 1.5)

        best_idx = np.argmax(dir_strength, axis=0)
        cols = np.arange(240)
        peak_vals = dir_strength[best_idx, cols]
        thresh = max(3.2, global_grad_noise * 2.4)
        sup = peak_vals >= thresh
        if int(np.sum(sup)) < 56:
            continue

        # Sub-pixel parabolic refinement along the radial profile.
        sub_r = sample_r[best_idx, 0].copy()
        for col in np.where(sup)[0]:
            bi = int(best_idx[col])
            if 0 < bi < band_steps - 1:
                y0, y1, y2 = float(dir_strength[bi - 1, col]), float(dir_strength[bi, col]), float(dir_strength[bi + 1, col])
                denom = 2.0 * (y0 - 2.0 * y1 + y2)
                if abs(denom) > 1e-6:
                    delta_idx = max(-0.5, min(0.5, (y0 - y2) / denom))
                    sub_r[col] += delta_idx * float(band_offsets[1] - band_offsets[0])

        pts_x = s_cx + sub_r[sup] * f_cos[sup]
        pts_y = s_cy + sub_r[sup] * f_sin[sup]
        fit_cx, fit_cy, fit_r, rmse = _huber_circle_fit(
            pts_x, pts_y, s_cx, s_cy, s_r, max_shift_from_init=orad * 0.055,
        )

        # Enforce physical bounds & max camera-tilt parallax offset (<= 13.5% of rim).
        offset_ratio = math.hypot(fit_cx - ocx, fit_cy - ocy) / max(orad, 1e-6)
        if offset_ratio > 0.135 or not (r_lo * 0.96 <= fit_r <= r_hi * 1.02):
            continue

        # Step 2: Re-evaluate exact multi-cue support on the refined circle!
        eval_offsets = np.linspace(-max(2.5, orad * 0.014), max(2.5, orad * 0.014), 7, dtype=np.float32)
        er = np.clip(fit_r + eval_offsets[:, None], 3.0, orad * 0.95)
        emx = (fit_cx + er * f_cos[None, :]).astype(np.float32)
        emy = (fit_cy + er * f_sin[None, :]).astype(np.float32)
        if float(emx.min()) < 1 or float(emx.max()) >= ww - 1 or float(emy.min()) < 1 or float(emy.max()) >= wh - 1:
            continue

        e_gx = cv2.remap(gx_l, emx, emy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
        e_gy = cv2.remap(gy_l, emx, emy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
        e_mag = cv2.remap(grad_mag, emx, emy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
        e_gtot = cv2.remap(g_total, emx, emy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)

        e_signed = e_gx * f_cos[None, :] + e_gy * f_sin[None, :]
        e_align = np.abs(e_signed) / e_gtot
        e_dir = e_mag * np.power(np.clip(e_align, 0.0, 1.0), 1.5)

        e_best = np.argmax(e_dir, axis=0)
        e_peak = e_dir[e_best, cols]
        e_sign_peak = e_signed[e_best, cols]
        e_align_peak = e_align[e_best, cols]
        e_sup = (e_peak >= thresh) & (e_align_peak >= 0.62)

        coverage = float(np.mean(e_sup))
        longest_arc = _longest_cyclic_run(e_sup)
        if coverage < 0.26 or longest_arc < 0.19:
            continue

        pos_frac = float(np.mean(e_sign_peak[e_sup] > 0))
        polarity = max(pos_frac, 1.0 - pos_frac)
        mean_align = float(np.mean(e_align_peak[e_sup]))
        rmse_ratio = rmse / max(orad, 1e-6)
        if rmse_ratio > 0.036:
            continue

        # Multi-channel Lab region contrast & meniscus ridge check across the boundary.
        near_d = max(3.5, orad * 0.018)
        far_d = max(9.0, orad * 0.052)
        sup_cos = f_cos[e_sup]
        sup_sin = f_sin[e_sup]

        def sample_band(chan: np.ndarray, offset_px: float) -> np.ndarray:
            rr = np.clip(fit_r + offset_px, 2.0, orad * 0.96)
            sx = (fit_cx + rr * sup_cos).astype(np.float32)[None, :]
            sy = (fit_cy + rr * sup_sin).astype(np.float32)[None, :]
            return cv2.remap(chan, sx, sy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)[0]

        l_in_near = sample_band(l_smooth, -near_d)
        l_out_near = sample_band(l_smooth, +near_d)
        l_in_far = sample_band(l_smooth, -far_d)
        l_out_far = sample_band(l_smooth, +far_d)
        l_on = sample_band(l_smooth, 0.0)

        a_diff = sample_band(a_smooth, +far_d) - sample_band(a_smooth, -far_d)
        b_diff = sample_band(b_smooth, +far_d) - sample_band(b_smooth, -far_d)

        near_diff = l_out_near - l_in_near
        far_diff = l_out_far - l_in_far
        chroma_step = np.hypot(a_diff, b_diff)

        # Region persistence: either consistent L step or noticeable Lab chroma step.
        persistent = (
            ((near_diff * far_diff > 0) & (np.abs(far_diff) >= np.maximum(2.5, np.abs(near_diff) * 0.28)))
            | (chroma_step >= 4.0)
        )
        region_step = float(np.mean(persistent))

        # Meniscus ridge: thin bright highlight or dark shadow right on the contact line
        # relative to the mean of inner & outer neighbours.
        ridge_contrast = np.abs(l_on - 0.5 * (l_in_near + l_out_near))
        meniscus_strength = float(np.clip(np.median(ridge_contrast) / 18.0, 0.0, 1.0))

        # Reject isolated specular lines that lack both region change and meniscus consistency.
        if region_step < 0.34 and not (meniscus_strength >= 0.45 and coverage >= 0.42 and polarity >= 0.62):
            continue

        # Base-plate discrimination: very small rings or razor-rigid concentric base steps.
        ratio = fit_r / max(orad, 1e-6)
        likely_base = False
        if ratio < 0.37 and (phone_to_rim_cm is None or fit_r < r_lo * 1.12):
            likely_base = True
        elif (
            ratio < 0.52
            and offset_ratio < 0.025
            and coverage >= 0.93
            and region_step >= 0.88
            and rmse_ratio <= 0.0085
            and meniscus_strength < 0.35
        ):
            likely_base = True

        strength_ratio = float(np.median(e_peak[e_sup])) / max(global_grad_noise, 1e-6)
        strength_score = min(1.0, max(0.0, (strength_ratio - 2.0) / 6.0))
        arc_score = min(1.0, longest_arc / 0.55)
        rmse_score = max(0.0, 1.0 - rmse_ratio / 0.032)
        offset_score = max(0.0, 1.0 - offset_ratio / 0.16)
        combined_region = max(region_step, 0.65 * meniscus_strength + 0.35 * region_step)

        score = (
            0.20 * coverage
            + 0.15 * arc_score
            + 0.17 * mean_align
            + 0.18 * combined_region
            + 0.12 * strength_score
            + 0.10 * rmse_score
            + 0.05 * polarity
            + 0.03 * offset_score
        )
        if score < 0.56:
            continue

        refined_list.append(
            RefinedWaterCandidate(
                center=(fit_cx / scale, fit_cy / scale),
                radius_px=fit_r / scale,
                score=float(score),
                coverage=coverage,
                longest_arc=longest_arc,
                normal_alignment=mean_align,
                region_step=region_step,
                meniscus_strength=meniscus_strength,
                radial_rmse_ratio=rmse_ratio,
                likely_base=likely_base,
                visible_mask=tuple(bool(v) for v in e_sup),
                focus_frame_index=focus_frame_index,
                focus_lens_position=focus_lens_position,
            )
        )

    if not refined_list:
        return []

    # Merge duplicate refined circles representing the same physical water ring.
    refined_list.sort(key=lambda c: c.radius_px)
    merged: list[RefinedWaterCandidate] = []
    for cand in refined_list:
        if merged and abs(cand.radius_px - merged[-1].radius_px) <= outer_radius_px * 0.048:
            if (not cand.likely_base and merged[-1].likely_base) or (
                cand.likely_base == merged[-1].likely_base and cand.score > merged[-1].score
            ):
                merged[-1] = cand
        else:
            merged.append(cand)

    # Physical floor-through-water rule: when looking down through transparent
    # water into a metal bottle, both the real water surface (outer, closer to
    # rim) and the bottle floor / embossed base (inner, near r_lo) can appear
    # sharp simultaneously. Whenever a strong higher-level water ring exists
    # strictly outside a floor-zone ring, demote the inner floor-zone ring as
    # `likely_base` while still keeping it available for user review.
    floor_ceiling_px = max(r_lo_orig * 1.15, outer_radius_px * 0.45)
    adjusted: list[RefinedWaterCandidate] = []
    for cand in merged:
        is_base = cand.likely_base
        if not is_base and cand.radius_px <= floor_ceiling_px:
            has_strong_higher_water = any(
                (not other.likely_base)
                and other.radius_px > cand.radius_px + outer_radius_px * 0.06
                and other.score >= 0.72
                and other.coverage >= 0.35
                and other.normal_alignment >= 0.78
                for other in merged
            )
            if has_strong_higher_water:
                is_base = True
        if is_base != cand.likely_base:
            adjusted.append(
                RefinedWaterCandidate(
                    center=cand.center,
                    radius_px=cand.radius_px,
                    score=cand.score,
                    coverage=cand.coverage,
                    longest_arc=cand.longest_arc,
                    normal_alignment=cand.normal_alignment,
                    region_step=cand.region_step,
                    meniscus_strength=cand.meniscus_strength,
                    radial_rmse_ratio=cand.radial_rmse_ratio,
                    likely_base=is_base,
                    visible_mask=cand.visible_mask,
                    focus_frame_index=cand.focus_frame_index,
                    focus_lens_position=cand.focus_lens_position,
                )
            )
        else:
            adjusted.append(cand)

    # Sort plausible water surfaces first, then by score (mild outer tie-breaker
    # when two strong rings are within 0.025 in score).
    adjusted.sort(key=lambda c: (c.likely_base, -(c.score + 0.02 * (c.radius_px / max(outer_radius_px, 1e-6)))))
    return adjusted[:max_candidates]


def select_sharpest_focus_frame(
    frames: list[tuple[np.ndarray, tuple[tuple[float, float], float], float | None, float | None]],
    *,
    profile: Sequence[ProfilePoint] | None = None,
    bottle_height_cm: float = 20.0,
    opening_diameter_cm: float = 7.0,
) -> FocusSelectionResult:
    """Choose the single sharpest unblended focus frame for the water surface.

    Each item in ``frames`` is ``(image_bgr, approx_rim, focal_px, lens_position)``.
    Every frame gets its own pixel-refined rim (eliminating VIO drift & ghosting),
    is scored by interior sharpness, ring-localized Depth-From-Focus sharpness,
    and multi-cue water contour strength, and the single clearest real frame is
    returned untouched (zero double-layer artifacts).
    """
    assert frames, "At least one frame is required"
    opening_r_cm = max(opening_diameter_cm / 2.0, 0.1)

    refined_frames: list[tuple[np.ndarray, tuple[tuple[float, float], float], float | None, float | None]] = []
    per_frame_sharp: list[float] = []
    per_frame_candidates: list[list[RefinedWaterCandidate]] = []

    for idx, (bgr, approx_rim, focal_px, lens_pos) in enumerate(frames):
        # Frame 0's guided rim came from real-time lock; subsequent frames refine
        # directly on image pixels so any hand drift is eliminated cleanly.
        rim = approx_rim if idx == 0 else refine_rim_on_frame(bgr, approx_rim)
        dist_cm = (focal_px * opening_r_cm / max(rim[1], 1e-6)) if focal_px else None
        r_lo, r_hi = compute_physical_radius_bounds(profile, bottle_height_cm, dist_cm, focal_px, rim[1])
        sharp = measure_interior_sharpness(bgr, rim, r_lo=r_lo, r_hi=r_hi)
        cands = detect_water_candidates_multicue(
            bgr,
            rim[0],
            rim[1],
            profile=profile,
            bottle_height_cm=bottle_height_cm,
            phone_to_rim_cm=dist_cm,
            focal_length_px=focal_px,
            max_candidates=5,
            focus_frame_index=idx,
            focus_lens_position=lens_pos,
        )
        refined_frames.append((bgr, rim, focal_px, lens_pos))
        per_frame_sharp.append(sharp)
        per_frame_candidates.append(cands)

    # Identify minimum lens position (closest/rim focus) if hardware lens telemetry exists.
    known_lps = [lp for _, _, _, lp in refined_frames if lp is not None]
    min_lp = min(known_lps) if known_lps else None
    has_focus_sweep = len(known_lps) >= 2 and (max(known_lps) - min(known_lps)) >= 0.12

    max_sharp = max(max(per_frame_sharp), 1e-6)
    best_idx = 0
    best_combined = -1e9

    for idx in range(len(refined_frames)):
        bgr, rim, _, lp = refined_frames[idx]
        sharp_norm = per_frame_sharp[idx] / max_sharp
        cands = per_frame_candidates[idx]
        non_base = [c for c in cands if not c.likely_base]

        if non_base:
            top = non_base[0]
            top_cand_score = top.score
            ring_sharp = _ring_radial_sharpness(bgr, top.center, top.radius_px, rim[1])
        elif cands:
            top = cands[0]
            top_cand_score = top.score * 0.65
            ring_sharp = _ring_radial_sharpness(bgr, top.center, top.radius_px, rim[1])
        else:
            top = None
            top_cand_score = 0.0
            ring_sharp = 0.0

        # Depth-From-Focus bonus: when a genuine focus sweep exists, interior
        # water surfaces are strictly deeper than the rim plane (lp > min_lp + 0.08).
        dff_bonus = 0.0
        if has_focus_sweep and lp is not None and min_lp is not None:
            is_rim_plane = (lp <= min_lp + 0.06)
            if top is not None and (top.radius_px / max(rim[1], 1e-6)) < 0.80:
                dff_bonus = -0.18 if is_rim_plane else 0.08
            elif is_rim_plane and per_frame_sharp[idx] < max_sharp * 0.85:
                dff_bonus = -0.10

        ring_sharp_norm = min(1.0, ring_sharp / max(max_sharp * 1.5, 1.0))
        combined = 0.45 * sharp_norm + 0.35 * top_cand_score + 0.20 * ring_sharp_norm + dff_bonus
        if combined > best_combined:
            best_combined = combined
            best_idx = idx

    sel_bgr, sel_rim, sel_focal, sel_lp = refined_frames[best_idx]
    return FocusSelectionResult(
        selected_index=best_idx,
        selected_bgr=sel_bgr,
        selected_rim=sel_rim,
        selected_focal_px=sel_focal,
        selected_lens_position=sel_lp,
        candidates=per_frame_candidates[best_idx],
        frame_count=len(refined_frames),
        base_interior_sharpness=per_frame_sharp[0],
        selected_interior_sharpness=per_frame_sharp[best_idx],
        per_frame_sharpness=per_frame_sharp,
    )
