## SIAG Track Builder v2 — Blender add-on / script.
##
## Generates every SIAG runner-track piece with the EXACT dimensions the game
## uses (Section_BeatRunner3d.gd + BeatRunnerPlayer.gd). No materials are ever
## assigned — that's yours.
##
## Per-part colouring:
##   Every piece is built as a parent Empty with SEPARATE child objects per
##   logical part (Floor, Curb.L, LaneLines, Rail, Lamp, …). Click any part in
##   Object Mode and give it a material — only that part changes.
##   For even finer control: Tab into Edit Mode, select faces, and use the
##   "Selected Faces → New Slot" button in the SIAG panel.
##   Some parts also ship with pre-set material indexes (e.g. floor: slot 0 =
##   top, 1 = sides, 2 = bottom; curbs alternate slot 0/1 every 2 m for that
##   red/white kerb look) — just fill the empty slots with your materials.
##
## How to use:
##   Edit > Preferences > Add-ons > Install… → pick this file → enable.
##   (or open in the Text Editor and Run Script)
##   3D Viewport > press N > "SIAG" tab. Set the sliders, click buttons.
##   Every Add is also tweakable afterwards in the redo panel (bottom-left).
##
## Conventions:
##   1 Blender unit = 1 m. Pieces run along +Y, entry at the origin,
##   floor TOP surface at Z = 0 (in-game floor top is y = 0).
##   Each track piece gets an "Exit" empty at its end for easy chaining
##   (snap 3D cursor to it, add the next piece at the cursor).
##   UVs are real-world metres.

bl_info = {
    "name": "SIAG Track Builder",
    "author": "Melody",
    "version": (2, 5),
    "blender": (3, 0, 0),
    "location": "View3D > Sidebar (N) > SIAG",
    "description": "Generate all SIAG runner track pieces (game-exact dimensions, no materials)",
    "category": "Add Mesh",
}

import bpy
import math
import os
import re
import json
from mathutils import Vector, Matrix
from bpy.props import (FloatProperty, IntProperty, BoolProperty,
                       EnumProperty, PointerProperty, StringProperty)
from bpy_extras.io_utils import ExportHelper

# ── Game constants (from the GDScript — don't change unless the game does) ──
TRACK_WIDTH   = 6.5     # lane span 4.8 (lanes at −2.4/0/+2.4) + lane_blocker_width 1.7
FLOOR_THICK   = 0.30    # floor box thickness; top surface at y = 0 in-game
LANE_XS       = (-2.4, 0.0, 2.4)
LANE_SEAM_X   = 1.2     # lane boundaries
BANK_MAX_DEG  = 21.0    # game max banking, sin(t·π) profile
ARC_SEGS      = 32      # game sub-segments per 90° arc

GATE_DEPTH    = 1.1     # gate_depth
BLOCKER_W     = 1.7     # lane_blocker_width
BLOCKER_H     = 2.5     # lane_blocker_height
HURDLE_H      = 0.9     # jump_hurdle_height
SLIDE_CLEAR   = 1.425   # slide_bar_y 1.65 − slide_bar_height 0.45 / 2

RAIL_LAT      = 3.35    # grind rail lateral offset (just past outer lane)
RAIL_H        = 0.88    # rail top height
RAIL_BAR      = 0.09    # rail bar cross-section
RAIL_POST_W   = 0.05    # support post cross-section
RAIL_POST_GAP = 5.0     # ~ one post per 5 m (game: every 7th of 56 segs)

WJ_WALL_THICK = 0.18    # corridor wall thickness
WJ_LEDGE_W    = 2.8     # ledge / approach platform width (one lane)
WJ_PILLAR_W   = 0.55    # entrance arch pillar
WJ_BEAM_H     = 0.45    # entrance arch crossbeam
WJ_PLATE      = (0.38, BLOCKER_H * 1.55, GATE_DEPTH * 2.0)   # wall-jump face plate

# ── Decoration defaults (not from the game — aesthetic add-ons) ──────────────
CURB_W        = 0.30
CURB_H        = 0.10
CURB_SEG      = 2.0     # curb colour alternation length (slots 0/1)
LINE_W        = 0.12    # lane line width
LINE_T        = 0.02    # lane line height above floor
DASH_LEN      = 1.5
DASH_GAP      = 1.5
STRIP_W       = 0.10    # edge light strip
STRIP_H       = 0.05

HALF_W = TRACK_WIDTH * 0.5


# ═════════════════════════════════════════════════════════════════════════════
#  Low-level builders
# ═════════════════════════════════════════════════════════════════════════════

def _link(obj):
    bpy.context.collection.objects.link(obj)
    return obj


def _new_empty(name, loc=(0, 0, 0)):
    e = bpy.data.objects.new(name, None)
    e.empty_display_type = 'PLAIN_AXES'
    e.empty_display_size = 1.2
    e.location = loc
    return _link(e)


def _new_obj(name, verts, faces, uvs, mat_ids, parent=None):
    """Create a mesh object. uvs: per-face tuple of per-loop (u,v).
    mat_ids: per-face material index. Empty material slots are created so
    face indexes survive — fill them with your own materials later."""
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([tuple(v) for v in verts], [], faces)
    mesh.validate()
    uv_layer = mesh.uv_layers.new(name="UVMap")
    li = 0
    for fi, poly in enumerate(mesh.polygons):
        poly.material_index = mat_ids[fi]
        for uv in uvs[fi]:
            uv_layer.data[li].uv = uv
            li += 1
    mesh.update()
    for _ in range(max(mat_ids) + 1 if mat_ids else 1):
        mesh.materials.append(None)
    obj = bpy.data.objects.new(name, mesh)
    _link(obj)
    if parent is not None:
        obj.parent = parent
    return obj


class _BoxAccum:
    """Accumulates axis-aligned boxes into one mesh's data."""

    def __init__(self):
        self.verts, self.faces, self.uvs, self.mats = [], [], [], []

    def box(self, size, center, mat=0):
        sx, sy, sz = size
        cx, cy, cz = center
        x0, x1 = cx - sx / 2, cx + sx / 2
        y0, y1 = cy - sy / 2, cy + sy / 2
        z0, z1 = cz - sz / 2, cz + sz / 2
        b = len(self.verts)
        self.verts += [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0),
                       (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]
        quads = [
            ((0, 3, 2, 1), lambda v: (v[0], v[1])),   # bottom (−Z)
            ((4, 5, 6, 7), lambda v: (v[0], v[1])),   # top (+Z)
            ((0, 1, 5, 4), lambda v: (v[0], v[2])),   # front (−Y)
            ((1, 2, 6, 5), lambda v: (v[1], v[2])),   # right (+X)
            ((2, 3, 7, 6), lambda v: (v[0], v[2])),   # back (+Y)
            ((3, 0, 4, 7), lambda v: (v[1], v[2])),   # left (−X)
        ]
        for idx, proj in quads:
            self.faces.append(tuple(b + i for i in idx))
            self.uvs.append(tuple(proj(self.verts[b + i]) for i in idx))
            self.mats.append(mat)
        return self

    def to_obj(self, name, parent=None):
        return _new_obj(name, self.verts, self.faces, self.uvs, self.mats, parent)


def _box_obj(name, size, center, parent=None, mat=0):
    return _BoxAccum().box(size, center, mat).to_obj(name, parent)


def _stamp(obj, ptype, **params):
    """Write SIAG metadata as custom properties. They export as glTF extras
    (the Export button enables this) and Godot's TrackPieceLibrary reads them
    to know each piece's type, length, radius, banking, … automatically."""
    obj["siag_type"] = ptype
    for k, v in params.items():
        obj["siag_" + k] = v
    return obj


# ── Stations: points along the track path ────────────────────────────────────
# station = (center: Vector at floor-top level, tangent: Vector, bank_rad, path_dist)

def straight_stations(length, step=CURB_SEG):
    n = max(1, int(math.ceil(length / step)))
    out = []
    for i in range(n + 1):
        y = min(length, i * step)
        out.append((Vector((0.0, y, 0.0)), Vector((0.0, 1.0, 0.0)), 0.0, y))
    if out[-1][3] < length:  # safety
        out.append((Vector((0.0, length, 0.0)), Vector((0.0, 1.0, 0.0)), 0.0, length))
    return out


def arc_stations(radius, is_right, segs, bank_deg, bank_mode):
    """90° arc, entry at origin heading +Y. bank_mode: FLAT | GAME | CONST."""
    s = 1.0 if is_right else -1.0
    out = []
    for i in range(segs + 1):
        t = i / segs
        a = t * math.pi * 0.5
        c = Vector((s * radius * (1.0 - math.cos(a)), radius * math.sin(a), 0.0))
        tan = Vector((s * math.sin(a), math.cos(a), 0.0))
        if bank_mode == 'FLAT':
            bank = 0.0
        elif bank_mode == 'CONST':
            bank = math.radians(bank_deg) * s
        else:  # GAME — sin profile, flat at entry/exit (matches the game)
            bank = math.radians(bank_deg * math.sin(t * math.pi)) * s
        out.append((c, tan, bank, a * radius))
    return out


def _station_at(stations, pd):
    """Linear interpolation between stations at path distance pd."""
    if pd <= stations[0][3]:
        return stations[0]
    for i in range(len(stations) - 1):
        a, b = stations[i], stations[i + 1]
        if pd <= b[3]:
            f = 0.0 if b[3] == a[3] else (pd - a[3]) / (b[3] - a[3])
            c = a[0].lerp(b[0], f)
            tan = (a[1].lerp(b[1], f)).normalized()
            return (c, tan, a[2] + (b[2] - a[2]) * f, pd)
    return stations[-1]


def _frame(station):
    """Banked right/up vectors + pivot for a station. Banking pivots around the
    floor's mid-thickness centreline — exactly like the game banks its meshes."""
    c, tan, bank, _pd = station
    t = tan.normalized()
    right = Vector((t.y, -t.x, 0.0))
    up = Vector((0.0, 0.0, 1.0))
    if bank != 0.0:
        rot = Matrix.Rotation(bank, 4, t)
        right = rot @ right
        up = rot @ up
    pivot = Vector((c.x, c.y, c.z - FLOOR_THICK * 0.5))
    return pivot, right, up


