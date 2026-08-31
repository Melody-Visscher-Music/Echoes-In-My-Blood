#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Beatmap Analyzer -- BeatNet + Librosa fusion.

Built for Rawstyle / hard dance, where generic beat trackers fail: gated kicks,
heavy distortion, reversed basslines and fake drops swamp ordinary onset
detectors, which see a wall of noise instead of a clean transient.

The fusion, and why each half is here:

  BeatNet   supplies the macro grid. Its CNN+DBN is rock solid on tempo and bar
            phase, but its frames are 20 ms wide, so its beat times are far too
            coarse to place notes against, and it knows nothing about structure.

  Librosa   supplies everything BeatNet lacks: a frequency-band split that
            separates the kick from the screech from the hats, sample-accurate
            transient snapping, and the structural read (drops, buildups,
            breakdowns, fake drops, gated-kick rolls).

Pipeline:
    1. decode -> mono float32 at 44.1 kHz (analysis) + 22.05 kHz wav (BeatNet)
    2. BeatNet offline DBN            -> tempo seed + bar phase
    3. DFT comb on the kick band      -> exact global BPM
    4. librosa DP tracker, kick band  -> per-beat placement that follows the kick
    5. transient snap                 -> sample-accurate beat times
    6. band-split onset detection     -> kick / mid / high events
    7. structural read                -> sections, drops, gated kicks, screeches
    8. map generation                 -> playable notes on the fused grid

CLI (this is how Godot drives it):
    python BeatmapAnalyzer.py --cli --audio SONG --out OUT.json \
        --progress-file P.json --cancel-file C.json --mapgen --map-diff 6
"""

from __future__ import annotations

import os
import sys
import json
import time
import math
import ctypes
import hashlib
import argparse
import traceback
import warnings
from dataclasses import dataclass, asdict, field
from typing import Optional, List, Dict, Any, Tuple, Callable

warnings.filterwarnings("ignore")

# ============================================================
# Identity
# ============================================================

APP_NAME = "Beatmap Analyzer"
APP_VERSION = "v1.0.0-fusion"
APP_ID = "%s %s" % (APP_NAME, APP_VERSION)
SCHEMA = "beatmap_analyzer_v3"

ProgressCB = Callable[[int, str], None]

SCRIPT_DIR = os.path.abspath(os.path.dirname(os.path.abspath(__file__)))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
DEFAULT_OUT_DIR = os.path.join(PROJECT_ROOT, "data", "Analysis")
CACHE_DIR = os.path.join(SCRIPT_DIR, ".cache")

# The fusion venv. Kept first so we never accidentally relaunch into the old
# madmom-only environment.
VENV_NAMES = (".venv-fusion",)


# ============================================================
# Venv bootstrap
# ============================================================

def _venv_python(venv_dir: str) -> Optional[str]:
    for rel in (("Scripts", "python.exe"), ("bin", "python")):
        p = os.path.join(venv_dir, *rel)
        if os.path.isfile(p):
            return p
    return None


def find_fusion_python() -> Optional[str]:
    for name in VENV_NAMES:
        p = _venv_python(os.path.join(SCRIPT_DIR, name))
        if p:
            return p
    return None


def _have_stack() -> bool:
    try:
        import numpy  # noqa: F401
        import librosa  # noqa: F401
        from BeatNet.BeatNet import BeatNet  # noqa: F401
        return True
    except Exception:
        return False


def relaunch_into_venv_if_needed() -> None:
    """If the current interpreter can't import the stack, re-exec in the venv."""
    if os.environ.get("BEATMAP_ANALYZER_RELAUNCHED") == "1":
        return
    if _have_stack():
        return
    py = find_fusion_python()
    if not py or os.path.normcase(py) == os.path.normcase(sys.executable):
        return
    env = dict(os.environ)
    env["BEATMAP_ANALYZER_RELAUNCHED"] = "1"
    import subprocess
    try:
        sys.exit(subprocess.call([py, os.path.abspath(__file__)] + sys.argv[1:], env=env))
    except SystemExit:
        raise
    except Exception:
        return


# ============================================================
# Progress / crash reporting
# ============================================================

def write_progress_file(path: Optional[str], pct: int, msg: str,
                        extra: Optional[Dict[str, Any]] = None) -> None:
    if not path:
        return
    try:
        payload: Dict[str, Any] = {
            "pct": int(max(0, min(100, int(pct)))),
            "msg": str(msg),
            "t": time.time(),
        }
        if extra:
            payload.update(extra)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
        os.replace(tmp, path)
    except Exception:
        pass


def _crash_log(text: str) -> str:
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        p = os.path.join(CACHE_DIR, "crash_%s.log" % time.strftime("%Y%m%d_%H%M%S"))
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
        return p
    except Exception:
        return ""


def _safe_mkdir(p: str) -> None:
    if p:
        try:
            os.makedirs(p, exist_ok=True)
        except Exception:
            pass


def _audio_hash(path: str) -> str:
    h = hashlib.sha1()
    try:
        st = os.stat(path)
        h.update(os.path.basename(path).encode("utf-8", "ignore"))
        h.update(str(st.st_size).encode())
        h.update(str(int(st.st_mtime)).encode())
        with open(path, "rb") as f:
            h.update(f.read(1 << 20))
    except Exception:
        h.update(path.encode("utf-8", "ignore"))
    return h.hexdigest()[:16]


# ============================================================
# Config
# ============================================================

@dataclass
class AnalysisConfig:
    min_bpm: float = 120.0
    max_bpm: float = 200.0
    time_signature: int = 4
    # Rawstyle band split (Hz). The kick lives in sub+punch; screeches in mid.
    sub_band: Tuple[float, float] = (35.0, 120.0)
    punch_band: Tuple[float, float] = (120.0, 260.0)
    mid_band: Tuple[float, float] = (700.0, 3500.0)
    high_band: Tuple[float, float] = (5000.0, 12000.0)
    snap_window_ms: float = 18.0
    onset_delta: float = 0.055
    tightness: float = 400.0
    use_beatnet: bool = True
    quick_seconds: int = 0
    auto: bool = True
    # Filled in by auto_tune(): per-band onset thresholds. Empty means "use
    # onset_delta for every band".
    band_deltas: Dict[str, float] = field(default_factory=dict)


@dataclass
class MapGenConfig:
    enabled: bool = True
    difficulty: int = 5
    lane_count: int = 4
    seed: int = 0
    min_gap_ms: int = 85
    allow_chords: bool = False
    chord_prob: float = 0.18
    allow_triplets: bool = True


@dataclass
class FusionResult:
    ok: bool = False
    bpm: Optional[float] = None
    beats: List[float] = field(default_factory=list)
    downbeats: List[float] = field(default_factory=list)
    onsets: List[Dict[str, Any]] = field(default_factory=list)
    bars: List[Dict[str, Any]] = field(default_factory=list)
    sections: List[Dict[str, Any]] = field(default_factory=list)
    offset_correction_s: float = 0.0
    duration_s: float = 0.0
    notes: str = ""
    error: Optional[str] = None
    extra: Dict[str, Any] = field(default_factory=dict)
    # The config actually used, after auto-tuning. Reported instead of the
    # requested one so the JSON never claims settings that were overridden.
    config_used: Optional["AnalysisConfig"] = None
    # In-process only, never serialised: the band bank, so map generation can
    # ask how much energy each grid slot actually has.
    bands: Any = None


# ============================================================
# Audio + band-split features
# ============================================================

ANALYSIS_SR = 44100
BEATNET_SR = 22050
HOP = 128          # 2.9 ms at 44.1 kHz. Accuracy is worth the extra work.
NFFT = 1024


