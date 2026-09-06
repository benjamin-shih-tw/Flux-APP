"""Phone-only echo and bottle-resonance analysis.

The iPhone recording contains five short 15--20 kHz chirps followed by a low
frequency sweep. Network and playback scheduling are never used as a time of
flight reference: every echo delay is measured from that repeat's recorded
direct arrival.
"""
from __future__ import annotations

import io
import math
import wave
from dataclasses import dataclass, field

import numpy as np
from scipy.signal import correlate, find_peaks, hilbert, peak_widths

from volume_engine import scaled_volume, total_volume_ml


PROBE_VERSION = 1
CHIRP_STARTS = np.array([0.1, 0.3, 0.5, 0.7, 0.9])
CHIRP_DURATION = 0.001
LOW_START, LOW_DURATION = 1.2, 0.3


def chirp(sample_rate: int, start_hz: float = 15_000.0,
          end_hz: float = 20_000.0,
          duration: float = CHIRP_DURATION) -> np.ndarray:
    """Generate the exact Hann-windowed probe used by the iOS capture code."""
    count = max(2, round(sample_rate * duration))
    t = np.arange(count) / sample_rate
    phase = 2 * np.pi * (start_hz * t + (end_hz - start_hz) * t * t / (2 * duration))
    return np.sin(phase) * np.hanning(count)


def read_pcm_wav(raw: bytes) -> tuple[np.ndarray, int]:
    """Read a bounded mono PCM16 WAV uploaded by the phone."""
    if len(raw) > 2_000_000:
        raise ValueError("Audio exceeds 2 MB.")
    try:
        with wave.open(io.BytesIO(raw), "rb") as wav:
            rate = wav.getframerate()
            if wav.getnchannels() != 1 or wav.getsampwidth() != 2 or wav.getcomptype() != "NONE":
                raise ValueError("Use mono, uncompressed PCM16 WAV.")
            if rate not in (44_100, 48_000) or not 1.8 * rate <= wav.getnframes() <= 3 * rate:
                raise ValueError("Use 44.1/48 kHz audio lasting 1.8--3 seconds.")
            data = wav.readframes(wav.getnframes())
            if len(data) != wav.getnframes() * 2:
                raise ValueError("Truncated WAV recording.")
    except (wave.Error, EOFError) as exc:
        raise ValueError("Invalid PCM WAV.") from exc

    samples = np.frombuffer(data, dtype="<i2").astype(np.float64) / 32768.0
    if np.mean(np.abs(samples) >= 0.995) > 0.001:
        raise ValueError("Recording clipped; reduce playback volume and retry.")
    return samples, rate


@dataclass
class AcousticEstimate:
    remaining_volume_ml: float | None = None
    water_depth_cm: float | None = None
    confidence: float = 0.0
    method_used: str = "acoustic_unavailable"
    debug_notes: list[str] = field(default_factory=list)
    echo_snr_db: float | None = None
    resonance_snr_db: float | None = None
    resonance_frequency_hz: float | None = None
    resonance_volume_ml: float | None = None
    echo_delays_ms: list[float] = field(default_factory=list)
    accepted_repeats: int = 0
    requires_retake: bool = False


