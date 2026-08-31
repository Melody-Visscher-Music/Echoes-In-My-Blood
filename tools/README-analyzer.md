# Beatmap Analyzer — BeatNet + Librosa fusion

Audio analysis for the beatmap editor, rebuilt around **BeatNet** (AI beat/downbeat
grid) and **librosa** (band-split onset detection and structure). Replaces the
previous madmom-driven analyzer.

## Why this split

Generic beat trackers fail on Rawstyle. Their models are trained on acoustic
material and expect clean transients; a distorted, gated kick reads to them as a
wall of broadband noise, so they drop the tempo or lock onto the wrong pulse.

The two halves cover each other's blind spots:

| | Good at | Blind to |
|---|---|---|
| **BeatNet** | tempo, bar phase, surviving distortion | 20 ms frame resolution; no structural awareness |
| **Librosa** | sample-accurate transients, band separation, structure | needs to be told where the beat is |

Measured on `Echoes in my blood.wav`: BeatNet alone produces beats with **31 ms**
spacing jitter (its frames are 20 ms wide). After fusion: **2.5 ms**.

## Pipeline

1. **Decode** → mono 44.1 kHz for analysis, 22.05 kHz WAV for BeatNet.
2. **BeatNet** (offline CNN + DBN) → tempo seed and bar phase.
3. **Tempo lock** — DFT comb over the kick envelope, coarse-to-fine, seeded by
   BeatNet's octave. Resolves tempo to <0.1 BPM.
4. **Grid search** — librosa DP beat tracking on the *kick band only*, at four
   tightness settings, plus the pure metronome grid. Each candidate is scored on
   kick-energy alignment, spacing regularity and coverage; the best wins.
5. **Transient snap** — per-beat deviations are measured, then a running median
   is applied, so a shared latency is corrected without introducing jitter.
6. **Band-split onsets** — kick / mid / high, each peak-picked with its own
   noise floor and plausible rate.
7. **Structure** — per-bar features → tags (`kick`, `gated_kick`, `kick_roll`,
   `screech`, `breakdown`, `buildup`) → sections, including **fake drops**
   (full energy for ≤2 bars, then collapse).
8. **Map generation** — onsets quantised to binary *and triplet* subdivisions,
   filled against per-role budget quotas, spread across lanes.

## Frequency bands

| Band | Range | What lives there |
|---|---|---|
| sub | 35–120 Hz | kick fundamental |
| punch | 120–260 Hz | kick body / distortion |
| mid | 700–3500 Hz | screeches, leads |
| high | 5–12 kHz | hats, crashes |

Sub and punch are filtered in the **time domain** (zero-phase Butterworth), not
read off the STFT — at any affordable FFT size a 35–120 Hz kick spans only two
or three bins, too coarse to time a transient. The kick detector is their
coincidence (`flux_sub × flux_punch`), which suppresses bass rumble and mid
stabs alike.

## Setup

