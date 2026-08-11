# SIAG — Blender assets

Everything Blender-related for SIAG lives here (scripts, .blend files, exports).

## How the game builds the track (source of truth)

From `scripts/beat3d/Section_BeatRunner3d.gd` + `BeatRunnerPlayer.gd`:

- Floor: boxes per straight segment, **6.5 m wide × 0.30 m thick**, top at **y = 0**. Lanes at x = −2.4 / 0 / +2.4.
- Straights 250–500 m; turns are **90° arcs** r = 12 / 20 / 32 m, banked up to **21°** (`sin(t·π)` profile, collision stays flat).
- Gates: depth 1.1 m, lane blocker 1.7 × 2.5 m, jump hurdle 0.9 m high, slide clearance 1.425 m, neon arch posts 0.10 m.
- Grind rail: 0.09 m square bar, top at 0.88 m, lateral ±3.35 m, support post every ~5 m. Sparks: 0.21 m orbs at 0.85 m over the rail path.
- Wall-jump: 0.18 m corridor walls (height ramps with the climb), 2.8 m wide ledges/approach, 0.55 m arch pillars, glowing face plates 0.38 × ~3.9 × 2.2 m.
- WJ descent slide: one 2.0 m glow strip per lane, run = clamp(height × 3.2, 24–52 m), outer rails 0.10 × 0.30 m, safe-entry beacon sphere r 0.35.
- Charge tunnel: torus hoops, opening r 1.15 m (alignment tolerance), tube 0.08 m, one per 4 m at 1.2 m height on the weave curve.
- Electric zones: pylons every 55 m at ±(track/2 + 14 m) — 22 m pole, 10 m crossbeam arm, glow tip; gates use 0.14 m fence posts + animated arcs.
- Halos: shape + radius from the game settings (default star r 5.8), tube 0.10 m; hold notes chain up to hundreds into a tunnel.
- World deco: 0.4 m gems every 32 m at ±(track/2 + 1.4), overhead arches every 64 m (posts 4.2 m), pulse pads every 128 m, haze pillars 20–35 m tall every 120 m at ±8/±14 m, city buildings in rows at ±16/±30 m.

## siag_track_builder.py (v2.2)

Install: `Edit > Preferences > Add-ons > Install…` → pick the file → enable (or Run Script in the Text Editor). Then `N` sidebar → **SIAG** tab. Panels: **Track**, **Obstacles & Rails**, **Decoration**, **World & FX**, **Colour Tools**, **Game Dimensions**. Every Add stays tweakable in the redo panel (bottom-left) right after adding.

**Colour source: "My exported track"** (v2.5, the default): new pieces dress themselves in the materials of your actual exported .glbs from `assets/track/` — asphalt textures, multi-coloured lane-line dashes (spread one colour per dash), everything. The .glb is imported once and only its materials are kept (cached in the .blend; hit **Re-read exported colours** after re-exporting your track). Parts or piece types you haven't exported fall back to the game palette below. The folder is auto-found when the .blend lives in the project; otherwise set it in Colour Tools.

**Game colours** (checkbox in the Track + Colour Tools panels, on by default, also per-Add in the redo panel): every new piece arrives pre-filled with the exact palette the game renders procedurally — floor grey, red/white kerbs, pink/blue blockers, rainbow WJ ledges, cyan/yellow descent slide, orange rail, gold sparks, halo colour A/B, city-window pink, all of it. The materials are shared (`SIAG Floor Top`, `SIAG Grind Rail`, …) — edit one and every piece using it recolours; they're plain Principled BSDF so they ride the .glb to Godot with no baking. Turn the toggle off and pieces come with blank slots like before — **all colouring stays yours either way.**

**Seam fixes (v2.3):** two separate ones.

- *Lateral (the real one):* the game's arc path was a tangent-stepped polyline that exited 0.3–0.8 m sideways+long of the true circle (scaling with radius, mirrored per turn direction) — so authored corners, which are true arcs anchored at the entry, missed the next piece's lane lines at the corner EXIT. Fixed in the game (`Section_BeatRunner3d.gd`): arc sub-segments are now midpoint-sampled chords (exit lands within ~2 mm) and corner pieces take their entry heading from the straight before the junction. No re-export needed — this was game-side.
- *Dash phase:* every piece now starts AND ends with a half dash and kerbs always fit an even whole segment count, so patterns continue across any junction. Re-add straights/turns with v2.3 for this part.

### Pieces