class Bands:
    """Frequency-split feature bank.

    The low bands are filtered in the time domain rather than read off the
    STFT. At any FFT size cheap enough to run at this hop, a 35-120 Hz kick
    occupies two or three bins -- far too coarse to time a transient. A
    zero-phase Butterworth bandpass keeps full sample resolution and, being
    zero-phase, introduces no group delay that would shift every kick late.

    The mid and high bands have no such problem, so they come off one STFT.
    `flux_*` are half-wave-rectified: rise-only energy change, which is what
    an onset physically is.
    """

    def __init__(self, y, sr: int, cfg: AnalysisConfig):
        import numpy as np
        import librosa

        self.sr = int(sr)
        self.hop = HOP
        self.fps = float(sr) / float(HOP)
        self.y = y
        self.duration = float(len(y)) / float(sr)

        S = np.abs(librosa.stft(y, n_fft=NFFT, hop_length=HOP)).astype(np.float32)
        self.S = S
        self.freqs = librosa.fft_frequencies(sr=sr, n_fft=NFFT)
        self.n_frames = S.shape[1]
        self.times = librosa.frames_to_time(
            np.arange(self.n_frames), sr=sr, hop_length=HOP)

        def stft_band(lo: float, hi: float):
            m = (self.freqs >= lo) & (self.freqs < hi)
            if not m.any():
                m = np.zeros_like(self.freqs, dtype=bool)
                m[min(1, len(m) - 1)] = True
            return S[m, :].sum(axis=0).astype(np.float64)

        self.e_sub = self._time_band(y, sr, *cfg.sub_band)
        self.e_punch = self._time_band(y, sr, *cfg.punch_band)
        self.e_mid = stft_band(*cfg.mid_band)
        self.e_high = stft_band(*cfg.high_band)
        self.e_all = S.sum(axis=0).astype(np.float64)

        self.flux_sub = self._flux(self.e_sub)
        self.flux_punch = self._flux(self.e_punch)
        self.flux_mid = self._flux(self.e_mid)
        self.flux_high = self._flux(self.e_high)
        self.flux_all = self._flux(self.e_all)

        # Kick drive: sub and punch rising together. The product suppresses
        # bass-only rumble and mid-only stabs, a discrimination that a plain
        # full-band flux cannot make on a distorted track.
        self.flux_kick = self._norm(
            np.sqrt(np.maximum(self.flux_sub * self.flux_punch, 0.0)))

        # Distortion cue: Rawstyle screeches are broadband and noisy, so high
        # spectral flatness in the mid band separates a screech from a clean
        # melodic lead.
        self.flatness = librosa.feature.spectral_flatness(S=S, power=1.0)[0].astype(np.float64)
        self.rms = librosa.feature.rms(
            S=S, frame_length=NFFT, hop_length=HOP)[0].astype(np.float64)

    def _time_band(self, y, sr: int, lo: float, hi: float):
        """Zero-phase bandpass -> rectified -> smoothed -> sampled on frames."""
        import numpy as np
        from scipy.signal import butter, sosfiltfilt
        from scipy.ndimage import uniform_filter1d

        nyq = 0.5 * float(sr)
        lo_n = max(1e-4, float(lo) / nyq)
        hi_n = min(0.999, float(hi) / nyq)
        if hi_n <= lo_n:
            hi_n = min(0.999, lo_n * 1.5)
        sos = butter(4, [lo_n, hi_n], btype="band", output="sos")
        xb = sosfiltfilt(sos, np.asarray(y, dtype=np.float64))
        env = np.abs(xb)
        env = uniform_filter1d(env, size=max(3, int(0.004 * sr)))
        idx = np.arange(self.n_frames) * self.hop
        idx = np.clip(idx, 0, env.size - 1)
        return env[idx]

    @staticmethod
    def _flux(e):
        import numpy as np
        f = np.diff(e, prepend=e[0])
        f[f < 0.0] = 0.0
        return f

    @staticmethod
    def _norm(x):
        import numpy as np
        mx = float(np.max(x)) if x.size else 0.0
        return x / mx if mx > 0 else x

    def frame_at(self, t: float) -> int:
        i = int(round(float(t) * self.fps))
        return max(0, min(self.n_frames - 1, i))

    def mean_between(self, arr, t0: float, t1: float) -> float:
        import numpy as np
        a = self.frame_at(t0)
        b = max(a + 1, self.frame_at(t1))
        seg = arr[a:b]
        return float(np.mean(seg)) if seg.size else 0.0


def load_audio(path: str, quick_seconds: int = 0):
    """Decode to mono float32. librosa handles wav/flac/ogg via soundfile and
    mp3/m4a via audioread, so no ffmpeg shell-out is needed."""
    import librosa
    dur = float(quick_seconds) if quick_seconds and quick_seconds > 0 else None
    y, sr = librosa.load(path, sr=ANALYSIS_SR, mono=True, duration=dur)
    return y, int(sr)


def _write_beatnet_wav(y, sr: int, dst: str) -> str:
    import librosa
    import soundfile as sf
    import numpy as np
    y22 = librosa.resample(y, orig_sr=sr, target_sr=BEATNET_SR)
    peak = float(np.max(np.abs(y22))) if y22.size else 0.0
    if peak > 0:
        y22 = (y22 / peak) * 0.95
    sf.write(dst, y22.astype("float32"), BEATNET_SR)
    return dst


# ============================================================
# Stage 1 -- BeatNet macro grid
# ============================================================

def beatnet_grid(y, sr: int, cache_dir: str,
                 progress: Optional[ProgressCB] = None) -> Dict[str, Any]:
    """Run BeatNet offline (CNN activations + DBN decoding).

    Returns beat times and bar positions (1 == downbeat). These are quantised
    to BeatNet's 20 ms frame rate, so we use them for tempo and bar phase only
    -- never for final note placement.
    """
    import numpy as np
    out: Dict[str, Any] = {"ok": False, "beats": [], "positions": [],
                           "bpm": None, "error": None}
    tmp_wav = os.path.join(cache_dir, "beatnet_input.wav")
    try:
        _write_beatnet_wav(y, sr, tmp_wav)
        if progress:
            progress(22, "BeatNet: loading model…")
        from BeatNet.BeatNet import BeatNet
        est = BeatNet(1, mode="offline", inference_model="DBN",
                      plot=[], thread=False, device="cpu")
        if progress:
            progress(26, "BeatNet: decoding beat grid…")
        raw = np.asarray(est.process(tmp_wav))
        if raw.ndim != 2 or raw.shape[0] < 4:
            out["error"] = "BeatNet returned too few beats."
            return out
        beats = raw[:, 0].astype(float)
        pos = raw[:, 1].astype(int)
        ibi = np.diff(beats)
        ibi = ibi[(ibi > 0.15) & (ibi < 1.2)]
        if ibi.size < 3:
            out["error"] = "BeatNet beat spacing implausible."
            return out
        out["ok"] = True
        out["beats"] = beats.tolist()
        out["positions"] = pos.tolist()
        out["bpm"] = float(60.0 / float(np.median(ibi)))
    except Exception:
        out["error"] = traceback.format_exc()[-4000:]
    finally:
        try:
            if os.path.isfile(tmp_wav):
                os.remove(tmp_wav)
        except Exception:
            pass
    return out


# ============================================================
# Stage 2 -- exact tempo from the kick band
# ============================================================