class AcousticEstimator:
    """Estimate the water depth from repeated echo measurements."""

    def estimate(
        self,
        samples: np.ndarray | None = None,
        sample_rate: int = 48_000,
        *,
        profile=None,
        bottle_height_cm: float = 20.0,
        bottle_volume_ml: float = 500.0,
        phone_to_rim_cm: float | None = None,
        opening_diameter_cm: float = 7.0,
        neck_length_cm: float | None = None,
        temperature_c: float = 20.0,
        speaker_offset_cm: float = 0.0,
        microphone_offset_cm: float = 0.0,
        direct_path_cm: float = 0.0,
    ) -> AcousticEstimate:
        result = AcousticEstimate()
        if samples is None:
            result.debug_notes.append("No acoustic recording supplied.")
            return result
        if profile is None or phone_to_rim_cm is None:
            result.debug_notes.append("A current camera-to-rim distance and bottle profile are required.")
            return result
        if len(samples) < round(1.8 * sample_rate):
            result.debug_notes.append("The acoustic recording is too short.")
            return result

        sound_speed_cm_s = (331.3 + 0.606 * temperature_c) * 100.0
        probe = chirp(sample_rate)
        correlation = correlate(samples, probe, mode="valid", method="fft")
        envelope = np.abs(hilbert(correlation))
        if not len(envelope) or float(np.max(envelope)) <= 1e-9:
            result.debug_notes.append("The recorded probe is too quiet to analyse.")
            return result

        first = self._first_direct_arrival(envelope, sample_rate)
        if first is None:
            result.debug_notes.append("Direct chirp not detected.")
            return result

        def water_path(depth_cm: float) -> float:
            vertical = phone_to_rim_cm + depth_cm
            return (
                math.hypot(vertical, speaker_offset_cm)
                + math.hypot(vertical, microphone_offset_cm)
            )

        rim_path = water_path(0.0)
        bottom_path = water_path(bottle_height_cm)
        if not 0 <= direct_path_cm < rim_path or bottom_path <= rim_path:
            result.debug_notes.append("Acoustic port geometry is inconsistent with the bottle model.")
            return result

        min_lag = max(1, math.ceil((rim_path - direct_path_cm) / sound_speed_cm_s * sample_rate))
        max_lag = math.floor((bottom_path - direct_path_cm) / sound_speed_cm_s * sample_rate)
        guard = max(4, math.ceil(2 * sample_rate / 5_000))
        noise = max(float(np.median(np.abs(correlation))) * 1.4826, 1e-8)

        depths: list[float] = []
        delays: list[float] = []
        snrs: list[float] = []
        for relative_start in CHIRP_STARTS - CHIRP_STARTS[0]:
            expected = first + round(float(relative_start) * sample_rate)
            direct = self._local_peak(envelope, expected, round(0.006 * sample_rate))
            if direct is None:
                continue

            start = direct + min_lag
            stop = min(len(correlation), direct + max_lag + 1)
            if stop - start <= guard * 2:
                continue
            window = np.abs(correlation[start:stop])
            peaks, _ = find_peaks(
                window,
                distance=guard,
                prominence=max(noise * 2.0, 1e-8),
            )
            if not len(peaks):
                continue
            ranked = sorted((int(peak), float(window[peak])) for peak in peaks)
            ranked.sort(key=lambda item: item[1], reverse=True)
            best_peak, best_level = ranked[0]
            if len(ranked) > 1 and ranked[1][1] >= best_level * 0.75:
                # A reflection and a meniscus can both be strong. Do not guess.
                continue
            snr = 20.0 * math.log10(max(best_level, 1e-9) / noise)
            direct_level = max(float(envelope[direct]), 1e-9)
            if snr < 12.0 or best_level < direct_level * 0.012:
                continue

            lag_samples = min_lag + best_peak
            measured_path = lag_samples / sample_rate * sound_speed_cm_s + direct_path_cm
            depth = self._invert_path(measured_path, water_path, bottle_height_cm)
            if depth is None:
                continue
            depths.append(depth)
            delays.append(lag_samples / sample_rate * 1_000.0)
            snrs.append(snr)

        if len(depths) < 3:
            result.debug_notes.append("Fewer than three unambiguous echoes; reposition and retry.")
            return result

        values = np.asarray(depths, dtype=np.float64)
        median = float(np.median(values))
        mad = float(np.median(np.abs(values - median)))
        tolerance = max(1.5, 3.0 * mad)
        keep = np.abs(values - median) <= tolerance
        if int(np.sum(keep)) < 3 or float(np.ptp(values[keep])) > 4.0:
            result.debug_notes.append("Echo distances are not repeatable.")
            return result

        depth = float(np.median(values[keep]))
        result.water_depth_cm = depth
        result.remaining_volume_ml = scaled_volume(profile, bottle_height_cm - depth, bottle_volume_ml)
        result.echo_snr_db = float(np.median(np.asarray(snrs)[keep]))
        result.echo_delays_ms = np.asarray(delays)[keep].round(4).tolist()
        result.accepted_repeats = int(np.sum(keep))
        result.confidence = min(
            0.88,
            0.56 + 0.035 * (result.accepted_repeats - 3)
            + 0.006 * max(result.echo_snr_db - 12.0, 0.0),
        )
        result.method_used = "acoustic_echo"

        self._analyse_resonance(
            samples, sample_rate, first, result, profile, bottle_height_cm,
            bottle_volume_ml, opening_diameter_cm, neck_length_cm, sound_speed_cm_s,
        )
        return result

    @staticmethod
    def _first_direct_arrival(envelope: np.ndarray, rate: int) -> int | None:
        search = envelope[:min(len(envelope), round(0.45 * rate))]
        if len(search) < 4:
            return None
        peaks, _ = find_peaks(
            search,
            height=max(float(np.max(search)) * 0.25, 1e-8),
            distance=max(1, round(0.01 * rate)),
        )
        return int(peaks[0]) if len(peaks) else None

    @staticmethod
    def _local_peak(values: np.ndarray, expected: int, radius: int) -> int | None:
        start = max(0, expected - radius)
        stop = min(len(values), expected + radius + 1)
        if stop <= start:
            return None
        return start + int(np.argmax(values[start:stop]))

    @staticmethod
    def _invert_path(target: float, path, height: float) -> float | None:
        low, high = 0.0, height
        if target < path(low) - 1e-6 or target > path(high) + 1e-6:
            return None
        for _ in range(45):
            middle = (low + high) / 2.0
            if path(middle) < target:
                low = middle
            else:
                high = middle
        return (low + high) / 2.0

    def _analyse_resonance(
        self, samples: np.ndarray, rate: int, first: int, result: AcousticEstimate,
        profile, height: float, capacity: float, diameter: float, neck: float | None,
        sound_speed_cm_s: float,
    ) -> None:
        offset = first - round(float(CHIRP_STARTS[0]) * rate)
        start = offset + round((LOW_START + LOW_DURATION + 0.01) * rate)
        end = min(len(samples), start + round(0.18 * rate))
        quiet = samples[max(0, first - round(0.08 * rate)):max(0, first - round(0.02 * rate))]
        if start < 0 or end <= start or len(quiet) < 100:
            return

        tail = samples[start:end]
        nfft = max(16_384, 2 ** int(math.ceil(math.log2(len(tail)))))
        spectrum = np.abs(np.fft.rfft(tail * np.hanning(len(tail)), nfft)) ** 2
        frequencies = np.fft.rfftfreq(nfft, 1 / rate)
        band = (frequencies > 100) & (frequencies < 3_000)
        peaks, _ = find_peaks(
            spectrum,
            prominence=max(float(np.median(spectrum[band])) * 2, 1e-12),
        )
        peaks = [int(p) for p in peaks if band[p]]
        if not peaks:
            return

        peak = max(peaks, key=lambda index: spectrum[index])
        frequency = float(frequencies[peak])
        floor = max(float(np.median(spectrum[band])), 1e-12)
        temporal_snr = 10 * math.log10(
            max(float(np.mean(tail ** 2)), 1e-12)
            / max(float(np.mean(quiet ** 2)), 1e-12)
        )
        spectral_snr = 10 * math.log10(max(float(spectrum[peak]), 1e-12) / floor)
        snr = min(spectral_snr, temporal_snr)
        width_hz = float(peak_widths(spectrum, [peak], rel_height=0.5)[0][0] * rate / nfft)
        result.resonance_frequency_hz = frequency
        result.resonance_snr_db = snr
        if snr < 10 or frequency / max(width_hz, 1.0) < 5:
            result.debug_notes.append("Resonance peak has insufficient SNR or sharpness.")
            return
        if neck is None or neck <= 0:
            result.debug_notes.append("Resonance recorded; a measured neck length is needed for volume cross-check.")
            return

        radius = diameter / 2.0
        if radius > 0.6 * max(point.radius_cm for point in profile) or result.water_depth_cm <= neck:
            result.debug_notes.append("Resonance excluded: no suitable narrow, dry neck.")
            return

        effective_length = neck + 1.7 * radius
        air_volume = (
            math.pi * radius ** 2 / effective_length
            * (sound_speed_cm_s / (2 * math.pi * frequency)) ** 2
        )
        total = total_volume_ml(profile)
        if not 0 < air_volume < total:
            result.debug_notes.append("Resonance air volume lies outside bottle geometry.")
            return

        resonance_remaining = capacity * (1 - air_volume / total)
        result.resonance_volume_ml = resonance_remaining
        if abs(resonance_remaining - result.remaining_volume_ml) > max(40, capacity * 0.20):
            result.requires_retake = True
            result.confidence = 0.0
            result.debug_notes.append("Echo and resonance disagree; repeat measurement.")
        else:
            result.method_used += "+resonance_checked"
            result.confidence = min(0.92, result.confidence + 0.05)