- **Straight** (length slider) and **90° Turn** (radius slider — game presets are 12/20/32 — direction, banking: Game sin-profile / Constant / Flat, bank-angle slider). Both can include: curbs, lane lines (dashed or solid), edge light strips, lane-seam edge loops.
- **Grind Rail** (length, side, lateral offset, posts), **Grind Spark** (orb radius/height, optional glow ring — separate object for a transparent emissive material), **Wall-Jump Section** (jumps / gap / step-height sliders → approach platform, ramping corridor walls, alternating ledges, wall plates, entrance arch, elevated exit floor), **Single Ledge**.
- **WJ Descent Slide** — the slide back down after the climb: one glow strip per lane (Strip.Safe / Strip.Mid / Strip.Far — colour the safe one cyan-ish and the others danger-ish, or don't), optional solid slabs, outer rails, entry beacon. Author the SAFE lane on the LEFT lane; height/run sliders (auto-run follows the game formula). The game stretches the piece to each song's exact climb and mirrors it when the run lands on the other side (`mirror_wj_slide` on the section node if it ever lands wrong).
- **Charge Hoop** (opening radius / tube / segments, optional stripe slots + studs) — the game scales it so the opening always matches the 1.15 m tolerance.
- **Lane Blocker** (1–3 lanes), **Jump Hurdle**, **Slide Gate** (each with its neon arch), **Fence Post** (electric-theme gate post, height/width/cap — the game stretches it per gate; the lightning arcs stay procedural).
- Decoration: **Neon Arch**, **Safe-Lane Strip** (author at lane x = 0 — the game moves it to the safe lane), **Approach Marks**, **Light Post** (lamp head is its own object; optional real point light — exports to Godot), **Beacon Pillar**.
- World & FX: **Halo Ring** (all 9 game shapes, radius/tube, dual-colour alternating slots 0/1), **Trackside Gem** (tilted cube or octahedron), **Overhead Deco Arch** (name the crystal "Crystal" and the game spins it), **Floor Pulse Pad**, **Haze Pillar** (optional stripe slots every N metres), **Electric Pylon** (arm toward +X, glow object named "Tip" gets the zone arc colour + pulse), **City Building** (windows all-sides / front / none — make several, the game cycles them).

### Animations

Everything the game animates can now be animated in Blender instead — and anything else too. Two ways that skip the timeline entirely (v2.4):

- **Pose snapshots** — the no-keyframe way. Pose the parts in the viewport (the fun bit), click **Snapshot**, pose again, Snapshot… then **Build Loop**: the add-on writes every keyframe with your easing preset (Smooth / Snappy / Bouncy / Linear), loops back to pose 1, and leaves the piece resting at pose 1. Anything you can pose, you can animate — gates that open, pylons that flex, whatever. Undo-last and Clear buttons included; snapshots are saved in the .blend until you clear them.
- **Anim tags** — the type-it way. Write a recipe in the Animation panel — `spin 3.6`, `bob 0.12 2`, `pulse 0.08 1`, `sway 15 2` — combine with `+` (`spin 4 + bob 0.1 2`), pick an axis with `spinx` / `boby` / `swayz`, hit **Apply Tags to Selected**. Shorter motions are stretched a touch so whole cycles fit the longest — the combined loop is always seamless. The recipe is stored on the object (`siag_anim`) so you can see what a part does.

Both produce ordinary keyframes, so they export and auto-play in game exactly like hand-made animation. The one-click Spin/Bob/Pulse buttons are still there for single motions:

- **Animation panel** → **Add Spin** (axis, seconds/turn, turns, reverse), **Add Bob** (hover drift — amplitude, period), **Add Pulse** (breathing scale) on any selected **part**. Or keyframe transforms by hand — any looping TRS animation works.
- The animated pieces have it built in: **Gem** and **Deco Arch** default to the game's exact spins (2.8 s gem, 3.6 s crystal), **Halo** ships a slow in-plane spin, **Charge Hoop** and **Spark** have optional spin/bob toggles.
- Animate **parts, never the piece's root empty** — the game owns the root transform (placement, mirroring, stretching). The operators skip roots with a warning; the game skips root-targeting tracks with a console note.
- Export as usual (animations ride the .glb). In game every animated piece auto-plays its loops wherever it's instanced, and the game's own procedural motion steps aside: authored gems/arch crystals/halos stop being spun by the game, everything else (hoops, sparks, buildings, pylons, …) simply gains motion it never had.
- Whole turns loop seamlessly. Multiple animated parts in one piece are merged onto one loop — keep them at the same cycle length or the shorter one will idle at the end.
- What CANNOT ride glTF: material/emission animation. The beat-pulse on emissive parts and the electric arcs stay game-driven (they need the song anyway).

### Colouring per part

- Each piece is a parent Empty with **separate child objects per part** (Floor, Curb.L, LaneLines, Rail, Plate.03, Lamp, …). Click a part in Object Mode, add a material — only that part changes.
- Finer control: Tab into Edit Mode, select faces → **Selected Faces → New Slot** (assigns them to a fresh empty material slot) or **Selection → Own Object**.
- Pre-set empty slots to fill in: Floor 0 = top, 1 = sides, 2 = bottom. Curbs alternate slots 0/1 every 2 m (red/white kerb style).

### Conventions & chaining

1 unit = 1 m, pieces run along +Y, entry at origin, floor top at Z = 0. Every track piece has an **Exit** arrow empty — `Shift+S > Cursor to Selected` on it, then add the next piece and move it to the cursor (`Shift+S > Selection to Cursor`).

## Exporting to Godot — automatic piece detection

The game now detects authored pieces by itself (`scripts/beat3d/TrackPieceLibrary.gd`). Workflow:

1. If a piece uses fancy materials (procedural textures, Mapping nodes, ColorRamps — anything beyond Image Texture → Principled BSDF), select it and click **Bake Materials → Export-Safe** first. It bakes colour (+ optional emission/normal) to packed image textures on a fresh non-overlapping UV layer and rebuilds the materials glTF-clean, so Godot shows exactly what Blender shows. Already-baked materials are skipped on re-runs.
2. Select your piece(s) in Blender and click **SIAG panel → Export to Godot → Export Selected → .glb**. This button writes the SIAG metadata (`siag_type`, `siag_length`, `siag_radius`, `siag_direction`, `siag_bank_deg`, …) into the glTF as extras — a manual glTF export also works if you enable *Include → Custom Properties*.
3. Save the .glb into the project's **`assets/track/`** folder (subfolders are fine). Several pieces in one .glb is fine too.
4. Run the game. At startup the runner scans `assets/track/`, logs what it found, and for every piece that exists it **skips the procedural visual and instances yours instead** — positioned, rotated and (for corners) banked along the generated path automatically. Whatever is missing keeps being generated exactly like before. Collision is always procedural, so gameplay never changes.

What gets swapped when present:

- `straight` — as soon as ONE straight piece exists, the game generates **zero** procedural straight slabs: pieces are tiled longest-first and the last few metres are closed with a Z-squashed copy of your shortest piece, so the floor is 100 % your assets.
- `turn` — as soon as turn pieces exist, the path generator **only picks corner radii you actually authored**, so every corner is covered by an asset and no procedural corner floors are built (chicanes prefer your two tightest radii). Export **both directions (L and R)** of each radius — a missing direction falls back to a procedural arc with a console warning. The procedural floor overlay + inner accent strip are skipped on authored arcs; the red outer barrier and gold beacons still spawn. Heads-up: Blender pieces arrive mirrored across the travel axis, so the game maps its right-arc to your **L** piece — if corners visibly bend the wrong way, toggle `mirror_turn_pieces` on the BeatRunner3d section node.
- `rail` — tiled along grind segments (author rails as side **Left** so they land on the game's rail side; sparks stay procedural).
- `hurdle`, `slide`, `blocker` (+ optional `arch` framing the safe lane) — replace the procedural gate visuals. The Lane Blocker has a **Gate side** option: make a *Left* and a *Right* version (the game's pink/blue distinction) and the matching one is used per gate; a *Generic* blocker covers both directions and any missing variant. The game never recolours your materials.
- `wj_plate`, `wj_ledge` — replace the wall-jump face plates and landing ledges (corridor walls, approach and elevated exit stay procedural for now).
- `wj_slide` — replaces the descent-slide glow strips, outer rails and entry beacon in one piece, stretched to the exact drop height + run and mirrored to the landing side. Collision, the jump lock and the wrong-lane shock stay procedural, and emissive parts beat-pulse like the kit.
- `charge_hoop` — every hoop of the charge tunnel, uniformly scaled so the opening stays at the 1.15 m alignment tolerance (the procedural colour cycling is skipped — your materials are used as-is).
- `spark` — the catchable grind orbs (the game keeps its own point light, catch pops and score popups).
- `fence_post` — every electric-gate post, stretched to each gate's height; arcs remain procedural lightning.
- `pylon` — electric-zone pylons, mirrored per side so the arm always reaches toward the track; a child named **Tip** gets the zone's arc colour and beat pulse.
- `halo` — replaces the melody/FX rings AND the hold-tunnel stream. Scaled to the settings' halo size, spun and faded per-instance — your materials are untouched (which also means the in-game halo colour settings don't apply to authored halos).
- `gem`, `deco_arch`, `pad`, `haze_pillar` — trackside deco set. Gems keep their spin + light; a deco-arch child named **Crystal** spins; pads join the beat-pulse; haze pillars are stretched to the game's varied heights.
- `building` — city skyline. Author several; the game cycles through all of them, stretches the far row taller/thinner, and pulses **Windows** emissives with the city beat.
- `beacon`, `strip`, `marks` — now actually consumed: beacons frame every corner entry/exit (mirrored to both sides, beat-pulsed), the safe-lane strip and approach marks replace the floor cues on every gate (marks stretch to lane- or full-track width; author the strip centred at x = 0).

If a .glb was exported without metadata, the library falls back to recognising object names (`TrackStraight_10m`, `TrackTurn90L_r20m`, `GrindRail_30m`, `JumpHurdle`, `Ledge`, `WallPlate`, `WJSlide`, `ChargeHoop`, `Spark`, `Pylon`, `FencePost`, `Halo`, `Gem`, `DecoArch`, `PulsePad`, `HazePillar`, `Building`, …) — but use the Export button, it's foolproof.

Orientation notes: Blender +Y (piece forward) becomes **−Z in Godot**; the game compensates with a 180° yaw when instancing, so you never have to think about it. In-game floor top is `y = 0`.
