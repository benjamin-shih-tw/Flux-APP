"""All-in-focus fusion for multi-focus top-down bottle captures.

When an iPhone wide camera focuses on a bottle rim at ~12 cm, its shallow
depth of field leaves the deeper water surface out of focus. After locking
the rim in frame 0, the app sweeps the lens through interior focus distances.
This module aligns those frames into frame 0's rim coordinates and fuses them
into one sharp image spanning both the rim and the interior water surface.
"""

from __future__ import annotations

from dataclasses import dataclass
import math

import cv2
import numpy as np


@dataclass(frozen=True)
class FocusFrame:
    image_bgr: np.ndarray
    rim: tuple[tuple[float, float], float]
    lens_position: float | None = None


@dataclass
class FocusStackResult:
    fused_bgr: np.ndarray
    frame_count: int
    base_interior_sharpness: float
    fused_interior_sharpness: float
    aligned_grays: list[np.ndarray]
    lens_positions: list[float | None]

    @property
    def sharpness_gain(self) -> float:
        if self.base_interior_sharpness <= 1e-6:
            return 1.0
        return float(self.fused_interior_sharpness / self.base_interior_sharpness)


def _interior_sharpness(gray: np.ndarray, rim: tuple[tuple[float, float], float]) -> float:
    (cx, cy), r = rim
    h, w = gray.shape[:2]
    yy, xx = np.ogrid[:h, :w]
    dist = np.hypot(xx - cx, yy - cy)
    mask = (dist >= r * 0.25) & (dist <= r * 0.88)
    if not np.any(mask):
        return 0.0
    lap = cv2.Laplacian(gray, cv2.CV_32F, ksize=3)
    return float(np.var(lap[mask]))


def align_frame_to_rim(
    image_bgr: np.ndarray,
    src_rim: tuple[tuple[float, float], float],
    dst_rim: tuple[tuple[float, float], float],
    dst_shape: tuple[int, int],
) -> np.ndarray | None:
    """Warp ``image_bgr`` so ``src_rim`` coincides with ``dst_rim``.

    Compensates both optical focus breathing (focal-length shift across lens
    positions) and small hand drift during the focus sweep.
    """
    (sx, sy), sr = src_rim
    (dx, dy), dr = dst_rim
    if sr <= 10.0 or dr <= 10.0:
        return None
    scale = dr / sr
    if not (0.75 <= scale <= 1.35):
        return None
    if math.hypot(dx - sx, dy - sy) > dr * 0.50:
        return None

    dst_h, dst_w = dst_shape
    matrix = np.array(
        [
            [scale, 0.0, dx - scale * sx],
            [0.0, scale, dy - scale * sy],
        ],
        dtype=np.float32,
    )
    return cv2.warpAffine(
        image_bgr,
        matrix,
        (dst_w, dst_h),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_REPLICATE,
    )


def _local_sharpness_energy(gray: np.ndarray, sigma: float) -> np.ndarray:
    gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    lap = cv2.Laplacian(gray, cv2.CV_32F, ksize=3)
    energy = gx * gx + gy * gy + 0.5 * lap * lap
    ksize = max(5, int(round(sigma * 3)) * 2 + 1)
    return cv2.GaussianBlur(energy, (ksize, ksize), sigma)


