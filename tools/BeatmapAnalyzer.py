#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from __future__ import annotations

import os
import sys
import re
import json
import time
import math
import queue
import shutil
import ctypes
import hashlib
import traceback
import platform
import subprocess
import colorsys
import argparse
import bisect
import random
from dataclasses import dataclass, asdict
from typing import Optional, List, Dict, Any, Tuple, Callable

# ============================================================
# App identity
# ============================================================

APP_NAME = "Beatmap Analyzer"
APP_VERSION = "v0.8.3"
APP_ID = f"{APP_NAME} {APP_VERSION}"

ProgressCB = Callable[[int, str], None]


# ============================================================
# Paths / Defaults
# ============================================================

def _home() -> str:
    return os.path.expanduser("~")

SCRIPT_PATH = os.path.abspath(__file__)
SCRIPT_DIR = os.path.abspath(os.path.dirname(__file__))

# project root = one level above /tools
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))

DEFAULT_OUT_DIR = os.path.join(
    PROJECT_ROOT,
    "data",
    "Analysis",
)

CACHE_DIR = os.path.join(SCRIPT_DIR, ".cache")
os.makedirs(CACHE_DIR, exist_ok=True)

RECENTS_PATH = os.path.join(CACHE_DIR, "recent_files.json")
VENV_CACHE_PATH = os.path.join(CACHE_DIR, "venv_python_path.txt")


# ============================================================
# Crash shield: always log fatal errors
# ============================================================

def _crash_log_file() -> str:
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
    except Exception:
        pass
    ts = time.strftime("%Y%m%d_%H%M%S")
    return os.path.join(CACHE_DIR, f"crash_{ts}.log")

def _write_text(path: str, text: str) -> None:
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
    except Exception:
        pass

def _show_fatal_popup(title: str, message: str) -> None:
    if os.name == "nt":
        try:
            ctypes.windll.user32.MessageBoxW(0, message, title, 0x10)  # MB_ICONERROR
            return
        except Exception:
            pass
    try:
        print(message, file=sys.stderr)
    except Exception:
        pass


# ============================================================
# Progress file for Godot UI
# ============================================================

def write_progress_file(path: Optional[str], pct: int, msg: str, extra: Optional[Dict[str, Any]] = None) -> None:
    if not path:
        return
    try:
        payload = {"pct": int(max(0, min(100, int(pct)))), "msg": str(msg), "t": time.time()}
        if extra:
            payload.update(extra)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
        os.replace(tmp, path)
    except Exception:
        pass


# ============================================================
# Venv auto-find + relaunch (works even when script elsewhere)
# ============================================================

def _in_venv() -> bool:
    return getattr(sys, "base_prefix", sys.prefix) != sys.prefix

def _norm(p: str) -> str:
    return os.path.abspath(p).replace("/", "\\").lower()

def _venv_python_from_venv_dir(venv_dir: str) -> Optional[str]:
    if not venv_dir:
        return None
    if os.name == "nt":
        cand = os.path.join(venv_dir, "Scripts", "python.exe")
    else:
        cand = os.path.join(venv_dir, "bin", "python")
    return cand if os.path.isfile(cand) else None

def _candidate_venvs_in_dir(base: str) -> List[str]:
    names = [".venv", "venv", "env"]
    out = []
    for n in names:
        p = os.path.join(base, n)
        py = _venv_python_from_venv_dir(p)
        if py:
            out.append(py)
    return out

def _walk_parents(start: str, max_levels: int = 10) -> List[str]:
    start = os.path.abspath(start)
    out = []
    cur = start
    for _ in range(max_levels):
        out.append(cur)
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return out

def _load_cached_venv_python() -> Optional[str]:
    try:
        if os.path.isfile(VENV_CACHE_PATH):
            p = open(VENV_CACHE_PATH, "r", encoding="utf-8").read().strip()
            if p and os.path.isfile(p):
                return p
    except Exception:
        pass
    return None

def _save_cached_venv_python(p: str) -> None:
    try:
        with open(VENV_CACHE_PATH, "w", encoding="utf-8") as f:
            f.write(p.strip())
    except Exception:
        pass

def _scan_for_venv_python_windows(max_seconds: float = 6.0) -> Optional[str]:
    """
    Optional deeper search (time-limited) for a .venv on Windows.
    This is NOT a full disk crawl; it stops after max_seconds.
    """
    if os.name != "nt":
        return None

    start = time.time()
    roots = []

    # Prioritize user profile locations first (fast + most likely).
    try:
        roots.append(_home())
        roots.append(os.path.join(_home(), "BeatmapAnalyzer"))
        roots.append(os.path.join(_home(), "Documents"))
        roots.append(os.path.join(_home(), "Desktop"))
    except Exception:
        pass

    # Then C:\Users (still usually manageable, but time-limited).
    roots.append(r"C:\Users")

    seen = set()
    for root in roots:
        root = os.path.abspath(root)
        if not os.path.isdir(root) or root in seen:
            continue
        seen.add(root)

        for dirpath, dirnames, filenames in os.walk(root):
            if (time.time() - start) > max_seconds:
                return None

            # prune heavy/system dirs
            dlow = dirpath.lower()
            if any(x in dlow for x in [
                r"\appdata\local\packages", r"\windows", r"\program files", r"\program files (x86)",
                r"\node_modules", r"\.git", r"\.godot", r"\library", r"\temp"
            ]):
                dirnames[:] = []
                continue

            # quick check: ".venv\Scripts\python.exe"
            if os.path.basename(dirpath).lower() in (".venv", "venv", "env"):
                py = _venv_python_from_venv_dir(dirpath)
                if py:
                    return py

            # prune depth a bit (keeps it snappy)
            rel_depth = dirpath[len(root):].count(os.sep)
            if rel_depth > 7:
                dirnames[:] = []
                continue

    return None

def find_best_venv_python(allow_scan: bool = False) -> Optional[str]:
    # 1) hard-priority: local project venv inside /tools/.venv
    local_tools_venv = os.path.join(SCRIPT_DIR, ".venv")
    py = _venv_python_from_venv_dir(local_tools_venv)
    if py:
        return py

    # 2) explicit env vars
    env_py = os.environ.get("BEATMAP_ANALYZER_PY", "").strip()
    if env_py and os.path.isfile(env_py):
        return env_py

    env_venv = os.environ.get("BEATMAP_ANALYZER_VENV", "").strip()
    if env_venv:
        py = _venv_python_from_venv_dir(env_venv)
        if py:
            return py

    # 3) cached venv path
    cached = _load_cached_venv_python()
    if cached:
        return cached

    # 4) walk upward from script dir
    for base in _walk_parents(SCRIPT_DIR, max_levels=12):
        cands = _candidate_venvs_in_dir(base)
        if cands:
            return cands[0]

    # 5) walk upward from cwd
    try:
        cwd = os.getcwd()
    except Exception:
        cwd = SCRIPT_DIR

    for base in _walk_parents(cwd, max_levels=12):
        cands = _candidate_venvs_in_dir(base)
        if cands:
            return cands[0]

    # 6) optional old home fallback
    common = os.path.join(_home(), "BeatmapAnalyzer", ".venv")
    py = _venv_python_from_venv_dir(common)
    if py:
        return py

    # 7) optional deeper scan
    if allow_scan or os.environ.get("BEATMAP_ANALYZER_SCAN_VENV", "").strip() in ("1", "true", "True"):
        py2 = _scan_for_venv_python_windows(max_seconds=6.0)
        if py2:
            return py2

    return None

def relaunch_into_found_venv_if_needed(allow_scan: bool = False) -> None:
    if os.name != "nt":
        return
    if "--no-relaunch" in sys.argv:
        return

    want = find_best_venv_python(allow_scan=allow_scan)
    if not want:
        return

    try:
        cur = _norm(sys.executable)
        wantn = _norm(want)
        cur_dir = _norm(os.path.dirname(sys.executable))
        want_dir = _norm(os.path.dirname(want))
        same_folder = (cur_dir == want_dir)
    except Exception:
        return

    if cur != wantn and not same_folder:
        _save_cached_venv_python(want)
        args = [want, SCRIPT_PATH] + [a for a in sys.argv[1:] if a != "--no-relaunch"] + ["--no-relaunch"]
        try:
            subprocess.Popen(args, cwd=os.getcwd())
        except Exception:
            tb = traceback.format_exc()
            logp = _crash_log_file()
            _write_text(logp, tb)
            _show_fatal_popup(APP_ID, f"Failed to relaunch into venv.\n\nCrash log:\n{logp}\n\n{tb[-1600:]}")
        raise SystemExit(0)


# ============================================================
# Dependency bootstrap
# ============================================================

def _pip_cmd() -> List[str]:
    return [sys.executable, "-m", "pip"]

def _run(cmd: List[str]) -> Tuple[bool, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True)
        out = (p.stdout or "") + ("\n" + (p.stderr or "") if p.stderr else "")
        return (p.returncode == 0), out.strip()
    except Exception:
        return False, traceback.format_exc()

def _try_import(name: str) -> Tuple[bool, str]:
    try:
        __import__(name)
        return True, ""
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"

def _py_version_tuple() -> Tuple[int, int]:
    return (sys.version_info.major, sys.version_info.minor)

def _pin_set_for_current_python() -> Dict[str, str]:
    maj, mi = _py_version_tuple()
    pins = {
        "pip": "pip",
        "setuptools": "setuptools<81",
        "wheel": "wheel",
        "numpy": "numpy==1.23.5",
        "scipy": "scipy==1.10.1",
        "cython": "Cython==0.29.37",
        "mido": "mido>=1.3.3",
        "madmom": "madmom==0.16.1",
        "librosa": "librosa==0.10.1",
        "soundfile": "soundfile>=0.12",
        "audioread": "audioread>=3.0",
    }
    if (maj, mi) >= (3, 12):
        pins["numpy"] = "numpy<2"
        pins["scipy"] = "scipy<2"
    return pins

def ensure_dependencies(force: bool = False, progress_cb: Optional[ProgressCB] = None) -> Dict[str, Any]:
    pins = _pin_set_for_current_python()
    report: Dict[str, Any] = {
        "python": sys.version,
        "executable": sys.executable,
        "platform": platform.platform(),
        "venv": _in_venv(),
        "steps": [],
        "ok": True,
        "warning": None,
    }

    maj, mi = _py_version_tuple()
    if (maj, mi) >= (3, 12):
        report["warning"] = "Python 3.12+ detected; madmom can be harder to build. Python 3.9 is the safest on Windows."

    def ping(p: int, m: str) -> None:
        if progress_cb:
            progress_cb(int(p), m)

    def step(title: str, cmd: List[str], pct: int) -> None:
        ping(pct, title)
        ok, out = _run(cmd)
        report["steps"].append({"title": title, "ok": ok, "cmd": cmd, "log": out[-9000:]})
        if not ok:
            report["ok"] = False

    base_ok = all(_try_import(m)[0] for m in ["numpy", "scipy", "Cython"])
    mad_ok = _try_import("madmom")[0]
    lib_ok = _try_import("librosa")[0]
    sf_ok = _try_import("soundfile")[0]

    if base_ok and (mad_ok or lib_ok) and sf_ok and not force:
        report["ok"] = True
        return report

    step("Upgrade pip tooling (pip/setuptools<81/wheel)", _pip_cmd() + ["install", "-U", pins["pip"], pins["setuptools"], pins["wheel"]], 10)
    step("Install pinned numpy/scipy/Cython/mido", _pip_cmd() + ["install", pins["numpy"], pins["scipy"], pins["cython"], pins["mido"]], 30)
    step("Install madmom (no-build-isolation)", _pip_cmd() + ["install", "--no-build-isolation", pins["madmom"]], 58)
    step("Install fallback libs (librosa/soundfile/audioread)", _pip_cmd() + ["install", pins["soundfile"], pins["audioread"], pins["librosa"]], 78)

    ping(90, "Verifying imports…")
    checks = ["numpy", "scipy", "Cython", "mido", "madmom", "librosa", "soundfile", "tkinter"]
    for mod in checks:
        ok, err = _try_import(mod)
        report["steps"].append({"title": f"Import check: {mod}", "ok": ok, "log": "OK" if ok else err})
        if not ok and mod in ["numpy", "scipy", "Cython"]:
            report["ok"] = False

    ping(100, "Dependency check done.")
    return report