def _sweep_data(runs, ring, edge_mats, alt_every=None, caps=True, cap_mat=None):
    """Sweep a closed cross-section ring [(lateral, z), …] along one or more
    runs of stations. Returns (verts, faces, uvs, mat_ids).
    edge_mats[k] = material index of the face bridging ring edge k;
    alt_every: if set, override with alternating slots 0/1 every N metres."""
    m = len(ring)
    half_t = FLOOR_THICK * 0.5
    perim = [0.0]
    for k in range(m):
        a, b = ring[k], ring[(k + 1) % m]
        perim.append(perim[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))

    verts, faces, uvs, mats = [], [], [], []
    for stations in runs:
        base = len(verts)
        for st in stations:
            pivot, right, up = _frame(st)
            for (x, z) in ring:
                verts.append(pivot + right * x + up * (z + half_t))
        S = len(stations)
        for i in range(S - 1):
            pd0, pd1 = stations[i][3], stations[i + 1][3]
            for k in range(m):
                k2 = (k + 1) % m
                faces.append((base + i * m + k, base + i * m + k2,
                              base + (i + 1) * m + k2, base + (i + 1) * m + k))
                uvs.append(((perim[k], pd0), (perim[k + 1], pd0),
                            (perim[k + 1], pd1), (perim[k], pd1)))
                if alt_every:
                    mats.append(int(((pd0 + pd1) * 0.5) // alt_every) % 2)
                else:
                    mats.append(edge_mats[k])
        if caps:
            cm = cap_mat if cap_mat is not None else edge_mats[-1]
            faces.append(tuple(reversed(range(base, base + m))))
            uvs.append(tuple((ring[k][0], ring[k][1]) for k in reversed(range(m))))
            mats.append(cm)
            b2 = base + (S - 1) * m
            faces.append(tuple(range(b2, b2 + m)))
            uvs.append(tuple((ring[k][0], ring[k][1]) for k in range(m)))
            mats.append(cm)
    return verts, faces, uvs, mats


def _rect_ring(x0, x1, z0, z1):
    return [(x0, z1), (x1, z1), (x1, z0), (x0, z0)]


# ═════════════════════════════════════════════════════════════════════════════
#  Piece builders
# ═════════════════════════════════════════════════════════════════════════════

def _add_exit_marker(parent, station):
    c, tan, _b, _pd = station
    e = bpy.data.objects.new("Exit", None)
    e.empty_display_type = 'SINGLE_ARROW'
    e.empty_display_size = 2.0
    e.location = (c.x, c.y, c.z)
    # arrow shows +Z; tilt it flat so it points along the travel direction
    yaw = math.atan2(-tan.x, tan.y)
    e.rotation_euler = (math.radians(90.0), 0.0, yaw)
    _link(e)
    e.parent = parent
    return e


def _floor_ring(lane_seams):
    h = HALF_W
    xs = [-h, -LANE_SEAM_X, LANE_SEAM_X, h] if lane_seams else [-h, h]
    pts = [(x, 0.0) for x in xs]
    pts += [(xs[-1], -FLOOR_THICK), (xs[0], -FLOOR_THICK)]
    n_top = len(xs)
    edge_mats = []
    for k in range(len(pts)):
        if k < n_top - 1:
            edge_mats.append(0)       # top
        elif k == n_top:
            edge_mats.append(2)       # bottom
        else:
            edge_mats.append(1)       # sides
    return pts, edge_mats


def _dash_runs(stations, total_len, lat_dummy=0.0):
    """Station pairs for dashed lane lines — SEAM-SAFE layout.

    Every piece starts AND ends with a HALF dash (dash centres at pd 0 and
    pd total), so at any junction the two half-dashes merge into one clean
    full dash — no matter how long each piece is. Corner arcs (r·π/2 is
    never a whole number of dash periods) used to end with a full dash
    flush against the exit, doubling up with the next piece's opening dash;
    the period is now stretched a touch per piece so a whole number of
    periods fits exactly, and the phase is symmetric."""
    period = DASH_LEN + DASH_GAP
    n = max(1, round(total_len / period))
    eff = total_len / n
    half = DASH_LEN * 0.5
    runs = []
    for k in range(n + 1):                   # dash centres at 0, eff, …, total
        c = k * eff
        a = max(0.0, c - half)
        b = min(total_len, c + half)
        if b - a > 0.02:
            runs.append([_station_at(stations, a), _station_at(stations, b)])
    return runs


def _curb_alt_len(total_len):
    """Curb red/white alternation length adjusted so a piece always holds an
    EVEN, whole number of segments — every piece then starts on slot 0 and
    ends completing slot 1, so the pattern continues seamlessly across any
    junction (arcs included)."""
    pairs = max(1, round(total_len / (CURB_SEG * 2.0)))
    return total_len / (pairs * 2.0)


def build_track_piece(name, stations, opts):
    """Floor + optional decorations, swept along `stations`.
    opts: dict(lane_seams, curbs, lane_lines, dashed, edge_strips)."""
    total_len = stations[-1][3]
    parent = _new_empty(name)

    ring, edge_mats = _floor_ring(opts.get("lane_seams", True))
    v, f, u, mi = _sweep_data([stations], ring, edge_mats, cap_mat=1)
    _new_obj("Floor", v, f, u, mi, parent)

    if opts.get("curbs", False):
        curb_alt = _curb_alt_len(total_len)   # even segment count → seam-safe
        for side, tag in ((-1, "L"), (1, "R")):
            x_out = side * HALF_W
            x_in = side * (HALF_W - CURB_W)
            ring_c = _rect_ring(min(x_in, x_out), max(x_in, x_out), 0.0, CURB_H)
            v, f, u, mi = _sweep_data([stations], ring_c, [0, 0, 0, 0],
                                      alt_every=curb_alt, cap_mat=0)
            _new_obj("Curb.%s" % tag, v, f, u, mi, parent)

    if opts.get("lane_lines", False):
        runs = (_dash_runs(stations, total_len) if opts.get("dashed", True)
                else [stations])
        all_v, all_f, all_u, all_m = [], [], [], []
        for lx in (-LANE_SEAM_X, LANE_SEAM_X):
            ring_l = _rect_ring(lx - LINE_W / 2, lx + LINE_W / 2, 0.001, LINE_T)
            v, f, u, mi = _sweep_data(runs, ring_l, [0, 0, 0, 0], cap_mat=0)
            off = len(all_v)
            all_v += v
            all_f += [tuple(i + off for i in face) for face in f]
            all_u += u
            all_m += mi
        ll = _new_obj("LaneLines", all_v, all_f, all_u, all_m, parent)
        # Faces per dash (4 sides + 2 caps) — lets exported multi-colour
        # dash materials be spread one colour per dash on re-generated lines.
        ll["siag_dash_faces"] = 6 if opts.get("dashed", True) else 0

    if opts.get("edge_strips", False):
        for side, tag in ((-1, "L"), (1, "R")):
            x_out = side * (HALF_W - 0.02)
            x_in = side * (HALF_W - 0.02 - STRIP_W)
            ring_s = _rect_ring(min(x_in, x_out), max(x_in, x_out), 0.001, STRIP_H)
            v, f, u, mi = _sweep_data([stations], ring_s, [0, 0, 0, 0], cap_mat=0)
            _new_obj("EdgeStrip.%s" % tag, v, f, u, mi, parent)

    _add_exit_marker(parent, stations[-1])
    return parent


def build_grind_rail(length, side, lateral, with_posts, parent_to=None):
    s = -1.0 if side == 'LEFT' else 1.0
    x = s * lateral
    parent = parent_to or _new_empty("GrindRail_%gm" % length)
    # main bar — game: 0.09 × 0.09 square bar, top edge ≈ RAIL_H
    _box_obj("Rail", (RAIL_BAR, length, RAIL_BAR),
             (x, length / 2, RAIL_H), parent)
    if with_posts:
        acc = _BoxAccum()
        n = max(2, int(length // RAIL_POST_GAP) + 1)
        for i in range(n):
            y = min(length - 0.1, 0.1 + i * RAIL_POST_GAP)
            acc.box((RAIL_POST_W, RAIL_POST_W, RAIL_H),
                    (x, y, RAIL_H / 2))
        acc.to_obj("Posts", parent)
    return parent


def build_wall_jump_kit(jumps, gap, step, with_plates, with_arch):
    """Full wall-jump section. Origin = first wall-jump gate; approach starts
    8 m before it (z = −8), matching the game layout."""
    parent = _new_empty("WallJumpKit_%dj" % jumps)
    total_h = jumps * step
    ledge_half = min(max(gap * 0.425, 3.0), 6.5)
    z_start = -8.0
    z_end = (jumps - 1) * gap + gap + ledge_half + 4.0
    corr_len = z_end - z_start

    # Approach platform — one lane wide, at the starting lane (left for wall_left)
    app_len = 9.0
    _box_obj("Approach", (WJ_LEDGE_W, app_len, FLOOR_THICK),
             (LANE_XS[0], z_start + app_len / 2, -FLOOR_THICK / 2), parent)

    # Corridor walls — 14 segments per side, height ramps with the climb
    wall_x = HALF_W + WJ_WALL_THICK / 2
    n_segs = 14
    seg_len = corr_len / n_segs
    for sgn, tag in ((-1, "L"), (1, "R")):
        acc = _BoxAccum()
        for i in range(n_segs):
            t = i / max(n_segs - 1, 1)
            h = BLOCKER_H * 1.1 + (total_h + 4.0 - BLOCKER_H * 1.1) * t
            zc = z_start + (i + 0.5) * seg_len
            acc.box((WJ_WALL_THICK, seg_len * 0.97, h), (sgn * wall_x, zc, h / 2))
        acc.to_obj("Wall.%s" % tag, parent)

    # Ledges — alternate sides (first jump = wall_left → land right)
    for i in range(1, jumps):
        lx = LANE_XS[-1] if (i - 1) % 2 == 0 else LANE_XS[0]
        h = i * step
        _box_obj("Ledge.%02d" % i, (WJ_LEDGE_W, ledge_half * 2, FLOOR_THICK),
                 (lx, i * gap, h - FLOOR_THICK / 2), parent)

    # Wall face plates at each gate (the glowing wall-jump targets)
    if with_plates:
        for i in range(jumps):
            sgn = -1 if i % 2 == 0 else 1     # wall_left first
            _box_obj("Plate.%02d" % i, (WJ_PLATE[0], WJ_PLATE[2], WJ_PLATE[1]),
                     (sgn * HALF_W, i * gap, BLOCKER_H * 0.78 + i * step), parent)

    # Entrance arch — two pillars + crossbeam (game adds an OmniLight here too)
    if with_arch:
        ph = total_h + 5.5
        az = z_start - 1.5
        for sgn, tag in ((-1, "L"), (1, "R")):
            px = sgn * (HALF_W + WJ_PILLAR_W / 2 + 0.08)
            _box_obj("ArchPillar.%s" % tag, (WJ_PILLAR_W, WJ_PILLAR_W, ph),
                     (px, az, ph / 2), parent)
        _box_obj("ArchBeam", (TRACK_WIDTH + WJ_PILLAR_W * 2 + 0.16, WJ_PILLAR_W, WJ_BEAM_H),
                 (0, az, ph), parent)

    # Elevated exit floor — flush with the last ledge
    elev_h = (jumps - 1) * step
    elev_z = (jumps - 1) * gap + ledge_half
    elev_len = 18.0
    _box_obj("ElevFloor", (TRACK_WIDTH, elev_len, FLOOR_THICK),
             (0, elev_z + elev_len / 2, elev_h - FLOOR_THICK / 2), parent)
    for sgn, tag in ((-1, "L"), (1, "R")):
        _box_obj("ElevRail.%s" % tag, (0.12, elev_len, 0.6),
                 (sgn * (HALF_W - 0.06), elev_z + elev_len / 2, elev_h + 0.3), parent)
    return parent


def build_gate_arch(parent, cx, width, bot, top, name="Arch"):
    pw = 0.10
    h = top - bot
    acc = _BoxAccum()
    acc.box((pw, pw, h), (cx - width / 2 - pw / 2, 0, bot + h / 2))
    acc.box((pw, pw, h), (cx + width / 2 + pw / 2, 0, bot + h / 2))
    acc.box((width + pw * 2 + 0.08, pw, pw), (cx, 0, top + pw / 2))
    for sx in (-1, 1):
        acc.box((pw * 1.6, pw * 1.6, pw * 1.6),
                (cx + sx * (width / 2 + pw / 2), 0, top + pw / 2))
    return acc.to_obj(name, parent)


# ═════════════════════════════════════════════════════════════════════════════
#  Settings (panel sliders) + operators
# ═════════════════════════════════════════════════════════════════════════════

class SIAGSettings(bpy.types.PropertyGroup):
    length: FloatProperty(name="Length", default=10.0, min=0.5, soft_max=100.0,
                          max=500.0, subtype='DISTANCE')
    radius: FloatProperty(name="Radius", default=20.0, min=4.0, soft_min=12.0,
                          soft_max=32.0, max=200.0, subtype='DISTANCE',
                          description="Game uses 12 (tight) / 20 (normal) / 32 (sweeping)")
    direction: EnumProperty(name="Direction", items=[
        ('RIGHT', "Right", ""), ('LEFT', "Left", "")], default='RIGHT')
    bank_mode: EnumProperty(name="Banking", items=[
        ('GAME', "Game (sin)", "Flat at entry/exit, max mid-arc — what the game does"),
        ('CONST', "Constant", "Same bank angle the whole arc"),
        ('FLAT', "Flat", "No banking")], default='GAME')
    bank_deg: FloatProperty(name="Max Bank", default=BANK_MAX_DEG, min=0.0,
                            max=45.0, subtype='FACTOR', description="Game uses 21°")
    segments: IntProperty(name="Segments", default=ARC_SEGS, min=4, max=128)
    lane_seams: BoolProperty(name="Lane seam loops", default=True,
                             description="Edge loops at x = ±1.2 on the top face")
    curbs: BoolProperty(name="Curbs", default=True,
                        description="Edge kerbs, colour-alternating every 2 m (slots 0/1)")
    lane_lines: BoolProperty(name="Lane lines", default=True)
    dashed: BoolProperty(name="Dashed", default=True)
    edge_strips: BoolProperty(name="Edge light strips", default=False,
                              description="Thin strips along both edges — give them an emissive material")
    game_colors: BoolProperty(name="Game colours", default=True,
                              description="Pre-fill every new piece's material "
                              "slots with the game's exact palette (shared "
                              "'SIAG …' materials — edit one, recolour every "
                              "piece). Off = blank slots, colouring is yours")
    color_source: EnumProperty(name="Colour source", items=[
        ('GLB', "My exported track", "Dress new pieces in the materials of "
         "your exported .glbs from assets/track (textures included); the "
         "game palette only fills what those don't cover"),
        ('GAME', "Game palette", "The procedural in-game colours")],
        default='GLB')
    assets_dir: StringProperty(name="assets/track folder", subtype='DIR_PATH',
                               default="",
                               description="Project's assets/track folder — "
                               "auto-found when the .blend lives in the "
                               "project; set it here otherwise")
    glb_mat_map: StringProperty(default="", options={'HIDDEN'})
    # ── Animation panel state ──
    anim_tags: StringProperty(name="Anim tags", default="spin 3.6",
                              description="Motion recipe, e.g.  spin 3.6  ·  "
                              "bob 0.12 2  ·  pulse 0.08 1  ·  sway 15 2  — "
                              "combine with +  (axis: spinx / boby / swayz)")
    pose_data: StringProperty(default="", options={'HIDDEN'})
    pose_count: IntProperty(default=0, options={'HIDDEN'})
    pose_seconds: FloatProperty(name="Seconds between poses", default=1.0,
                                min=0.1, max=30.0)
    pose_easing: EnumProperty(name="Easing", items=[
        ('SMOOTH', "Smooth", "Gentle ease in and out"),
        ('SNAPPY', "Snappy", "Quick move, soft landing"),
        ('BOUNCY', "Bouncy", "Overshoot and settle"),
        ('LINEAR', "Linear", "Constant speed")], default='SMOOTH')
    pose_loop: BoolProperty(name="Loop back to pose 1", default=True,
                            description="Ends by easing back into the first "
                                        "pose so the loop is seamless")


def _opts(p):
    return dict(lane_seams=p.lane_seams, curbs=p.curbs, lane_lines=p.lane_lines,
                dashed=p.dashed, edge_strips=p.edge_strips)


class _SIAGOp(bpy.types.Operator):
    bl_options = {'REGISTER', 'UNDO'}

    _copy = ()   # settings fields to pull from the panel on invoke

    def invoke(self, context, event):
        s = context.scene.siag
        for f in self._copy:
            setattr(self, f, getattr(s, f))
        # Global "Game colours" toggle flows into every Add that supports it
        # (still overridable per-add in the redo panel).
        if hasattr(self, "game_colors"):
            self.game_colors = s.game_colors
        return self.execute(context)


class SIAG_OT_add_straight(_SIAGOp):
    bl_idname = "siag.add_straight"
    bl_label = "Straight"
    bl_description = "Straight track piece (6.5 m wide, 0.3 m thick, top at Z=0)"
    _copy = ("length", "lane_seams", "curbs", "lane_lines", "dashed", "edge_strips")

    length: SIAGSettings.__annotations__["length"]
    lane_seams: SIAGSettings.__annotations__["lane_seams"]
    curbs: SIAGSettings.__annotations__["curbs"]
    lane_lines: SIAGSettings.__annotations__["lane_lines"]
    dashed: SIAGSettings.__annotations__["dashed"]
    edge_strips: SIAGSettings.__annotations__["edge_strips"]
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        st = straight_stations(self.length)
        p = build_track_piece("TrackStraight_%gm" % self.length, st, _opts(self))
        if self.game_colors:
            _precolor(p, "straight")
        _stamp(p, "straight", length=self.length)
        return {'FINISHED'}


class SIAG_OT_add_turn(_SIAGOp):
    bl_idname = "siag.add_turn"
    bl_label = "90° Turn"
    bl_description = "Quarter-circle turn — radius slider, banked or flat"
    _copy = ("radius", "direction", "bank_mode", "bank_deg", "segments",
             "lane_seams", "curbs", "lane_lines", "dashed", "edge_strips")

    radius: SIAGSettings.__annotations__["radius"]
    direction: SIAGSettings.__annotations__["direction"]
    bank_mode: SIAGSettings.__annotations__["bank_mode"]
    bank_deg: SIAGSettings.__annotations__["bank_deg"]
    segments: SIAGSettings.__annotations__["segments"]
    lane_seams: SIAGSettings.__annotations__["lane_seams"]
    curbs: SIAGSettings.__annotations__["curbs"]
    lane_lines: SIAGSettings.__annotations__["lane_lines"]
    dashed: SIAGSettings.__annotations__["dashed"]
    edge_strips: SIAGSettings.__annotations__["edge_strips"]
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        st = arc_stations(self.radius, self.direction == 'RIGHT',
                          self.segments, self.bank_deg, self.bank_mode)
        side = "R" if self.direction == 'RIGHT' else "L"
        p = build_track_piece("TrackTurn90%s_r%gm" % (side, self.radius), st, _opts(self))
        if self.game_colors:
            _precolor(p, "turn")
        _stamp(p, "turn", radius=self.radius, direction=side,
               bank_deg=(0.0 if self.bank_mode == 'FLAT' else self.bank_deg),
               bank_mode=self.bank_mode,
               length=self.radius * math.pi * 0.5)
        return {'FINISHED'}


class SIAG_OT_add_rail(_SIAGOp):
    bl_idname = "siag.add_rail"
    bl_label = "Grind Rail"
    bl_description = "Grind rail: 0.09 m bar at 0.88 m height, lateral ±3.35 m, posts every 5 m"
    _copy = ("length",)

    length: SIAGSettings.__annotations__["length"]
    side: EnumProperty(name="Side", items=[('LEFT', "Left", ""), ('RIGHT', "Right", "")],
                       default='LEFT')
    lateral: FloatProperty(name="Lateral offset", default=RAIL_LAT, min=0.0, max=6.0)
    posts: BoolProperty(name="Support posts", default=True)
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = build_grind_rail(self.length, self.side, self.lateral, self.posts)
        if self.game_colors:
            _precolor(p, "rail")
        _stamp(p, "rail", length=self.length, side=self.side, lateral=self.lateral)
        return {'FINISHED'}


class SIAG_OT_add_wj_kit(_SIAGOp):
    bl_idname = "siag.add_wj_kit"
    bl_label = "Wall-Jump Section"
    bl_description = "Full wall-jump corridor: approach, ramping walls, ledges, plates, arch, elevated exit"

    jumps: IntProperty(name="Jumps", default=5, min=2, max=12)
    gap: FloatProperty(name="Gap (m)", default=10.0, min=4.0, max=20.0,
                       description="Z distance between wall-jump gates")
    step: FloatProperty(name="Step height", default=1.0, min=0.3, max=2.5,
                        description="Height gained per jump")
    plates: BoolProperty(name="Wall plates", default=True)
    arch: BoolProperty(name="Entrance arch", default=True)
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = build_wall_jump_kit(self.jumps, self.gap, self.step, self.plates, self.arch)
        if self.game_colors:
            _precolor(p, "wj_kit")
        _stamp(p, "wj_kit", jumps=self.jumps, gap=self.gap, step=self.step)
        return {'FINISHED'}


class SIAG_OT_add_wj_ledge(_SIAGOp):
    bl_idname = "siag.add_wj_ledge"
    bl_label = "Single Ledge"
    bl_description = (
        "Wall-jump landing ledge (2.8 m wide, 0.3 m thick), centred at the origin "
        "with its top at Z=0.  Set Index 1-8 to assign a specific jump slot "
        "(slot 1 = first landing / red, 2 = orange … 8 = white).  "
        "Index 0 = generic fallback used for any slot that has no dedicated piece."
    )

    index: IntProperty(
        name="Ledge Index (0 = generic)",
        default=0, min=0, max=8,
        description=(
            "0 = generic fallback for every slot, "
            "1-8 = dedicated piece for that jump position "
            "(1=red, 2=orange, 3=yellow, 4=green, 5=blue, 6=purple, 7=pink, 8=white)"
        ),
    )
    depth: FloatProperty(name="Depth", default=8.5, min=3.0, max=13.0)
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        if self.index == 0:
            name   = "Ledge"
            stype  = "wj_ledge"
        else:
            name   = "WJLedge_%02d" % self.index
            stype  = "wj_ledge_%d" % self.index
        p = _new_empty(name)
        o = _box_obj(name, (WJ_LEDGE_W, self.depth, FLOOR_THICK),
                     (0.0, 0.0, -FLOOR_THICK / 2), p)
        if self.game_colors:
            _precolor(p, "wj_ledge", index=self.index)
        _stamp(p, stype, depth=self.depth, index=self.index)
        return {'FINISHED'}


class SIAG_OT_add_plate(_SIAGOp):
    bl_idname = "siag.add_plate"
    bl_label = "Wall Plate"
    bl_description = ("Glowing wall-jump target plate (0.38 × 2.2 × ~3.9 m), "
                      "centred at the origin — the game mounts it on the "
                      "corridor walls at each wall-jump gate")

    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("WallPlate")
        o = _box_obj("Plate", (WJ_PLATE[0], WJ_PLATE[2], WJ_PLATE[1]),
                     (0.0, 0.0, 0.0), p)
        if self.game_colors:
            _precolor(p, "wj_plate")
        _stamp(p, "wj_plate")
        return {'FINISHED'}


class SIAG_OT_add_blocker(_SIAGOp):
    bl_idname = "siag.add_blocker"
    bl_label = "Lane Blocker"
    bl_description = "Lane-gate wall: 2.5 m high, 1.1 m deep (the thing you dodge)"

    lanes: IntProperty(name="Lanes covered", default=1, min=1, max=3)
    variant: EnumProperty(name="Gate side", items=[
        ('ANY', "Generic (both)", "One look used for both gate directions"),
        ('left', "Left gate", "Only used on 'dodge left' gates (pink in the procedural look)"),
        ('right', "Right gate", "Only used on 'dodge right' gates (blue in the procedural look)"),
    ], default='ANY', description="The game picks the matching variant per gate; "
                                  "a Generic blocker covers whatever variant is missing")
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        w = (self.lanes - 1) * 2.4 + BLOCKER_W
        suffix = {"ANY": "", "left": "_L", "right": "_R"}[self.variant]
        p = _new_empty("LaneBlocker" + suffix)
        o = _box_obj("Blocker", (w, GATE_DEPTH, BLOCKER_H), (0, 0, BLOCKER_H / 2), p)
        if self.game_colors:
            _precolor(p, "blocker", variant=self.variant)
        _stamp(p, "blocker", lanes=self.lanes, width=w)
        if self.variant != 'ANY':
            p["siag_variant"] = self.variant
        return {'FINISHED'}


class SIAG_OT_add_hurdle(_SIAGOp):
    bl_idname = "siag.add_hurdle"
    bl_label = "Jump Hurdle"
    bl_description = "Full-width jump barrier: 6.5 × 0.9 m high × 1.1 m deep"

    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("JumpHurdle")
        _box_obj("Hurdle", (TRACK_WIDTH, GATE_DEPTH, HURDLE_H), (0, 0, HURDLE_H / 2), p)
        build_gate_arch(p, 0, TRACK_WIDTH, HURDLE_H, HURDLE_H + 2.0)
        if self.game_colors:
            _precolor(p, "hurdle")
        _stamp(p, "hurdle")
        return {'FINISHED'}


class SIAG_OT_add_slide(_SIAGOp):
    bl_idname = "siag.add_slide"
    bl_label = "Slide Gate"
    bl_description = "Overhead slab you slide under — clearance 1.425 m, top 2.5 m"

    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("SlideGate")
        h = BLOCKER_H - SLIDE_CLEAR
        _box_obj("Overhead", (TRACK_WIDTH, GATE_DEPTH, h),
                 (0, 0, SLIDE_CLEAR + h / 2), p)
        build_gate_arch(p, 0, TRACK_WIDTH, 0.0, SLIDE_CLEAR)
        if self.game_colors:
            _precolor(p, "slide")
        _stamp(p, "slide")
        return {'FINISHED'}


class SIAG_OT_add_arch(_SIAGOp):
    bl_idname = "siag.add_arch"
    bl_label = "Neon Arch"
    bl_description = "Gate arch frame (0.10 m posts + beam + corner cubes)"

    width: FloatProperty(name="Opening width", default=BLOCKER_W, min=0.5, max=8.0)
    top: FloatProperty(name="Top height", default=BLOCKER_H, min=0.5, max=10.0)
    bottom: FloatProperty(name="Bottom height", default=0.0, min=0.0, max=8.0)
    offset_x: FloatProperty(name="X offset", default=0.0, min=-3.0, max=3.0,
                            description="Centre on a lane: −2.4 / 0 / +2.4")
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("NeonArch")
        build_gate_arch(p, self.offset_x, self.width, self.bottom, self.top)
        if self.game_colors:
            _precolor(p, "arch")
        _stamp(p, "arch", width=self.width, top=self.top, bottom=self.bottom)
        return {'FINISHED'}


class SIAG_OT_add_strip(_SIAGOp):
    bl_idname = "siag.add_strip"
    bl_label = "Safe-Lane Strip"
    bl_description = "Glowing floor strip marking the safe lane (game: 1.19 × 0.04 m)"

    lane_x: FloatProperty(name="Lane X", default=0.0, min=-2.4, max=2.4)
    length: FloatProperty(name="Length", default=GATE_DEPTH * 1.2, min=0.3, max=20.0)
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("SafeStrip")
        o = _box_obj("Strip", (BLOCKER_W * 0.7, self.length, 0.04),
                     (self.lane_x, 0, 0.02), p)
        if self.game_colors:
            _precolor(p, "strip")
        _stamp(p, "strip", length=self.length)
        return {'FINISHED'}


class SIAG_OT_add_marks(_SIAGOp):
    bl_idname = "siag.add_marks"
    bl_label = "Approach Marks"
    bl_description = "Three floor hash lines leading up to a gate"

    width: FloatProperty(name="Width", default=TRACK_WIDTH * 0.8, min=0.5, max=8.0)
    offset_x: FloatProperty(name="X offset", default=0.0, min=-3.0, max=3.0)
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("ApproachMarks")
        acc = _BoxAccum()
        for i in range(3):
            acc.box((self.width * (1.0 - i * 0.18), 0.35, 0.03),
                    (self.offset_x, -2.0 - i * 1.6, 0.015))
        o = acc.to_obj("Marks", p)
        if self.game_colors:
            _precolor(p, "marks")
        _stamp(p, "marks", width=self.width)
        return {'FINISHED'}


class SIAG_OT_add_lightpost(_SIAGOp):
    bl_idname = "siag.add_lightpost"
    bl_label = "Light Post"
    bl_description = "Trackside lamp post — Lamp head is its own object for an emissive material"

    side: EnumProperty(name="Side", items=[('LEFT', "Left", ""), ('RIGHT', "Right", "")],
                       default='RIGHT')
    height: FloatProperty(name="Height", default=4.0, min=1.5, max=12.0)
    real_light: BoolProperty(name="Add point light", default=True,
                             description="Actual light (exports to Godot via glTF)")
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        s = -1 if self.side == 'LEFT' else 1
        x = s * (HALF_W + 0.4)
        p = _new_empty("LightPost")
        acc = _BoxAccum()
        acc.box((0.12, 0.12, self.height), (x, 0, self.height / 2))
        acc.box((1.2, 0.10, 0.10), (x - s * 0.6, 0, self.height - 0.05))
        acc.to_obj("Post", p)
        _box_obj("Lamp", (0.35, 0.35, 0.18),
                 (x - s * 1.1, 0, self.height - 0.18), p)
        if self.real_light:
            ld = bpy.data.lights.new("LampLight", type='POINT')
            ld.energy = 100.0
            lo = bpy.data.objects.new("LampLight", ld)
            lo.location = (x - s * 1.1, 0, self.height - 0.35)
            _link(lo)
            lo.parent = p
        if self.game_colors:
            _precolor(p, "lightpost")
        _stamp(p, "lightpost", height=self.height, side=self.side)
        return {'FINISHED'}


class SIAG_OT_add_beacon(_SIAGOp):
    bl_idname = "siag.add_beacon"
    bl_label = "Beacon Pillar"
    bl_description = "Tall glowing pillar (0.55 m sq) like the arc entry beacons"

    height: FloatProperty(name="Height", default=6.0, min=1.0, max=30.0)
    side: EnumProperty(name="Side", items=[('LEFT', "Left", ""), ('RIGHT', "Right", "")],
                       default='RIGHT')
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        s = -1 if self.side == 'LEFT' else 1
        x = s * (HALF_W + WJ_PILLAR_W / 2 + 0.08)
        p = _new_empty("Beacon")
        _box_obj("Pillar", (WJ_PILLAR_W, WJ_PILLAR_W, self.height),
                 (x, 0, self.height / 2), p)
        _box_obj("Cap", (WJ_PILLAR_W * 1.3, WJ_PILLAR_W * 1.3, 0.25),
                 (x, 0, self.height + 0.125), p)
        if self.game_colors:
            _precolor(p, "beacon")
        _stamp(p, "beacon", height=self.height, side=self.side)
        return {'FINISHED'}


# ═════════════════════════════════════════════════════════════════════════════
#  v2.2 — new game elements (WJ descent slide, charge tunnel, grind sparks,
#  electric theme, halos, world decoration, city buildings)
# ═════════════════════════════════════════════════════════════════════════════

def _rotate_span(acc, start, ang, axis, pivot=(0.0, 0.0, 0.0)):
    """Rotate acc.verts[start:] by ang (radians) around axis 'X'|'Y'|'Z'
    through pivot — bakes inclined/leaning boxes straight into the mesh."""
    c, s = math.cos(ang), math.sin(ang)
    px, py, pz = pivot
    for i in range(start, len(acc.verts)):
        x, y, z = acc.verts[i]
        x -= px; y -= py; z -= pz
        if axis == 'X':
            y, z = y * c - z * s, y * s + z * c
        elif axis == 'Y':
            x, z = x * c + z * s, -x * s + z * c
        else:
            x, y = x * c - y * s, x * s + y * c
        acc.verts[i] = (x + px, y + py, z + pz)


def _torus_obj(name, major_r, minor_r, major_segs, minor_segs,
               parent=None, alt_every=0):
    """Torus standing upright: ring in the X-Z plane, hole facing +Y (the
    travel direction) — exactly how the game orients hoops and halos.
    alt_every > 0 alternates material slots 0/1 every N major segments."""
    verts, faces, uvs, mats = [], [], [], []
    for i in range(major_segs):
        th = i / major_segs * math.tau
        for j in range(minor_segs):
            ph = j / minor_segs * math.tau
            rr = major_r + minor_r * math.cos(ph)
            verts.append((rr * math.cos(th), minor_r * math.sin(ph),
                          rr * math.sin(th)))
    for i in range(major_segs):
        i2 = (i + 1) % major_segs
        m = ((i // alt_every) % 2) if alt_every > 0 else 0
        u0 = i / major_segs * math.tau * major_r
        u1 = (i + 1) / major_segs * math.tau * major_r
        for j in range(minor_segs):
            j2 = (j + 1) % minor_segs
            v0 = j / minor_segs * math.tau * minor_r
            v1 = (j + 1) / minor_segs * math.tau * minor_r
            a = i * minor_segs + j
            b = i2 * minor_segs + j
            c = i2 * minor_segs + j2
            d = i * minor_segs + j2
            faces.append((a, d, c, b))                      # outward normals
            uvs.append(((u0, v0), (u0, v1), (u1, v1), (u1, v0)))
            mats.append(m)
    return _new_obj(name, verts, faces, uvs, mats, parent)


def _sphere_obj(name, radius, half_height, segs, rings, parent=None):
    """UV sphere, squashable: equator radius `radius`, pole height
    ±half_height (set equal to radius for a perfect sphere)."""
    verts = [(0.0, 0.0, half_height)]
    for ri in range(1, rings):
        phi = ri / rings * math.pi
        rr, z = radius * math.sin(phi), half_height * math.cos(phi)
        for si in range(segs):
            th = si / segs * math.tau
            verts.append((rr * math.cos(th), rr * math.sin(th), z))
    verts.append((0.0, 0.0, -half_height))
    faces, uvs, mats = [], [], []

    def _uv(ri, si):
        return (si / segs * math.tau * radius, (1.0 - ri / rings) * math.pi * radius)

    last = len(verts) - 1
    for si in range(segs):
        s2 = (si + 1) % segs
        faces.append((0, 1 + si, 1 + s2))                   # top cap fan
        uvs.append((_uv(0, si), _uv(1, si), _uv(1, si + 1)))
        mats.append(0)
        base = 1 + (rings - 2) * segs
        faces.append((last, base + s2, base + si))          # bottom cap fan
        uvs.append((_uv(rings, si), _uv(rings - 1, si + 1), _uv(rings - 1, si)))
        mats.append(0)
    for ri in range(rings - 2):
        r0, r1 = 1 + ri * segs, 1 + (ri + 1) * segs
        for si in range(segs):
            s2 = (si + 1) % segs
            faces.append((r0 + si, r1 + si, r1 + s2, r0 + s2))
            uvs.append((_uv(ri + 1, si), _uv(ri + 2, si),
                        _uv(ri + 2, si + 1), _uv(ri + 1, si + 1)))
            mats.append(0)
    return _new_obj(name, verts, faces, uvs, mats, parent)


def _disc_obj(name, radius, thick, segs, parent=None):
    """Flat cylinder (axis Z) — the game's spark glow ring."""
    verts, faces, uvs, mats = [], [], [], []
    for zi, z in enumerate((thick * 0.5, -thick * 0.5)):
        for si in range(segs):
            th = si / segs * math.tau
            verts.append((radius * math.cos(th), radius * math.sin(th), z))
    top = tuple(range(segs))
    bot = tuple(range(segs, segs * 2))
    faces.append(top)                                        # +Z face (CCW)
    uvs.append(tuple((verts[i][0], verts[i][1]) for i in top))
    mats.append(0)
    faces.append(tuple(reversed(bot)))                       # −Z face
    uvs.append(tuple((verts[i][0], verts[i][1]) for i in reversed(bot)))
    mats.append(0)
    for si in range(segs):
        s2 = (si + 1) % segs
        faces.append((si, segs + si, segs + s2, s2))         # side band
        u0 = si / segs * math.tau * radius
        u1 = (si + 1) / segs * math.tau * radius
        uvs.append(((u0, thick), (u0, 0.0), (u1, 0.0), (u1, thick)))
        mats.append(0)
    return _new_obj(name, verts, faces, uvs, mats, parent)


def _shape_points(shape, radius):
    """The game's halo outlines (_get_shape_points) — (x, z) tuples."""
    pts = []
    if shape == 'TRIANGLE':
        for i in range(3):
            a = i / 3.0 * math.tau - math.pi * 0.5
            pts.append((math.cos(a) * radius, math.sin(a) * radius))
    elif shape == 'SQUARE':
        for i in range(4):
            a = i / 4.0 * math.tau + math.pi * 0.25
            pts.append((math.cos(a) * radius, math.sin(a) * radius))
    elif shape == 'PENTAGON':
        for i in range(5):
            a = i / 5.0 * math.tau - math.pi * 0.5
            pts.append((math.cos(a) * radius, math.sin(a) * radius))
    elif shape == 'HEXAGON':
        for i in range(6):
            a = i / 6.0 * math.tau
            pts.append((math.cos(a) * radius, math.sin(a) * radius))
    elif shape == 'DIAMOND':
        for i in range(4):
            a = i / 4.0 * math.tau
            pts.append((math.cos(a) * radius, math.sin(a) * radius))
    elif shape == 'CROSS':
        w, l = radius * 0.28, radius
        pts = [(-w, -l), (w, -l), (w, -w), (l, -w), (l, w), (w, w),
               (w, l), (-w, l), (-w, w), (-l, w), (-l, -w), (-w, -w)]
    elif shape == 'HEART':
        for i in range(32):
            t = i / 32.0 * math.tau
            x = 16.0 * math.sin(t) ** 3
            y = -(13.0 * math.cos(t) - 5.0 * math.cos(2 * t)
                  - 2.0 * math.cos(3 * t) - math.cos(4 * t))
            pts.append((x * radius / 16.0, y * radius / 16.0))
    else:  # STAR
        for i in range(10):
            a = i / 10.0 * math.tau - math.pi * 0.5
            r = radius if i % 2 == 0 else radius * 0.42
            pts.append((math.cos(a) * r, math.sin(a) * r))
    return pts


def _outline_obj(name, pts, tube_r, parent=None, alt=False):
    """Closed outline of square-section tubes in the X-Z plane (like the
    game's shape halos). alt = alternate material slots 0/1 per segment."""
    acc = _BoxAccum()
    n = len(pts)
    for i in range(n):
        ax, az = pts[i]
        bx, bz = pts[(i + 1) % n]
        dx, dz = bx - ax, bz - az
        length = math.hypot(dx, dz) * 1.02      # slight overlap at corners
        start = len(acc.verts)
        acc.box((tube_r * 2.0, tube_r * 2.0, length), (0.0, 0.0, 0.0),
                mat=(i % 2 if alt else 0))
        _rotate_span(acc, start, math.atan2(dx, dz), 'Y')
        for vi in range(start, len(acc.verts)):
            x, y, z = acc.verts[vi]
            acc.verts[vi] = (x + (ax + bx) * 0.5, y, z + (az + bz) * 0.5)
    return acc.to_obj(name, parent)


# ── WJ descent slide ─────────────────────────────────────────────────────────

def build_wj_slide(height, run, strip_w, strip_t, with_slabs, with_rails,
                   rail_h, with_beacon):
    """Post-wall-jump descent slide. Origin = slide entry at the ELEVATED
    floor level (Z = 0 local); the slide descends to Z = −height at Y = run.
    Author the SAFE lane on the LEFT lane (x = −2.4) — the game mirrors the
    piece when the run lands on the other side, and stretches it to the
    exact height/run of each song's climb."""
    parent = _new_empty("WJSlide")
    pitch = math.atan2(height, run)
    diag = math.hypot(height, run)
    names = ("Strip.Safe", "Strip.Mid", "Strip.Far")   # safe = LEFT lane

    for li, lx in enumerate(LANE_XS):
        start_c = (0.0, diag * 0.5, strip_t * 0.5 + 0.14)   # game strip sits 0.17 up
        if with_slabs:
            acc = _BoxAccum()
            s0 = len(acc.verts)
            acc.box((strip_w, diag, 0.28), (0.0, diag * 0.5, 0.0))
            _rotate_span(acc, s0, -pitch, 'X')
            o = acc.to_obj("Slab.%02d" % (li + 1), parent)
            o.location = (lx, 0.0, 0.0)
        acc = _BoxAccum()
        s0 = len(acc.verts)
        acc.box((strip_w, diag, strip_t), start_c)
        _rotate_span(acc, s0, -pitch, 'X')
        o = acc.to_obj(names[li] if li < len(names) else "Strip.%02d" % (li + 1),
                       parent)
        o.location = (lx, 0.0, 0.0)

    if with_rails:
        for sgn, tag, lx in ((-1, "L", LANE_XS[0]), (1, "R", LANE_XS[-1])):
            acc = _BoxAccum()
            s0 = len(acc.verts)
            acc.box((0.10, diag, rail_h), (0.0, diag * 0.5, 0.28 + rail_h * 0.5))
            _rotate_span(acc, s0, -pitch, 'X')
            o = acc.to_obj("Rail.%s" % tag, parent)
            o.location = (lx + sgn * (strip_w * 0.5 + 0.05), 0.0, 0.0)

    if with_beacon:
        o = _sphere_obj("Beacon", 0.35, 0.35, 20, 10, parent)
        o.location = (LANE_XS[0], 0.0, 0.6)    # safe-entry marker (game: h+0.6)
    return parent


class SIAG_OT_add_wj_slide(_SIAGOp):
    bl_idname = "siag.add_wj_slide"
    bl_label = "WJ Descent Slide"
    bl_description = (
        "The slide back down after a wall-jump climb: one glow strip per lane "
        "(safe lane + electrified lanes), outer rails, entry beacon.  Author "
        "the SAFE lane on the LEFT lane — the game mirrors and stretches the "
        "piece to each song's exact climb height and run length"
    )

    height: FloatProperty(name="Drop height", default=5.0, min=0.5, max=20.0,
                          description="Elevated-floor height the slide descends "
                                      "(game: jumps × step, e.g. 5 × 1 m)")
    auto_run: BoolProperty(name="Auto run length", default=True,
                           description="Game formula: clamp(height × 3.2, 24-52 m)")
    run: FloatProperty(name="Run length", default=34.0, min=5.0, max=80.0,
                       description="Horizontal length of the descent")
    strip_w: FloatProperty(name="Lane strip width", default=2.0, min=0.5, max=2.4)
    strip_t: FloatProperty(name="Strip thickness", default=0.06, min=0.01, max=0.30)
    slabs: BoolProperty(name="Solid ramp slabs", default=False,
                        description="Add a 0.28 m body under each strip "
                                    "(collision stays procedural either way)")
    rails: BoolProperty(name="Outer edge rails", default=True)
    rail_h: FloatProperty(name="Rail height", default=0.30, min=0.05, max=1.5)
    beacon: BoolProperty(name="Entry beacon", default=True,
                         description="Sphere marking the safe entry lane")
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        run = min(max(self.height * 3.2, 24.0), 52.0) if self.auto_run else self.run
        p = build_wj_slide(self.height, run, self.strip_w, self.strip_t,
                           self.slabs, self.rails, self.rail_h, self.beacon)
        if self.game_colors:
            _precolor(p, "wj_slide")
        _stamp(p, "wj_slide", height=self.height, run=run)
        return {'FINISHED'}


# ── Charge tunnel hoop ───────────────────────────────────────────────────────

class SIAG_OT_add_charge_hoop(_SIAGOp):
    bl_idname = "siag.add_charge_hoop"
    bl_label = "Charge Hoop"
    bl_description = (
        "Charge-tunnel hoop the player threads during the drop buildup.  "
        "Origin = hoop centre, hole faces the travel direction.  The game "
        "spawns one every 4 m at 1.2 m height and scales it so the opening "
        "always equals the 1.15 m alignment tolerance"
    )

    gap_radius: FloatProperty(name="Opening radius", default=1.15, min=0.3,
                              max=4.0, description="Game alignment tolerance: 1.15 m")
    tube: FloatProperty(name="Tube radius", default=0.08, min=0.02, max=0.5)
    segments: IntProperty(name="Ring segments", default=48, min=8, max=128)
    tube_segments: IntProperty(name="Tube segments", default=12, min=3, max=32)
    alt_stripes: IntProperty(name="Stripe slots (0 = off)", default=0, min=0, max=32,
                             description="Alternate material slots 0/1 every N "
                                         "segments for a striped hoop")
    studs: IntProperty(name="Studs (0 = off)", default=0, min=0, max=24,
                       description="Small cubes around the rim (own object)")
    stud_size: FloatProperty(name="Stud size", default=0.10, min=0.02, max=0.5)
    animate: BoolProperty(name="Spin animation", default=False,
                          description="In-plane spin — visible with stripes "
                                      "or studs")
    spin_seconds: FloatProperty(name="Seconds per turn", default=4.0,
                                min=0.2, max=60.0)
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("ChargeHoop")
        ring = _torus_obj("Ring", self.gap_radius + self.tube, self.tube,
                          self.segments, self.tube_segments, p,
                          alt_every=self.alt_stripes)
        if self.animate:
            _spin_action(context, ring, 'Y', self.spin_seconds)
        if self.studs > 0:
            acc = _BoxAccum()
            r = self.gap_radius + self.tube
            for i in range(self.studs):
                a = i / self.studs * math.tau
                acc.box((self.stud_size,) * 3,
                        (math.cos(a) * r, 0.0, math.sin(a) * r), mat=0)
            studs = acc.to_obj("Studs", p)
            if self.animate:
                _spin_action(context, studs, 'Y', self.spin_seconds)
        if self.game_colors:
            _precolor(p, "charge_hoop")
        _stamp(p, "charge_hoop", gap=self.gap_radius, tube=self.tube)
        return {'FINISHED'}


# ── Grind spark ──────────────────────────────────────────────────────────────

class SIAG_OT_add_spark(_SIAGOp):
    bl_idname = "siag.add_spark"
    bl_label = "Grind Spark"
    bl_description = (
        "Catchable spark orb on the grind rail (one per rap syllable).  "
        "Origin = orb centre; the game plants it 0.85 m above the rail path "
        "and keeps its own catch-pop effects and light"
    )

    orb_radius: FloatProperty(name="Orb radius", default=0.21, min=0.05, max=1.0)
    orb_height: FloatProperty(name="Orb height", default=0.38, min=0.05, max=2.0,
                              description="Vertical size — game default is a "
                                          "slightly squashed 0.38 m")
    ring: BoolProperty(name="Glow ring", default=True,
                       description="Flat disc under the orb (own object — "
                                   "give it a transparent emissive material)")
    ring_radius: FloatProperty(name="Ring radius", default=0.38, min=0.1, max=2.0)
    ring_thick: FloatProperty(name="Ring thickness", default=0.04, min=0.01, max=0.3)
    segments: IntProperty(name="Segments", default=20, min=6, max=64)
    animate: BoolProperty(name="Hover bob", default=False,
                          description="Gentle up-down hover on the orb "
                                      "(the game sparks are static by default)")
    bob_amp: FloatProperty(name="Bob amplitude", default=0.06, min=0.01, max=0.5)
    bob_seconds: FloatProperty(name="Seconds per cycle", default=1.6,
                               min=0.2, max=30.0)
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("Spark")
        orb = _sphere_obj("Orb", self.orb_radius, self.orb_height * 0.5,
                          self.segments, max(4, self.segments // 2), p)
        if self.animate:
            _bob_action(context, orb, 'Z', self.bob_amp, self.bob_seconds)
        if self.ring:
            _disc_obj("Ring", self.ring_radius, self.ring_thick, self.segments, p)
        if self.game_colors:
            _precolor(p, "spark")
        _stamp(p, "spark", orb=self.orb_radius)
        return {'FINISHED'}


# ── Electric theme ───────────────────────────────────────────────────────────

class SIAG_OT_add_pylon(_SIAGOp):
    bl_idname = "siag.add_pylon"
    bl_label = "Electric Pylon"
    bl_description = (
        "Trackside high-voltage pylon for electric zones (game: every 55 m, "
        "14 m out from the track edge).  Author the crossbeam arm pointing "
        "+X (toward the track); the game mirrors it for the far side.  "
        "Name the glow object 'Tip' — the game gives it the zone's arc "
        "colour and pulses it"
    )

    height: FloatProperty(name="Height", default=22.0, min=4.0, max=60.0)
    pole_w: FloatProperty(name="Pole width", default=0.50, min=0.1, max=2.0)
    reach: FloatProperty(name="Arm reach", default=10.0, min=1.0, max=25.0,
                         description="Crossbeam length toward the track")
    braces: BoolProperty(name="X-braces", default=True)
    brace_deg: FloatProperty(name="Brace angle", default=22.0, min=5.0, max=45.0)
    tip: BoolProperty(name="Glow tip", default=True,
                      description="Insulator sphere at the arm end (name it "
                                  "'Tip' to get the game's arc colour + pulse)")
    tip_radius: FloatProperty(name="Tip radius", default=0.30, min=0.05, max=1.0)
    base: BoolProperty(name="Base plate", default=False)
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("Pylon")
        h = self.height
        _box_obj("Pole", (self.pole_w, self.pole_w, h), (0, 0, h / 2), p)
        if self.braces:
            acc = _BoxAccum()
            for sgn in (-1.0, 1.0):
                s0 = len(acc.verts)
                acc.box((0.18, 0.18, h * 0.62), (0, 0, h / 2))
                _rotate_span(acc, s0, math.radians(sgn * self.brace_deg), 'Y',
                             (0, 0, h / 2))
            acc.to_obj("Braces", p)
        _box_obj("Arm", (self.reach, 0.32, 0.32), (self.reach / 2, 0, h), p)
        if self.tip:
            o = _sphere_obj("Tip", self.tip_radius, self.tip_radius, 16, 8, p)
            o.location = (self.reach, 0.0, h)
        if self.base:
            _box_obj("Base", (self.pole_w * 3.0, self.pole_w * 3.0, 0.25),
                     (0, 0, 0.125), p)
        if self.game_colors:
            _precolor(p, "pylon")
        _stamp(p, "pylon", height=h, reach=self.reach)
        return {'FINISHED'}


class SIAG_OT_add_fence_post(_SIAGOp):
    bl_idname = "siag.add_fence_post"
    bl_label = "Fence Post"
    bl_description = (
        "Electric-gate fence post (the arcs between posts stay procedural — "
        "they're animated lightning).  Origin at the base; the game stretches "
        "it to each gate's height (2.5 m lane gates, 4 m wall gates)"
    )

    height: FloatProperty(name="Height", default=2.5, min=0.5, max=8.0)
    width: FloatProperty(name="Width", default=0.14, min=0.04, max=0.6)
    cap: BoolProperty(name="Top cap", default=True,
                      description="Small insulator cap (own object)")
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("FencePost")
        _box_obj("Post", (self.width, self.width, self.height),
                 (0, 0, self.height / 2), p)
        if self.cap:
            _box_obj("Cap", (self.width * 1.6, self.width * 1.6, self.width),
                     (0, 0, self.height + self.width / 2), p)
        if self.game_colors:
            _precolor(p, "fence_post")
        _stamp(p, "fence_post", height=self.height)
        return {'FINISHED'}


# ── Halo / hold-tunnel ring ──────────────────────────────────────────────────

class SIAG_OT_add_halo(_SIAGOp):
    bl_idname = "siag.add_halo"
    bl_label = "Halo Ring"
    bl_description = (
        "Melody/FX halo the player flies through — hold notes chain hundreds "
        "into a tunnel.  Origin = ring centre, hole faces the travel "
        "direction.  The game scales it to the configured halo size, spins "
        "it, and fades it in/out (your materials are kept as-is)"
    )

    shape: EnumProperty(name="Shape", items=[
        ('CIRCLE', "Circle", ""), ('TRIANGLE', "Triangle", ""),
        ('SQUARE', "Square", ""), ('PENTAGON', "Pentagon", ""),
        ('HEXAGON', "Hexagon", ""), ('STAR', "Star", ""),
        ('DIAMOND', "Diamond", ""), ('CROSS', "Cross", ""),
        ('HEART', "Heart", "")], default='STAR',
        description="Game default is the settings' halo shape (star)")
    radius: FloatProperty(name="Radius", default=5.8, min=0.5, max=20.0,
                          description="Game halo size setting default: 5.8")
    tube: FloatProperty(name="Tube radius", default=0.10, min=0.02, max=1.0)
    segments: IntProperty(name="Circle segments", default=64, min=8, max=150)
    dual: BoolProperty(name="Dual-colour slots", default=True,
                       description="Alternate material slots 0/1 around the "
                                   "ring — fill both for the two-colour look")
    animate: BoolProperty(name="Spin animation", default=True,
                          description="Slow in-plane spin baked into the ring "
                                      "(replaces the game's random spin)")
    spin_seconds: FloatProperty(name="Seconds per turn", default=9.0,
                                min=0.5, max=60.0)
    spin_reverse: BoolProperty(name="Reverse spin", default=False)
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("Halo")
        if self.shape == 'CIRCLE':
            o = _torus_obj("Ring", self.radius, self.tube, self.segments, 12, p,
                           alt_every=(max(1, self.segments // 12) if self.dual else 0))
        else:
            o = _outline_obj("Ring", _shape_points(self.shape, self.radius),
                             self.tube, p, alt=self.dual)
        if self.animate:
            _spin_action(context, o, 'Y', self.spin_seconds,
                         reverse=self.spin_reverse)
        if self.game_colors:
            _precolor(p, "halo")
        _stamp(p, "halo", radius=self.radius, shape=self.shape.lower())
        return {'FINISHED'}


# ── World decoration set ─────────────────────────────────────────────────────

class SIAG_OT_add_gem(_SIAGOp):
    bl_idname = "siag.add_gem"
    bl_label = "Trackside Gem"
    bl_description = (
        "Spinning gem lining the track (game: both sides every 32 m at "
        "1.7 m height, spin + light added automatically).  Origin = centre"
    )

    size: FloatProperty(name="Size", default=0.40, min=0.1, max=2.0)
    style: EnumProperty(name="Style", items=[
        ('CUBE', "Tilted cube", "The game's 35° tilted box"),
        ('OCTA', "Octahedron", "Classic double-pyramid gem")], default='CUBE')
    elongate: FloatProperty(name="Elongation", default=1.0, min=0.5, max=3.0,
                            description="Octahedron only — stretch along Z")
    animate: BoolProperty(name="Spin animation", default=True,
                          description="Bake the game's 2.8 s spin into the "
                                      "piece (replaces the in-game spin)")
    spin_seconds: FloatProperty(name="Seconds per turn", default=2.8,
                                min=0.2, max=30.0)
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("Gem")
        s = self.size
        if self.style == 'CUBE':
            acc = _BoxAccum()
            acc.box((s, s, s), (0, 0, 0))
            _rotate_span(acc, 0, math.radians(35.0), 'X')
            _rotate_span(acc, 0, math.radians(35.0), 'Y')
            o = acc.to_obj("Gem", p)
        else:
            h = s * self.elongate
            verts = [(s/2, 0, 0), (-s/2, 0, 0), (0, s/2, 0), (0, -s/2, 0),
                     (0, 0, h/2), (0, 0, -h/2)]
            faces = [(4, 0, 2), (4, 2, 1), (4, 1, 3), (4, 3, 0),
                     (5, 2, 0), (5, 1, 2), (5, 3, 1), (5, 0, 3)]
            uvs = [tuple((verts[i][0] + verts[i][1], verts[i][2]) for i in f)
                   for f in faces]
            o = _new_obj("Gem", verts, faces, uvs, [0] * len(faces), p)
        if self.animate:
            _spin_action(context, o, 'Z', self.spin_seconds)
        if self.game_colors:
            _precolor(p, "gem")
        _stamp(p, "gem", size=s)
        return {'FINISHED'}


class SIAG_OT_add_deco_arch(_SIAGOp):
    bl_idname = "siag.add_deco_arch"
    bl_label = "Overhead Deco Arch"
    bl_description = (
        "Full-track overhead arch (game: every 64 m — posts, struts, beam, "
        "dangling crystal).  Name the crystal object 'Crystal' and the game "
        "spins it just like the procedural one"
    )

    width: FloatProperty(name="Width", default=TRACK_WIDTH, min=3.0, max=12.0,
                         description="Post-to-post span (track is 6.5 m)")
    post_h: FloatProperty(name="Post height", default=4.2, min=2.0, max=12.0)
    post_w: FloatProperty(name="Post width", default=0.10, min=0.04, max=0.5)
    struts: BoolProperty(name="Diagonal struts", default=True)
    beam: BoolProperty(name="Top beam", default=True)
    crystal: BoolProperty(name="Dangling crystal", default=True)
    crystal_s: FloatProperty(name="Crystal size", default=0.22, min=0.05, max=1.0)
    animate: BoolProperty(name="Spin the crystal", default=True,
                          description="Bake the game's 3.6 s crystal spin "
                                      "(replaces the in-game spin)")
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("DecoArch")
        hw = self.width / 2
        for sgn, tag in ((-1, "L"), (1, "R")):
            _box_obj("Post.%s" % tag, (self.post_w, self.post_w, self.post_h),
                     (sgn * hw, 0, self.post_h / 2), p)
            if self.struts:
                acc = _BoxAccum()
                s0 = len(acc.verts)
                acc.box((0.06, 0.06, 0.70),
                        (sgn * (hw - 0.4), 0, self.post_h - 0.4))
                _rotate_span(acc, s0, math.radians(sgn * 25.0), 'Y',
                             (sgn * (hw - 0.4), 0, self.post_h - 0.4))
                acc.to_obj("Strut.%s" % tag, p)
        if self.beam:
            _box_obj("Beam", (self.width + self.post_w, 0.10, 0.10),
                     (0, 0, self.post_h), p)
        if self.crystal:
            s = self.crystal_s
            acc = _BoxAccum()
            acc.box((s, s, s * 2.0), (0, 0, 0))
            _rotate_span(acc, 0, math.radians(45.0), 'Y')
            o = acc.to_obj("Crystal", p)
            o.location = (0, 0, self.post_h - 0.7)
            if self.animate:
                _spin_action(context, o, 'Z', 3.6)
        if self.game_colors:
            _precolor(p, "deco_arch")
        _stamp(p, "deco_arch", width=self.width, height=self.post_h)
        return {'FINISHED'}


class SIAG_OT_add_pad(_SIAGOp):
    bl_idname = "siag.add_pad"
    bl_label = "Floor Pulse Pad"
    bl_description = (
        "Glowing floor pad near the track edge (game: every 128 m, "
        "alternating sides, pulsing with the beat — emissive materials on "
        "authored pads pulse too)"
    )

    width: FloatProperty(name="Width", default=0.80, min=0.2, max=3.0)
    length: FloatProperty(name="Length", default=1.40, min=0.3, max=6.0)
    thick: FloatProperty(name="Thickness", default=0.04, min=0.01, max=0.3)
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("PulsePad")
        o = _box_obj("Pad", (self.width, self.length, self.thick),
                     (0, 0, self.thick / 2), p)
        if self.game_colors:
            _precolor(p, "pad")
        _stamp(p, "pad", width=self.width, length=self.length)
        return {'FINISHED'}


class SIAG_OT_add_haze_pillar(_SIAGOp):
    bl_idname = "siag.add_haze_pillar"
    bl_label = "Haze Pillar"
    bl_description = (
        "Tall thin background pillar far outside the track (game: every "
        "120 m at 8/14 m out, heights 20-35 m — it stretches this piece).  "
        "Origin at the base"
    )

    height: FloatProperty(name="Height", default=26.0, min=5.0, max=60.0)
    width: FloatProperty(name="Width", default=0.22, min=0.05, max=2.0)
    stripes: FloatProperty(name="Stripe every (0 = off)", default=0.0, min=0.0,
                           max=10.0, description="Alternate material slots 0/1 "
                                                 "every N metres up the pillar")
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("HazePillar")
        if self.stripes > 0.05:
            acc = _BoxAccum()
            z, i = 0.0, 0
            while z < self.height - 0.001:
                seg = min(self.stripes, self.height - z)
                acc.box((self.width, self.width, seg),
                        (0, 0, z + seg / 2), mat=i % 2)
                z += seg
                i += 1
            acc.to_obj("Pillar", p)
        else:
            _box_obj("Pillar", (self.width, self.width, self.height),
                     (0, 0, self.height / 2), p)
        if self.game_colors:
            _precolor(p, "haze_pillar")
        _stamp(p, "haze_pillar", height=self.height)
        return {'FINISHED'}


# ── Animations ───────────────────────────────────────────────────────────────
# Looping TRANSFORM animations (spin / bob / pulse) that export through glTF.
# Godot's TrackPieceLibrary re-targets them onto each piece and auto-plays them
# looped; where the game used to spin things itself (gems, arch crystals,
# halos) an authored animation takes over instead. Material/emission flicker
# can't travel through glTF — the game's beat-pulse keeps driving emissives.
# Animate PARTS (child objects), never the piece's root empty: the game owns
# the root transform (placement, mirroring, stretching).

def _anim_fps(context):
    rd = context.scene.render
    return rd.fps / rd.fps_base


def _new_action(obj, label):
    if obj.animation_data is None:
        obj.animation_data_create()
    act = bpy.data.actions.new(name="%s_%s" % (obj.name, label))
    obj.animation_data.action = act
    return act


def _spin_action(context, obj, axis='Z', seconds=2.8, turns=1.0, reverse=False):
    """Constant-speed rotation loop. Whole `turns` = seamless loop."""
    if obj.rotation_mode != 'XYZ':
        obj.rotation_mode = 'XYZ'
    act = _new_action(obj, "Spin")
    idx = 'XYZ'.index(axis)
    end = 1.0 + max(2.0, round(seconds * _anim_fps(context)))
    base = obj.rotation_euler[idx]
    sgn = -1.0 if reverse else 1.0
    fc = act.fcurves.new(data_path="rotation_euler", index=idx)
    fc.keyframe_points.add(2)
    fc.keyframe_points[0].co = (1.0, base)
    fc.keyframe_points[1].co = (end, base + sgn * math.tau * turns)
    for kp in fc.keyframe_points:
        kp.interpolation = 'LINEAR'
    fc.update()
    return act


def _bob_action(context, obj, axis='Z', amp=0.15, seconds=2.0):
    """Smooth up-and-down hover loop around the object's current position."""
    act = _new_action(obj, "Bob")
    idx = 'XYZ'.index(axis)
    q = max(1.0, seconds * _anim_fps(context) / 4.0)
    base = obj.location[idx]
    fc = act.fcurves.new(data_path="location", index=idx)
    pts = ((1.0, base), (1.0 + q, base + amp), (1.0 + 2 * q, base),
           (1.0 + 3 * q, base - amp), (1.0 + 4 * q, base))
    fc.keyframe_points.add(len(pts))
    for kp, (f, v) in zip(fc.keyframe_points, pts):
        kp.co = (f, v)
        kp.interpolation = 'SINE'
        kp.easing = 'EASE_IN_OUT'
    fc.update()
    return act


def _pulse_action(context, obj, amount=0.08, seconds=1.0):
    """Breathing scale loop (1 → 1+amount → 1) on all three axes."""
    act = _new_action(obj, "Pulse")
    h = max(1.0, seconds * _anim_fps(context) / 2.0)
    for idx in range(3):
        base = obj.scale[idx]
        fc = act.fcurves.new(data_path="scale", index=idx)
        pts = ((1.0, base), (1.0 + h, base * (1.0 + amount)), (1.0 + 2 * h, base))
        fc.keyframe_points.add(len(pts))
        for kp, (f, v) in zip(fc.keyframe_points, pts):
            kp.co = (f, v)
            kp.interpolation = 'SINE'
            kp.easing = 'EASE_IN_OUT'
        fc.update()
    return act


def _anim_targets(self, context):
    """Selected objects that are safe to animate (skips piece root empties)."""
    out = []
    for obj in context.selected_objects:
        if "siag_type" in obj:
            self.report({'WARNING'},
                        "%s is a piece root — animate its child parts instead "
                        "(the game owns the root transform)" % obj.name)
            continue
        out.append(obj)
    if not out:
        self.report({'WARNING'}, "Nothing to animate — select a piece PART")
    return out


class SIAG_OT_anim_spin(bpy.types.Operator):
    bl_idname = "siag.anim_spin"
    bl_label = "Add Spin"
    bl_description = ("Looping rotation on every selected part.  Exports with "
                      "the piece; the game auto-plays it (and stops spinning "
                      "the piece itself for gems, arch crystals and halos)")
    bl_options = {'REGISTER', 'UNDO'}

    axis: EnumProperty(name="Axis", items=[
        ('X', "X", ""), ('Y', "Y (travel)", ""), ('Z', "Z (up)", "")],
        default='Z')
    seconds: FloatProperty(name="Seconds per turn", default=2.8, min=0.1,
                           max=60.0, description="Game gems: 2.8 · crystals: 3.6")
    turns: FloatProperty(name="Turns per loop", default=1.0, min=0.25, max=8.0,
                         description="Whole turns loop seamlessly")
    reverse: BoolProperty(name="Reverse", default=False)

    @classmethod
    def poll(cls, context):
        return len(context.selected_objects) > 0

    def execute(self, context):
        for obj in _anim_targets(self, context):
            _spin_action(context, obj, self.axis, self.seconds,
                         self.turns, self.reverse)
        return {'FINISHED'}


class SIAG_OT_anim_bob(bpy.types.Operator):
    bl_idname = "siag.anim_bob"
    bl_label = "Add Bob"
    bl_description = ("Looping hover (up-down drift) on every selected part — "
                      "nice on sparks, gems and crystals")
    bl_options = {'REGISTER', 'UNDO'}

    axis: EnumProperty(name="Axis", items=[
        ('X', "X", ""), ('Y', "Y (travel)", ""), ('Z', "Z (up)", "")],
        default='Z')
    amplitude: FloatProperty(name="Amplitude", default=0.15, min=0.01, max=3.0,
                             subtype='DISTANCE')
    seconds: FloatProperty(name="Seconds per cycle", default=2.0, min=0.2, max=30.0)

    @classmethod
    def poll(cls, context):
        return len(context.selected_objects) > 0

    def execute(self, context):
        for obj in _anim_targets(self, context):
            _bob_action(context, obj, self.axis, self.amplitude, self.seconds)
        return {'FINISHED'}


class SIAG_OT_anim_pulse(bpy.types.Operator):
    bl_idname = "siag.anim_pulse"
    bl_label = "Add Pulse (scale)"
    bl_description = ("Looping breathing-scale on every selected part — a "
                      "geometry pulse that works alongside the game's "
                      "emission beat-pulse")
    bl_options = {'REGISTER', 'UNDO'}

    amount: FloatProperty(name="Grow amount", default=0.08, min=0.01, max=1.0,
                          description="0.08 = +8 % at the peak")
    seconds: FloatProperty(name="Seconds per cycle", default=1.0, min=0.1, max=30.0)

    @classmethod
    def poll(cls, context):
        return len(context.selected_objects) > 0

    def execute(self, context):
        for obj in _anim_targets(self, context):
            _pulse_action(context, obj, self.amount, self.seconds)
        return {'FINISHED'}


# ── Pose snapshots — animate by POSING, never by keyframing ──────────────────
# Pose the parts in the viewport → Snapshot → pose again → Snapshot → Build
# Loop. The add-on writes all keyframes (easing preset, loop back to pose 1)
# and leaves the piece resting at pose 1. Anything you can pose, you can
# animate — no dope sheet, no timeline, no graph editor.

_POSE_EASING = {
    'SMOOTH': ('SINE',   'EASE_IN_OUT'),
    'SNAPPY': ('QUART',  'EASE_OUT'),
    'BOUNCY': ('BOUNCE', 'EASE_OUT'),
    'LINEAR': ('LINEAR', 'EASE_IN_OUT'),
}


def _anim_scope(context):
    """Parts to capture: every MESH/EMPTY under the selection's top-level
    parents (the roots themselves excluded — the game owns root transforms)."""
    roots = set()
    for obj in context.selected_objects:
        top = obj
        while top.parent is not None:
            top = top.parent
        roots.add(top)
    out, seen = [], set()
    for r in roots:
        stack = list(r.children)
        while stack:
            o = stack.pop()
            if o.name in seen:
                continue
            seen.add(o.name)
            if o.type in ('MESH', 'EMPTY'):
                out.append(o)
            stack.extend(o.children)
    return out


def _pose_list(s):
    import json
    return json.loads(s.pose_data) if s.pose_data else []


def _pose_store(s, data):
    import json
    s.pose_data = json.dumps(data)
    s.pose_count = len(data)


class SIAG_OT_pose_snapshot(bpy.types.Operator):
    bl_idname = "siag.pose_snapshot"
    bl_label = "Snapshot Pose"
    bl_description = ("Store the current arrangement of every part of the "
                      "selected piece as one pose.  Pose → Snapshot → repeat, "
                      "then Build Loop writes all the keyframes for you")
    bl_options = {'REGISTER', 'UNDO'}

    @classmethod
    def poll(cls, context):
        return len(context.selected_objects) > 0

    def execute(self, context):
        objs = _anim_scope(context)
        if not objs:
            self.report({'WARNING'}, "Select a piece (or any of its parts) first")
            return {'CANCELLED'}
        s = context.scene.siag
        pose = {}
        for o in objs:
            if o.rotation_mode != 'XYZ':
                o.rotation_mode = 'XYZ'
            pose[o.name] = [list(o.location), list(o.rotation_euler), list(o.scale)]
        data = _pose_list(s)
        data.append(pose)
        _pose_store(s, data)
        self.report({'INFO'}, "Pose %d stored (%d parts)" % (len(data), len(pose)))
        return {'FINISHED'}


class SIAG_OT_pose_undo(bpy.types.Operator):
    bl_idname = "siag.pose_undo"
    bl_label = "Undo Last"
    bl_description = "Remove the most recent snapshot"

    def execute(self, context):
        s = context.scene.siag
        data = _pose_list(s)
        if data:
            data.pop()
        _pose_store(s, data)
        return {'FINISHED'}


class SIAG_OT_pose_clear(bpy.types.Operator):
    bl_idname = "siag.pose_clear"
    bl_label = "Clear"
    bl_description = "Throw away all stored snapshots"

    def execute(self, context):
        _pose_store(context.scene.siag, [])
        return {'FINISHED'}


class SIAG_OT_pose_build(bpy.types.Operator):
    bl_idname = "siag.pose_build"
    bl_label = "Build Loop Animation"
    bl_description = ("Turn the stored snapshots into a looping animation: "
                      "keyframes + easing on every part that moved, loop back "
                      "to pose 1, piece left resting at pose 1.  Exports with "
                      "the piece; the game auto-plays it")
    bl_options = {'REGISTER', 'UNDO'}

    @classmethod
    def poll(cls, context):
        return getattr(context.scene, "siag", None) is not None \
            and context.scene.siag.pose_count >= 2

    def execute(self, context):
        s = context.scene.siag
        data = _pose_list(s)
        if len(data) < 2:
            self.report({'WARNING'}, "Need at least 2 snapshots")
            return {'CANCELLED'}
        step = max(2.0, s.pose_seconds * _anim_fps(context))
        interp, easing = _POSE_EASING[s.pose_easing]
        poses = data + ([data[0]] if s.pose_loop else [])

        names = set()
        for p in poses:
            names.update(p.keys())

        built = 0
        for name in sorted(names):
            obj = bpy.data.objects.get(name)
            if obj is None:
                continue
            first = next(p[name] for p in poses if name in p)
            vals, last = [], first
            for p in poses:
                last = p.get(name, last)
                vals.append(last)
            # which of the 9 channels actually move?
            moving = []
            for di in range(3):
                for ch in range(3):
                    series = [v[di][ch] for v in vals]
                    if any(abs(x - series[0]) > 1e-6 for x in series):
                        moving.append((di, ch, series))
            if not moving:
                continue
            if obj.rotation_mode != 'XYZ':
                obj.rotation_mode = 'XYZ'
            act = _new_action(obj, "Poses")
            for di, ch, series in moving:
                dp = ("location", "rotation_euler", "scale")[di]
                fc = act.fcurves.new(data_path=dp, index=ch)
                fc.keyframe_points.add(len(series))
                for ki, val in enumerate(series):
                    kp = fc.keyframe_points[ki]
                    kp.co = (1.0 + ki * step, val)
                    kp.interpolation = interp
                    kp.easing = easing
                fc.update()
            # rest state = pose 1
            obj.location       = vals[0][0]
            obj.rotation_euler = vals[0][1]
            obj.scale          = vals[0][2]
            built += 1

        if built == 0:
            self.report({'WARNING'}, "No part moved between snapshots — nothing to animate")
            return {'CANCELLED'}
        self.report({'INFO'}, "Loop built: %d part(s) × %d pose(s)" % (built, len(data)))
        return {'FINISHED'}


# ── Anim tags — type a motion recipe instead of animating ────────────────────
# "spin 3.6" · "bob 0.12 2" · "pulse 0.08 1" · "sway 15 2" — combine with +:
# "spin 4 + bob 0.1 2".  Axis suffix on spin/bob/sway: spinx / boby / swayz.
# Shorter motions are stretched a touch so whole cycles fit the longest one —
# the combined loop is always seamless.

_TAG_DEFAULTS = {"spin": [4.0, 1.0], "bob": [0.15, 2.0],
                 "pulse": [0.08, 1.0], "sway": [15.0, 2.0]}


def _parse_tags(text):
    """→ (motions, error): motions = [(kind, axis, nums), …]."""
    out = []
    for chunk in text.split("+"):
        toks = chunk.split()
        if not toks:
            continue
        kind = toks[0].lower()
        axis = 'Z'
        if kind[-1:] in ("x", "y", "z") and kind[:-1] in ("spin", "bob", "sway"):
            axis = kind[-1].upper()
            kind = kind[:-1]
        if kind not in _TAG_DEFAULTS:
            return None, chunk.strip()
        try:
            nums = [float(t) for t in toks[1:]]
        except ValueError:
            return None, chunk.strip()
        vals = list(_TAG_DEFAULTS[kind])
        for i in range(min(len(nums), len(vals))):
            vals[i] = nums[i]
        out.append((kind, axis, vals))
    return out, None


def _tag_cycle(kind, vals):
    """Seconds one cycle of this motion takes."""
    return vals[0] if kind == "spin" else vals[1]


def _apply_tags(context, obj, motions):
    """Build ONE combined looping action from parsed tag motions."""
    if obj.rotation_mode != 'XYZ':
        obj.rotation_mode = 'XYZ'
    fps = _anim_fps(context)
    total = max(_tag_cycle(k, v) for k, v, in [(m[0], m[2]) for m in motions])
    act = _new_action(obj, "Tags")
    taken = set()
    skipped = []
    for kind, axis, vals in motions:
        cyc = _tag_cycle(kind, vals)
        n = max(1, round(total / cyc))
        eff = total / n                       # stretched so cycles fit exactly
        ai = 'XYZ'.index(axis)
        chans = [("scale", 0), ("scale", 1), ("scale", 2)] if kind == "pulse" \
            else [(("rotation_euler" if kind in ("spin", "sway") else "location"), ai)]
        if any(c in taken for c in chans):
            skipped.append(kind)
            continue
        taken.update(chans)
        end = 1.0 + total * fps
        for dp, ch in chans:
            base = (obj.scale[ch] if dp == "scale" else
                    obj.rotation_euler[ch] if dp == "rotation_euler" else
                    obj.location[ch])
            fc = act.fcurves.new(data_path=dp, index=ch)
            if kind == "spin":
                turns = vals[1] * n
                fc.keyframe_points.add(2)
                fc.keyframe_points[0].co = (1.0, base)
                fc.keyframe_points[1].co = (end, base + math.tau * turns)
                for kp in fc.keyframe_points:
                    kp.interpolation = 'LINEAR'
            else:
                if kind == "pulse":
                    hi, lo = base * (1.0 + vals[0]), base
                    pts = [lo, hi, lo]
                elif kind == "sway":
                    d = math.radians(vals[0])
                    pts = [base, base + d, base, base - d, base]
                else:                          # bob
                    pts = [base, base + vals[0], base, base - vals[0], base]
                seg = eff * fps / (len(pts) - 1)
                fc.keyframe_points.add((len(pts) - 1) * n + 1)
                ki = 0
                for cyc_i in range(n):
                    start = 1.0 + cyc_i * eff * fps
                    rng = range(len(pts)) if cyc_i == 0 else range(1, len(pts))
                    for pi in rng:
                        kp = fc.keyframe_points[ki]
                        kp.co = (start + pi * seg, pts[pi])
                        kp.interpolation = 'SINE'
                        kp.easing = 'EASE_IN_OUT'
                        ki += 1
            fc.update()
    return skipped


class SIAG_OT_anim_tags(bpy.types.Operator):
    bl_idname = "siag.anim_tags"
    bl_label = "Apply Tags to Selected"
    bl_description = ("Build a looping animation on every selected part from "
                      "the tag recipe above.  spin <s/turn> <turns> · "
                      "bob <m> <s> · pulse <grow> <s> · sway <deg> <s> — "
                      "combine with +, axis via spinx/boby/swayz")
    bl_options = {'REGISTER', 'UNDO'}

    @classmethod
    def poll(cls, context):
        return len(context.selected_objects) > 0

    def execute(self, context):
        s = context.scene.siag
        motions, err = _parse_tags(s.anim_tags)
        if err is not None:
            self.report({'ERROR'}, "Can't read tag: '%s'  (spin/bob/pulse/sway)" % err)
            return {'CANCELLED'}
        if not motions:
            self.report({'WARNING'}, "Type a recipe first, e.g.  spin 3.6 + bob 0.1 2")
            return {'CANCELLED'}
        done = 0
        for obj in _anim_targets(self, context):
            skipped = _apply_tags(context, obj, motions)
            obj["siag_anim"] = s.anim_tags
            done += 1
            for k in skipped:
                self.report({'WARNING'},
                            "%s: '%s' skipped — channel already used" % (obj.name, k))
        if done:
            self.report({'INFO'}, "Tagged %d part(s): %s" % (done, s.anim_tags))
        return {'FINISHED'}


class SIAG_PT_anim(bpy.types.Panel):
    bl_label = "Animation"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "SIAG"

    def draw(self, context):
        s = context.scene.siag
        lay = self.layout

        box = lay.box()
        box.label(text="Anim tags — type it, get it:")
        box.prop(s, "anim_tags", text="")
        box.operator("siag.anim_tags", icon='PLAY')

        box = lay.box()
        box.label(text="Pose snapshots — pose, don't keyframe:")
        row = box.row(align=True)
        row.operator("siag.pose_snapshot",
                     text="Snapshot  (%d)" % s.pose_count, icon='RENDER_STILL')
        row.operator("siag.pose_undo", text="", icon='LOOP_BACK')
        row.operator("siag.pose_clear", text="", icon='TRASH')
        box.prop(s, "pose_seconds")
        box.prop(s, "pose_easing", text="")
        box.prop(s, "pose_loop")
        box.operator("siag.pose_build", icon='PLAY')

        col = lay.column(align=True)
        col.label(text="One-click basics:")
        col.operator("siag.anim_spin", icon='FILE_REFRESH')
        col.operator("siag.anim_bob", icon='MOD_WAVE')
        col.operator("siag.anim_pulse", icon='PROP_ON')

        box = lay.box()
        for line in (
            "Select PARTS, not the piece root.",
            "Everything exports in the .glb;",
            "the game auto-plays it looped.",
            "Gems/crystals/halos with an",
            "animation replace the game spin.",
            "Emission flicker stays in-game.",
        ):
            box.label(text=line)


# ── Precolour (game look) ────────────────────────────────────────────────────
# One toggle (SIAG panels → "Game colours") fills every new piece's material
# slots with shared "SIAG …" materials matching the colours the game renders
# procedurally right now (albedo + emission via Principled BSDF — they ride
# the .glb into Godot unchanged). Turn it off for bare pieces, or recolour
# any part afterwards: the slots are ordinary materials, nothing is locked.

def _light(c, f):
    return tuple(ci + (1.0 - ci) * f for ci in c)


def _dark(c, f):
    return tuple(ci * (1.0 - f) for ci in c)


# Exact colours from Section_BeatRunner3d.gd / GameConfig.gd
_ACT_COLS   = {"left": (1.00, 0.35, 0.65), "right": (0.30, 0.65, 1.00),
               "jump": (0.30, 1.00, 0.55), "slide": (0.00, 0.821, 0.729),
               "wall": (1.00, 0.55, 0.10)}
_LEDGE_COLS = [(1.00, 0.10, 0.10), (1.00, 0.50, 0.00), (1.00, 0.95, 0.00),
               (0.10, 0.85, 0.20), (0.10, 0.45, 1.00), (0.60, 0.10, 1.00),
               (1.00, 0.30, 0.80), (1.00, 1.00, 1.00)]
_FLOOR_COL  = (0.943, 0.948, 0.952)      # GameConfig.floor_color
_DARK_BODY  = (0.04, 0.02, 0.08)         # facade / building silhouette
_DARK_METAL = (0.12, 0.14, 0.18)         # fence posts, lamp posts
_PYLON_BODY = (0.10, 0.12, 0.16)
_WJ_PURPLE  = (0.65, 0.15, 1.00)
_ELEV_PURP  = _dark((0.70, 0.22, 0.95), 0.15)
_RAIL_ORNG  = (1.00, 0.55, 0.10)
_EDGE_RED   = (0.96, 0.00, 0.016)
_GOLD       = (1.00, 0.88, 0.25)
_CYAN_SAFE  = (0.15, 0.90, 1.00)
_DANGER_YEL = (1.00, 0.75, 0.05)
_HOOP_CYAN  = (0.30, 0.79, 1.00)         # Color.from_hsv(0.55, 0.70, 1.00)
_SPARK_YEL  = (1.00, 0.90, 0.20)
_SPARK_AMB  = (1.00, 0.70, 0.05)
_HALO_A     = (1.00, 0.45, 0.70)         # GameConfig.halo_color_a
_HALO_B     = (0.45, 0.82, 1.00)         # GameConfig.halo_color_b
_ELEC_BLUE  = (0.20, 0.80, 1.00)
_GEM_PINK   = (1.00, 0.35, 0.65)
_WIN_PINK   = (1.00, 0.25, 0.60)


def _mat(name, rgb, emit=0.0, metallic=0.0, rough=0.6, alpha=1.0):
    """Get-or-create a shared 'SIAG <name>' Principled material."""
    key = "SIAG %s" % name
    m = bpy.data.materials.get(key)
    if m is not None:
        return m
    m = bpy.data.materials.new(key)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    col = (rgb[0], rgb[1], rgb[2], alpha)
    if bsdf is not None:
        bsdf.inputs["Base Color"].default_value = col
        bsdf.inputs["Metallic"].default_value = metallic
        bsdf.inputs["Roughness"].default_value = rough
        if emit > 0.0:
            for nm in ("Emission Color", "Emission"):   # 4.x / 3.x input name
                if nm in bsdf.inputs:
                    bsdf.inputs[nm].default_value = col
                    break
            if "Emission Strength" in bsdf.inputs:
                bsdf.inputs["Emission Strength"].default_value = emit
        if alpha < 1.0 and hasattr(m, "blend_method"):
            m.blend_method = 'BLEND'
    m.diffuse_color = col        # solid-viewport tint
    m["siag_baked"] = True       # already glTF-clean — the Bake button skips it
    return m


def _paint(obj, *mats):
    """Fill an object's slots with mats (index-matched, last one repeats)."""
    if obj is None or getattr(obj, "type", None) != 'MESH':
        return
    if len(obj.data.materials) == 0:
        obj.data.materials.append(None)
    for i in range(len(obj.data.materials)):
        obj.data.materials[i] = mats[min(i, len(mats) - 1)]


def _ledge_mat(idx):
    """Rainbow ledge material for 1-based jump slot; 0 = generic purple."""
    if idx <= 0:
        return _mat("Ledge Generic", _WJ_PURPLE, emit=1.0)
    c = _LEDGE_COLS[min(idx - 1, len(_LEDGE_COLS) - 1)]
    return _mat("Ledge %d" % idx, c, emit=1.0)


# ── Colours from YOUR exported .glbs ─────────────────────────────────────────
# With colour source "My exported track", a freshly added piece first tries to
# dress itself in the materials of the matching .glb in the project's
# assets/track/ folder (textures and all — imported once, then cached in the
# .blend). Parts the export doesn't cover fall back to the game palette, and
# piece types with no export at all fall back entirely.

_TYPE_FILE_HINTS = {
    "straight": "TrackStraight", "turn": "TrackTurn90", "rail": "GrindRail",
    "hurdle": "JumpHurdle", "slide": "SlideGate", "blocker": "LaneBlocker",
    "arch": "NeonArch", "strip": "SafeStrip", "marks": "ApproachMarks",
    "lightpost": "LightPost", "beacon": "Beacon", "wj_plate": "WallPlate",
    "wj_ledge": "Ledge", "wj_kit": "WallJumpKit", "wj_slide": "WJSlide",
    "charge_hoop": "ChargeHoop", "spark": "Spark", "pylon": "Pylon",
    "fence_post": "FencePost", "halo": "Halo", "gem": "Gem",
    "deco_arch": "DecoArch", "pad": "PulsePad", "haze_pillar": "HazePillar",
    "building": "Building",
}


def _strip_suffix(name):
    """'Curb.L.001' → 'Curb.L' (Blender's numeric de-dup suffix only)."""
    return re.sub(r"\.\d+$", "", name)


# The project's assets/track — used when the field in Colour Tools is empty
# and no smart guess hits (fresh unsaved scene + installed add-on has neither
# a .blend location nor a useful __file__, which otherwise finds nothing).
_PROJECT_ASSETS_FALLBACK = r"C:\Users\maike\Documents\siag\assets\track"


def _assets_dir():
    s = getattr(bpy.context.scene, "siag", None)
    if s is not None and s.assets_dir:
        d = bpy.path.abspath(s.assets_dir)
        if os.path.isdir(d):
            return d
    # Walk upward from the saved .blend, then from the add-on file — covers
    # a stage.blend saved anywhere inside the project.
    starts = []
    if bpy.data.filepath:
        starts.append(os.path.dirname(bpy.data.filepath))
    try:
        starts.append(os.path.dirname(os.path.abspath(__file__)))
    except Exception:
        pass
    for d in starts:
        for _ in range(5):
            cand = os.path.join(d, "assets", "track")
            if os.path.isdir(cand):
                return cand
            parent = os.path.dirname(d)
            if parent == d:
                break
            d = parent
    if os.path.isdir(_PROJECT_ASSETS_FALLBACK):
        return _PROJECT_ASSETS_FALLBACK
    return ""


def _glb_mats_for(ptype):
    """{part_name: [material_name, …]} from the exported .glb matching ptype.
    Imports the .glb once, keeps only its materials (fake-user'd), and caches
    the mapping as JSON in the .blend so reopening doesn't re-import."""
    s = getattr(bpy.context.scene, "siag", None)
    if s is None:
        return {}
    cache = json.loads(s.glb_mat_map) if s.glb_mat_map else {}
    entry = cache.get(ptype)
    if entry is not None:
        live = all(bpy.data.materials.get(mn) is not None
                   for mats in entry.values() for mn in mats if mn)
        if live:
            return entry
    folder = _assets_dir()
    hint = _TYPE_FILE_HINTS.get(ptype, "")
    if not folder or not hint:
        return {}
    path = ""
    for root, _dirs, files in os.walk(folder):
        for fn in sorted(files):
            if fn.startswith(hint) and fn.lower().endswith((".glb", ".gltf")):
                path = os.path.join(root, fn)
                break
        if path:
            break
    if not path:
        print("[SIAG] no exported .glb for '%s' in %s — game palette used" % (ptype, folder))
        cache[ptype] = {}
        s.glb_mat_map = json.dumps(cache)
        return {}
    print("[SIAG] colours for '%s' from %s" % (ptype, os.path.basename(path)))
    before = set(o.name for o in bpy.data.objects)
    try:
        bpy.ops.import_scene.gltf(filepath=path)
    except Exception:
        return {}
    entry = {}
    imported = [o for o in bpy.data.objects if o.name not in before]
    for o in imported:
        if o.type == 'MESH' and len(o.data.materials) > 0:
            entry[_strip_suffix(o.name)] = \
                [(m.name if m is not None else "") for m in o.data.materials]
            for m in o.data.materials:
                if m is not None:
                    m.use_fake_user = True   # survive the object cleanup below
    for o in imported:
        try:
            bpy.data.objects.remove(o, do_unlink=True)
        except Exception:
            pass
    cache[ptype] = entry
    s.glb_mat_map = json.dumps(cache)
    return entry


def _apply_glb_mats(p, ptype, entry=None):
    """Dress a new piece in its exported .glb's materials. Returns True when
    at least one part was covered. Parts with more exported materials than
    generated slots (your multi-coloured LaneLines dashes) get the extra
    slots appended and the colours spread one per dash."""
    if entry is None:
        entry = _glb_mats_for(ptype)
    if not entry:
        return False
    hit = False
    for ch in p.children:
        if getattr(ch, "type", "") != 'MESH':
            continue
        base = _strip_suffix(ch.name)
        mats = entry.get(base)
        if mats is None:   # Ledge.01 ↔ Ledge, Plate.02 ↔ Plate.00, …
            for k, v in entry.items():
                kb = k.rstrip("0123456789.")
                if base.startswith(kb) or k.startswith(base):
                    mats = v
                    break
        if not mats:
            continue
        while len(ch.data.materials) < len(mats):
            ch.data.materials.append(None)
        real = []
        for i, mn in enumerate(mats):
            m = bpy.data.materials.get(mn) if mn else None
            if m is not None:
                ch.data.materials[i] = m
                real.append(i)
        if real:
            hit = True
        dash_faces = ch.get("siag_dash_faces", 0)
        if dash_faces and len(real) > 1:
            for pi, poly in enumerate(ch.data.polygons):
                poly.material_index = real[(pi // dash_faces) % len(real)]
    return hit


class SIAG_OT_glb_refresh(bpy.types.Operator):
    bl_idname = "siag.glb_refresh"
    bl_label = "Re-read exported colours"
    bl_description = ("Forget the cached .glb materials and re-import them on "
                      "the next Add — run this after re-exporting your track")

    def execute(self, context):
        s = context.scene.siag
        s.glb_mat_map = ""
        self.report({'INFO'}, "Exported-colour cache cleared")
        return {'FINISHED'}


def _precolor(p, ptype, variant='ANY', index=0):
    """Paint a freshly built piece with the game's current procedural look.
    Children are matched by name prefix; multi-slot parts get one material
    per slot (curbs red/white, halo A/B, floor top/side/bottom, …).
    Colour source "My exported track" dresses parts from the project .glbs
    first; the palette below only fills whatever that didn't cover."""
    try:
        _src = bpy.context.scene.siag.color_source
    except Exception:
        _src = 'GAME'
    if _src == 'GLB':
        _apply_glb_mats(p, ptype)
    M = _mat
    for ch in p.children:
        if getattr(ch, "type", "") == 'MESH' and \
                any(m is not None for m in ch.data.materials):
            continue   # exported-.glb materials already cover this part
        n = ch.name
        if ptype in ("straight", "turn"):
            if n.startswith("Floor"):
                _paint(ch, M("Floor Top", _FLOOR_COL, rough=0.75),
                       M("Floor Side", _dark(_FLOOR_COL, 0.45), rough=0.8),
                       M("Floor Bottom", _dark(_FLOOR_COL, 0.75), rough=0.9))
            elif n.startswith("Curb"):
                _paint(ch, M("Curb Red", (0.90, 0.10, 0.12), emit=0.4),
                       M("Curb White", (0.95, 0.95, 0.95), emit=0.4))
            elif n.startswith("LaneLines"):
                _paint(ch, M("Lane Line", (0.95, 0.97, 1.00), emit=0.6))
            elif n.startswith("EdgeStrip"):
                _paint(ch, M("Edge Strip", _EDGE_RED, emit=0.8))
        elif ptype == "rail":
            if n.startswith("Rail"):
                _paint(ch, M("Grind Rail", _RAIL_ORNG, emit=6.0))
            elif n.startswith("Posts"):
                _paint(ch, M("Dark Metal", _DARK_METAL, metallic=0.8, rough=0.3))
        elif ptype == "spark":
            if n.startswith("Orb"):
                _paint(ch, M("Spark Orb", _SPARK_YEL, emit=9.0))
            elif n.startswith("Ring"):
                _paint(ch, M("Spark Ring", _SPARK_AMB, emit=4.0, alpha=0.7))
        elif ptype == "wj_kit":
            if n.startswith("Approach"):
                _paint(ch, M("WJ Approach", _dark(_WJ_PURPLE, 0.35), emit=0.5))
            elif n.startswith("Wall"):
                _paint(ch, M("Facade Body", _DARK_BODY, rough=0.85))
            elif n.startswith("Ledge"):
                digits = "".join(c for c in n if c.isdigit())
                _paint(ch, _ledge_mat(int(digits) if digits else 0))
            elif n.startswith("Plate"):
                _paint(ch, M("WJ Plate", _RAIL_ORNG, emit=2.5))
            elif n.startswith("Arch"):
                _paint(ch, M("WJ Arch", _light(_WJ_PURPLE, 0.2), emit=1.5))
            elif n.startswith("ElevFloor"):
                _paint(ch, M("Elev Floor", _ELEV_PURP, emit=0.8))
            elif n.startswith("ElevRail"):
                _paint(ch, M("Elev Rail", _light((0.85, 0.45, 1.00), 0.2), emit=2.0))
        elif ptype == "wj_ledge":
            _paint(ch, _ledge_mat(index))
        elif ptype == "wj_plate":
            _paint(ch, M("WJ Plate", _RAIL_ORNG, emit=2.5))
        elif ptype == "wj_slide":
            if n.startswith("Strip.Safe"):
                _paint(ch, M("Slide Safe", _CYAN_SAFE, emit=4.5))
            elif n.startswith("Strip"):
                _paint(ch, M("Slide Danger", _DANGER_YEL, emit=6.0))
            elif n.startswith("Slab"):
                _paint(ch, M("Facade Body", _DARK_BODY, rough=0.85))
            elif n.startswith("Rail"):
                _paint(ch, M("Slide Rail", _light(_CYAN_SAFE, 0.3), emit=7.0))
            elif n.startswith("Beacon"):
                _paint(ch, M("Slide Beacon", _CYAN_SAFE, emit=14.0))
        elif ptype == "blocker":
            col = {"left": _ACT_COLS["left"], "right": _ACT_COLS["right"]}.get(
                variant, (0.65, 0.50, 0.83))
            _paint(ch, M("Blocker %s" % variant, col, emit=1.2, rough=0.5))
        elif ptype == "hurdle":
            if n.startswith("Arch"):
                _paint(ch, M("Hurdle Arch", _light(_ACT_COLS["jump"], 0.06), emit=3.0))
            else:
                _paint(ch, M("Hurdle", _ACT_COLS["jump"], emit=1.2))
        elif ptype == "slide":
            if n.startswith("Arch"):
                _paint(ch, M("Slide Gate Arch", _light(_ACT_COLS["slide"], 0.06), emit=3.0))
            else:
                _paint(ch, M("Slide Gate", _ACT_COLS["slide"], emit=1.2))
        elif ptype == "arch":
            _paint(ch, M("Neon Arch", (0.85, 0.95, 1.00), emit=3.0))
        elif ptype == "strip":
            _paint(ch, M("Safe Strip", (0.95, 0.97, 1.00), emit=2.5))
        elif ptype == "marks":
            _paint(ch, M("Approach Marks", (0.85, 0.85, 0.85), emit=0.5))
        elif ptype == "lightpost":
            if n.startswith("Lamp"):
                _paint(ch, M("Lamp", (1.00, 0.85, 0.50), emit=8.0))
            else:
                _paint(ch, M("Dark Metal", _DARK_METAL, metallic=0.8, rough=0.3))
        elif ptype == "beacon":
            if n.startswith("Cap"):
                _paint(ch, M("Beacon Cap", _light(_GOLD, 0.3), emit=2.5))
            else:
                _paint(ch, M("Beacon Gold", _GOLD, emit=1.8))
        elif ptype == "pylon":
            if n.startswith("Pole"):
                _paint(ch, M("Pylon Pole", _PYLON_BODY, metallic=0.75, rough=0.35))
            elif n.startswith("Braces"):
                _paint(ch, M("Pylon Brace", _light(_PYLON_BODY, 0.10),
                             metallic=0.70, rough=0.40))
            elif n.startswith("Arm"):
                _paint(ch, M("Pylon Arm", _light(_PYLON_BODY, 0.08),
                             metallic=0.75, rough=0.30))
            elif n.startswith("Tip"):
                _paint(ch, M("Pylon Tip", _light(_ELEC_BLUE, 0.2), emit=1.2))
            elif n.startswith("Base"):
                _paint(ch, M("Pylon Pole", _PYLON_BODY, metallic=0.75, rough=0.35))
        elif ptype == "fence_post":
            if n.startswith("Cap"):
                _paint(ch, M("Fence Cap", _light(_DARK_METAL, 0.15),
                             metallic=0.8, rough=0.3))
            else:
                _paint(ch, M("Dark Metal", _DARK_METAL, metallic=0.8, rough=0.3))
        elif ptype == "halo":
            _paint(ch, M("Halo A", _HALO_A, emit=2.5),
                   M("Halo B", _HALO_B, emit=2.5))
        elif ptype == "charge_hoop":
            if n.startswith("Studs"):
                _paint(ch, M("Hoop Stud", (1.00, 1.00, 1.00), emit=4.0))
            else:
                _paint(ch, M("Hoop A", _HOOP_CYAN, emit=2.2),
                       M("Hoop B", _dark(_HOOP_CYAN, 0.35), emit=2.2))
        elif ptype == "gem":
            _paint(ch, M("Gem", _GEM_PINK, emit=0.6, rough=0.68))
        elif ptype == "deco_arch":
            if n.startswith("Crystal"):
                _paint(ch, M("Arch Crystal", _light(_GEM_PINK, 0.3), emit=1.5))
            else:
                _paint(ch, M("Deco Arch", _dark(_GEM_PINK, 0.15), emit=0.5))
        elif ptype == "pad":
            _paint(ch, M("Pulse Pad", _GEM_PINK, emit=0.8))
        elif ptype == "haze_pillar":
            _paint(ch, M("Haze A", _dark(_GEM_PINK, 0.5), emit=0.4),
                   M("Haze B", _dark(_GEM_PINK, 0.7), emit=0.4))
        elif ptype == "building":
            if n.startswith("Windows"):
                _paint(ch, M("Bldg Windows", _WIN_PINK, emit=1.5))
            elif n.startswith("Cap"):
                _paint(ch, M("Bldg Cap", _light(_WIN_PINK, 0.3), emit=1.0))
            else:
                _paint(ch, M("Bldg Body", _DARK_BODY, rough=0.9))
    return p


def _maybe_precolor(context, p, ptype, variant='ANY', index=0):
    if getattr(context.scene, "siag", None) is not None \
            and context.scene.siag.game_colors:
        _precolor(p, ptype, variant, index)


# ── City building ────────────────────────────────────────────────────────────

class SIAG_OT_add_building(_SIAGOp):
    bl_idname = "siag.add_building"
    bl_label = "City Building"
    bl_description = (
        "Skyline building (game: 18 per side in two distance rows; the far "
        "row is auto-stretched taller/thinner).  Add SEVERAL different ones "
        "— the game cycles through all authored buildings.  Parts: Body, "
        "Windows (emissive — pulses with the city beat), Cap"
    )

    width: FloatProperty(name="Width", default=4.0, min=1.0, max=20.0)
    depth: FloatProperty(name="Depth", default=5.0, min=1.0, max=20.0)
    height: FloatProperty(name="Height", default=14.0, min=2.0, max=80.0)
    strip_h: FloatProperty(name="Window strip height", default=0.14,
                           min=0.05, max=1.0)
    strip_gap: FloatProperty(name="Window strip gap", default=2.2,
                             min=0.3, max=6.0)
    windows: EnumProperty(name="Windows", items=[
        ('ALL', "All sides", "Looks right from every angle (default)"),
        ('FRONT', "Front only", "Cheapest — on the −Y face, which faces the "
                                "approaching player in game"),
        ('NONE', "None", "Dark silhouette only")], default='ALL')
    cap: BoolProperty(name="Rooftop cap", default=True)
    game_colors: SIAGSettings.__annotations__["game_colors"]

    def execute(self, context):
        p = _new_empty("Building")
        w, d, h = self.width, self.depth, self.height
        _box_obj("Body", (w, d, h), (0, 0, h / 2), p)
        if self.windows != 'NONE':
            acc = _BoxAccum()
            z = self.strip_gap
            while z < h - 0.5:
                if self.windows == 'ALL':
                    acc.box((w + 0.04, d + 0.04, self.strip_h),
                            (0, 0, z + self.strip_h / 2))
                else:
                    acc.box((w + 0.02, 0.06, self.strip_h),
                            (0, -d / 2 - 0.03, z + self.strip_h / 2))
                z += self.strip_gap
            acc.to_obj("Windows", p)
        if self.cap:
            _box_obj("Cap", (w + 0.06, d + 0.06, 0.08), (0, 0, h + 0.04), p)
        if self.game_colors:
            _precolor(p, "building")
        _stamp(p, "building", width=w, depth=d, height=h)
        return {'FINISHED'}


# ── Bake materials to export-safe textures ───────────────────────────────────

class SIAG_OT_bake_materials(bpy.types.Operator):
    bl_idname = "siag.bake_materials"
    bl_label = "Bake Materials → Export-Safe"
    bl_description = ("Bake every material on the selected pieces (procedural "
                      "nodes, Mapping setups, anything glTF can't carry) down "
                      "to plain image textures and rebuild the materials as "
                      "Image Texture → Principled BSDF, so Godot shows exactly "
                      "what you see in Blender. Already-baked materials are "
                      "skipped. Run this BEFORE Export Selected → .glb")
    bl_options = {'REGISTER', 'UNDO'}

    resolution: EnumProperty(name="Texture size", items=[
        ('512', "512", ""), ('1024', "1024", ""), ('2048', "2048", "")],
        default='1024')
    bake_emission: BoolProperty(name="Bake emission (glow)", default=True)
    bake_normal: BoolProperty(name="Bake normal map", default=False,
        description="Capture bump/normal detail (slower)")
    samples: IntProperty(name="Bake samples", default=16, min=1, max=256,
        description="Cycles samples used while baking — 16 is plenty for colour")

    @classmethod
    def poll(cls, context):
        return context.mode == 'OBJECT' and len(context.selected_objects) > 0

    def execute(self, context):
        scene = context.scene
        prev_engine = scene.render.engine
        scene.render.engine = 'CYCLES'
        prev_samples = scene.cycles.samples
        scene.cycles.samples = self.samples
        res = int(self.resolution)

        # Collect mesh objects, including children of selected parents
        objs = []
        seen = set()
        for o in context.selected_objects:
            stack = [o]
            while stack:
                c = stack.pop()
                if c.name not in seen:
                    seen.add(c.name)
                    if c.type == 'MESH' and any(m is not None for m in c.data.materials):
                        objs.append(c)
                    stack.extend(c.children)

        baked = 0
        for obj in objs:
            try:
                baked += self._bake_object(context, obj, res)
            except RuntimeError as ex:
                self.report({'WARNING'}, "Bake failed on %s: %s" % (obj.name, ex))

        scene.cycles.samples = prev_samples
        scene.render.engine = prev_engine
        self.report({'INFO'}, "Baked %d material(s) across %d object(s)" % (baked, len(objs)))
        return {'FINISHED'}

    def _bake_object(self, context, obj, res):
        for o in context.selected_objects:
            o.select_set(False)
        obj.select_set(True)
        context.view_layer.objects.active = obj
        mesh = obj.data

        # Shared materials bake per-object → make them single-user first
        for i, mat in enumerate(mesh.materials):
            if mat is not None and mat.users > 1:
                mesh.materials[i] = mat.copy()
        mats = [m for m in mesh.materials if m is not None and not m.get("siag_baked", False)]
        if not mats:
            return 0
        for mat in mats:
            mat.use_nodes = True

        # The track pieces use tiling world-scale UVs which OVERLAP — baking
        # needs unique 0-1 islands, so bake into a dedicated second UV layer.
        if "BakeUV" not in mesh.uv_layers:
            mesh.uv_layers.new(name="BakeUV")
        mesh.uv_layers.active = mesh.uv_layers["BakeUV"]
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        bpy.ops.uv.smart_project(island_margin=0.02)
        bpy.ops.object.mode_set(mode='OBJECT')

        passes = [("DIFFUSE", "_col", True)]
        if self.bake_emission:
            passes.append(("EMIT", "_emit", True))
        if self.bake_normal:
            passes.append(("NORMAL", "_nrm", False))

        images = {m.name: {} for m in mats}
        for btype, suffix, srgb in passes:
            for mat in mats:
                img = bpy.data.images.new("%s_%s%s" % (obj.name, mat.name, suffix),
                                          res, res, alpha=False)
                img.colorspace_settings.name = 'sRGB' if srgb else 'Non-Color'
                nt = mat.node_tree
                node = nt.nodes.new("ShaderNodeTexImage")
                node.name = "SIAG_BAKE_TARGET"
                node.image = img
                for n in nt.nodes:
                    n.select = False
                node.select = True
                nt.nodes.active = node
                images[mat.name][suffix] = img
            kwargs = dict(type=btype, use_clear=True, margin=4)
            if btype == "DIFFUSE":
                kwargs["pass_filter"] = {'COLOR'}   # pure colour, no lighting
            bpy.ops.object.bake(**kwargs)
            for mat in mats:
                node = mat.node_tree.nodes.get("SIAG_BAKE_TARGET")
                if node is not None:
                    mat.node_tree.nodes.remove(node)

        # Rebuild each material as a clean, glTF-safe tree
        for mat in mats:
            imgs = images[mat.name]
            rough, metal = 0.7, 0.0
            for n in mat.node_tree.nodes:
                if n.type == 'BSDF_PRINCIPLED':
                    if not n.inputs["Roughness"].is_linked:
                        rough = n.inputs["Roughness"].default_value
                    if not n.inputs["Metallic"].is_linked:
                        metal = n.inputs["Metallic"].default_value
                    break
            nt = mat.node_tree
            nt.nodes.clear()
            out = nt.nodes.new("ShaderNodeOutputMaterial")
            out.location = (400, 0)
            bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
            bsdf.location = (0, 0)
            bsdf.inputs["Roughness"].default_value = rough
            bsdf.inputs["Metallic"].default_value = metal
            nt.links.new(bsdf.outputs[0], out.inputs["Surface"])
            uvn = nt.nodes.new("ShaderNodeUVMap")
            uvn.location = (-700, 0)
            uvn.uv_map = "BakeUV"

            def _tex(img, x, y):
                t = nt.nodes.new("ShaderNodeTexImage")
                t.location = (x, y)
                t.image = img
                nt.links.new(uvn.outputs[0], t.inputs["Vector"])
                return t

            t_col = _tex(imgs["_col"], -400, 250)
            nt.links.new(t_col.outputs["Color"], bsdf.inputs["Base Color"])
            if "_emit" in imgs:
                t_e = _tex(imgs["_emit"], -400, -100)
                ein = bsdf.inputs.get("Emission Color") or bsdf.inputs.get("Emission")
                if ein is not None:
                    nt.links.new(t_e.outputs["Color"], ein)
                    es = bsdf.inputs.get("Emission Strength")
                    if es is not None:
                        es.default_value = 1.0
            if "_nrm" in imgs:
                t_n = _tex(imgs["_nrm"], -500, -450)
                nm = nt.nodes.new("ShaderNodeNormalMap")
                nm.location = (-200, -450)
                nt.links.new(t_n.outputs["Color"], nm.inputs["Color"])
                nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
            mat["siag_baked"] = True

        # Pack images into the .blend so the .glb embeds them on export
        for d in images.values():
            for img in d.values():
                img.pack()

        # glTF should sample the baked textures via the new unique UVs
        mesh.uv_layers["BakeUV"].active_render = True
        return len(mats)


# ── Export ────────────────────────────────────────────────────────────────────

class SIAG_OT_export_glb(bpy.types.Operator, ExportHelper):
    bl_idname = "siag.export_glb"
    bl_label = "Export Selected → .glb"
    bl_description = ("Export the selected pieces as .glb with SIAG metadata "
                      "(custom properties → glTF extras) so Godot's "
                      "TrackPieceLibrary recognises them automatically. "
                      "Save into the project's assets/track/ folder")
    filename_ext = ".glb"
    filter_glob: StringProperty(default="*.glb", options={'HIDDEN'})

    @classmethod
    def poll(cls, context):
        return len(context.selected_objects) > 0

    def execute(self, context):
        # Extend the selection to full hierarchies so child parts come along
        for obj in list(context.selected_objects):
            root = obj
            while root.parent is not None and root.parent.select_get():
                root = root.parent
            stack = [root]
            while stack:
                o = stack.pop()
                o.select_set(True)
                stack.extend(o.children)
        # Ensure every selected mesh has a UV map — required for fur/custom shaders.
        # Meshes that already have at least one UV layer are left untouched;
        # any mesh without one gets an auto Smart UV Project unwrap.
        _prev_active = context.view_layer.objects.active
        for _uv_obj in context.selected_objects:
            if _uv_obj.type != 'MESH' or len(_uv_obj.data.uv_layers) > 0:
                continue
            context.view_layer.objects.active = _uv_obj
            bpy.ops.object.mode_set(mode='EDIT')
            bpy.ops.mesh.select_all(action='SELECT')
            bpy.ops.uv.smart_project(angle_limit=66.0, island_margin=0.02)
            bpy.ops.object.mode_set(mode='OBJECT')
        context.view_layer.objects.active = _prev_active
        bpy.ops.export_scene.gltf(
            filepath=self.filepath,
            export_format='GLB',
            use_selection=True,
            export_extras=True,      # ← carries the siag_* metadata to Godot
            export_lights=True,      # ← carries Light objects (KHR_lights_punctual)
            export_texcoords=True,   # ← UV maps (required for fur and custom shaders)
            export_animations=True,  # ← carries spin/bob/pulse loops to the game
            export_yup=True,
            export_apply=True,
        )
        self.report({'INFO'}, "Exported with SIAG metadata: %s" % self.filepath)
        return {'FINISHED'}


# ── Colour tools ──────────────────────────────────────────────────────────────

class SIAG_OT_faces_to_slot(bpy.types.Operator):
    bl_idname = "siag.faces_to_slot"
    bl_label = "Selected Faces → New Slot"
    bl_description = ("Edit Mode: assign the selected faces to a brand-new empty "
                      "material slot, then drop your material into that slot")
    bl_options = {'REGISTER', 'UNDO'}

    @classmethod
    def poll(cls, context):
        return context.mode == 'EDIT_MESH'

    def execute(self, context):
        obj = context.edit_object
        bpy.ops.object.material_slot_add()
        obj.active_material_index = len(obj.material_slots) - 1
        bpy.ops.object.material_slot_assign()
        self.report({'INFO'}, "Faces moved to slot %d — add your material there"
                    % obj.active_material_index)
        return {'FINISHED'}


class SIAG_OT_separate(bpy.types.Operator):
    bl_idname = "siag.separate_sel"
    bl_label = "Selection → Own Object"
    bl_description = "Edit Mode: split the selected faces into their own object (then colour it in Object Mode)"
    bl_options = {'REGISTER', 'UNDO'}

    @classmethod
    def poll(cls, context):
        return context.mode == 'EDIT_MESH'

    def execute(self, context):
        bpy.ops.mesh.separate(type='SELECTED')
        return {'FINISHED'}


# ═════════════════════════════════════════════════════════════════════════════
#  UI
# ═════════════════════════════════════════════════════════════════════════════

class SIAG_PT_track(bpy.types.Panel):
    bl_label = "Track"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "SIAG"

    def draw(self, context):
        s = context.scene.siag
        lay = self.layout
        col = lay.column(align=True)
        col.prop(s, "length")
        col.operator("siag.add_straight", icon='MESH_PLANE')
        lay.separator()
        col = lay.column(align=True)
        col.prop(s, "radius", slider=True)
        row = col.row(align=True)
        row.prop(s, "direction", expand=True)
        col.prop(s, "bank_mode", text="")
        sub = col.column(align=True)
        sub.enabled = s.bank_mode != 'FLAT'
        sub.prop(s, "bank_deg", slider=True)
        col.prop(s, "segments")
        col.operator("siag.add_turn", icon='CURVE_NCIRCLE')

        box = lay.box()
        box.label(text="Decorations on new pieces:")
        box.prop(s, "lane_seams")
        box.prop(s, "curbs")
        row = box.row()
        row.prop(s, "lane_lines")
        sub = row.row()
        sub.enabled = s.lane_lines
        sub.prop(s, "dashed")
        box.prop(s, "edge_strips")
        box.prop(s, "game_colors", icon='MATERIAL')
        sub = box.row()
        sub.enabled = s.game_colors
        sub.prop(s, "color_source", text="")


class SIAG_PT_pieces(bpy.types.Panel):
    bl_label = "Obstacles & Rails"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "SIAG"

    def draw(self, context):
        col = self.layout.column(align=True)
        col.operator("siag.add_rail", icon='IPO_LINEAR')
        col.operator("siag.add_spark", icon='LIGHT_POINT')
        col.separator()
        col.operator("siag.add_wj_kit", icon='MOD_BUILD')
        col.operator("siag.add_wj_slide", icon='IPO_EASE_IN')
        col.operator("siag.add_plate", icon='SNAP_VOLUME')
        col.separator()
        col.operator("siag.add_charge_hoop", icon='MESH_TORUS')
        col.separator()

        # Indexed ledge slots — one button per jump position.
        # Click the slot you want to model; the operator creates a correctly
        # named/stamped placeholder at the right dimensions.
        _LEDGE_LABELS = [
            (0, "Ledge (generic fallback)", 'MESH_CUBE'),
            (1, "Ledge 1 — Red",    'MESH_CUBE'),
            (2, "Ledge 2 — Orange", 'MESH_CUBE'),
            (3, "Ledge 3 — Yellow", 'MESH_CUBE'),
            (4, "Ledge 4 — Green",  'MESH_CUBE'),
            (5, "Ledge 5 — Blue",   'MESH_CUBE'),
            (6, "Ledge 6 — Purple", 'MESH_CUBE'),
            (7, "Ledge 7 — Pink",   'MESH_CUBE'),
            (8, "Ledge 8 — White",  'MESH_CUBE'),
        ]
        box = self.layout.box()
        box.label(text="Wall-Jump Ledges:")
        bcol = box.column(align=True)
        for idx, label, icon in _LEDGE_LABELS:
            op = bcol.operator("siag.add_wj_ledge", text=label, icon=icon)
            op.index = idx

        col = self.layout.column(align=True)
        col.separator()
        col.operator("siag.add_blocker", icon='SNAP_FACE')
        col.operator("siag.add_hurdle", icon='TRIA_UP_BAR')
        col.operator("siag.add_slide", icon='TRIA_DOWN_BAR')
        col.operator("siag.add_fence_post", icon='RIGID_BODY')


class SIAG_PT_deco(bpy.types.Panel):
    bl_label = "Decoration"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "SIAG"

    def draw(self, context):
        col = self.layout.column(align=True)
        col.operator("siag.add_arch", icon='META_PLANE')
        col.operator("siag.add_strip", icon='SEQ_STRIP_DUPLICATE')
        col.operator("siag.add_marks", icon='ALIGN_JUSTIFY')
        col.operator("siag.add_lightpost", icon='LIGHT_SPOT')
        col.operator("siag.add_beacon", icon='LIGHT_SUN')


class SIAG_PT_world(bpy.types.Panel):
    bl_label = "World & FX"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "SIAG"

    def draw(self, context):
        col = self.layout.column(align=True)
        col.operator("siag.add_halo", icon='MESH_CIRCLE')
        col.separator()
        col.operator("siag.add_gem", icon='MESH_ICOSPHERE')
        col.operator("siag.add_deco_arch", icon='SPHERECURVE')
        col.operator("siag.add_pad", icon='MESH_PLANE')
        col.operator("siag.add_haze_pillar", icon='MESH_CYLINDER')
        col.separator()
        col.operator("siag.add_pylon", icon='OUTLINER_OB_LATTICE')
        col.operator("siag.add_building", icon='HOME')


class SIAG_PT_color(bpy.types.Panel):
    bl_label = "Colour Tools"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "SIAG"

    def draw(self, context):
        lay = self.layout
        s = context.scene.siag
        lay.prop(s, "game_colors", icon='MATERIAL')
        sub = lay.column()
        sub.enabled = s.game_colors
        sub.prop(s, "color_source", text="")
        if s.color_source == 'GLB':
            sub.prop(s, "assets_dir", text="")
            found = _assets_dir()
            if found:
                sub.label(text="✔ " + os.path.basename(os.path.dirname(found))
                          + "/" + os.path.basename(found), icon='CHECKMARK')
            else:
                sub.label(text="assets/track NOT found — set it above!",
                          icon='ERROR')
            sub.operator("siag.glb_refresh", icon='FILE_REFRESH')
        col = lay.column(align=True)
        col.operator("siag.faces_to_slot", icon='FACESEL')
        col.operator("siag.separate_sel", icon='MOD_EXPLODE')
        box = lay.box()
        for line in (
            "'My exported track': new pieces",
            "wear the materials of your",
            "assets/track .glbs (textures",
            "included); the game palette",
            "fills anything not exported.",
            "Object Mode: click a part,",
            "add a material — done.",
            "Edit Mode: select faces, use",
            "the buttons above.",
            "Pre-set slots (fill them in):",
            "Floor: 0 top · 1 sides · 2 bottom",
            "Curbs: 0/1 alternate (seam-safe)",
        ):
            box.label(text=line)


class SIAG_PT_export(bpy.types.Panel):
    bl_label = "Export to Godot"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "SIAG"

    def draw(self, context):
        lay = self.layout
        col = lay.column(align=True)
        col.operator("siag.bake_materials", icon='RENDER_STILL')
        col.operator("siag.export_glb", icon='EXPORT')
        box = lay.box()
        for line in (
            "1. Bake (fancy node materials",
            "    → plain textures Godot",
            "    can read — else they",
            "    export white).",
            "2. Export into the project's",
            "    assets/track/ folder.",
            "The game auto-detects every",
            "piece and only generates",
            "what's missing.",
        ):
            box.label(text=line)


class SIAG_PT_info(bpy.types.Panel):
    bl_label = "Game Dimensions"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "SIAG"
    bl_options = {'DEFAULT_CLOSED'}

    def draw(self, context):
        box = self.layout.box()
        for line in (
            "Track: 6.5 w × 0.3 thick, top Z=0",
            "Lanes: x = −2.4 / 0 / +2.4",
            "Turns: 90°, r 12/20/32, bank 21°",
            "Blocker: 1.7 × 2.5 × 1.1 deep",
            "Hurdle h: 0.9 · Slide gap: 1.425",
            "Rail: 0.09² @ h 0.88, x ±3.35",
            "WJ ledge: 2.8 w · wall 0.18 thick",
            "WJ slide: run 24-52, strips 2.0 w",
            "Hoop: r 1.15 @ h 1.2, every 4 m",
            "Spark: orb 0.21 @ h 0.85 on rail",
            "Pylon: h 22, reach 10, ±14 m out",
            "Halo: r 5.8 (setting), tube 0.1",
            "Gems every 32 m · arches 64 m",
            "Buildings: rows ±16 m / ±30 m",
        ):
            box.label(text=line)


# ═════════════════════════════════════════════════════════════════════════════

classes = (
    SIAGSettings,
    SIAG_OT_add_straight, SIAG_OT_add_turn, SIAG_OT_add_rail,
    SIAG_OT_add_wj_kit, SIAG_OT_add_wj_ledge, SIAG_OT_add_plate,
    SIAG_OT_add_blocker, SIAG_OT_add_hurdle, SIAG_OT_add_slide,
    SIAG_OT_add_arch, SIAG_OT_add_strip, SIAG_OT_add_marks,
    SIAG_OT_add_lightpost, SIAG_OT_add_beacon,
    SIAG_OT_add_wj_slide, SIAG_OT_add_charge_hoop, SIAG_OT_add_spark,
    SIAG_OT_add_pylon, SIAG_OT_add_fence_post, SIAG_OT_add_halo,
    SIAG_OT_add_gem, SIAG_OT_add_deco_arch, SIAG_OT_add_pad,
    SIAG_OT_add_haze_pillar, SIAG_OT_add_building,
    SIAG_OT_anim_spin, SIAG_OT_anim_bob, SIAG_OT_anim_pulse,
    SIAG_OT_pose_snapshot, SIAG_OT_pose_undo, SIAG_OT_pose_clear,
    SIAG_OT_pose_build, SIAG_OT_anim_tags, SIAG_OT_glb_refresh,
    SIAG_OT_bake_materials, SIAG_OT_export_glb,
    SIAG_OT_faces_to_slot, SIAG_OT_separate,
    SIAG_PT_track, SIAG_PT_pieces, SIAG_PT_deco, SIAG_PT_world,
    SIAG_PT_anim, SIAG_PT_export, SIAG_PT_color, SIAG_PT_info,
)


def register():
    for c in classes:
        bpy.utils.register_class(c)
    bpy.types.Scene.siag = PointerProperty(type=SIAGSettings)


def unregister():
    del bpy.types.Scene.siag
    for c in reversed(classes):
        bpy.utils.unregister_class(c)


if __name__ == "__main__":
    try:
        unregister()
    except Exception:
        pass
    register()