def fuse_focus_stack(
    base_bgr: np.ndarray,
    base_rim: tuple[tuple[float, float], float],
    extra_frames: list[FocusFrame],
    base_lens_position: float | None = None,
) -> FocusStackResult:
    """Fuse ``base_bgr`` (sharp rim) and interior focus frames into one sharp image."""
    h, w = base_bgr.shape[:2]
    base_gray = cv2.cvtColor(base_bgr, cv2.COLOR_BGR2GRAY)
    base_sharp = _interior_sharpness(base_gray, base_rim)

    aligned_bgrs: list[np.ndarray] = [base_bgr]
    aligned_grays: list[np.ndarray] = [base_gray]
    lens_positions: list[float | None] = [base_lens_position]

    for item in extra_frames:
        warped = align_frame_to_rim(item.image_bgr, item.rim, base_rim, (h, w))
        if warped is None:
            continue
        aligned_bgrs.append(warped)
        aligned_grays.append(cv2.cvtColor(warped, cv2.COLOR_BGR2GRAY))
        lens_positions.append(item.lens_position)

    if len(aligned_bgrs) == 1:
        return FocusStackResult(
            fused_bgr=base_bgr,
            frame_count=1,
            base_interior_sharpness=base_sharp,
            fused_interior_sharpness=base_sharp,
            aligned_grays=aligned_grays,
            lens_positions=lens_positions,
        )

    # Compute smooth weight maps at a bounded working resolution for speed,
    # then upsample weights to full sensor resolution.
    work_scale = min(1.0, 960.0 / max(h, w))
    work_w = max(64, round(w * work_scale))
    work_h = max(64, round(h * work_scale))
    (cx, cy), r = base_rim
    work_cx, work_cy, work_r = cx * work_scale, cy * work_scale, r * work_scale

    yy_w, xx_w = np.ogrid[:work_h, :work_w]
    dist_w = np.hypot(xx_w - work_cx, yy_w - work_cy).astype(np.float32)
    interior_mask_w = (dist_w >= work_r * 0.20) & (dist_w <= work_r * 0.90)

    work_grays = [
        cv2.resize(g, (work_w, work_h), interpolation=cv2.INTER_AREA).astype(np.float32)
        if work_scale < 1.0
        else g.astype(np.float32)
        for g in aligned_grays
    ]

    # Match minor exposure drift across interior focus frames to avoid brightness
    # seams while preserving local contrast.
    interior_means = [
        float(np.mean(wg[interior_mask_w])) if np.any(interior_mask_w) else 128.0
        for wg in work_grays
    ]
    target_mean = float(np.median(interior_means))
    gains: list[float] = []
    for mean_val in interior_means:
        gain = target_mean / max(mean_val, 10.0)
        gains.append(float(min(1.30, max(0.75, gain))))

    sigma = max(4.0, work_r * 0.045)
    energies = [
        _local_sharpness_energy(wg * gain, sigma)
        for wg, gain in zip(work_grays, gains)
    ]

    # Winner-biased power weighting selects the sharpest depth layer at each
    # location while transitioning smoothly between depths.
    eps = 1e-2
    stacked_e = np.stack(energies, axis=0)
    max_e = np.maximum(np.max(stacked_e, axis=0, keepdims=True), eps)
    normalized = np.clip(stacked_e / max_e, 0.0, 1.0)
    powered = np.power(normalized + 1e-3, 3.0)
    weights_w = powered / np.sum(powered, axis=0, keepdims=True)

    # Outside the inner lip (dist >= 0.96 * R), smoothly lock to frame 0 so the
    # bottle rim and outer frame retain frame 0's exact sharpness and alignment.
    rim_blend = np.clip((dist_w - work_r * 0.90) / max(work_r * 0.08, 2.0), 0.0, 1.0)
    for idx in range(len(aligned_bgrs)):
        if idx == 0:
            weights_w[idx] = weights_w[idx] * (1.0 - rim_blend) + rim_blend
        else:
            weights_w[idx] = weights_w[idx] * (1.0 - rim_blend)

    fused = np.zeros((h, w, 3), dtype=np.float32)
    for idx, (frame_bgr, gain) in enumerate(zip(aligned_bgrs, gains)):
        weight_full = (
            cv2.resize(weights_w[idx], (w, h), interpolation=cv2.INTER_LINEAR)
            if work_scale < 1.0
            else weights_w[idx]
        )
        # Apply gentle luminance matching only inside the interior; keep frame 0
        # untouched outside the rim.
        if idx == 0:
            adjusted = frame_bgr.astype(np.float32)
        else:
            adjusted = np.clip(frame_bgr.astype(np.float32) * gain, 0.0, 255.0)
        fused += adjusted * weight_full[:, :, None]

    fused_u8 = np.clip(np.rint(fused), 0, 255).astype(np.uint8)
    fused_gray = cv2.cvtColor(fused_u8, cv2.COLOR_BGR2GRAY)
    fused_sharp = _interior_sharpness(fused_gray, base_rim)

    return FocusStackResult(
        fused_bgr=fused_u8,
        frame_count=len(aligned_bgrs),
        base_interior_sharpness=base_sharp,
        fused_interior_sharpness=fused_sharp,
        aligned_grays=aligned_grays,
        lens_positions=lens_positions,
    )


def candidate_peak_lens_position(
    aligned_grays: list[np.ndarray],
    lens_positions: list[float | None],
    center: tuple[float, float],
    radius_px: float,
    outer_radius_px: float,
) -> float | None:
    """Return the lens position that maximized sharpness along a candidate ring."""
    if len(aligned_grays) < 2 or len(aligned_grays) != len(lens_positions):
        return None
    h, w = aligned_grays[0].shape[:2]
    cx, cy = center
    band = max(4.0, outer_radius_px * 0.03)
    y0 = max(0, int(math.floor(cy - radius_px - band - 2)))
    y1 = min(h, int(math.ceil(cy + radius_px + band + 2)))
    x0 = max(0, int(math.floor(cx - radius_px - band - 2)))
    x1 = min(w, int(math.ceil(cx + radius_px + band + 2)))
    if y1 - y0 < 8 or x1 - x0 < 8:
        return None

    yy, xx = np.ogrid[y0:y1, x0:x1]
    dist = np.hypot(xx - cx, yy - cy)
    ring_mask = (dist >= max(2.0, radius_px - band)) & (dist <= radius_px + band)
    if not np.any(ring_mask):
        return None

    best_score = -1.0
    best_lens: float | None = None
    for gray, lens_pos in zip(aligned_grays, lens_positions):
        if lens_pos is None:
            continue
        patch = gray[y0:y1, x0:x1]
        lap = cv2.Laplacian(patch, cv2.CV_32F, ksize=3)
        score = float(np.var(lap[ring_mask]))
        if score > best_score:
            best_score = score
            best_lens = float(lens_pos)
    return best_lens