# ============================================================
# Audio helpers
# ============================================================

def _hash_for_cache(path: str) -> str:
    st = os.stat(path)
    h = hashlib.sha1()
    h.update(os.path.abspath(path).encode("utf-8", "ignore"))
    h.update(str(st.st_size).encode())
    h.update(str(int(st.st_mtime)).encode())
    return h.hexdigest()[:12]

def _find_ffmpeg() -> Optional[str]:
    exe = "ffmpeg.exe" if os.name == "nt" else "ffmpeg"
    return shutil.which(exe)

def _ffmpeg_convert_to_wav(
    src: str,
    dst_wav: str,
    *,
    quick_seconds: int = 0,
) -> Tuple[bool, str]:
    ffmpeg = _find_ffmpeg()
    if not ffmpeg:
        return False, "ffmpeg not found in PATH."

    cmd = [ffmpeg, "-y", "-nostdin"]
    if quick_seconds and quick_seconds > 0:
        cmd += ["-t", str(int(quick_seconds))]
    cmd += ["-i", src, "-vn", "-ac", "1", "-ar", "44100", "-f", "wav", dst_wav]

    ok, out = _run(cmd)
    if ok and os.path.isfile(dst_wav) and os.path.getsize(dst_wav) > 44:
        return True, out
    return False, out

def _safe_mkdir(p: str) -> None:
    os.makedirs(p, exist_ok=True)

def _sanitize_filename(name: str) -> str:
    name = re.sub(r"[<>:\"/\\|?*\x00-\x1F]", "_", name)
    name = name.strip().strip(".")
    return name or "analysis"


# ============================================================
# Data structures
# ============================================================

@dataclass
class AnalysisConfig:
    backend: str  # "auto" | "madmom" | "librosa"
    min_bpm: float = 90.0
    max_bpm: float = 220.0
    prefer_time_signature: int = 4
    onset_refine_ms: int = 200
    onset_threshold_mode: str = "auto"  # "auto" | "fixed"
    onset_threshold_fixed: float = 0.35
    accurate_mode: bool = True
    onset_percentile: Optional[int] = None
    onset_factor: Optional[float] = None

@dataclass
class AnalysisOptions:
    safe_mode: bool = False
    quick_seconds: int = 0
    use_cache: bool = True
    normalize_audio: bool = True
    auto_tune: bool = True
    percussive_assist: bool = False
    maximize_confidence: bool = True
    max_passes: int = 20
    no_improve_limit: int = 6
    improve_epsilon: float = 0.002
    force_full_passes: bool = False  # NEW: run all passes even if plateau

@dataclass
class AnalysisResult:
    ok: bool
    backend_used: str
    notes: str
    audio_path: str
    bpm: Optional[float] = None
    beats: Optional[List[float]] = None
    downbeats: Optional[List[float]] = None
    onsets: Optional[List[float]] = None
    offset_correction_s: float = 0.0
    extra: Optional[Dict[str, Any]] = None
    error: Optional[str] = None

# ============================================================
# MapGen (mixed-lane beatmap suggestion)
# ============================================================

@dataclass
class MapGenConfig:
    enabled: bool = True
    difficulty: int = 5            # 1..10 (higher = denser + more complex)
    lane_count: int = 4
    seed: int = 0                  # 0 = deterministic from audio hash
    min_gap_ms: int = 85           # minimum gap between consecutive notes (global)
    allow_chords: bool = False
    chord_prob: float = 0.10       # only used if allow_chords + high difficulty


def _subdiv_for_diff(diff: int) -> int:
    d = max(1, min(10, int(diff)))
    if d <= 3:
        return 1     # quarters
    if d <= 6:
        return 2     # eighths
    return 4         # sixteenths


def _nearest_in_sorted(xs: List[float], x: float) -> Tuple[float, float]:
    # returns (nearest_value, abs_distance)
    if not xs:
        return (x, 1e9)
    i = bisect.bisect_left(xs, x)
    best = xs[min(i, len(xs) - 1)]
    best_d = abs(best - x)
    if i > 0:
        cand = xs[i - 1]
        d = abs(cand - x)
        if d < best_d:
            best, best_d = cand, d
    return best, best_d


def _grid_from_beats(beats: List[float], subdiv: int) -> List[float]:
    beats = _dedupe_sorted(_clamp_events_nonnegative(beats or []), eps=1e-4)
    if len(beats) < 2:
        return beats
    subdiv = max(1, int(subdiv))
    out: List[float] = []
    for i in range(len(beats) - 1):
        a = beats[i]
        b = beats[i + 1]
        dt = b - a
        if dt <= 1e-4:
            continue
        for s in range(subdiv):
            out.append(a + dt * (float(s) / float(subdiv)))
    out.append(beats[-1])
    return _dedupe_sorted(out, eps=1e-4)


def _quantize_to_grid(t: float, grid: List[float], tol_s: float) -> Optional[float]:
    if t is None or not math.isfinite(t) or t < 0.0 or not grid:
        return None
    nearest, dist = _nearest_in_sorted(grid, float(t))
    return nearest if dist <= tol_s else None


def _difficulty_density_per_beat(diff: int, bpm: Optional[float]) -> float:
    d = max(1, min(10, int(diff)))
    # 1..10 -> 0.55..1.85 notes/beat
    base = 0.55 + (float(d - 1) / 9.0) * 1.30
    if bpm and bpm > 1e-3:
        # high bpm gets a small density reduction, low bpm a small boost
        scale = max(0.75, min(1.20, 160.0 / float(bpm)))
        base *= scale
    return base


def _jack_gap_ms_for_diff(diff: int) -> int:
    d = max(1, min(10, int(diff)))
    # 1..10 -> 210..75
    return int(max(75, min(220, 225 - d * 15)))