Needs **Python 3.9** and **Visual Studio Build Tools** with the C++ workload and
a Windows SDK — madmom (BeatNet's DBN decoder) compiles from Cython sources.

```powershell
powershell -ExecutionPolicy Bypass -File tools\setup_fusion_env.ps1
```

Verify:

```powershell
tools\.venv-fusion\Scripts\python.exe tools\BeatmapAnalyzer.py --selftest
```

## CLI

```
tools\.venv-fusion\Scripts\python.exe tools\BeatmapAnalyzer.py --cli ^
    --audio "audio\Echoes in my blood.wav" ^
    --out "data\Analysis\echoes.analysis.json" ^
    --progress-file "data\Analysis\echoes.progress.json" ^
    --mapgen --map-diff 6
```

| Flag | Default | Meaning |
|---|---|---|
| `--auto` | **on** | derive tempo window, onset thresholds and snap window from the audio |
| `--no-auto` | off | use the values below verbatim |
| `--min-bpm` / `--max-bpm` | 120 / 200 | tempo window (ignored under `--auto`) |
| `--ts` | 4 | beats per bar |
| `--snap-ms` | 18 | transient snap window (ignored under `--auto`) |
| `--onset-delta` | 0.055 | onset threshold (ignored under `--auto`) |
| `--no-beatnet` | off | librosa-only grid |
| `--quick-seconds` | 0 | analyze first N seconds only |
| `--map-diff` | 5 | 1–10, sets density and subdivision depth (6 ≈ a hand-authored chart) |
| `--map-lanes` | **2** | 2 = beats lane + melody lane; 4+ spreads roles |
| `--no-map-triplets` | off | binary subdivisions only |
| `--map-allow-chords` | off | rare two-lane hits at diff ≥9 |

### Auto mode

On by default, so the settings dialog can be left alone. It derives:

- **tempo window** — from BeatNet's own estimate, widened to ±62% so a
  half/double error is still inside the search but nothing else is.
- **onset threshold, per band** — from the spread of each band's flux
  distribution. A heavily limited master and a dynamic one need very different
  absolute thresholds to mean the same thing.
- **snap window** — 4.5% of one beat, so it scales with tempo instead of being
  generous at 120 BPM and reckless at 180.

The JSON records both what was asked for (`config_requested`) and what actually
ran (`config`), so auto's choices are always visible.

## How notes are chosen

Placement is **grid-driven**, not onset-driven. Measured against the
hand-authored reference chart for this game: 69% of beat-lane gaps are exactly
one beat, and the melody lane runs on eighths and sixteenths. That chart also
places 635 beat notes where onset detection finds only 404 kicks -- the author
charts the *pulse*, which carries on through bars where no clean transient
survives the distortion.

So each grid slot is scored by **band energy** ("is the kick playing here?"),
the strongest slots fill the budget, and detected onsets are used only to snap
a chosen slot onto the real transient. An earlier version ranked onsets by
strength instead; its notes clumped into loud sections and scored barely above
chance against the reference.

Slot scores are **relative to a rolling loudness reference** (~7 s window), not
absolute. Scoring on absolute energy makes the whole track compete against its
own loudest passages, so a quiet-but-busy intro or breakdown loses every slot to
the drops and comes out empty -- one 8.2 s stretch with 35 kick and 34 mid
onsets was being skipped entirely. A per-band silence floor keeps genuine
silence empty regardless of how favourable its local ratio looks.

Measured on `Echoes in my blood.wav`, notes landing within 35 ms of a detected
musical event:

| | beat lane | melody lane |
|---|---|---|
| this analyzer | **63%** | **64%** |
| hand-authored | 34% | 45% |
| chance | 27% | 34% |

The hand-authored chart scores lower because it was tapped live and carries
roughly 100 ms of human latency with ~100 ms jitter; its tempo is sound (154.02
implied vs 154.09 measured), so that offset is performance, not drift.

## Two-lane charting

With `--map-lanes 2` (the default) every note carries a `role_class`:

| `role_class` | Roles | Lane | Colour |
|---|---|---|---|
| `beat` | kick, gated_kick, kick_offbeat, hat | 0 | pink |
| `melody` | screech, lead | 1 | blue |

The analyzer decides this, so AutoFinish has no lane mapping to configure. The
per-lane min-gap still applies, but the *global* gap does not: a kick and a
screech landing together are two lanes and are meant to be hit at once.

Runtime is roughly **3 minutes for a 5 minute track** — deliberately favouring
accuracy over speed.

## Output — `beatmap_analyzer_v3`

```jsonc
{
  "schema": "beatmap_analyzer_v3",
  "bpm": 154.0938,
  "beats": [...],            // seconds
  "downbeats": [...],
  "onsets":  [{ "t", "strength", "band", "role", "section", "on_beat", ... }],
  "bars":    [{ "t", "sub", "mid", "kicks_per_beat", "tags", "intensity" }],
  "sections":[{ "kind": "drop|breakdown|buildup|fake_drop|groove", "t", "t_end" }],
  "map_notes":[{ "t", "t_ms", "lane", "basis", "role_class", "div", "triplet", "intensity" }]
}
```

The editor (`ManualMapper.gd`) reads both `v3` and the legacy `v2` schema.

## Godot link

`ManualMapper.gd` spawns the analyzer with `OS.create_process`, polls the
progress JSON for the progress bar, and watches for the cancel file. Relevant
knobs live at the top of the script:

```gdscript
@export var python_executable: String = ".../tools/.venv-fusion/Scripts/pythonw.exe"
@export var analyzer_script_path: String = "res://tools/BeatmapAnalyzer.py"
```