def _decimate_env(env, fps: float, target_fps: float = 200.0):
    """Shrink an envelope for tempo work.

    Tempo is a property of the whole track, so it does not need transient
    resolution -- but the correlation cost is linear in frame count, and at
    2.9 ms frames a five-minute track is 100k samples per candidate tempo.
    Block-summing to ~5 ms preserves every periodicity below 100 BPM-equivalent
    while cutting the work by an order of magnitude.
    """
    import numpy as np
    env = np.asarray(env, dtype=np.float64)
    factor = max(1, int(round(float(fps) / float(target_fps))))
    if factor <= 1:
        return env, float(fps)
    n = (env.size // factor) * factor
    if n <= 0:
        return env, float(fps)
    small = env[:n].reshape(-1, factor).sum(axis=1)
    return small, float(fps) / float(factor)


def _dft_scan(env, fps: float, bpm_lo: float, bpm_hi: float, n: int):
    import numpy as np
    t = np.arange(env.size) / float(fps)
    bpms = np.linspace(float(bpm_lo), float(bpm_hi), int(n))
    mag = np.empty(bpms.size)
    ang = np.empty(bpms.size)
    step = 512
    for i in range(0, bpms.size, step):
        chunk = bpms[i:i + step]
        z = np.exp(-2j * np.pi * np.outer(chunk / 60.0, t)) @ env
        mag[i:i + step] = np.abs(z)
        ang[i:i + step] = np.angle(z)
    return bpms, mag, ang


def dft_tempo(env, fps: float, bpm_lo: float, bpm_hi: float,
              n: int = 4000) -> Tuple[float, float, float]:
    """Comb/DFT tempo estimate, coarse to fine.

    Correlating the kick envelope against a complex exponential at each
    candidate tempo yields, in one shot, how periodic the track is at that
    tempo (magnitude) and where beat one sits (phase), weighted by onset
    strength. Over a full track this resolves tempo far finer than counting
    inter-beat intervals -- which BeatNet's 20 ms frames cap at roughly 2 BPM.

    The scan runs twice: coarse over the whole range, then a narrow refinement
    around the winner at full precision.
    """
    import numpy as np
    env = np.asarray(env, dtype=np.float64)
    if env.size < 16:
        return (0.0, 0.0, 0.0)

    small, sfps = _decimate_env(env, fps)
    total = float(np.sum(small)) + 1e-9

    bpms, mag, ang = _dft_scan(small, sfps, bpm_lo, bpm_hi, n)
    k = int(np.argmax(mag))
    coarse = float(bpms[k])

    span = max(0.6, (float(bpm_hi) - float(bpm_lo)) / float(n) * 8.0)
    b2, m2, a2 = _dft_scan(small, sfps,
                           max(float(bpm_lo), coarse - span),
                           min(float(bpm_hi), coarse + span), 3000)
    k2 = int(np.argmax(m2))
    if m2[k2] >= mag[k]:
        return (float(b2[k2]), float(m2[k2] / total), float(a2[k2]))
    return (coarse, float(mag[k] / total), float(ang[k]))


def refine_tempo(bands: Bands, cfg: AnalysisConfig,
                 seed_bpm: Optional[float]) -> Dict[str, Any]:
    """Lock the exact BPM, using BeatNet's estimate only to pick the octave."""
    import numpy as np

    env = bands.flux_kick
    if float(np.sum(env)) <= 0:
        env = Bands._norm(bands.flux_all)

    lo, hi = float(cfg.min_bpm), float(cfg.max_bpm)
    wide_bpm, wide_mag, wide_ang = dft_tempo(env, bands.fps, lo, hi, 6000)

    chosen, mag, ang = wide_bpm, wide_mag, wide_ang
    source = "dft_wide"

    if seed_bpm and seed_bpm > 0:
        # Search tightly around BeatNet's seed and its octaves, then take
        # whichever is genuinely most periodic.
        cands = [(chosen, mag, ang, source)]
        for mult, tag in ((1.0, "dft_at_beatnet"), (0.5, "dft_half"), (2.0, "dft_double")):
            c = float(seed_bpm) * mult
            if not (lo * 0.6 <= c <= hi * 1.4):
                continue
            b, m, a = dft_tempo(env, bands.fps, max(lo * 0.6, c - 8.0),
                                min(hi * 1.4, c + 8.0), 2500)
            cands.append((b, m, a, tag))
        # A doubled tempo always scores some energy, so the seed octave only
        # loses on a clear win, not a marginal one.
        best = max(cands, key=lambda c: c[1])
        near = [c for c in cands if abs(c[0] - float(seed_bpm)) < 0.12 * float(seed_bpm)]
        if near:
            ns = max(near, key=lambda c: c[1])
            if ns[1] >= best[1] * 0.72:
                best = ns
        chosen, mag, ang, source = best

    period = 60.0 / chosen if chosen > 0 else 0.0
    phase = float(np.mod(ang / (2.0 * np.pi) * period, period)) if period > 0 else 0.0
    return {"bpm": float(chosen), "period": float(period), "phase": phase,
            "strength": float(mag), "source": source,
            "wide_bpm": float(wide_bpm), "wide_strength": float(wide_mag)}


# ============================================================
# Stage 3 -- beat placement on the kick band
# ============================================================

def track_beats(bands: Bands, cfg: AnalysisConfig, bpm: float) -> List[float]:
    """Dynamic-programming beat tracking driven by the kick band.

    Feeding the tracker the kick-drive curve instead of a full-band onset
    envelope is what makes this survive Rawstyle: the distorted mid/high wall
    never gets a vote, so screeches and reverse basses cannot pull the grid.
    """
    import numpy as np
    import librosa

    env = bands.flux_kick
    if float(np.sum(env)) <= 0:
        env = Bands._norm(bands.flux_all)

    try:
        _tempo, frames = librosa.beat.beat_track(
            onset_envelope=env, sr=bands.sr, hop_length=bands.hop,
            start_bpm=float(bpm), tightness=float(cfg.tightness),
            trim=False, units="frames")
        beats = librosa.frames_to_time(
            np.asarray(frames), sr=bands.sr, hop_length=bands.hop)
        return [float(t) for t in np.atleast_1d(beats)]
    except Exception:
        return []


def synth_grid(period: float, phase: float, duration: float) -> List[float]:
    if period <= 0:
        return []
    n = int(math.floor((duration - phase) / period)) + 1
    if n <= 0:
        return []
    return [float(phase + period * i) for i in range(n)]


def fuse_beats(tracked: List[float], period: float, phase: float,
               duration: float,
               max_dev_ratio: float = 0.28) -> Tuple[List[float], Dict[str, Any]]:
    """Reconcile the DP beats with the ideal constant-tempo grid.

    The DP tracker follows the music but wobbles and drops beats wherever the
    kick disappears (breakdowns). The ideal grid is perfectly regular but deaf.
    Using the grid as the skeleton and pulling each slot onto a nearby tracked
    beat yields a grid that is both complete and musically anchored.
    """
    import numpy as np
    ideal = synth_grid(period, phase, duration)
    if not ideal:
        return (sorted(tracked), {"mode": "tracked_only", "matched": 0})
    if not tracked:
        return (ideal, {"mode": "ideal_only", "matched": 0})

    tr = np.asarray(sorted(tracked), dtype=float)
    tol = period * float(max_dev_ratio)
    fused: List[float] = []
    matched = 0
    for g in ideal:
        j = int(np.searchsorted(tr, g))
        best = None
        bestd = 1e9
        for jj in (j - 1, j, j + 1):
            if 0 <= jj < tr.size:
                d = abs(float(tr[jj]) - g)
                if d < bestd:
                    bestd, best = d, float(tr[jj])
        if best is not None and bestd <= tol:
            fused.append(best)
            matched += 1
        else:
            fused.append(float(g))

    fused = sorted(fused)
    # Enforce spacing so a bad pull cannot collapse two beats together.
    cleaned: List[float] = []
    for t in fused:
        if cleaned and (t - cleaned[-1]) < period * 0.45:
            continue
        cleaned.append(t)
    return (cleaned, {"mode": "fused", "matched": matched,
                      "ideal": len(ideal), "tracked": len(tracked)})


def snap_to_transients(times: List[float], bands: Bands,
                       window_ms: float = 18.0) -> Tuple[List[float], float]:
    """Align a grid to the kick transients without destroying its regularity.

    Snapping each beat independently to its nearest flux peak looks right per
    beat and is wrong overall: neighbouring kick-roll hits pull individual
    beats off by up to the window width, and the grid ends up jittering by more
    than it was ever misaligned. Electronic tracks are machine-timed, so the
    true correction is smooth -- a fixed latency plus, at most, slow drift.

    So we measure the per-beat deviation, then apply a running median of it.
    Outliers (a beat that landed on a roll hit) are voted down by their
    neighbours, while a genuine shared offset survives intact.
    """
    import numpy as np
    if not times:
        return ([], 0.0)

    env = bands.flux_kick
    w = max(1, int(round((float(window_ms) / 1000.0) * bands.fps)))
    n = len(times)

    devs = np.full(n, np.nan, dtype=float)
    floor = float(np.percentile(env, 90)) * 0.15
    for i, t in enumerate(times):
        c = bands.frame_at(t)
        a = max(0, c - w)
        b = min(bands.n_frames, c + w + 1)
        if b - a < 2:
            continue
        seg = env[a:b]
        peak = float(np.max(seg))
        if peak <= max(1e-9, floor):
            continue          # no transient here (breakdown) -- leave the beat alone
        k = a + int(np.argmax(seg))
        devs[i] = float(k) / bands.fps - float(t)

    if not np.any(np.isfinite(devs)):
        return (list(times), 0.0)

    med = float(np.nanmedian(devs))
    smooth = _running_nanmedian(devs, win=17, fallback=med)

    out = [float(t) + float(s) for t, s in zip(times, smooth)]
    out.sort()
    return (out, med)


def _running_nanmedian(x, win: int = 17, fallback: float = 0.0):
    """Median filter that ignores gaps, so breakdowns don't drag the curve."""
    import numpy as np
    x = np.asarray(x, dtype=float)
    n = x.size
    half = max(1, int(win) // 2)
    out = np.empty(n, dtype=float)
    for i in range(n):
        a = max(0, i - half)
        b = min(n, i + half + 1)
        seg = x[a:b]
        seg = seg[np.isfinite(seg)]
        out[i] = float(np.median(seg)) if seg.size else float(fallback)
    return out


def assign_downbeats(beats: List[float], bn_beats: List[float],
                     bn_pos: List[int], bands: Optional[Bands] = None,
                     ts: int = 4) -> Tuple[List[float], int]:
    """Carry BeatNet's bar phase onto the fused beats.

    BeatNet's downbeat call is its real strength -- it hears the bar even when
    the kick pattern gives nothing away -- so we keep its phase and re-time it
    onto our own, more accurate beats.
    """
    import numpy as np
    if not beats:
        return ([], 0)
    ts = 4 if int(ts) not in (3, 4) else int(ts)
    ba = np.asarray(beats, dtype=float)

    if bn_beats and bn_pos and len(bn_beats) == len(bn_pos):
        votes = np.zeros(ts, dtype=float)
        for t, p in zip(bn_beats, bn_pos):
            i = int(np.argmin(np.abs(ba - float(t))))
            if abs(float(ba[i]) - float(t)) < 0.18:
                votes[(i - (int(p) - 1)) % ts] += 1.0
        if float(votes.sum()) > 0:
            off = int(np.argmax(votes))
            return ([float(beats[i]) for i in range(off, len(beats), ts)], off)

    # No usable BeatNet phase: pick the offset whose beats hit hardest.
    if bands is not None:
        best_off, best_score = 0, -1.0
        for off in range(ts):
            idx = list(range(off, len(beats), ts))
            if not idx:
                continue
            s = float(np.mean([bands.flux_kick[bands.frame_at(beats[i])] for i in idx]))
            if s > best_score:
                best_score, best_off = s, off
        return ([float(beats[i]) for i in range(best_off, len(beats), ts)], best_off)

    return ([float(beats[i]) for i in range(0, len(beats), ts)], 0)


# ============================================================
# Stage 4 -- band-split onset detection
# ============================================================

# Minimum spacing per band, as a fraction of one beat. The kick can roll at
# 1/8 but never faster in practice; hats and screeches can go to 1/16.
BAND_SPEC = (
    # One kick detector, not two. Sub and punch fire together on every
    # Rawstyle kick, so peak-picking them separately double-counts each hit
    # and makes plain four-to-the-floor look like a gated roll. flux_kick is
    # already the coincidence of both, and it is the same curve the beat grid
    # is built on, so onsets and beats agree by construction.
    ("kick", "flux_kick", 0.42),
    ("mid",  "flux_mid",  0.22),
    ("high", "flux_high", 0.22),
)


def detect_band_onsets(bands: Bands, cfg: AnalysisConfig,
                       period: float) -> List[Dict[str, Any]]:
    """Peak-pick each band separately, then merge.

    Splitting first is the whole point: a full-band detector on Rawstyle sees
    the distorted kick and the screech as one continuous smear. Per band, each
    element has its own noise floor and its own plausible rate.
    """
    import numpy as np
    import librosa

    events: List[Dict[str, Any]] = []
    fps = bands.fps

    for name, attr, beat_frac in BAND_SPEC:
        env = np.asarray(getattr(bands, attr), dtype=np.float64)
        mx = float(np.max(env)) if env.size else 0.0
        if mx <= 0:
            continue
        env = env / mx

        wait = max(1, int(round(period * beat_frac * fps))) if period > 0 else 4
        try:
            pk = librosa.util.peak_pick(
                env,
                pre_max=max(1, int(0.020 * fps)),
                post_max=max(1, int(0.020 * fps)),
                pre_avg=max(1, int(0.100 * fps)),
                post_avg=max(1, int(0.100 * fps)),
                delta=float(cfg.band_deltas.get(name, cfg.onset_delta)),
                wait=wait)
        except Exception:
            continue

        for k in np.atleast_1d(np.asarray(pk, dtype=int)):
            k = int(k)
            if k < 0 or k >= env.size:
                continue
            events.append({
                "t": round(float(k) / fps, 5),
                "strength": round(float(env[k]), 4),
                "band": name,
                "src": "librosa",
            })

    events.sort(key=lambda e: (e["t"], e["band"]))
    return events


def merge_close_onsets(events: List[Dict[str, Any]],
                       eps: float = 0.012) -> List[Dict[str, Any]]:
    """De-duplicate near-simultaneous events inside each band.

    Bands stay separate: a screech landing on a kick is genuinely two things
    the chart may want to place, so only repeats within one band collapse.
    """
    if not events:
        return []

    out: List[Dict[str, Any]] = []
    for band in ("kick", "mid", "high"):
        same = sorted([e for e in events if e["band"] == band], key=lambda x: x["t"])
        keep: List[Dict[str, Any]] = []
        for e in same:
            if keep and (e["t"] - keep[-1]["t"]) <= eps:
                # Same hit seen twice: keep the earlier time (the true attack)
                # and the stronger reading.
                keep[-1]["strength"] = max(keep[-1]["strength"], e["strength"])
                continue
            keep.append(dict(e))
        out.extend(keep)

    order = {"kick": 0, "mid": 1, "high": 2}
    out.sort(key=lambda e: (e["t"], order.get(e["band"], 9)))
    return out


# ============================================================
# Auto-tuning -- derive settings from the audio instead of the user
# ============================================================

def auto_tune(bands: Bands, cfg: AnalysisConfig,
              seed_bpm: Optional[float]) -> Tuple[AnalysisConfig, Dict[str, Any]]:
    """Pick the analysis settings from the audio itself.

    Every knob here has a defensible automatic value, so leaving them to be
    guessed by hand only invites a bad tempo window or a threshold that mutes
    half the track. What each one is derived from:

      tempo window  BeatNet's own estimate, widened just enough to cover a
                    half/double error, so the DFT never has to search a range
                    the track cannot possibly be in.
      onset delta   the spread of each band's own flux distribution -- a
                    heavily limited master and a dynamic one need very
                    different absolute thresholds to mean the same thing.
      snap window   a fraction of one beat, so it scales with tempo instead of
                    being a fixed millisecond count that is generous at 120 BPM
                    and reckless at 180.
    """
    import numpy as np

    out = AnalysisConfig(**asdict(cfg))
    notes: Dict[str, Any] = {"applied": True}

    # --- tempo window ---
    if seed_bpm and seed_bpm > 0:
        lo = max(60.0, float(seed_bpm) * 0.62)
        hi = min(260.0, float(seed_bpm) * 1.62)
    else:
        # No BeatNet: fall back to librosa's own global estimate.
        try:
            import librosa
            est = float(np.atleast_1d(librosa.feature.tempo(
                onset_envelope=bands.flux_kick, sr=bands.sr,
                hop_length=bands.hop, aggregate=np.median))[0])
        except Exception:
            est = 150.0
        lo = max(60.0, est * 0.62)
        hi = min(260.0, est * 1.62)
    out.min_bpm, out.max_bpm = float(lo), float(hi)
    notes["bpm_window"] = [round(lo, 2), round(hi, 2)]

    # --- onset threshold, per band ---
    deltas: Dict[str, float] = {}
    for name, attr, _frac in BAND_SPEC:
        env = np.asarray(getattr(bands, attr), dtype=np.float64)
        mx = float(np.max(env)) if env.size else 0.0
        if mx <= 0:
            deltas[name] = float(cfg.onset_delta)
            continue
        env = env / mx
        spread = float(np.percentile(env, 96) - np.percentile(env, 55))
        deltas[name] = float(min(0.20, max(0.020, spread * 0.55)))
    out.band_deltas = deltas
    notes["band_deltas"] = {k: round(v, 4) for k, v in deltas.items()}

    return out, notes


def auto_snap_window_ms(period: float, fallback: float) -> float:
    """Snap window as a share of one beat, clamped to sane millisecond bounds."""
    if period <= 0:
        return float(fallback)
    return float(min(26.0, max(8.0, period * 1000.0 * 0.045)))

# ============================================================
# Stage 5 -- structural read (what BeatNet cannot see)
# ============================================================

def _pct(arr, q: float) -> float:
    import numpy as np
    a = np.asarray(arr, dtype=float)
    return float(np.percentile(a, q)) if a.size else 0.0


def analyze_bars(bands: Bands, beats: List[float], downbeats: List[float],
                 onsets: List[Dict[str, Any]], period: float,
                 ts: int = 4) -> List[Dict[str, Any]]:
    """Per-bar feature table. Everything structural is derived from this."""
    import numpy as np
    if not downbeats:
        return []

    sub_ref = _pct(bands.e_sub, 95) + 1e-9
    mid_ref = _pct(bands.e_mid, 95) + 1e-9
    high_ref = _pct(bands.e_high, 95) + 1e-9
    rms_ref = _pct(bands.rms, 95) + 1e-9

    kick_t = np.asarray([o["t"] for o in onsets
                         if o["band"] == "kick"], dtype=float)
    mid_t = np.asarray([o["t"] for o in onsets if o["band"] == "mid"], dtype=float)

    bars: List[Dict[str, Any]] = []
    for i, t0 in enumerate(downbeats):
        t1 = downbeats[i + 1] if i + 1 < len(downbeats) else min(
            bands.duration, t0 + period * ts)
        if t1 <= t0:
            continue
        span = t1 - t0
        nk = int(np.sum((kick_t >= t0) & (kick_t < t1)))
        nm = int(np.sum((mid_t >= t0) & (mid_t < t1)))
        bars.append({
            "index": i,
            "t": round(float(t0), 5),
            "t_end": round(float(t1), 5),
            "sub": round(bands.mean_between(bands.e_sub, t0, t1) / sub_ref, 4),
            "mid": round(bands.mean_between(bands.e_mid, t0, t1) / mid_ref, 4),
            "high": round(bands.mean_between(bands.e_high, t0, t1) / high_ref, 4),
            "rms": round(bands.mean_between(bands.rms, t0, t1) / rms_ref, 4),
            "flatness": round(bands.mean_between(bands.flatness, t0, t1), 5),
            "kicks": nk,
            "kicks_per_beat": round(nk / max(1e-6, span / period), 3),
            "mid_hits": nm,
        })
    return bars


def tag_bars(bars: List[Dict[str, Any]]) -> None:
    """Label each bar with what the track is doing there.

    Rawstyle structure is legible from three signals: how much sub is present
    (kick on or off), how fast the kick is repeating (gated rolls), and how
    noisy the mid band is (screeches). Read together they separate a real drop
    from a breakdown, a buildup, or a fake drop.
    """
    import numpy as np
    if not bars:
        return

    sub = np.asarray([b["sub"] for b in bars], dtype=float)
    rms = np.asarray([b["rms"] for b in bars], dtype=float)
    kpb = np.asarray([b["kicks_per_beat"] for b in bars], dtype=float)
    flat = np.asarray([b["flatness"] for b in bars], dtype=float)
    mid = np.asarray([b["mid"] for b in bars], dtype=float)

    sub_hi = float(np.percentile(sub, 62))
    sub_lo = float(np.percentile(sub, 32))
    rms_hi = float(np.percentile(rms, 60))
    flat_hi = float(np.percentile(flat, 70))
    mid_hi = float(np.percentile(mid, 62))

    # Hysteresis on the kick decision. Percentile thresholds sit right in the
    # middle of the data, so bars hovering near the boundary flip on and off
    # and shred the section list into one-bar fragments. Requiring a bar to
    # clear a higher bar to switch on than to stay on keeps runs intact.
    sub_on = float(np.percentile(sub, 66))
    sub_off = float(np.percentile(sub, 46))
    kicking_prev = False

    # An absolute floor for "there is a kick here at all", so a filtered or
    # side-chained intro kick is not mistaken for silence.
    sub_floor = float(np.percentile(sub, 22))

    for i, b in enumerate(bars):
        tags: List[str] = []
        thresh = sub_off if kicking_prev else sub_on
        kick_rate_ok = (kpb[i] >= (0.45 if kicking_prev else 0.6))
        # Energy OR rate. Intro and breakdown kicks are deliberately quiet, so
        # judging on sub energy alone labelled busy sections "no_kick" -- which
        # then suppressed their rolls and left them out of the chart entirely.
        kicking = ((sub[i] >= thresh) and kick_rate_ok) or                   (kpb[i] >= 0.9 and sub[i] >= sub_floor)
        kicking_prev = kicking

        if kicking:
            tags.append("kick")
            # A gated kick chops one hit into a burst; more than ~1.6 kick
            # events per beat means a roll rather than a four-to-the-floor.
            if kpb[i] >= 1.6:
                tags.append("gated_kick")
            if kpb[i] >= 2.6:
                tags.append("kick_roll")
        elif sub[i] <= sub_lo:
            tags.append("no_kick")

        if (mid[i] >= mid_hi) and (flat[i] >= flat_hi):
            tags.append("screech")

        if (not kicking) and rms[i] < rms_hi:
            tags.append("breakdown")

        # Buildup: energy climbing with the kick thinning out.
        if i >= 2 and i + 1 < len(bars):
            rising = rms[i] > rms[i - 1] > rms[i - 2]
            if rising and kpb[i] < 0.6 and sub[i] < sub_hi:
                tags.append("buildup")

        b["tags"] = tags
        b["intensity"] = round(float(
            0.55 * min(1.0, rms[i]) + 0.30 * min(1.0, sub[i]) +
            0.15 * min(1.0, mid[i])), 4)


def find_sections(bars: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Group tagged bars into named sections and flag fake drops.

    A fake drop is the pattern that breaks naive trackers: the track hits full
    energy for a bar or two, then yanks it away again instead of sustaining.
    Detecting it needs a look at how long a drop *lasts*, which is why this
    runs over bar runs rather than instantaneous energy.
    """
    if not bars:
        return []

    def kind_of(b: Dict[str, Any]) -> str:
        tags = b.get("tags", [])
        if "buildup" in tags:
            return "buildup"
        if "kick" in tags:
            return "drop" if b.get("intensity", 0.0) >= 0.45 else "groove"
        if "breakdown" in tags or "no_kick" in tags:
            return "breakdown"
        return "groove"

    runs: List[Dict[str, Any]] = []
    for b in bars:
        k = kind_of(b)
        if runs and runs[-1]["kind"] == k:
            runs[-1]["t_end"] = b["t_end"]
            runs[-1]["bars"] += 1
        else:
            runs.append({"kind": k, "t": b["t"], "t_end": b["t_end"], "bars": 1})

    # A "drop" that survives fewer than 2 bars and falls back into low energy
    # is a fake drop, not a section.
    for i, r in enumerate(runs):
        if r["kind"] == "drop" and r["bars"] <= 2:
            nxt = runs[i + 1] if i + 1 < len(runs) else None
            if nxt is not None and nxt["kind"] in ("breakdown", "buildup"):
                r["kind"] = "fake_drop"

    for r in runs:
        r["t"] = round(float(r["t"]), 5)
        r["t_end"] = round(float(r["t_end"]), 5)
    return runs


def tag_onsets(onsets: List[Dict[str, Any]], bars: List[Dict[str, Any]],
               beats: List[float], period: float) -> None:
    """Attach musical role and grid position to every onset.

    `role` is what the map generator keys off: a sub hit on a downbeat during a
    drop should not be treated like a hat during a breakdown.
    """
    import numpy as np
    if not onsets:
        return
    bt = np.asarray(beats, dtype=float) if beats else np.zeros(0)
    bar_starts = np.asarray([b["t"] for b in bars], dtype=float) if bars else np.zeros(0)

    for o in onsets:
        t = float(o["t"])
        # Which bar are we in, and what is that bar doing?
        tags: List[str] = []
        if bar_starts.size:
            bi = int(np.searchsorted(bar_starts, t, side="right")) - 1
            bi = max(0, min(len(bars) - 1, bi))
            tags = list(bars[bi].get("tags", []))
            o["bar"] = int(bi)
            o["intensity"] = float(bars[bi].get("intensity", 0.5))
        else:
            o["bar"] = -1
            o["intensity"] = 0.5

        # Distance to the nearest beat, in fractions of a beat.
        if bt.size and period > 0:
            j = int(np.argmin(np.abs(bt - t)))
            dev = (t - float(bt[j])) / period
            o["beat_index"] = int(j)
            o["beat_dev"] = round(float(dev), 4)
            o["on_beat"] = bool(abs(dev) <= 0.10)
        else:
            o["beat_index"] = -1
            o["beat_dev"] = 0.0
            o["on_beat"] = False

        band = o.get("band", "all")
        if band == "kick":
            # Test on-beat FIRST. A gated bar still has a kick on the beat, and
            # calling that "gated" throws away the one distinction the chart
            # cares about most -- the pulse you actually step on. Only the
            # off-beat hits in a gated bar are the roll.
            if o["on_beat"]:
                o["role"] = "kick"
            elif "gated_kick" in tags or "kick_roll" in tags:
                o["role"] = "gated_kick"
            else:
                o["role"] = "kick_offbeat"
        elif band == "mid":
            o["role"] = "screech" if "screech" in tags else "lead"
        else:
            o["role"] = "hat"

        if "breakdown" in tags:
            o["section"] = "breakdown"
        elif "buildup" in tags:
            o["section"] = "buildup"
        elif "kick" in tags:
            o["section"] = "drop"
        else:
            o["section"] = "groove"


# ============================================================
# Stage 6 -- map generation
# ============================================================

def _density_for_diff(diff: int) -> float:
    """Target notes per beat, across both lanes.

    Calibrated against a hand-authored chart for this game: ~2.4 notes per beat
    total (0.87 on the beat lane, 1.5 on the melody lane). The melody lane
    drives world FX rather than taps, so high totals here stay playable -- the
    earlier curve topped out below what a real chart uses and left songs sparse.
    """
    return {1: 0.50, 2: 0.80, 3: 1.10, 4: 1.50, 5: 1.90,
            6: 2.30, 7: 2.70, 8: 3.10, 9: 3.60, 10: 4.20}.get(int(diff), 2.3)


# How the note budget splits between the two lanes, and how much a slot is
# discounted for being an ornament rather than the backbone. Measured against
# the hand-authored reference: 635 beat notes to 1108 melody notes, of which
# 69% of beat gaps are exactly one beat.
# The two-lane split the editor charts against: everything you feel as the
# pulse goes left, everything you hear as the tune goes right.
BEAT_LANE = 0
MELODY_LANE = 1

BEAT_LANE_SHARE = 0.37
MELODY_LANE_SHARE = 0.63
ROLL_WEIGHT = 0.55
# A slot quieter than this fraction of the band's own median is treated as
# silence and never charted, however favourable its local ratio looks.
SILENCE_FLOOR = 0.30
MEL_DIV_WEIGHT = {1: 1.00, 2: 0.92, 4: 0.72, 8: 0.50}
# Triplet slots are offered as candidates but weighted below their binary
# neighbours, so they only win where the mid band genuinely peaks off the
# binary grid. The reference chart is binary throughout; a song that actually
# swings still gets them.
TRIPLET_DIVS = {3: 0.62, 6: 0.44}


def _local_reference(bands, arr, duration: float,
                     win_s: float = 7.0, pct: float = 80.0):
    """Rolling loudness reference for one band, sampled once per second.

    Scoring grid slots on absolute energy makes the whole track compete against
    its own loudest passages, so an intro or breakdown that is quiet but busy
    loses every slot to the drops and comes out empty. Dividing by a local
    reference asks "is this loud *for around here*", which keeps quiet sections
    charted at their own scale.
    """
    import numpy as np
    n = max(1, int(math.ceil(duration)))
    per_sec = np.empty(n, dtype=float)
    for i in range(n):
        per_sec[i] = bands.mean_between(arr, float(i), float(i) + 1.0)

    half = max(1, int(round(win_s)))
    ref = np.empty(n, dtype=float)
    for i in range(n):
        a = max(0, i - half)
        b = min(n, i + half + 1)
        seg = per_sec[a:b]
        ref[i] = float(np.percentile(seg, pct)) if seg.size else 0.0
    return ref


def _ref_at(ref, t: float) -> float:
    import numpy as np
    if ref is None or len(ref) == 0:
        return 1.0
    i = int(min(len(ref) - 1, max(0, int(t))))
    return float(ref[i])


def _slot_energy(bands, arr, t: float, half_win: float) -> float:
    return bands.mean_between(arr, t - half_win, t + half_win)


def _snap_to_onset(t: float, cand, tol: float) -> float:
    """Move a grid slot onto a real transient if one is close enough."""
    import numpy as np
    if cand is None or len(cand) == 0:
        return t
    j = int(np.searchsorted(cand, t))
    best, bestd = t, 1e9
    for jj in (j - 1, j, j + 1):
        if 0 <= jj < len(cand):
            d = abs(float(cand[jj]) - t)
            if d < bestd:
                bestd, best = d, float(cand[jj])
    return best if bestd <= tol else t


def _section_of(tags: List[str]) -> str:
    if "breakdown" in tags:
        return "breakdown"
    if "buildup" in tags:
        return "buildup"
    if "kick" in tags:
        return "drop"
    return "groove"


def _take_budget(cands: List[Dict[str, Any]], budget: int,
                 min_gap: float) -> List[Dict[str, Any]]:
    """Keep the highest-energy slots, then enforce spacing in time order."""
    if budget <= 0 or not cands:
        return []
    ranked = sorted(cands, key=lambda c: -float(c["score"]))[:budget]
    ranked.sort(key=lambda c: float(c["t"]))
    out: List[Dict[str, Any]] = []
    last = -1e9
    for c in ranked:
        t = float(c["t"])
        if (t - last) < min_gap:
            continue
        out.append(c)
        last = t
    return out


def generate_map_notes(*, onsets: List[Dict[str, Any]], beats: List[float],
                       downbeats: List[float], period: float,
                       audio_hash: str, cfg: MapGenConfig,
                       bands: Optional["Bands"] = None,
                       bars: Optional[List[Dict[str, Any]]] = None) -> List[Dict[str, Any]]:
    """Fill the rhythmic grid wherever the music is active.

    Charts for this game are grid backbones, not transcriptions of every
    detected transient. Measured against the hand-authored reference, 69% of
    beat-lane gaps are exactly one beat and the melody lane runs on eighths and
    sixteenths. That chart also places 635 beat notes where onset detection
    finds only 404 kicks -- the author charts the *pulse*, which carries on
    through bars where no clean transient survives the distortion.

    So a slot is chosen by band energy ("is the kick playing here?"), and
    detected onsets are used only to snap a chosen slot onto the real
    transient. Ranking onsets by strength instead made notes clump into loud
    sections and scored barely above chance against the reference.
    """
    import numpy as np

    if not beats or period <= 0 or len(beats) < 4:
        return []

    lane_count = max(1, int(cfg.lane_count))
    diff = max(1, min(10, int(cfg.difficulty)))
    min_gap = float(cfg.min_gap_ms) / 1000.0

    ba = np.asarray(beats, dtype=float)
    n_beats = float(len(ba))
    total_density = _density_for_diff(diff)
    beat_budget = int(round(total_density * BEAT_LANE_SHARE * n_beats))
    mel_budget = int(round(total_density * MELODY_LANE_SHARE * n_beats))

    down = set(round(float(t), 3) for t in downbeats)
    by_band: Dict[str, Any] = {}
    for b in ("kick", "mid", "high"):
        v = sorted(float(o["t"]) for o in onsets if o.get("band") == b)
        by_band[b] = np.asarray(v, dtype=float) if v else np.zeros(0)

    bar_starts = np.asarray([b["t"] for b in bars], dtype=float) if bars else np.zeros(0)

    def _bar_at(t: float) -> Optional[Dict[str, Any]]:
        if bar_starts.size == 0 or not bars:
            return None
        i = int(np.searchsorted(bar_starts, t, side="right")) - 1
        return bars[max(0, min(len(bars) - 1, i))]

    def bar_tags(t: float) -> List[str]:
        b = _bar_at(t)
        return list(b.get("tags", [])) if b else []

    def bar_intensity(t: float) -> float:
        b = _bar_at(t)
        return float(b.get("intensity", 0.5)) if b else 0.5

    e_kick = bands.e_sub if bands is not None else None
    e_mid = bands.e_mid if bands is not None else None
    snap_tol = period * 0.14

    # Rolling references, plus an absolute floor per band so genuine silence
    # still stays empty rather than being scaled up into notes.
    ref_kick = ref_mid = None
    floor_kick = floor_mid = 0.0
    if bands is not None:
        import numpy as _np
        dur_s = float(bands.duration)
        ref_kick = _local_reference(bands, e_kick, dur_s)
        ref_mid = _local_reference(bands, e_mid, dur_s)
        floor_kick = float(_np.percentile(e_kick, 55)) * SILENCE_FLOOR
        floor_mid = float(_np.percentile(e_mid, 55)) * SILENCE_FLOOR

    def energy(arr, t: float, half: float) -> float:
        if bands is None or arr is None:
            return 1.0
        return _slot_energy(bands, arr, t, half)

    def rel_energy(arr, ref, floor: float, t: float, half: float) -> float:
        """Loudness of this slot relative to its own neighbourhood."""
        if bands is None or arr is None:
            return 1.0
        e = _slot_energy(bands, arr, t, half)
        if e <= floor:
            return 0.0
        return e / (_ref_at(ref, t) + 1e-9)

    # ---------------- beat lane: quarter-note backbone ----------------
    beat_cands: List[Dict[str, Any]] = []
    half = period * 0.30
    for t in ba:
        beat_cands.append({"t": float(t), "div": 1, "triplet": False,
                           "role": "kick", "band": "kick",
                           "score": rel_energy(e_kick, ref_kick, floor_kick, float(t), half),
                           "on_beat": True})

    # Rolls only inside bars the structural pass called gated, and only where a
    # kick transient is genuinely present -- otherwise a roll is invented.
    if diff >= 3:
        divs = [2] if diff < 6 else [2, 4]
        kc = by_band["kick"]
        for i in range(len(ba) - 1):
            t0, t1 = float(ba[i]), float(ba[i + 1])
            tags = bar_tags(t0)
            if "gated_kick" not in tags and "kick_roll" not in tags:
                continue
            for d in divs:
                step = (t1 - t0) / float(d)
                for k in range(1, d):
                    st = t0 + step * k
                    if kc.size == 0:
                        continue
                    j = max(1, min(len(kc) - 1, int(np.searchsorted(kc, st))))
                    if min(abs(st - kc[j - 1]), abs(st - kc[j])) > period * 0.10:
                        continue
                    beat_cands.append({
                        "t": st, "div": d, "triplet": False,
                        "role": "gated_kick", "band": "kick",
                        "score": rel_energy(e_kick, ref_kick, floor_kick, st, half * 0.6) * ROLL_WEIGHT,
                        "on_beat": False})

    beat_notes = _take_budget(beat_cands, beat_budget, min_gap)

    # ---------------- melody lane: eighth/sixteenth backbone ----------------
    mel_cands: List[Dict[str, Any]] = []
    mel_divs = [1, 2] if diff < 4 else ([1, 2, 4] if diff < 8 else [1, 2, 4, 8])
    trip_divs: List[int] = []
    if bool(cfg.allow_triplets) and diff >= 5:
        trip_divs = [3] if diff < 8 else [3, 6]
    seen: set = set()
    half_m = period * 0.20
    for i in range(len(ba) - 1):
        t0, t1 = float(ba[i]), float(ba[i + 1])
        for d in mel_divs + trip_divs:
            is_trip = d in TRIPLET_DIVS
            w = TRIPLET_DIVS[d] if is_trip else MEL_DIV_WEIGHT.get(d, 0.6)
            step = (t1 - t0) / float(d)
            for k in range(d):
                st = t0 + step * k
                key = round(st, 4)
                if key in seen:
                    continue
                seen.add(key)
                mel_cands.append({
                    "t": st, "div": d, "triplet": is_trip,
                    "role": "screech" if "screech" in bar_tags(st) else "lead",
                    "band": "mid",
                    "score": rel_energy(e_mid, ref_mid, floor_mid, st, half_m) * w,
                    "on_beat": (k == 0)})

    mel_notes = _take_budget(mel_cands, mel_budget, min_gap)

    # ---------------- assemble ----------------
    out: List[Dict[str, Any]] = []
    for chosen, rc in ((beat_notes, "beat"), (mel_notes, "melody")):
        cand_arr = by_band["kick"] if rc == "beat" else by_band["mid"]
        lane = BEAT_LANE if rc == "beat" else min(MELODY_LANE, lane_count - 1)
        lane = max(0, min(lane_count - 1, lane))
        for n in chosen:
            t = _snap_to_onset(float(n["t"]), cand_arr, snap_tol)
            out.append({
                "t": round(t, 5),
                "t_ms": int(round(t * 1000.0)),
                "lane": int(lane),
                "kind": "tap",
                "basis": n["role"],
                "role_class": rc,
                "band": n["band"],
                "section": _section_of(bar_tags(float(n["t"]))),
                "div": int(n["div"]),
                "triplet": bool(n.get("triplet", False)),
                "intensity": round(bar_intensity(float(n["t"])), 3),
                "on_beat": bool(n["on_beat"]),
                "downbeat": bool(round(float(n["t"]), 3) in down),
            })

    out.sort(key=lambda d: (d["t"], d["lane"]))
    return out


# ============================================================
# Grid scoring -- pick the best candidate instead of the first
# ============================================================

def score_grid(beats: List[float], bands: Bands, period: float) -> Dict[str, float]:
    """How well does this grid explain the kick track?

    Three things matter and they trade off, so we score all three: how much
    kick energy the beats actually land on, how regular the spacing is, and
    how completely the grid covers the track.
    """
    import numpy as np
    if len(beats) < 8 or period <= 0:
        return {"score": -1.0, "energy": 0.0, "regularity": 0.0, "coverage": 0.0}

    env = bands.flux_kick
    ref = float(np.mean(env)) + 1e-9
    hit = np.asarray([env[bands.frame_at(t)] for t in beats], dtype=float)
    energy = float(np.mean(hit) / ref)

    d = np.diff(np.asarray(beats, dtype=float))
    med = float(np.median(d)) if d.size else period
    regularity = float(np.mean(np.abs(d - med) <= 0.006)) if d.size else 0.0

    expected = max(1.0, bands.duration / period)
    coverage = float(min(1.0, len(beats) / expected))

    # Regularity leads. A grid that sits on more kick energy but wanders is
    # worse to play than a steady one slightly off: the player feels spacing,
    # not absolute alignment, and a constant offset is correctable downstream.
    score = (0.34 * min(energy / 6.0, 1.0) + 0.51 * regularity + 0.15 * coverage)
    return {"score": round(score, 5), "energy": round(energy, 4),
            "regularity": round(regularity, 4), "coverage": round(coverage, 4)}


def build_grid(bands: Bands, cfg: AnalysisConfig, tempo: Dict[str, Any],
               progress: Optional[ProgressCB] = None) -> Tuple[List[float], Dict[str, Any]]:
    """Try several grid strategies and keep the best-scoring one.

    Accuracy matters more than runtime here, so rather than trusting one
    tracker configuration we build all of them and let the kick track decide.
    """
    period = float(tempo["period"])
    phase = float(tempo["phase"])
    attempts: List[Dict[str, Any]] = []

    for tight in (600.0, 400.0, 200.0, 100.0):
        c2 = AnalysisConfig(**{**asdict(cfg), "tightness": tight})
        tracked = track_beats(bands, c2, tempo["bpm"])
        if not tracked:
            continue
        fused, info = fuse_beats(tracked, period, phase, bands.duration)
        for snap_on in (True, False):
            g = fused
            moved = 0.0
            if snap_on:
                g, moved = snap_to_transients(fused, bands, cfg.snap_window_ms)
            sc = score_grid(g, bands, period)
            attempts.append({"beats": g, "score": sc["score"], "detail": sc,
                             "tightness": tight, "snapped": snap_on,
                             "fuse": info, "snap_shift": round(moved, 5)})
        if progress:
            progress(58, "Grid search: tightness %d…" % int(tight))

    # Always include the pure metronome grid as a floor.
    ideal = synth_grid(period, phase, bands.duration)
    if ideal:
        gi, mi = snap_to_transients(ideal, bands, cfg.snap_window_ms)
        for g, lab, mv in ((ideal, False, 0.0), (gi, True, mi)):
            sc = score_grid(g, bands, period)
            attempts.append({"beats": g, "score": sc["score"], "detail": sc,
                             "tightness": 0.0, "snapped": lab,
                             "fuse": {"mode": "ideal"}, "snap_shift": round(mv, 5)})

    if not attempts:
        return (ideal, {"mode": "ideal_fallback"})

    best = max(attempts, key=lambda a: a["score"])
    return (best["beats"], {
        "chosen_tightness": best["tightness"],
        "chosen_snapped": best["snapped"],
        "chosen_score": best["score"],
        "chosen_detail": best["detail"],
        "snap_shift_s": best["snap_shift"],
        "fuse": best["fuse"],
        "candidates": [{"tightness": a["tightness"], "snapped": a["snapped"],
                        "score": a["score"], "n": len(a["beats"])}
                       for a in attempts],
    })


# ============================================================
# Orchestrator
# ============================================================

def analyze(audio_path: str, cfg: AnalysisConfig,
            progress_cb: Optional[ProgressCB] = None,
            cancel_cb: Optional[Callable[[], bool]] = None) -> FusionResult:
    import numpy as np

    def ping(p: int, m: str) -> None:
        if progress_cb:
            progress_cb(int(p), str(m))

    def cancelled() -> bool:
        return bool(cancel_cb and cancel_cb())

    res = FusionResult()
    if not os.path.isfile(audio_path):
        res.error = "Audio file not found: %s" % audio_path
        return res

    _safe_mkdir(CACHE_DIR)

    ping(4, "Decoding audio…")
    y, sr = load_audio(audio_path, cfg.quick_seconds)
    if y is None or len(y) < sr:
        res.error = "Audio too short or failed to decode."
        return res
    res.duration_s = round(float(len(y)) / float(sr), 3)
    if cancelled():
        res.error = "Canceled by user."
        return res

    ping(12, "Splitting frequency bands…")
    bands = Bands(y, sr, cfg)
    if cancelled():
        res.error = "Canceled by user."
        return res

    bn = {"ok": False, "beats": [], "positions": [], "bpm": None, "error": "disabled"}
    if cfg.use_beatnet:
        ping(20, "BeatNet: macro beat grid…")
        bn = beatnet_grid(y, sr, CACHE_DIR, progress_cb)
    seed_bpm = bn.get("bpm") if bn.get("ok") else None
    if cancelled():
        res.error = "Canceled by user."
        return res

    auto_notes: Dict[str, Any] = {"applied": False}
    if cfg.auto:
        ping(30, "Auto-tuning settings from the audio…")
        cfg, auto_notes = auto_tune(bands, cfg, seed_bpm)

    ping(34, "Locking tempo on the kick band…")
    tempo = refine_tempo(bands, cfg, seed_bpm)
    if tempo["period"] <= 0:
        res.error = "Tempo estimation failed."
        return res

    if cfg.auto:
        # The snap window depends on tempo, so it can only be set now.
        cfg.snap_window_ms = auto_snap_window_ms(float(tempo["period"]),
                                                 cfg.snap_window_ms)
        auto_notes["snap_window_ms"] = round(cfg.snap_window_ms, 2)

    ping(44, "Beat grid search…")
    beats, grid_info = build_grid(bands, cfg, tempo, progress_cb)
    if not beats:
        res.error = "Beat tracking produced no beats."
        return res
    if cancelled():
        res.error = "Canceled by user."
        return res

    ping(66, "Locating downbeats…")
    downbeats, bar_off = assign_downbeats(
        beats, bn.get("beats", []), bn.get("positions", []),
        bands, cfg.time_signature)

    ping(72, "Detecting band-split onsets…")
    period = float(tempo["period"])
    onsets = merge_close_onsets(detect_band_onsets(bands, cfg, period))
    if cancelled():
        res.error = "Canceled by user."
        return res

    ping(82, "Reading structure (drops, gates, screeches)…")
    bars = analyze_bars(bands, beats, downbeats, onsets, period, cfg.time_signature)
    tag_bars(bars)
    sections = find_sections(bars)
    tag_onsets(onsets, bars, beats, period)

    ping(90, "Finalising…")
    # Median distance from a beat to its kick transient: the residual latency
    # the game can subtract if a chart still feels early or late.
    dev = []
    for t in beats[: min(len(beats), 400)]:
        c = bands.frame_at(t)
        a = max(0, c - int(0.02 * bands.fps))
        b = min(bands.n_frames, c + int(0.02 * bands.fps) + 1)
        if b - a > 1:
            k = a + int(np.argmax(bands.flux_kick[a:b]))
            dev.append(float(k) / bands.fps - float(t))
    res.offset_correction_s = round(float(np.median(dev)), 5) if dev else 0.0

    res.ok = True
    res.config_used = cfg
    res.bands = bands
    res.bpm = round(float(tempo["bpm"]), 4)
    res.beats = [round(float(t), 5) for t in beats]
    res.downbeats = [round(float(t), 5) for t in downbeats]
    res.onsets = onsets
    res.bars = bars
    res.sections = sections

    counts: Dict[str, int] = {}
    for o in onsets:
        counts[o.get("role", "?")] = counts.get(o.get("role", "?"), 0) + 1
    sec_counts: Dict[str, int] = {}
    for s in sections:
        sec_counts[s["kind"]] = sec_counts.get(s["kind"], 0) + 1

    res.notes = ("BeatNet+Librosa fusion | %.2f BPM | %d beats | %d bars | %d onsets"
                 % (res.bpm, len(beats), len(bars), len(onsets)))
    res.extra = {
        "auto": auto_notes,
        "tempo": tempo,
        "grid": grid_info,
        "beatnet": {"ok": bool(bn.get("ok")), "bpm": bn.get("bpm"),
                    "beats": len(bn.get("beats", [])),
                    "error": (bn.get("error") or None)},
        "bar_offset": int(bar_off),
        "onset_roles": counts,
        "section_counts": sec_counts,
        "band_hz": {"sub": list(cfg.sub_band), "punch": list(cfg.punch_band),
                    "mid": list(cfg.mid_band), "high": list(cfg.high_band)},
        "resolution_ms": round(1000.0 / bands.fps, 3),
    }
    return res


# ============================================================
# Export
# ============================================================

def build_payload(audio_path: str, res: FusionResult, cfg: AnalysisConfig,
                  map_cfg: Optional[MapGenConfig],
                  map_notes: List[Dict[str, Any]], elapsed: float) -> Dict[str, Any]:
    cfgd = asdict(res.config_used or cfg)
    for k in ("sub_band", "punch_band", "mid_band", "high_band"):
        cfgd[k] = list(cfgd[k])
    return {
        "app": {"name": APP_NAME, "version": APP_VERSION},
        "schema": SCHEMA,
        "engine": "beatnet+librosa",
        "ok": bool(res.ok),
        "audio": os.path.abspath(audio_path),
        "duration_s": res.duration_s,
        "backend": "beatnet+librosa",
        "notes": res.notes,
        "bpm": res.bpm,
        "offset_correction_s": res.offset_correction_s,
        "beats": res.beats,
        "downbeats": res.downbeats,
        "onsets": res.onsets,
        "bars": res.bars,
        "sections": res.sections,
        "map_notes": map_notes,
        "config": cfgd,
        "config_requested": {k: (list(v) if isinstance(v, tuple) else v)
                             for k, v in asdict(cfg).items()},
        "mapgen": asdict(map_cfg) if map_cfg else {},
        "extra": res.extra,
        "error": res.error,
        "generated_at_unix": int(time.time()),
        "elapsed_s": round(float(elapsed), 3),
    }


def write_json(path: str, payload: Dict[str, Any]) -> None:
    _safe_mkdir(os.path.dirname(os.path.abspath(path)))
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def default_out_for(audio_path: str) -> str:
    stem = os.path.splitext(os.path.basename(audio_path))[0]
    safe = "".join(ch for ch in stem if ch.isalnum() or ch in " ._-").strip() or "beatmap"
    return os.path.join(DEFAULT_OUT_DIR, safe + ".analysis.json")


# ============================================================
# CLI
# ============================================================

def run_cli(args: argparse.Namespace) -> int:
    t0 = time.time()
    prog = args.progress_file or ""
    audio = os.path.abspath(args.audio)
    out = os.path.abspath(args.out) if args.out else default_out_for(audio)

    def ping(p: int, m: str) -> None:
        write_progress_file(prog, p, m)
        try:
            print("[%3d%%] %s" % (int(p), m), flush=True)
        except Exception:
            pass

    def cancelled() -> bool:
        return bool(args.cancel_file and os.path.isfile(args.cancel_file))

    cfg = AnalysisConfig(
        min_bpm=float(args.min_bpm),
        max_bpm=float(args.max_bpm),
        time_signature=int(args.ts),
        snap_window_ms=float(args.snap_ms),
        onset_delta=float(args.onset_delta),
        use_beatnet=(not args.no_beatnet),
        quick_seconds=int(args.quick_seconds),
        auto=bool(args.auto),
    )
    map_cfg = MapGenConfig(
        enabled=bool(args.mapgen),
        difficulty=int(args.map_diff),
        lane_count=int(args.map_lanes),
        seed=int(args.map_seed),
        min_gap_ms=int(args.map_min_gap_ms),
        allow_chords=bool(args.map_allow_chords),
        allow_triplets=bool(args.map_triplets),
    )

    ping(1, "Starting %s…" % APP_ID)
    try:
        res = analyze(audio, cfg, ping, cancelled)
    except Exception:
        tb = traceback.format_exc()
        _crash_log(tb)
        res = FusionResult(ok=False, error=tb[-4000:])

    map_notes: List[Dict[str, Any]] = []
    if res.ok and map_cfg.enabled:
        ping(94, "Generating map notes…")
        try:
            map_notes = generate_map_notes(
                onsets=res.onsets, beats=res.beats, downbeats=res.downbeats,
                period=(60.0 / res.bpm) if res.bpm else 0.0,
                audio_hash=_audio_hash(audio), cfg=map_cfg,
                bands=res.bands, bars=res.bars)
        except Exception:
            tb = traceback.format_exc()
            _crash_log(tb)
            res.extra["mapgen_error"] = tb[-2000:]

    ping(97, "Writing JSON…")
    payload = build_payload(audio, res, cfg, map_cfg, map_notes, time.time() - t0)
    try:
        write_json(out, payload)
    except Exception:
        tb = traceback.format_exc()
        _crash_log(tb)
        write_progress_file(prog, 100, "Failed: could not write JSON")
        sys.stderr.write(tb)
        return 1

    if res.ok:
        ping(100, "Done — %.2f BPM, %d beats, %d notes"
             % (res.bpm or 0.0, len(res.beats), len(map_notes)))
        return 0

    write_progress_file(prog, 100, "Failed: %s" % (res.error or "unknown")[:200])
    try:
        print("FAILED: %s" % (res.error or "unknown"), file=sys.stderr)
    except Exception:
        pass
    return 2


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        prog="BeatmapAnalyzer",
        description="BeatNet + Librosa fusion beat/structure analyzer for Rawstyle.")
    ap.add_argument("--cli", action="store_true", help="CLI mode (Godot uses this).")
    ap.add_argument("--audio", type=str, default="", help="Audio file path.")
    ap.add_argument("--out", type=str, default="", help="Output JSON path.")
    ap.add_argument("--progress-file", type=str, default="",
                    help="Progress JSON written here for the Godot UI.")
    ap.add_argument("--cancel-file", type=str, default="",
                    help="If this file appears, the run aborts.")

    ap.add_argument("--min-bpm", type=float, default=120.0)
    ap.add_argument("--max-bpm", type=float, default=200.0)
    ap.add_argument("--ts", type=int, default=4, choices=[3, 4])
    ap.add_argument("--snap-ms", type=float, default=18.0,
                    help="Transient snap window (ms).")
    ap.add_argument("--onset-delta", type=float, default=0.055,
                    help="Onset peak-pick threshold; lower finds more.")
    ap.add_argument("--auto", dest="auto", action="store_true", default=True,
                    help="Derive tempo window, onset thresholds and snap window "
                         "from the audio (default).")
    ap.add_argument("--no-auto", dest="auto", action="store_false",
                    help="Use the values passed on the command line verbatim.")
    ap.add_argument("--no-beatnet", action="store_true",
                    help="Skip BeatNet; librosa-only grid.")
    ap.add_argument("--quick-seconds", type=int, default=0,
                    help="Analyze only the first N seconds (0 = whole track).")

    ap.add_argument("--mapgen", dest="mapgen", action="store_true", default=True)
    ap.add_argument("--no-mapgen", dest="mapgen", action="store_false")
    ap.add_argument("--map-diff", type=int, default=5)
    ap.add_argument("--map-lanes", type=int, default=2,
                    help="2 = beats lane + melody lane (roles decide the lane). "
                         "4 or more spreads roles across lanes instead.")
    ap.add_argument("--map-seed", type=int, default=0)
    ap.add_argument("--map-min-gap-ms", type=int, default=85)
    ap.add_argument("--map-allow-chords", action="store_true")
    ap.add_argument("--map-triplets", dest="map_triplets", action="store_true",
                    default=True, help="Allow 1/12 and 1/24 triplet placement.")
    ap.add_argument("--no-map-triplets", dest="map_triplets", action="store_false",
                    help="Binary subdivisions only (1/4, 1/8, 1/16, 1/32).")

    ap.add_argument("--no-relaunch", action="store_true",
                    help="Do not re-exec into the fusion venv.")
    ap.add_argument("--selftest", action="store_true",
                    help="Verify the BeatNet/Librosa stack and exit.")

    ns = ap.parse_args(argv)
    ns.map_diff = max(1, min(10, int(ns.map_diff)))
    ns.map_min_gap_ms = max(20, min(400, int(ns.map_min_gap_ms)))
    ns.map_lanes = max(1, min(8, int(ns.map_lanes)))
    return ns


def selftest() -> int:
    print("%s selftest" % APP_ID)
    print("  python  : %s" % sys.version.split()[0])
    print("  exe     : %s" % sys.executable)
    ok = True
    for mod in ("numpy", "scipy", "librosa", "torch", "madmom", "soundfile"):
        try:
            m = __import__(mod)
            print("  %-9s: %s" % (mod, getattr(m, "__version__", "ok")))
        except Exception as e:
            ok = False
            print("  %-9s: MISSING (%s)" % (mod, e))
    try:
        from BeatNet.BeatNet import BeatNet  # noqa: F401
        print("  BeatNet  : ok")
    except Exception as e:
        ok = False
        print("  BeatNet  : MISSING (%s)" % e)
    print("  RESULT   : %s" % ("OK" if ok else "INCOMPLETE"))
    return 0 if ok else 1


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    if not args.no_relaunch:
        relaunch_into_venv_if_needed()
    if args.selftest:
        return selftest()
    if not args.audio:
        print("No --audio given. Use --help for usage, or --selftest to check the stack.",
              file=sys.stderr)
        return 2
    return run_cli(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception:
        tb = traceback.format_exc()
        p = _crash_log(tb)
        sys.stderr.write(tb)
        if os.name == "nt":
            try:
                ctypes.windll.user32.MessageBoxW(
                    0, "%s crashed.\n\nLog: %s\n\n%s" % (APP_ID, p, tb[-1200:]),
                    APP_ID, 0x10)
            except Exception:
                pass
        raise SystemExit(1)