def _choose_lane(
    *,
    t_ms: int,
    basis: str,
    intensity: float,
    lane_count: int,
    last_lane: int,
    last_t_by_lane: List[int],
    jack_gap_ms: int,
    rng: random.Random,
) -> int:
    best_lane = 0
    best_score = -1e18

    outer = {0, lane_count - 1} if lane_count >= 2 else {0}
    mid_l = max(0, (lane_count // 2) - 1)
    mid_r = min(lane_count - 1, (lane_count // 2))

    for ln in range(lane_count):
        s = 0.0

        # basis preferences
        if basis == "downbeat":
            s += 1.0 if ln in outer else 0.35
        elif basis == "beat":
            s += 0.80 if (ln == mid_l or ln == mid_r) else 0.55
        else:  # onset/other
            s += 0.78

        # movement flow
        if last_lane >= 0:
            dist = abs(ln - last_lane)
            s += 0.50 - 0.16 * float(dist)  # prefer nearby lanes
            if intensity > 0.65:
                s += 0.04 * float(dist)      # but allow bigger jumps in busy parts

            # light encouragement to alternate parity (feels like L/R hands)
            if (ln % 2) != (last_lane % 2):
                s += 0.10

        # anti-jack
        dt = t_ms - last_t_by_lane[ln]
        if dt < jack_gap_ms:
            s -= 2.2 * (1.0 - float(dt) / float(jack_gap_ms))

        # tiny random jitter to break ties consistently (seeded)
        s += (rng.random() - 0.5) * 0.02

        if s > best_score:
            best_score = s
            best_lane = ln

    return best_lane


def generate_map_notes(
    *,
    audio_path: str,
    beats: List[float],
    downbeats: List[float],
    onsets: List[float],
    bpm: Optional[float],
    time_signature: int,
    cfg: MapGenConfig,
) -> List[Dict[str, Any]]:
    beats = _dedupe_sorted(_clamp_events_nonnegative(beats or []), eps=1e-4)
    if len(beats) < 2:
        return []

    lane_count = max(1, int(cfg.lane_count))
    ts = 4 if int(time_signature) not in (3, 4) else int(time_signature)

    # deterministic seed if 0
    if int(cfg.seed) == 0:
        try:
            seed = int(_hash_for_cache(audio_path), 16) & 0x7FFFFFFF
        except Exception:
            seed = 1337
    else:
        seed = int(cfg.seed) & 0x7FFFFFFF
    rng = random.Random(seed)

    diff = max(1, min(10, int(cfg.difficulty)))
    subdiv = _subdiv_for_diff(diff)

    # quantize tolerance tightens with difficulty
    tol_ms = 36 if diff <= 3 else (26 if diff <= 6 else 18)
    tol_s = float(tol_ms) / 1000.0

    grid = _grid_from_beats(beats, subdiv=subdiv)

    # slot flags keyed by quantized grid time
    slot: Dict[float, Dict[str, Any]] = {t: {"beat": False, "down": False, "onset_n": 0} for t in grid}

    # mark beats/downbeats
    for t in beats:
        qt = _quantize_to_grid(t, grid, tol_s)
        if qt is not None and qt in slot:
            slot[qt]["beat"] = True

    for t in (downbeats or []):
        qt = _quantize_to_grid(float(t), grid, tol_s)
        if qt is not None and qt in slot:
            slot[qt]["down"] = True

    # count onsets per slot (after quantize)
    onsets_q: List[float] = []
    for t in (onsets or []):
        qt = _quantize_to_grid(float(t), grid, tol_s)
        if qt is not None and qt in slot:
            slot[qt]["onset_n"] = int(slot[qt]["onset_n"]) + 1
            onsets_q.append(qt)
    onsets_q = sorted(onsets_q)

    # intensity per grid slot based on local onset density (simple + effective)
    # intensity = onsets in a ~1.2s window mapped to 0..1
    def intensity_at(t: float) -> float:
        if not onsets_q:
            return 0.0
        w = 0.60  # seconds each side
        lo = t - w
        hi = t + w
        i0 = bisect.bisect_left(onsets_q, lo)
        i1 = bisect.bisect_right(onsets_q, hi)
        n = max(0, i1 - i0)
        return max(0.0, min(1.0, float(n) / 8.0))

    notes_per_beat = _difficulty_density_per_beat(diff, bpm)
    p_per_slot = min(0.98, max(0.02, notes_per_beat / float(subdiv)))
    global_gap = max(45, int(cfg.min_gap_ms))

    jack_gap_ms = _jack_gap_ms_for_diff(diff)

    last_t_ms = -10**9
    last_lane = -1
    last_t_by_lane = [-10**9 for _ in range(lane_count)]

    out: List[Dict[str, Any]] = []

    # Iterate grid in order
    for gt in grid:
        flags = slot.get(gt, None)
        if flags is None:
            continue

        beat_flag = bool(flags.get("beat", False))
        down_flag = bool(flags.get("down", False))
        onset_n = int(flags.get("onset_n", 0))

        # Decide basis/priority for this slot
        basis = "none"
        if down_flag:
            basis = "downbeat"
        elif onset_n > 0:
            basis = "onset"
        elif beat_flag:
            basis = "beat"

        if basis == "none":
            continue

        t_ms = int(round(gt * 1000.0))
        if (t_ms - last_t_ms) < global_gap:
            continue

        inten = intensity_at(gt)

        # Selection rules
        pick = False
        if basis == "downbeat":
            pick = True
        elif basis == "beat":
            # calm sections = fewer beats on low difficulty
            mult = 0.85 + 0.25 * inten
            if diff <= 3:
                mult *= 0.75
            pick = (rng.random() < (p_per_slot * mult))
        else:  # onset
            # onsets become more important at higher diff + higher intensity
            mult = 0.95 + 0.55 * inten + 0.06 * float(max(0, diff - 4))
            if diff <= 2 and inten < 0.55:
                mult *= 0.55
            pick = (rng.random() < min(0.98, p_per_slot * mult))

        if not pick:
            continue

        lane = _choose_lane(
            t_ms=t_ms,
            basis=basis,
            intensity=inten,
            lane_count=lane_count,
            last_lane=last_lane,
            last_t_by_lane=last_t_by_lane,
            jack_gap_ms=jack_gap_ms,
            rng=rng,
        )

        # optional chord (very controlled)
        chord = False
        if cfg.allow_chords and diff >= 9 and inten > 0.72 and basis in ("downbeat", "onset"):
            if rng.random() < float(cfg.chord_prob):
                chord = True

        out.append({
            "t": float(gt),
            "lane": int(lane),
            "kind": "tap",
            "basis": basis,
            "intensity": round(float(inten), 3),
        })

        last_t_ms = t_ms
        last_lane = lane
        last_t_by_lane[lane] = t_ms

        if chord and lane_count >= 2:
            # pick a second lane far-ish from the first
            other_choices = [ln for ln in range(lane_count) if ln != lane]
            other_choices.sort(key=lambda ln: -abs(ln - lane))
            lane2 = other_choices[0] if other_choices else lane
            # respect jack gap on lane2 too
            if (t_ms - last_t_by_lane[lane2]) >= max(40, jack_gap_ms // 2):
                out.append({
                    "t": float(gt),
                    "lane": int(lane2),
                    "kind": "tap",
                    "basis": basis + "_chord",
                    "intensity": round(float(inten), 3),
                })
                last_t_by_lane[lane2] = t_ms

    # final sort (time then lane)
    out.sort(key=lambda d: (float(d.get("t", 0.0)), int(d.get("lane", 0))))
    return out


# ============================================================
# Core math helpers
# ============================================================

def _clamp_events_nonnegative(times: List[float]) -> List[float]:
    return [t for t in times if t is not None and t >= 0.0 and math.isfinite(t)]

def _dedupe_sorted(times: List[float], eps: float = 1e-4) -> List[float]:
    if not times:
        return []
    times = sorted(times)
    out = [times[0]]
    for t in times[1:]:
        if (t - out[-1]) > eps:
            out.append(t)
    return out

def _median_bpm_from_beats(beats: List[float]) -> Optional[float]:
    if not beats or len(beats) < 6:
        return None
    intervals = [beats[i + 1] - beats[i] for i in range(len(beats) - 1)]
    intervals = [x for x in intervals if x > 1e-3]
    if not intervals:
        return None
    intervals.sort()
    mid = intervals[len(intervals) // 2]
    if mid <= 0:
        return None
    return 60.0 / mid

def _beat_interval_stats(beats: List[float]) -> Dict[str, float]:
    if not beats or len(beats) < 8:
        return {"mean": 0.0, "std": 0.0, "cv": 1.0}
    ints = [beats[i + 1] - beats[i] for i in range(len(beats) - 1)]
    ints = [x for x in ints if 0.1 <= x <= 2.0]
    if len(ints) < 6:
        return {"mean": 0.0, "std": 0.0, "cv": 1.0}
    m = sum(ints) / len(ints)
    v = sum((x - m) ** 2 for x in ints) / max(1, len(ints) - 1)
    s = math.sqrt(v)
    cv = (s / m) if m > 1e-9 else 1.0
    return {"mean": float(m), "std": float(s), "cv": float(cv)}

def _sample_activation_at_times(act: "Any", times: List[float], fps: float) -> List[float]:
    try:
        import numpy as np
        a = np.asarray(act).astype(float).ravel()
        if a.size < 5:
            return []
        out = []
        max_t = (a.size - 1) / float(fps)
        for t in times:
            if 0.0 <= t <= max_t:
                idx = int(round(t * float(fps)))
                idx = max(0, min(idx, a.size - 1))
                out.append(float(a[idx]))
        return out
    except Exception:
        return []

def _confidence_from_madmom_outputs(
    beats: List[float],
    downbeats: List[float],
    onsets: List[float],
    beat_act: "Any",
    onset_act: "Any",
    fps: float,
) -> Dict[str, Any]:
    try:
        import numpy as np

        beats = beats or []
        downbeats = downbeats or []
        onsets = onsets or []

        bi = _beat_interval_stats(beats)
        cv = float(bi["cv"])

        beat_samples = _sample_activation_at_times(beat_act, beats, fps)
        onset_samples_on_beats = _sample_activation_at_times(onset_act, beats, fps)

        def safe_mean(xs: List[float]) -> float:
            return float(sum(xs) / len(xs)) if xs else 0.0

        beat_mean = safe_mean(beat_samples)
        onset_on_beat_mean = safe_mean(onset_samples_on_beats)

        ba = np.asarray(beat_act).astype(float).ravel()
        oa = np.asarray(onset_act).astype(float).ravel()

        ba_mean = float(np.mean(ba)) if ba.size else 0.0
        ba_std = float(np.std(ba)) if ba.size else 1.0
        oa_mean = float(np.mean(oa)) if oa.size else 0.0
        oa_std = float(np.std(oa)) if oa.size else 1.0

        beat_z = (beat_mean - ba_mean) / (ba_std + 1e-9)
        onset_z = (onset_on_beat_mean - oa_mean) / (oa_std + 1e-9)

        db_ratio = 0.0
        if beats:
            db_ratio = min(1.0, len(downbeats) / max(1.0, len(beats) / 4.0))

        cv_score = 1.0 - min(1.0, max(0.0, (cv - 0.02) / 0.18))
        beat_score = min(1.0, max(0.0, (beat_z + 0.2) / 3.2))
        onset_score = min(1.0, max(0.0, (onset_z + 0.2) / 3.2))
        n_score = min(1.0, max(0.0, (len(beats) - 16) / 120.0))

        score = (0.36 * beat_score + 0.22 * onset_score + 0.18 * cv_score + 0.12 * db_ratio + 0.12 * n_score)
        score = float(min(1.0, max(0.0, score)))

        return {
            "score": score,
            "beat_score": beat_score,
            "onset_score": onset_score,
            "cv_score": cv_score,
            "db_ratio": db_ratio,
            "n_beats": len(beats),
            "cv": cv,
            "beat_z": float(beat_z),
            "onset_z": float(onset_z),
        }
    except Exception:
        return {"score": 0.0, "error": "confidence calc failed"}

def _refine_offset_with_onset_activation(
    event_times: List[float],
    onset_activation: "Any",
    fps: float,
    search_ms: int
) -> float:
    import numpy as np

    if onset_activation is None or len(event_times) < 10:
        return 0.0

    act = np.asarray(onset_activation).astype(float).ravel()
    if act.size < 40:
        return 0.0
    if float(np.max(act)) <= 1e-6:
        return 0.0

    times = np.asarray(event_times, dtype=float)
    max_t = (act.size - 1) / float(fps)
    times = times[(times >= 0.0) & (times <= max_t)]
    if times.size < 10:
        return 0.0

    lags = np.arange(-search_ms, search_ms + 1, 1, dtype=float) / 1000.0
    best_lag = 0.0
    best_score = -1e18

    for lag in lags:
        t = times + lag
        t = t[(t >= 0.0) & (t <= max_t)]
        if t.size < 10:
            continue
        idx = np.clip(np.rint(t * float(fps)).astype(int), 0, act.size - 1)
        score = float(np.sum(act[idx]))
        if score > best_score:
            best_score = score
            best_lag = float(lag)

    return best_lag


# ============================================================
# Backends
# ============================================================

def analyze_with_madmom(
    audio_path: str,
    cfg: AnalysisConfig,
    *,
    progress_cb: Optional[ProgressCB] = None,
) -> AnalysisResult:
    import warnings
    warnings.filterwarnings("ignore", message="pkg_resources is deprecated.*")
    warnings.filterwarnings("ignore", message="Creating an ndarray from ragged nested sequences.*")
    warnings.filterwarnings("ignore", category=DeprecationWarning)
    warnings.filterwarnings("ignore", category=FutureWarning)

    def ping(p: int, m: str) -> None:
        if progress_cb:
            progress_cb(int(p), m)

    try:
        import numpy as np
        from madmom.features.beats import RNNBeatProcessor, DBNBeatTrackingProcessor
        from madmom.features.downbeats import RNNDownBeatProcessor, DBNDownBeatTrackingProcessor
        from madmom.features.onsets import RNNOnsetProcessor, OnsetPeakPickingProcessor
    except Exception as e:
        return AnalysisResult(
            ok=False,
            backend_used="madmom",
            notes="madmom import failed",
            audio_path=audio_path,
            error=f"{type(e).__name__}: {e}\n\n{traceback.format_exc()}",
        )

    try:
        fps = 100

        ping(6, "madmom: Beat activation")
        beat_act = RNNBeatProcessor()(audio_path)

        ping(24, "madmom: Beat tracking")
        beat_tracker = DBNBeatTrackingProcessor(
            fps=fps,
            min_bpm=float(cfg.min_bpm),
            max_bpm=float(cfg.max_bpm),
        )
        beats = beat_tracker(beat_act)
        beats = _dedupe_sorted(_clamp_events_nonnegative([float(x) for x in beats]))

        ping(40, "madmom: Downbeat activation")
        db_act = RNNDownBeatProcessor()(audio_path)

        ping(54, "madmom: Downbeat tracking")
        beats_per_bar = [int(cfg.prefer_time_signature)]
        db_tracker = DBNDownBeatTrackingProcessor(
            beats_per_bar=beats_per_bar,
            fps=fps,
            min_bpm=float(cfg.min_bpm),
            max_bpm=float(cfg.max_bpm),
        )
        db = db_tracker(db_act)
        db = np.asarray(db)
        downbeats: List[float] = []
        if db.ndim == 2 and db.shape[1] >= 2:
            for t, pos in db[:, 0:2]:
                if int(round(float(pos))) == 1:
                    downbeats.append(float(t))
        downbeats = _dedupe_sorted(_clamp_events_nonnegative(downbeats))

        ping(64, "madmom: Onset activation")
        onset_act = RNNOnsetProcessor()(audio_path)

        ping(74, "madmom: Picking onsets")
        if cfg.onset_threshold_mode == "fixed":
            thr = float(cfg.onset_threshold_fixed)
            thr_meta = {"mode": "fixed", "thr": thr}
        else:
            pctl = cfg.onset_percentile if cfg.onset_percentile is not None else (94 if cfg.accurate_mode else 90)
            pctl = int(max(80, min(98, pctl)))
            factor = cfg.onset_factor if cfg.onset_factor is not None else (0.55 if cfg.accurate_mode else 0.45)
            factor = float(max(0.30, min(0.85, factor)))

            thr = float(np.percentile(onset_act, pctl) * factor)
            thr = max(0.12, min(thr, 0.80))
            thr_meta = {"mode": "auto", "pctl": pctl, "factor": factor, "thr": thr}

        onset_picker = OnsetPeakPickingProcessor(
            fps=fps,
            threshold=thr,
            combine=0.02 if cfg.accurate_mode else 0.04,
            pre_max=0.03, post_max=0.03,
            pre_avg=0.10, post_avg=0.10,
        )
        onsets = onset_picker(onset_act)
        onsets = _dedupe_sorted(_clamp_events_nonnegative([float(x) for x in onsets]))

        ping(86, "madmom: Refining offset")
        offset = 0.0
        if cfg.accurate_mode and cfg.onset_refine_ms > 0 and len(beats) >= 10:
            offset = _refine_offset_with_onset_activation(
                beats, onset_act, fps=float(fps), search_ms=int(cfg.onset_refine_ms)
            )
            if abs(offset) > 1e-6:
                beats = _dedupe_sorted(_clamp_events_nonnegative([t + offset for t in beats]))
                downbeats = _dedupe_sorted(_clamp_events_nonnegative([t + offset for t in downbeats]))
                onsets = _dedupe_sorted(_clamp_events_nonnegative([t + offset for t in onsets]))

        bpm = _median_bpm_from_beats(beats)

        ping(94, "madmom: Confidence scoring")
        confidence = _confidence_from_madmom_outputs(beats, downbeats, onsets, beat_act, onset_act, fps=float(fps))

        extra = {
            "fps": fps,
            "min_bpm": cfg.min_bpm,
            "max_bpm": cfg.max_bpm,
            "time_signature": cfg.prefer_time_signature,
            "onset_threshold": thr_meta,
            "confidence": confidence,
        }

        ping(100, "madmom: Done")
        return AnalysisResult(
            ok=True,
            backend_used="madmom",
            notes="madmom used ✅",
            audio_path=audio_path,
            bpm=bpm,
            beats=beats,
            downbeats=downbeats,
            onsets=onsets,
            offset_correction_s=float(offset),
            extra=extra,
        )
    except Exception as e:
        return AnalysisResult(
            ok=False,
            backend_used="madmom",
            notes="madmom analysis crashed",
            audio_path=audio_path,
            error=f"{type(e).__name__}: {e}\n\n{traceback.format_exc()}",
        )

def analyze_with_librosa(
    audio_path: str,
    cfg: AnalysisConfig,
    *,
    progress_cb: Optional[ProgressCB] = None,
) -> AnalysisResult:
    def ping(p: int, m: str) -> None:
        if progress_cb:
            progress_cb(int(p), m)

    try:
        import librosa
    except Exception as e:
        return AnalysisResult(
            ok=False,
            backend_used="librosa",
            notes="librosa import failed",
            audio_path=audio_path,
            error=f"{type(e).__name__}: {e}\n\n{traceback.format_exc()}",
        )

    try:
        ping(12, "librosa: Loading audio")
        y, sr = librosa.load(audio_path, sr=44100, mono=True, duration=None)

        ping(46, "librosa: Beat tracking")
        tempo, beat_frames = librosa.beat.beat_track(y=y, sr=sr, start_bpm=150.0, units="frames")
        beats = librosa.frames_to_time(beat_frames, sr=sr).tolist()
        beats = _dedupe_sorted(_clamp_events_nonnegative([float(x) for x in beats]))

        ping(74, "librosa: Onset detection")
        onset_frames = librosa.onset.onset_detect(y=y, sr=sr, backtrack=False, units="frames")
        onsets = librosa.frames_to_time(onset_frames, sr=sr).tolist()
        onsets = _dedupe_sorted(_clamp_events_nonnegative([float(x) for x in onsets]))

        downbeats = []
        if beats:
            for i, t in enumerate(beats):
                if i % int(cfg.prefer_time_signature) == 0:
                    downbeats.append(float(t))

        ping(100, "librosa: Done")
        return AnalysisResult(
            ok=True,
            backend_used="librosa",
            notes="librosa used (fallback)",
            audio_path=audio_path,
            bpm=float(tempo) if tempo else _median_bpm_from_beats(beats),
            beats=beats,
            downbeats=_dedupe_sorted(downbeats),
            onsets=onsets,
            offset_correction_s=0.0,
            extra={"sr": sr, "confidence": {"score": 0.45}},
        )
    except Exception as e:
        return AnalysisResult(
            ok=False,
            backend_used="librosa",
            notes="librosa analysis crashed",
            audio_path=audio_path,
            error=f"{type(e).__name__}: {e}\n\n{traceback.format_exc()}",
        )


# ============================================================
# Percussive assist (HPSS)
# ============================================================

def make_percussive_wav(wav_in: str, wav_out: str) -> Tuple[bool, str]:
    ok, _ = _try_import("librosa")
    ok2, _ = _try_import("soundfile")
    if not (ok and ok2):
        return False, "librosa + soundfile required for percussive assist."

    try:
        import numpy as np
        import librosa
        import soundfile as sf

        y, sr = librosa.load(wav_in, sr=44100, mono=True)
        _, y_perc = librosa.effects.hpss(y)

        mx = float(np.max(np.abs(y_perc))) if y_perc.size else 0.0
        if mx > 1e-6:
            y_perc = (y_perc / mx) * 0.95

        sf.write(wav_out, y_perc, sr, subtype="PCM_16")
        return True, "OK"
    except Exception:
        return False, traceback.format_exc()


# ============================================================
# Auto settings guess (tempo-guided)
# ============================================================

def auto_guess_settings(audio_path: str) -> Dict[str, Any]:
    out = {
        "min_bpm": 90.0,
        "max_bpm": 220.0,
        "ts": 4,
        "refine_ms": 220,
        "notes": "Default guess",
        "tempo_est": 140.0,
    }

    ok, _ = _try_import("librosa")
    if not ok:
        out["notes"] = "librosa not available; using defaults."
        return out

    try:
        import librosa
        y, sr = librosa.load(audio_path, sr=44100, mono=True, duration=75.0)
        tempo, _ = librosa.beat.beat_track(y=y, sr=sr, start_bpm=150.0)
        tempo = float(tempo) if tempo else 140.0

        cand = tempo
        while cand > 230:
            cand *= 0.5
        while cand < 70:
            cand *= 2.0
        if 70 <= cand <= 105:
            cand2 = cand * 2.0
            if cand2 <= 240:
                cand = cand2

        min_bpm = max(60.0, cand * 0.65)
        max_bpm = min(260.0, cand * 1.35)
        refine = 280 if cand < 120 else 240 if cand < 170 else 220

        out.update({
            "min_bpm": float(min_bpm),
            "max_bpm": float(max_bpm),
            "ts": 4,
            "refine_ms": int(refine),
            "notes": f"Estimated tempo ~{cand:.1f} BPM.",
            "tempo_est": float(cand),
        })
        return out
    except Exception:
        out["notes"] = "Auto-guess failed; using defaults."
        return out


# ============================================================
# Confidence maximizer
# ============================================================

def _conf_score(res: AnalysisResult) -> float:
    try:
        conf = (res.extra or {}).get("confidence", {}) or {}
        s = float(conf.get("score", 0.0) or 0.0)
    except Exception:
        s = 0.0
    beats_n = len(res.beats or [])
    return s + min(0.02, beats_n / 20000.0)

def _mutate_from_best(best: AnalysisConfig, step_i: int, tempo_est: float) -> AnalysisConfig:
    c = AnalysisConfig(**asdict(best))

    recipes = [
        "widen_bpm", "narrow_bpm", "refine_plus", "refine_minus",
        "pctl_plus", "pctl_minus", "factor_plus", "factor_minus",
        "flip_ts", "big_widen",
    ]
    r = recipes[step_i % len(recipes)]

    def clamp(x, a, b):
        return max(a, min(b, x))

    if c.onset_percentile is None:
        c.onset_percentile = 94 if c.accurate_mode else 90
    if c.onset_factor is None:
        c.onset_factor = 0.55 if c.accurate_mode else 0.45

    if r == "widen_bpm":
        c.min_bpm = clamp(c.min_bpm * 0.92, 50.0, 200.0)
        c.max_bpm = clamp(c.max_bpm * 1.08, 120.0, 280.0)
    elif r == "narrow_bpm":
        mid = (c.min_bpm + c.max_bpm) * 0.5
        span = max(40.0, (c.max_bpm - c.min_bpm) * 0.80)
        c.min_bpm = clamp(mid - span * 0.5, 50.0, 240.0)
        c.max_bpm = clamp(mid + span * 0.5, 90.0, 280.0)
    elif r == "refine_plus":
        c.onset_refine_ms = int(clamp(c.onset_refine_ms + 40, 80, 520))
    elif r == "refine_minus":
        c.onset_refine_ms = int(clamp(c.onset_refine_ms - 40, 80, 520))
    elif r == "pctl_plus":
        c.onset_percentile = int(clamp(c.onset_percentile + 2, 84, 98))
    elif r == "pctl_minus":
        c.onset_percentile = int(clamp(c.onset_percentile - 2, 84, 98))
    elif r == "factor_plus":
        c.onset_factor = float(clamp(c.onset_factor + 0.05, 0.30, 0.85))
    elif r == "factor_minus":
        c.onset_factor = float(clamp(c.onset_factor - 0.05, 0.30, 0.85))
    elif r == "flip_ts":
        c.prefer_time_signature = 3 if int(c.prefer_time_signature) == 4 else 4
    elif r == "big_widen":
        c.min_bpm = 60.0
        c.max_bpm = 260.0
        c.onset_refine_ms = int(clamp(c.onset_refine_ms + 60, 120, 520))

    if c.min_bpm >= c.max_bpm - 5:
        c.min_bpm = max(50.0, c.max_bpm - 40.0)

    if 80.0 <= tempo_est <= 240.0 and (step_i % 4 == 0):
        mid = tempo_est
        span = max(60.0, (c.max_bpm - c.min_bpm))
        c.min_bpm = clamp(mid - span * 0.55, 50.0, 240.0)
        c.max_bpm = clamp(mid + span * 0.55, 90.0, 280.0)

    return c


# ============================================================
# Orchestrator (normalize/cache + maximize confidence)
# ============================================================

def analyze_audio_and_export(
    audio_path: str,
    out_json_path: str,
    cfg: AnalysisConfig,
    opt: AnalysisOptions,
    *,
    progress_cb: Optional[ProgressCB] = None,
    cancel_flag: Optional[Callable[[], bool]] = None,
    map_cfg: Optional[MapGenConfig] = None,
) -> Tuple[AnalysisResult, Dict[str, Any]]:
    report: Dict[str, Any] = {"steps": [], "ok": True}
    t0 = time.time()

    def canceled() -> bool:
        return bool(cancel_flag and cancel_flag())

    def ping(p: int, m: str) -> None:
        if progress_cb:
            progress_cb(int(p), m)

    if not os.path.isfile(audio_path):
        res = AnalysisResult(False, "none", "No file", audio_path, error="Audio file not found.")
        report["ok"] = False
        return res, report

    _safe_mkdir(os.path.dirname(out_json_path))

    h = _hash_for_cache(audio_path)
    cache_dir = os.path.join(os.path.dirname(out_json_path), ".beatmap_analyzer_cache")
    _safe_mkdir(cache_dir)
    cached_wav = os.path.join(cache_dir, f"{h}.norm.wav")
    cached_perc = os.path.join(cache_dir, f"{h}.perc.wav")

    analysis_path = audio_path

    if opt.normalize_audio:
        ping(4, "Preparing audio…")
        if opt.use_cache and os.path.isfile(cached_wav) and os.path.getsize(cached_wav) > 44:
            analysis_path = cached_wav
        else:
            ok, _ = _ffmpeg_convert_to_wav(audio_path, cached_wav, quick_seconds=int(opt.quick_seconds))
            if ok:
                analysis_path = cached_wav

    if canceled():
        res = AnalysisResult(False, "none", "Canceled", analysis_path, error="Canceled by user.")
        report["ok"] = False
        return res, report

    mad_ok, mad_err = _try_import("madmom")
    lib_ok, lib_err = _try_import("librosa")

    cfg2 = AnalysisConfig(**asdict(cfg))
    tempo_est = 140.0

    if opt.auto_tune:
        ping(10, "Auto-tuning settings…")
        guess = auto_guess_settings(analysis_path)
        tempo_est = float(guess.get("tempo_est", tempo_est))
        cfg2.min_bpm = float(guess["min_bpm"])
        cfg2.max_bpm = float(guess["max_bpm"])
        cfg2.prefer_time_signature = int(guess["ts"])
        cfg2.onset_refine_ms = int(guess["refine_ms"])
        cfg2.accurate_mode = True

    percussive_ready = False
    if opt.percussive_assist:
        ping(14, "Building percussive assist…")
        if opt.use_cache and os.path.isfile(cached_perc) and os.path.getsize(cached_perc) > 44:
            percussive_ready = True
        else:
            ok, _ = make_percussive_wav(analysis_path, cached_perc)
            percussive_ready = ok

    def run_once(run_cfg: AnalysisConfig, file_path: str, cb: Optional[ProgressCB]) -> AnalysisResult:
        backend2 = run_cfg.backend.strip().lower()

        if opt.safe_mode and backend2 == "auto":
            backend2 = "librosa"

        if backend2 == "madmom":
            if not mad_ok:
                return AnalysisResult(False, "madmom", "madmom forced but not available", file_path,
                                     error=f"madmom import failed: {mad_err}")
            return analyze_with_madmom(file_path, run_cfg, progress_cb=cb)

        if backend2 == "librosa":
            if not lib_ok:
                return AnalysisResult(False, "librosa", "librosa forced but not available", file_path,
                                     error=f"librosa import failed: {lib_err}")
            return analyze_with_librosa(file_path, run_cfg, progress_cb=cb)

        if mad_ok and not opt.safe_mode:
            r = analyze_with_madmom(file_path, run_cfg, progress_cb=cb)
            if r.ok:
                return r
            if lib_ok:
                r2 = analyze_with_librosa(file_path, run_cfg, progress_cb=cb)
                r2.notes = f"madmom failed, fallback to librosa\nmadmom error: {r.error}"
                return r2
            return r

        if lib_ok:
            return analyze_with_librosa(file_path, run_cfg, progress_cb=cb)

        return AnalysisResult(False, "none", "No backend available", file_path,
                              error=f"madmom: {mad_err}\nlibrosa: {lib_err}")

    def map_progress(start: int, end: int, prefix: str) -> Optional[ProgressCB]:
        if not progress_cb:
            return None
        span = max(1, end - start)
        def _cb(p: int, m: str):
            p2 = start + int(span * (max(0, min(100, int(p))) / 100.0))
            progress_cb(p2, f"{prefix}{m}")
        return _cb

    def pick_audio_variant(prefer_perc: bool) -> Tuple[str, str]:
        if prefer_perc and percussive_ready:
            return cached_perc, "Percussive"
        return analysis_path, "Full"

    best_res: Optional[AnalysisResult] = None
    best_cfg: Optional[AnalysisConfig] = None
    best_variant = "Full"
    best_score = -1e9

    ping(20, "Analyzing…")

    forced_librosa = (cfg2.backend.strip().lower() == "librosa") or (opt.safe_mode and cfg2.backend.strip().lower() == "auto")

    if not opt.maximize_confidence or forced_librosa:
        fpath, flavor = pick_audio_variant(prefer_perc=opt.percussive_assist)
        res = run_once(cfg2, fpath, map_progress(22, 92, f"{flavor}: "))
        best_res, best_cfg, best_variant = res, cfg2, flavor
        best_score = _conf_score(res) if res.ok else -1.0
    else:
        no_improve = 0
        total_budget = max(1, int(opt.max_passes))
        seed_variants = [False] + ([True] if (opt.percussive_assist and percussive_ready) else [])
        pass_index = 0

        for prefer_perc in seed_variants:
            if canceled():
                break
            pass_index += 1
            fpath, flavor = pick_audio_variant(prefer_perc=prefer_perc)
            res = run_once(cfg2, fpath, map_progress(22, 42, f"Seed {pass_index}: {flavor} "))
            s = _conf_score(res) if res.ok else -1.0
            if res.ok and s > best_score + 1e-9:
                best_res, best_cfg, best_variant, best_score = res, AnalysisConfig(**asdict(cfg2)), flavor, s
                no_improve = 0
            else:
                no_improve += 1

        while pass_index < total_budget and not canceled():
            if best_cfg is None:
                best_cfg = AnalysisConfig(**asdict(cfg2))

            prefer_perc = (pass_index % 2 == 1) and (opt.percussive_assist and percussive_ready)
            fpath, flavor = pick_audio_variant(prefer_perc=prefer_perc)

            trial_cfg = _mutate_from_best(best_cfg, pass_index, tempo_est)
            trial_cfg.backend = cfg2.backend
            trial_cfg.accurate_mode = True

            pass_index += 1
            start = 42 + int((92 - 42) * ((pass_index - 1) / max(1, total_budget)))
            end = 42 + int((92 - 42) * (pass_index / max(1, total_budget)))

            res = run_once(trial_cfg, fpath, map_progress(start, end, f"Pass {pass_index}/{total_budget} {flavor}: "))
            s = _conf_score(res) if res.ok else -1.0

            if res.ok and s > best_score + float(opt.improve_epsilon):
                best_res, best_cfg, best_variant, best_score = res, trial_cfg, flavor, s
                no_improve = 0
            else:
                no_improve += 1

            ping(min(92, 42 + int((92 - 42) * (pass_index / max(1, total_budget)))),
                 f"Best confidence: {best_score:.3f} (no-improve {no_improve}/{opt.no_improve_limit})")

            if (not opt.force_full_passes) and (no_improve >= int(opt.no_improve_limit)):
                break

    if canceled():
        res = AnalysisResult(False, "none", "Canceled", analysis_path, error="Canceled by user.")
        report["ok"] = False
        return res, report

    res = best_res if best_res is not None else AnalysisResult(False, "none", "All passes failed", analysis_path, error="No successful analysis pass.")
    cfg_used = best_cfg if best_cfg is not None else cfg2

    extra = dict(res.extra or {})
    extra["maximize_confidence"] = {
        "best_score": best_score,
        "best_variant": best_variant,
        "stopped_reason": "plateau_or_budget" if not opt.force_full_passes else "budget",
    }
    res.extra = extra

        # ----------------------------
    # MapGen (optional)
    # ----------------------------
    map_notes: List[Dict[str, Any]] = []
    if map_cfg and bool(map_cfg.enabled) and res.ok:
        try:
            ping(94, "MapGen (placing notes)…")
            map_notes = generate_map_notes(
                audio_path=audio_path,
                beats=res.beats or [],
                downbeats=res.downbeats or [],
                onsets=res.onsets or [],
                bpm=res.bpm,
                time_signature=int(cfg_used.prefer_time_signature),
                cfg=map_cfg,
            )
        except Exception:
            report["steps"].append({"title": "MapGen failed", "ok": False, "log": traceback.format_exc()[-8000:]})
            map_notes = []

    ping(96, "Saving JSON…")

    payload_json = {
        "app": {"name": APP_NAME, "version": APP_VERSION},
        "schema": "beatmap_analyzer_v2",
        "audio": os.path.abspath(audio_path),
        "analysis_audio_used": os.path.abspath(res.audio_path),
        "backend": res.backend_used,
        "notes": res.notes,
        "bpm": res.bpm,
        "offset_correction_s": res.offset_correction_s,
        "beats": res.beats or [],
        "downbeats": res.downbeats or [],
        "onsets": res.onsets or [],
        "config": asdict(cfg_used),
        "options": asdict(opt),
        "mapgen": asdict(map_cfg) if map_cfg else {},
        "map_notes": map_notes,
        "extra": res.extra or {},
        "generated_at_unix": int(time.time()),
        "elapsed_s": round(time.time() - t0, 3),
    }

    try:
        with open(out_json_path, "w", encoding="utf-8") as f:
            json.dump(payload_json, f, indent=2, ensure_ascii=False)
    except Exception:
        report["ok"] = False
        if res.ok:
            res.ok = False
            res.error = "JSON write failed:\n" + traceback.format_exc()

    ping(100, "Done ✅")
    return res, report


# ============================================================
# Recents
# ============================================================

def load_recents() -> List[str]:
    try:
        if os.path.isfile(RECENTS_PATH):
            with open(RECENTS_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, list):
                return [str(x) for x in data if isinstance(x, str)]
    except Exception:
        pass
    return []

def save_recents(paths: List[str]) -> None:
    try:
        paths2 = []
        seen = set()
        for p in paths:
            p = os.path.abspath(p)
            if p not in seen:
                seen.add(p)
                paths2.append(p)
        paths2 = paths2[:8]
        with open(RECENTS_PATH, "w", encoding="utf-8") as f:
            json.dump(paths2, f, indent=2)
    except Exception:
        pass

def push_recent(path: str) -> List[str]:
    rec = load_recents()
    path = os.path.abspath(path)
    rec = [p for p in rec if os.path.abspath(p) != path]
    rec.insert(0, path)
    save_recents(rec)
    return rec


# ============================================================
# CLI (Godot mode)
# ============================================================

def _default_out_for_audio(audio_path: str) -> str:
    base = os.path.splitext(os.path.basename(audio_path))[0]
    base = _sanitize_filename(base)
    _safe_mkdir(DEFAULT_OUT_DIR)
    return os.path.join(DEFAULT_OUT_DIR, base + ".analysis.json")

def run_cli(args: argparse.Namespace) -> int:
    print("[AnalyzerDBG] sys.executable =", sys.executable)
    print("[AnalyzerDBG] sys.version =", sys.version)
    print("[AnalyzerDBG] SCRIPT_DIR =", SCRIPT_DIR)
    print("[AnalyzerDBG] DEFAULT_OUT_DIR =", DEFAULT_OUT_DIR)

    audio_path = (args.audio or "").strip()
    out_path = (args.out or "").strip()
    progress_file = (args.progress_file or "").strip() or None

    def ping(p: int, m: str):
        write_progress_file(progress_file, p, m)

    if not audio_path:
        print("ERROR: --audio is required for CLI mode.", file=sys.stderr)
        ping(100, "ERROR: missing --audio")
        return 2

    if not os.path.isfile(audio_path):
        print(f"ERROR: Audio file not found: {audio_path}", file=sys.stderr)
        ping(100, "ERROR: audio not found")
        return 2

    if not out_path:
        out_path = _default_out_for_audio(audio_path)

    if args.ensure_deps:
        ping(3, "Checking/installing dependencies…")
        rep = ensure_dependencies(force=False, progress_cb=lambda p, m: ping(int(p * 0.20), m))
        if not rep.get("ok", False):
            ping(100, "Dependencies failed ❌")
            print("ERROR: dependencies not OK", file=sys.stderr)
            return 3

    cfg = AnalysisConfig(
        backend=str(args.backend).strip(),
        min_bpm=float(args.min_bpm),
        max_bpm=float(args.max_bpm),
        prefer_time_signature=int(args.ts),
        onset_refine_ms=int(args.refine_ms),
        accurate_mode=bool(args.accurate),
    )

    opt = AnalysisOptions(
        safe_mode=bool(args.safe_mode),
        quick_seconds=int(args.quick_seconds),
        use_cache=True,
        normalize_audio=bool(args.normalize),
        auto_tune=bool(args.auto_tune),
        percussive_assist=bool(args.percussive),
        maximize_confidence=bool(args.max_confidence),
        max_passes=int(args.max_passes),
        no_improve_limit=int(args.no_improve_limit),
        improve_epsilon=float(args.improve_epsilon),
        force_full_passes=bool(args.force_full_passes),
    )

    if opt.maximize_confidence:
        cfg.accurate_mode = True
        opt.quick_seconds = 0

    # ----------------------------
    # Cancel file support
    # ----------------------------
    cancel_file = (getattr(args, "cancel_file", "") or "").strip() or None

    def cancel_flag() -> bool:
        if not cancel_file:
            return False
        return os.path.isfile(cancel_file)

    # ----------------------------
    # MapGen config
    # ----------------------------
    map_cfg = MapGenConfig(
        enabled=bool(getattr(args, "mapgen", True)),
        difficulty=int(getattr(args, "map_diff", 5)),
        lane_count=4,
        seed=int(getattr(args, "map_seed", 0)),
        min_gap_ms=int(getattr(args, "map_min_gap_ms", 85)),
        allow_chords=bool(getattr(args, "map_allow_chords", False)),
        chord_prob=0.10,
    )

    ping(8, "Analyzing…")
    res, rep2 = analyze_audio_and_export(
        audio_path, out_path, cfg, opt,
        progress_cb=lambda p, m: ping(p, m),
        cancel_flag=cancel_flag,
        map_cfg=map_cfg,
    )

    if not res.ok:
        ping(100, "Failed ❌")
        print("❌ Failed", file=sys.stderr)
        print(f"Backend attempted: {res.backend_used}", file=sys.stderr)
        print(res.error or "Unknown error", file=sys.stderr)
        return 2

    conf = ((res.extra or {}).get("confidence", {}) or {})
    conf_score = conf.get("score", None)
    conf_txt = f"{conf_score:.3f}" if isinstance(conf_score, (int, float)) else "n/a"

    maxi = (res.extra or {}).get("maximize_confidence", {}) or {}
    best_s = maxi.get("best_score", None)
    best_s_txt = f"{best_s:.3f}" if isinstance(best_s, (int, float)) else conf_txt

    bpm_txt = f"{res.bpm:.2f}" if res.bpm else "unknown"
    print("✅ Success")
    print(f"Backend:        {res.backend_used}")
    print(f"BPM:            {bpm_txt}")
    print(f"Confidence:     {conf_txt}")
    print(f"Best score:     {best_s_txt}")
    print(f"Beats:          {len(res.beats or [])}")
    print(f"Downbeats:      {len(res.downbeats or [])}")
    print(f"Onsets:         {len(res.onsets or [])}")
    print(f"Offset corr:    {res.offset_correction_s:+.4f}s")
    print("")
    print("Saved JSON:")
    print(out_path)

    ping(100, "Done ✅")
    write_progress_file(progress_file, 100, "Done ✅", {"out": out_path, "confidence": conf_score, "best_score": best_s})
    return 0



# ============================================================
# GUI
# ============================================================

def run_gui(prefill_audio: str = "", prefill_out: str = "") -> int:
    import tkinter as tk
    from tkinter import ttk, filedialog, messagebox

    COLORS = {
        "bg": "#12001f",
        "panel": "#1a0030",
        "panel2": "#0f0024",
        "text": "#f3eaff",
        "muted": "#c9b7ff",
        "border": "#3a1a66",
        "pink": "#ff6bd6",
        "pink2": "#ff3fbf",
        "lav": "#b37cff",
        "good": "#7CFF9A",
        "bad": "#FF6B6B",
        "warn": "#FFD36B",
        "dark": "#150018",
    }

    root = tk.Tk()
    root.title(f"{APP_ID}  •  madmom preferred")
    root.configure(bg=COLORS["bg"])

    root.geometry("560x740")
    root.minsize(520, 660)

    try:
        if os.name == "nt":
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        pass

    style = ttk.Style()
    try:
        style.theme_use("clam")
    except Exception:
        pass

    style.configure("TCombobox", padding=6)
    style.configure("TNotebook", background=COLORS["bg"], borderwidth=0)
    style.configure("TNotebook.Tab", padding=[10, 6])

    q: "queue.Queue[Tuple[str, Any]]" = queue.Queue()

    state = {"busy": False, "cancel": False, "last_progress_ts": time.time(), "last_msg": "", "spin_i": 0}
    prog = {"shown": 0.0, "target": 0}
    pb_anim = {"phase": 0.0}
    pb_h = 16

    def set_target(p: int, msg: str = ""):
        p = max(0, min(100, int(p)))
        if p > prog["target"]:
            prog["target"] = p
        if msg:
            state["last_msg"] = msg
            status_var.set(msg)
        state["last_progress_ts"] = time.time()

    def hsv_to_hex(h: float, s: float, v: float) -> str:
        r, g, b = colorsys.hsv_to_rgb(h % 1.0, s, v)
        return f"#{int(r*255):02x}{int(g*255):02x}{int(b*255):02x}"

    def draw_rainbow_bar():
        w = pb_canvas.winfo_width()
        h = pb_canvas.winfo_height()
        if w <= 2 or h <= 2:
            root.after(16, draw_rainbow_bar)
            return

        pb_canvas.delete("all")

        # background + border
        pb_canvas.create_rectangle(0, 0, w, h, fill=COLORS["panel2"], outline=COLORS["border"])

        fill_w = int(w * (max(0.0, min(100.0, prog["shown"])) / 100.0))
        if fill_w > 0:
            stripe = 10
            phase = pb_anim["phase"]

            # Rainbow fill
            for x in range(0, fill_w, stripe):
                hue = (x / max(1, w)) + phase
                col = hsv_to_hex(hue, 0.85, 1.0)
                pb_canvas.create_rectangle(x, 0, min(fill_w, x + stripe), h, fill=col, outline="")

            # Removed the old top "white cap" lines entirely ✅
            # (You asked to remove the white stuff on top.)

            # Moving vertical installer sheen (inside filled area)
            sheen_w = max(10, min(22, w // 28))
            sheen_x = int(((phase * 1.6) % 1.0) * fill_w)
            x0 = max(0, sheen_x - sheen_w // 2)
            x1 = min(fill_w, sheen_x + sheen_w // 2)

            # layered shimmer bands (brighter center, softer edges)
            bands = [
                ("gray75", 0.22),
                ("gray50", 0.42),
                ("gray25", 0.68),
                ("gray12", 0.92),
            ]
            for st, t in bands:
                bx0 = int(x0 + (x1 - x0) * (0.5 - t / 2.0))
                bx1 = int(x0 + (x1 - x0) * (0.5 + t / 2.0))
                bx0 = max(0, bx0)
                bx1 = min(fill_w, bx1)
                if bx1 > bx0:
                    pb_canvas.create_rectangle(bx0, 1, bx1, h - 1, fill="#ffffff", outline="", stipple=st)

            # subtle inner dark edge for crispness (not white)
            pb_canvas.create_rectangle(1, 1, max(1, fill_w - 1), h - 1, outline="#2a1246")

        pb_canvas.create_text(w - 34, h // 2, text=f"{int(prog['shown'])}%", fill=COLORS["text"], font=("Segoe UI", 9, "bold"))
        pb_anim["phase"] = (pb_anim["phase"] + 0.0045) % 1.0
        root.after(16, draw_rainbow_bar)

    def animate_progress():
        t = float(prog["target"])
        s = float(prog["shown"])

        # Smooth approach that looks like an installer bar
        if s < t:
            s = s + (t - s) * 0.12
            if (t - s) < 0.12:
                s = t
            prog["shown"] = min(s, 100.0)

        if state["busy"]:
            dt = time.time() - state["last_progress_ts"]
            if dt > 7.0:
                state["spin_i"] += 1
                spinner = ["∙", "•", "●", "•"][state["spin_i"] % 4]
                status_var.set((state["last_msg"] or "Working") + f" {spinner}")

        root.after(16, animate_progress)

    def card(parent, title_text: str):
        c = tk.Frame(parent, bg=COLORS["panel"], bd=0, highlightthickness=1, highlightbackground=COLORS["border"])
        h = tk.Frame(c, bg=COLORS["panel"])
        h.pack(fill="x", padx=12, pady=(12, 8))
        tk.Label(h, text=title_text, fg=COLORS["text"], bg=COLORS["panel"], font=("Segoe UI", 11, "bold")).pack(anchor="w")
        body = tk.Frame(c, bg=COLORS["panel"])
        body.pack(fill="both", expand=True, padx=12, pady=(0, 12))
        return c, body

    def log_append(txt: str):
        log_box.configure(state="normal")
        log_box.insert("end", txt.rstrip() + "\n")
        log_box.see("end")
        log_box.configure(state="disabled")

    def set_results(txt: str):
        results_box.configure(state="normal")
        results_box.delete("1.0", "end")
        results_box.insert("1.0", txt)
        results_box.configure(state="disabled")

    def default_out_path_for_audio(ap: str) -> str:
        base = os.path.splitext(os.path.basename(ap))[0]
        base = _sanitize_filename(base)
        _safe_mkdir(DEFAULT_OUT_DIR)
        return os.path.join(DEFAULT_OUT_DIR, base + ".analysis.json")

    def set_busy(b: bool):
        state["busy"] = b
        for w in [btn_install, btn_analyze, btn_cancel, btn_browse, btn_out, btn_open]:
            try:
                w.configure(state=("disabled" if b and w not in [btn_cancel] else "normal"))
            except Exception:
                pass
        if not b:
            btn_cancel.configure(state="disabled")
        else:
            btn_cancel.configure(state="normal")

    header = tk.Frame(root, bg=COLORS["bg"])
    header.pack(fill="x", padx=14, pady=(12, 8))
    tk.Label(header, text=APP_NAME, fg=COLORS["text"], bg=COLORS["bg"], font=("Segoe UI", 18, "bold")).pack(anchor="w")
    tk.Label(header, text=f"{APP_VERSION}  •  purple-pink build  •  rainbow loader",
             fg=COLORS["muted"], bg=COLORS["bg"], font=("Segoe UI", 10)).pack(anchor="w", pady=(2, 0))

    main = tk.Frame(root, bg=COLORS["bg"])
    main.pack(fill="both", expand=True, padx=14, pady=8)

    file_card, file_body = card(main, "Project")
    file_card.pack(fill="x", pady=(0, 10))

    audio_var = tk.StringVar(value=prefill_audio or "")
    out_var = tk.StringVar(value=prefill_out or "")
    backend_var = tk.StringVar(value="auto")

    recents = load_recents()
    recent_var = tk.StringVar(value=recents[0] if recents else "")
    recent_box = ttk.Combobox(file_body, textvariable=recent_var, values=recents, state="readonly")
    tk.Label(file_body, text="Recent", fg=COLORS["muted"], bg=COLORS["panel"], font=("Segoe UI", 9)).pack(anchor="w")
    recent_box.pack(fill="x", pady=(6, 10))

    def apply_audio(p: str):
        if p and os.path.isfile(p):
            audio_var.set(p)
            if not out_var.get().strip():
                out_var.set(default_out_path_for_audio(p))

    def on_recent(_evt=None):
        apply_audio(recent_var.get().strip())
    recent_box.bind("<<ComboboxSelected>>", on_recent)

    tk.Label(file_body, text="Audio", fg=COLORS["muted"], bg=COLORS["panel"], font=("Segoe UI", 9)).pack(anchor="w")
    row_a = tk.Frame(file_body, bg=COLORS["panel"])
    row_a.pack(fill="x", pady=(6, 10))

    ent_audio = tk.Entry(row_a, textvariable=audio_var, fg=COLORS["text"], bg=COLORS["panel2"], insertbackground=COLORS["text"],
                         relief="flat", font=("Segoe UI", 10))
    ent_audio.pack(side="left", fill="x", expand=True, ipady=6)

    def pick_audio():
        p = filedialog.askopenfilename(
            title="Choose audio file",
            filetypes=[("Audio files", "*.wav *.mp3 *.flac *.ogg *.m4a *.aac *.aiff *.aif"), ("All files", "*.*")],
        )
        if p:
            apply_audio(p)
            new_rec = push_recent(p)
            recent_box.configure(values=new_rec)
            recent_var.set(new_rec[0])

    btn_browse = tk.Button(row_a, text="Browse", command=pick_audio,
                           bg=COLORS["pink"], fg=COLORS["dark"], relief="flat",
                           font=("Segoe UI", 10, "bold"), padx=12, pady=6)
    btn_browse.pack(side="left", padx=(10, 0))

    tk.Label(file_body, text="Output JSON", fg=COLORS["muted"], bg=COLORS["panel"], font=("Segoe UI", 9)).pack(anchor="w")
    row_o = tk.Frame(file_body, bg=COLORS["panel"])
    row_o.pack(fill="x", pady=(6, 0))

    ent_out = tk.Entry(row_o, textvariable=out_var, fg=COLORS["text"], bg=COLORS["panel2"], insertbackground=COLORS["text"],
                       relief="flat", font=("Segoe UI", 10))
    ent_out.pack(side="left", fill="x", expand=True, ipady=6)

    def pick_out():
        _safe_mkdir(DEFAULT_OUT_DIR)
        p = filedialog.asksaveasfilename(
            title="Save analysis JSON as…",
            defaultextension=".json",
            filetypes=[("JSON", "*.json"), ("All files", "*.*")],
            initialdir=DEFAULT_OUT_DIR,
        )
        if p:
            out_var.set(p)

    btn_out = tk.Button(row_o, text="Path", command=pick_out,
                        bg=COLORS["lav"], fg=COLORS["dark"], relief="flat",
                        font=("Segoe UI", 10, "bold"), padx=12, pady=6)
    btn_out.pack(side="left", padx=(10, 0))

    settings_card, settings_body = card(main, "Settings")
    settings_card.pack(fill="x", pady=(0, 10))

    accurate_var = tk.BooleanVar(value=True)
    normalize_var = tk.BooleanVar(value=True)
    autotune_var = tk.BooleanVar(value=True)
    percussive_var = tk.BooleanVar(value=False)
    safe_mode_var = tk.BooleanVar(value=False)
    max_conf_var = tk.BooleanVar(value=True)
    force_full_var = tk.BooleanVar(value=False)  # NEW toggle

    max_passes_var = tk.IntVar(value=20)
    min_bpm_var = tk.DoubleVar(value=90.0)
    max_bpm_var = tk.DoubleVar(value=220.0)
    ts_var = tk.IntVar(value=4)
    refine_ms_var = tk.IntVar(value=220)
    quick_var = tk.IntVar(value=0)

    top_row = tk.Frame(settings_body, bg=COLORS["panel"])
    top_row.pack(fill="x", pady=(0, 6))
    tk.Label(top_row, text="Backend", fg=COLORS["muted"], bg=COLORS["panel"], font=("Segoe UI", 9)).pack(side="left")
    backend_box = ttk.Combobox(top_row, textvariable=backend_var, values=["auto", "madmom", "librosa"], state="readonly", width=10)
    backend_box.pack(side="right")

    row_bpm = tk.Frame(settings_body, bg=COLORS["panel"])
    row_bpm.pack(fill="x", pady=6)
    tk.Label(row_bpm, text="BPM", fg=COLORS["muted"], bg=COLORS["panel"], font=("Segoe UI", 9)).pack(side="left")
    tk.Entry(row_bpm, textvariable=min_bpm_var, width=7, fg=COLORS["text"], bg=COLORS["panel2"],
             insertbackground=COLORS["text"], relief="flat", font=("Segoe UI", 10)).pack(side="right", ipady=4)
    tk.Label(row_bpm, text="min", fg=COLORS["muted"], bg=COLORS["panel"], font=("Segoe UI", 8)).pack(side="right", padx=(6, 0))
    tk.Entry(row_bpm, textvariable=max_bpm_var, width=7, fg=COLORS["text"], bg=COLORS["panel2"],
             insertbackground=COLORS["text"], relief="flat", font=("Segoe UI", 10)).pack(side="right", ipady=4)
    tk.Label(row_bpm, text="max", fg=COLORS["muted"], bg=COLORS["panel"], font=("Segoe UI", 8)).pack(side="right", padx=(6, 10))

    row_misc = tk.Frame(settings_body, bg=COLORS["panel"])
    row_misc.pack(fill="x", pady=6)
    tk.Label(row_misc, text="TS", fg=COLORS["muted"], bg=COLORS["panel"], font=("Segoe UI", 9)).pack(side="left")
    ttk.Combobox(row_misc, textvariable=ts_var, values=[3, 4], state="readonly", width=5).pack(side="left", padx=(8, 14))
    tk.Label(row_misc, text="Refine ms", fg=COLORS["muted"], bg=COLORS["panel"], font=("Segoe UI", 9)).pack(side="left")
    tk.Entry(row_misc, textvariable=refine_ms_var, width=7, fg=COLORS["text"], bg=COLORS["panel2"],
             insertbackground=COLORS["text"], relief="flat", font=("Segoe UI", 10)).pack(side="left", padx=(8, 14), ipady=4)
    tk.Label(row_misc, text="Quick s", fg=COLORS["muted"], bg=COLORS["panel"], font=("Segoe UI", 9)).pack(side="left")
    tk.Entry(row_misc, textvariable=quick_var, width=7, fg=COLORS["text"], bg=COLORS["panel2"],
             insertbackground=COLORS["text"], relief="flat", font=("Segoe UI", 10)).pack(side="left", padx=(8, 0), ipady=4)

    def tgl(text: str, var: tk.Variable):
        tk.Checkbutton(
            settings_body, text=text, variable=var,
            fg=COLORS["text"], bg=COLORS["panel"],
            activebackground=COLORS["panel"], activeforeground=COLORS["text"],
            selectcolor=COLORS["panel2"], font=("Segoe UI", 10, "bold"),
        ).pack(anchor="w", pady=2)

    tgl("Accurate mode", accurate_var)
    tgl("Normalize (ffmpeg)", normalize_var)
    tgl("Auto-tune settings", autotune_var)
    tgl("Percussive assist", percussive_var)
    tgl("Safe mode (librosa)", safe_mode_var)
    tgl("Maximize confidence (keeps trying)", max_conf_var)
    tgl("Force full passes (ignore plateau)", force_full_var)  # NEW

    row_pass = tk.Frame(settings_body, bg=COLORS["panel"])
    row_pass.pack(fill="x", pady=(6, 0))
    tk.Label(row_pass, text="Max passes", fg=COLORS["muted"], bg=COLORS["panel"], font=("Segoe UI", 9)).pack(side="left")
    tk.Entry(row_pass, textvariable=max_passes_var, width=6, fg=COLORS["text"], bg=COLORS["panel2"],
             insertbackground=COLORS["text"], relief="flat", font=("Segoe UI", 10)).pack(side="right", ipady=4)

    status_card, status_body = card(main, "Progress")
    status_card.pack(fill="x", pady=(0, 10))

    status_var = tk.StringVar(value="Ready.")
    tk.Label(status_body, textvariable=status_var, fg=COLORS["text"], bg=COLORS["panel"],
             font=("Segoe UI", 10), wraplength=520, justify="left").pack(anchor="w", pady=(0, 8))

    pb_canvas = tk.Canvas(status_body, height=pb_h, bg=COLORS["panel"], highlightthickness=0)
    pb_canvas.pack(fill="x")

    action_row = tk.Frame(main, bg=COLORS["bg"])
    action_row.pack(fill="x", pady=(0, 10))

    def open_output_folder():
        p = out_var.get().strip()
        if not p:
            return
        folder = os.path.dirname(os.path.abspath(p))
        if os.path.isdir(folder):
            try:
                if os.name == "nt":
                    os.startfile(folder)  # type: ignore
                else:
                    subprocess.run(["xdg-open", folder])
            except Exception:
                messagebox.showerror("Open failed", "Could not open folder:\n" + folder)

    def cancel_now():
        if not state["busy"]:
            return
        state["cancel"] = True
        state["last_msg"] = "Cancel requested… stopping between steps."
        status_var.set(state["last_msg"])

    def build_cfg_opt() -> Tuple[AnalysisConfig, AnalysisOptions]:
        cfg = AnalysisConfig(
            backend=backend_var.get().strip(),
            min_bpm=float(min_bpm_var.get()),
            max_bpm=float(max_bpm_var.get()),
            prefer_time_signature=int(ts_var.get()),
            onset_refine_ms=int(refine_ms_var.get()),
            accurate_mode=bool(accurate_var.get()),
        )
        opt = AnalysisOptions(
            safe_mode=bool(safe_mode_var.get()),
            quick_seconds=int(quick_var.get()),
            use_cache=True,
            normalize_audio=bool(normalize_var.get()),
            auto_tune=bool(autotune_var.get()),
            percussive_assist=bool(percussive_var.get()),
            maximize_confidence=bool(max_conf_var.get()),
            max_passes=max(1, min(200, int(max_passes_var.get()))),
            force_full_passes=bool(force_full_var.get()),
        )
        if opt.maximize_confidence:
            cfg.accurate_mode = True
            opt.quick_seconds = 0
        return cfg, opt

    def install_deps():
        if state["busy"]:
            messagebox.showinfo("Busy", "Already working.")
            return
        set_busy(True)
        state["cancel"] = False
        prog["target"] = 0
        state["last_msg"] = "Installing/repairing dependencies…"
        status_var.set(state["last_msg"])
        log_append("\n== Install/Repair deps ==")

        def worker():
            rep = ensure_dependencies(force=False, progress_cb=lambda p, m: q.put(("progress", (p, m))))
            q.put(("deps", rep))

        import threading
        threading.Thread(target=worker, daemon=True).start()

    def analyze_now():
        if state["busy"]:
            messagebox.showinfo("Busy", "Already analyzing.")
            return

        ap = audio_var.get().strip()
        if not ap or not os.path.isfile(ap):
            messagebox.showerror("No file", "Choose a valid audio file first.")
            return

        op = out_var.get().strip()
        if not op:
            out_var.set(default_out_path_for_audio(ap))
            op = out_var.get().strip()

        cfg, opt = build_cfg_opt()

        set_busy(True)
        state["cancel"] = False
        prog["target"] = 0
        state["last_msg"] = "Analyzing…"
        status_var.set(state["last_msg"])

        def worker():
            rep = ensure_dependencies(force=False, progress_cb=lambda p, m: q.put(("progress", (int(p * 0.25), m))))
            q.put(("deps_short", rep))

            res, rep2 = analyze_audio_and_export(
                ap, op, cfg, opt,
                progress_cb=lambda p, m: q.put(("progress", (p, m))),
                cancel_flag=lambda: bool(state["cancel"]),
            )
            q.put(("res", (res, op, rep2)))

        import threading
        threading.Thread(target=worker, daemon=True).start()

    btn_install = tk.Button(action_row, text="Install/Repair", command=install_deps,
                            bg=COLORS["lav"], fg=COLORS["dark"], relief="flat",
                            font=("Segoe UI", 10, "bold"), padx=12, pady=8)
    btn_install.pack(side="left")

    btn_analyze = tk.Button(action_row, text="Analyze", command=analyze_now,
                            bg=COLORS["pink2"], fg=COLORS["dark"], relief="flat",
                            font=("Segoe UI", 12, "bold"), padx=16, pady=10)
    btn_analyze.pack(side="left", padx=(10, 0))

    btn_cancel = tk.Button(action_row, text="Cancel", command=cancel_now,
                           bg=COLORS["bad"], fg=COLORS["dark"], relief="flat",
                           font=("Segoe UI", 10, "bold"), padx=12, pady=8)
    btn_cancel.pack(side="left", padx=(10, 0))
    btn_cancel.configure(state="disabled")

    btn_open = tk.Button(action_row, text="Open Folder", command=open_output_folder,
                         bg=COLORS["pink"], fg=COLORS["dark"], relief="flat",
                         font=("Segoe UI", 10, "bold"), padx=12, pady=8)
    btn_open.pack(side="right")

    tabs = ttk.Notebook(main)
    tabs.pack(fill="both", expand=True)

    tab_res = tk.Frame(tabs, bg=COLORS["bg"])
    tab_log = tk.Frame(tabs, bg=COLORS["bg"])
    tabs.add(tab_res, text="Result")
    tabs.add(tab_log, text="Log")

    results_box = tk.Text(tab_res, height=10, bg=COLORS["panel2"], fg=COLORS["text"],
                          insertbackground=COLORS["text"], relief="flat")
    results_box.pack(fill="both", expand=True)
    results_box.insert("1.0", "No analysis yet.\n")
    results_box.configure(state="disabled")

    log_box = tk.Text(tab_log, height=10, bg=COLORS["panel2"], fg=COLORS["text"],
                      insertbackground=COLORS["text"], relief="flat")
    log_box.pack(fill="both", expand=True)
    log_box.insert("1.0", f"{APP_ID} log\n")
    log_box.configure(state="disabled")

    # Apply prefill (if launched with args)
    if prefill_audio:
        apply_audio(prefill_audio)
        if prefill_out:
            out_var.set(prefill_out)

    def poll():
        try:
            while True:
                kind, payload = q.get_nowait()

                if kind == "progress":
                    pct, msg = payload
                    set_target(int(pct), str(msg))

                elif kind == "deps":
                    rep = payload
                    log_append("\n== Dependency report ==")
                    log_append(f"Python: {rep.get('python','')}")
                    log_append(f"Exe:    {rep.get('executable','')}")
                    if rep.get("warning"):
                        log_append("⚠️ " + str(rep["warning"]))
                    for s in rep.get("steps", []):
                        icon = "✅" if s.get("ok") else "❌"
                        log_append(f"{icon} {s.get('title')}")
                        if not s.get("ok"):
                            log_append("   ↳ " + str(s.get("log", "")).replace("\n", "\n   ↳ ")[:2500])
                    set_target(100, "Dependencies check complete ✅")
                    set_busy(False)

                elif kind == "deps_short":
                    rep = payload
                    if not rep.get("ok", False):
                        log_append("\n⚠️ Dependencies not fully OK. Some features may fail.")

                elif kind == "res":
                    res, outp, _rep2 = payload

                    if not res.ok:
                        set_target(100, "Analysis failed ❌")
                        set_results(f"Backend attempted: {res.backend_used}\n\n{res.notes}\n\nERROR:\n{res.error}\n")
                        set_busy(False)
                        continue

                    conf = ((res.extra or {}).get("confidence", {}) or {})
                    conf_score = conf.get("score", None)
                    conf_txt = f"{conf_score:.3f}" if isinstance(conf_score, (int, float)) else "n/a"

                    beat_n = len(res.beats or [])
                    db_n = len(res.downbeats or [])
                    on_n = len(res.onsets or [])
                    bpm_txt = f"{res.bpm:.2f}" if res.bpm else "unknown"

                    maxi = (res.extra or {}).get("maximize_confidence", {}) or {}
                    best_s = maxi.get("best_score", None)
                    best_s_txt = f"{best_s:.3f}" if isinstance(best_s, (int, float)) else conf_txt

                    summary = (
                        f"✅ Success\n"
                        f"Backend:        {res.backend_used}\n"
                        f"BPM:            {bpm_txt}\n"
                        f"Confidence:     {conf_txt}\n"
                        f"Best score:     {best_s_txt}\n"
                        f"Beats:          {beat_n}\n"
                        f"Downbeats:      {db_n}\n"
                        f"Onsets:         {on_n}\n"
                        f"Offset corr:    {res.offset_correction_s:+.4f}s\n\n"
                        f"Saved JSON:\n{outp}\n"
                    )
                    set_results(summary)
                    set_target(100, "Done ✅")

                    new_rec = push_recent(audio_var.get().strip())
                    recent_box.configure(values=new_rec)
                    recent_var.set(new_rec[0])

                    set_busy(False)

        except queue.Empty:
            pass

        root.after(120, poll)

    root.after(16, animate_progress)
    root.after(16, draw_rainbow_bar)
    root.after(120, poll)

    root.mainloop()
    return 0


# ============================================================
# Entrypoint
# ============================================================

def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--cli", action="store_true", help="Run in CLI mode (Godot-friendly).")
    ap.add_argument("--audio", type=str, default="", help="Audio file path.")
    ap.add_argument("--out", type=str, default="", help="Output JSON path.")
    ap.add_argument("--progress-file", type=str, default="", help="Write progress JSON here (for Godot progress UI).")

    ap.add_argument("--cancel-file", type=str, default="", help="CLI: if this file exists, analysis cancels.")
    ap.add_argument("--mapgen", action="store_true", help="Generate mixed-lane beatmap into map_notes.")
    ap.add_argument("--no-mapgen", action="store_true", help="Disable map generation.")
    ap.add_argument("--map-diff", type=int, default=5, help="Map difficulty 1..10.")
    ap.add_argument("--map-seed", type=int, default=0, help="0 = deterministic from audio hash.")
    ap.add_argument("--map-min-gap-ms", type=int, default=85, help="Global min gap between notes.")
    ap.add_argument("--map-allow-chords", action="store_true", help="Allow rare chords on high difficulty.")


    ap.add_argument("--backend", type=str, default="auto", choices=["auto", "madmom", "librosa"])
    ap.add_argument("--min-bpm", type=float, default=90.0)
    ap.add_argument("--max-bpm", type=float, default=220.0)
    ap.add_argument("--ts", type=int, default=4, choices=[3, 4])
    ap.add_argument("--refine-ms", type=int, default=220)

    ap.add_argument("--accurate", action="store_true", help="Accurate mode.")
    ap.add_argument("--fast", action="store_true", help="Fast-ish mode (turns off accurate).")

    ap.add_argument("--normalize", action="store_true")
    ap.add_argument("--no-normalize", action="store_true")
    ap.add_argument("--auto-tune", action="store_true")
    ap.add_argument("--no-auto-tune", action="store_true")
    ap.add_argument("--percussive", action="store_true")
    ap.add_argument("--safe-mode", action="store_true")
    ap.add_argument("--max-confidence", action="store_true")
    ap.add_argument("--no-max-confidence", action="store_true")

    ap.add_argument("--max-passes", type=int, default=50)
    ap.add_argument("--no-improve-limit", type=int, default=6)
    ap.add_argument("--improve-epsilon", type=float, default=0.002)
    ap.add_argument("--force-full-passes", action="store_true")

    ap.add_argument("--quick-seconds", type=int, default=0)
    ap.add_argument("--ensure-deps", action="store_true", help="CLI: install/repair deps if needed.")
    ap.add_argument("--scan-venv", action="store_true", help="Allow time-limited deeper venv scan if not found.")
    ap.add_argument("--no-relaunch", action="store_true", help="Disable venv relaunch.")
    ap.add_argument("--no-autostart", action="store_true", help="GUI: do not autostart (reserved; GUI currently manual).")

    ns = ap.parse_args(argv)

    # normalize flags
    if ns.fast:
        ns.accurate = False
    elif not ns.accurate:
        ns.accurate = True

    if ns.no_normalize:
        ns.normalize = False
    elif not ns.normalize:
        ns.normalize = True

    if ns.no_auto_tune:
        ns.auto_tune = False
    elif not ns.auto_tune:
        ns.auto_tune = True

    if ns.no_max_confidence:
        ns.max_confidence = False
    elif not ns.max_confidence:
        ns.max_confidence = True
    
    if ns.no_mapgen:
        ns.mapgen = False
    elif not ns.mapgen:
        ns.mapgen = True

    ns.map_diff = max(1, min(10, int(ns.map_diff)))
    ns.map_min_gap_ms = max(25, min(250, int(ns.map_min_gap_ms)))

    ns.max_passes = max(1, min(200, int(ns.max_passes)))
    return ns

def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)

    # venv relaunch (unless disabled)
    if "--no-relaunch" not in sys.argv and not args.no_relaunch:
        relaunch_into_found_venv_if_needed(allow_scan=bool(args.scan_venv))

    # Choose mode:
    # - Explicit --cli
    # - Or if Godot passes audio+out+progress-file etc (we treat that as CLI)
    wants_cli = bool(args.cli) or (bool(args.audio) and (bool(args.out) or bool(args.progress_file)))

    if wants_cli:
        return run_cli(args)

    # GUI
    return run_gui(prefill_audio=str(args.audio or ""), prefill_out=str(args.out or ""))

def safe_entry() -> int:
    try:
        return main()
    except SystemExit:
        raise
    except Exception:
        tb = traceback.format_exc()
        logp = _crash_log_file()
        _write_text(logp, tb)
        _show_fatal_popup(APP_ID, f"{APP_ID} crashed.\n\nCrash log saved to:\n{logp}\n\nLast traceback:\n{tb[-1600:]}")
        return 1

if __name__ == "__main__":
    raise SystemExit(safe_entry())
