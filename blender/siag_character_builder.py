## SIAG Character Builder — Blender add-on / script.
##
## Builds the SIAG runner character in a SMOOTH anime style: each colour
## region is sculpted by voxel-remeshing overlapping blobs into one
## continuous organic surface (no balloon-segment joints), skinned with soft
## envelope weights so limbs bend like a body, plus a subtle mesh hair base
## topped with REAL Blender particle hair & fur running hair-dynamics
## physics. Same philosophy as the track builder:
## NO materials are created — every body part is its own object (Head, Jacket,
## Ear.L, EarInner.L, ChestFur, Tail.01, Eye.R, …) with one empty material
## slot, so you click a part in Object Mode, add a material, done.
##
## What you get:
##   - Parametric smooth anthro body (height / head size / bulk / tail
##     sliders), built in T-pose facing −Y (Blender's standard forward).
##   - A complete armature: hips→spine→chest→neck→head, ear bones, 2-bone
##     arms + hands, 2-bone legs + feet, tail chain. Every part is rigidly
##     skinned to its bone — parts overlap at the joints so bending looks
##     clean in this style, and it exports perfectly to Godot.
##   - Generated animations as separate Actions, stashed in NLA tracks so
##     they ALL export into the .glb: Idle, Run, Jump, Slide, Grind.
##     They're honest starting points — scrub them, then fine-tune in the
##     Action editor. If a limb swings the wrong way, flip the sign of the
##     keyed value (axis conventions are noted on the ARMS_DOWN constant).
##   - Metadata stamping + one-click .glb export (with animations) like the
##     track pieces. The bake button from the track add-on works on the
##     character too if you give it fancy node materials.
##
## Install like the track builder: Preferences > Add-ons > Install… → enable.
## Panel: 3D Viewport > N > "SIAG" tab > Character / Character Animations.

bl_info = {
    "name": "SIAG Character Builder",
    "author": "Melody",
    "version": (2, 0),
    "blender": (3, 0, 0),
    "location": "View3D > Sidebar (N) > SIAG",
    "description": "Build, rig and animate the SIAG runner character — organic sculpted body, particle hair/fur with physics",
    "category": "Object",
}

import bpy
import bmesh
import math
from mathutils import Matrix, Vector  # noqa: F401 (Vector used by callers)
from bpy.props import (FloatProperty, IntProperty, BoolProperty,
                       EnumProperty, PointerProperty, StringProperty)
from bpy_extras.io_utils import ExportHelper

## Shoulder X-rotation (degrees) that brings the T-pose arms down to the
## sides in the generated animations. If your arms rotate the wrong way
## after building (bone-roll conventions can flip it), change the sign here
## and re-run "Create Animations".
ARMS_DOWN = -75.0


# ═════════════════════════════════════════════════════════════════════════════
#  Mesh helpers — smooth blobs (spheres / cones) instead of boxes
# ═════════════════════════════════════════════════════════════════════════════

def _link(obj):
    bpy.context.collection.objects.link(obj)
    return obj


def _stamp(obj, ptype, **params):
    obj["siag_type"] = ptype
    for k, v in params.items():
        obj["siag_" + k] = v
    return obj


# ── Reference palette — simple glTF-safe materials, shared by name ───────────
# (Base colour + roughness + metallic only, so they export to Godot 1:1.
#  Tweak any of them in Blender afterwards — they're ordinary materials.)
_PALETTE = {
    "FurBlack":   ((0.055, 0.055, 0.065), 0.85, 0.0),
    "FurWhite":   ((0.93, 0.91, 0.88), 0.85, 0.0),
    "FurGrey":    ((0.74, 0.74, 0.77), 0.85, 0.0),
    "InnerEar":   ((0.75, 0.32, 0.33), 0.80, 0.0),
    "HairBlonde": ((0.91, 0.82, 0.55), 0.75, 0.0),
    "JacketRed":  ((0.75, 0.06, 0.06), 0.35, 0.0),
    "ShirtRed":   ((0.62, 0.10, 0.11), 0.80, 0.0),
    "PantsBlack": ((0.085, 0.085, 0.095), 0.90, 0.0),
    "BeltBlack":  ((0.05, 0.05, 0.055), 0.45, 0.0),
    "Silver":     ((0.80, 0.80, 0.85), 0.25, 1.0),
    "EyeWhite":   ((0.95, 0.96, 0.98), 0.40, 0.0),
    "IrisBlue":   ((0.12, 0.45, 0.95), 0.30, 0.0),
    "IrisPurple": ((0.55, 0.22, 0.88), 0.30, 0.0),
    "NoseBlack":  ((0.02, 0.02, 0.025), 0.40, 0.0),
    "Ivory":      ((0.92, 0.92, 0.86), 0.50, 0.0),
    "ClawGrey":   ((0.22, 0.22, 0.24), 0.50, 0.0),
}

# Which material each part gets (exact name first, then prefix before the dot)
_PART_MAT = {
    "Body": "FurBlack", "WhiteFur": "FurWhite", "Shirt": "ShirtRed",
    "Pants": "PantsBlack",
    "Head": "FurBlack", "Ear": "FurBlack", "EarInner": "InnerEar",
    "EarRings": "Silver",
    "Muzzle": "FurWhite", "Cheek": "FurWhite", "Nose": "NoseBlack",
    "Eye": "EyeWhite", "Iris.L": "IrisBlue", "Iris.R": "IrisPurple",
    "Fangs": "Ivory", "Piercings": "Silver",
    "Hair": "HairBlonde", "Fringe": "HairBlonde",
    "Ruff": "FurWhite", "ChestFur": "FurWhite", "Belly": "FurWhite",
    "Torso": "ShirtRed", "Jacket": "JacketRed", "Collar": "JacketRed",
    "Zipper": "Silver", "Studs": "Silver",
    "Shoulder": "JacketRed", "UpperArm": "JacketRed", "Forearm": "JacketRed",
    "Cuff": "JacketRed", "Hand": "FurBlack", "Claws": "ClawGrey",
    "Pelvis": "PantsBlack", "Belt": "BeltBlack", "Buckle": "Silver",
    "Thigh": "PantsBlack", "Shin": "PantsBlack", "Foot": "FurBlack",
    "Tail": "FurBlack", "TailTip": "FurGrey",
}


def _mat(key):
    rgb, rough, metal = _PALETTE[key]
    m = bpy.data.materials.get("SIAG." + key)
    if m is not None:
        return m
    m = bpy.data.materials.new("SIAG." + key)
    m.use_nodes = True
    b = m.node_tree.nodes.get("Principled BSDF")
    if b is not None:
        b.inputs["Base Color"].default_value = (rgb[0], rgb[1], rgb[2], 1.0)
        b.inputs["Roughness"].default_value = rough
        b.inputs["Metallic"].default_value = metal
    m.diffuse_color = (rgb[0], rgb[1], rgb[2], 1.0)   # viewport solid colour
    m.roughness = rough
    m.metallic = metal
    return m


def _mat_for(part_name):
    key = _PART_MAT.get(part_name)
    if key is None:
        key = _PART_MAT.get(part_name.split(".")[0], "FurBlack")
    return _mat(key)


def _xform(scale_xyz, center, rot_deg=(0, 0, 0)):
    m = Matrix.Translation(center)
    rx, ry, rz = (math.radians(a) for a in rot_deg)
    m = m @ Matrix.Rotation(rz, 4, 'Z') @ Matrix.Rotation(ry, 4, 'Y') \
          @ Matrix.Rotation(rx, 4, 'X')
    return m @ Matrix.Diagonal((scale_xyz[0], scale_xyz[1], scale_xyz[2], 1.0))


class _Blob:
    """Accumulates smooth primitives (ellipsoids, cones) into one mesh."""

    def __init__(self):
        self.bm = bmesh.new()
        self.bm.loops.layers.uv.new("UVMap")

    def sphere(self, radii, center, rot=(0, 0, 0), seg=24, rings=16):
        bmesh.ops.create_uvsphere(
            self.bm, u_segments=seg, v_segments=rings, radius=1.0,
            matrix=_xform(radii, center, rot), calc_uvs=True)
        return self

    def cone(self, r_base, r_tip, depth, center, rot=(0, 0, 0), seg=16):
        bmesh.ops.create_cone(
            self.bm, cap_ends=True, cap_tris=True, segments=seg,
            radius1=r_base, radius2=max(r_tip, 0.001), depth=depth,
            matrix=_xform((1, 1, 1), center, rot), calc_uvs=True)
        return self

    def to_obj(self, name):
        mesh = bpy.data.meshes.new(name)
        self.bm.to_mesh(mesh)
        self.bm.free()
        for p in mesh.polygons:
            p.use_smooth = True
        mesh.materials.append(None)   # one empty slot — drop your material in
        return _link(bpy.data.objects.new(name, mesh))


def _set(obj, attr, val):
    """setattr that survives renamed RNA props across Blender versions."""
    try:
        setattr(obj, attr, val)
    except Exception:
        pass


def _apply_mod(obj, mod):
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=mod.name)


def _organic(obj, voxel, smooth_iters=6, target_faces=None):
    """Voxel-remesh the overlapping blobs of one object into a SINGLE smooth
    organic surface (this is what kills the balloon/blocky look), relax it,
    then decimate back to a game-friendly polycount."""
    for o in bpy.context.selected_objects:
        o.select_set(False)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    obj.data.remesh_voxel_size = voxel
    _set(obj.data, "remesh_voxel_adaptivity", 0.0)
    try:
        bpy.ops.object.voxel_remesh()
    except RuntimeError:
        pass                      # degenerate blob — keep it un-remeshed
    m = obj.modifiers.new("OrganicSmooth", 'SMOOTH')
    m.factor, m.iterations = 1.0, smooth_iters
    _apply_mod(obj, m)
    if target_faces and len(obj.data.polygons) > target_faces:
        d = obj.modifiers.new("OrganicDecimate", 'DECIMATE')
        d.ratio = target_faces / len(obj.data.polygons)
        _apply_mod(obj, d)
    for p in obj.data.polygons:
        p.use_smooth = True
    obj.select_set(False)
    return obj


def _envelope_skin(obj, caps, max_inf=3):
    """Soft capsule-envelope weights: every vertex blends between its nearest
    bones, so elbows/knees/spine bend smoothly like an actual body instead of
    the parts separating."""
    vgs = {c[0]: obj.vertex_groups.new(name=c[0]) for c in caps}
    for v in obj.data.vertices:
        p = v.co
        best, dmin, nmin = [], 1e9, caps[0][0]
        for name, a, b, r, blend in caps:
            ab = b - a
            t = max(0.0, min(1.0, (p - a).dot(ab) / max(ab.length_squared, 1e-9)))
            d = (p - (a + ab * t)).length
            if d < dmin:
                dmin, nmin = d, name
            x = (d - r) / blend
            if x < 1.0:
                best.append((1.0 if x <= 0.0 else (1.0 - x) ** 2, name))
        if not best:
            best = [(1.0, nmin)]
        best.sort(reverse=True)
        tot = sum(w for w, _ in best[:max_inf])
        for w, name in best[:max_inf]:
            vgs[name].add((v.index,), w / tot, 'REPLACE')


def _hair_psys(obj, name, count, length, children=20, clump=0.4, rough=0.05,
               radius=0.004, steps=2, dynamics=False, stiffness=0.5,
               density_vg=None):
    """Real Blender hair: a particle-hair system growing from the object's
    surface. With dynamics on it gets actual hair physics — press ▶ and the
    strands settle/flow/bounce with the animations. NOTE: strands are
    viewport/render only; glTF export keeps the mesh hair (Godot can't
    import particle hair)."""
    mod = obj.modifiers.new(name, 'PARTICLE_SYSTEM')
    ps = mod.particle_system
    st = ps.settings
    st.type = 'HAIR'
    st.count = count
    st.hair_length = length
    _set(st, "hair_step", 5)
    st.use_advanced_hair = True
    st.child_type = 'INTERPOLATED'
    _set(st, "child_nbr", children)
    _set(st, "rendered_child_count", children * 2)
    st.clump_factor = clump
    _set(st, "roughness_2", rough)
    _set(st, "roughness_2_size", 1.5)
    _set(st, "root_radius", 1.0)
    _set(st, "tip_radius", 0.0)
    _set(st, "radius_scale", radius)
    _set(st, "display_step", steps)
    _set(st, "use_hair_bspline", True)
    if density_vg:
        ps.vertex_group_density = density_vg
    if dynamics:
        ps.use_hair_dynamics = True
        try:
            cs = ps.cloth.settings
            _set(cs, "mass", 0.02)
            _set(cs, "bending_stiffness", stiffness)
            _set(cs, "pin_stiffness", 1.0)
            _set(cs, "quality", 4)
        except Exception:
            pass
    return ps


# ═════════════════════════════════════════════════════════════════════════════
#  Character build — smooth anime/chibi proportions
# ═════════════════════════════════════════════════════════════════════════════

def build_character(height, head_size, tail_segs, bulk, precolored=True,
                    detail=1.0, particles=True, hair_phys=True,
                    fur_phys=True):
    """Returns the armature object; all parts are skinned children of it.
    Smooth anthro in T-pose, facing −Y, feet on Z=0. Body regions are
    voxel-remeshed into continuous organic surfaces and envelope-skinned;
    particle hair/fur systems (with hair dynamics) sit on top. With
    precolored=True every part gets a simple reference-palette material
    (still fully editable); otherwise slots stay empty like the tracks."""
    k = height / 1.6          # global scale (layout authored at 1.6 m)
    s = head_size             # head-parts scale
    w = bulk                  # body width/thickness scale

    # ── Armature (identical layout to the game rig) ─────────────────────────
    arm_data = bpy.data.armatures.new("SIAGCharRig")
    arm = _link(bpy.data.objects.new("SIAGCharacter", arm_data))
    bpy.context.view_layer.objects.active = arm
    for o in bpy.context.selected_objects:
        o.select_set(False)
    arm.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT')

    def bone(name, head, tail, parent=None):
        eb = arm_data.edit_bones.new(name)
        eb.head = tuple(v * k for v in head)
        eb.tail = tuple(v * k for v in tail)
        if parent is not None:
            eb.parent = arm_data.edit_bones[parent]
        return eb

    shoulder_x = (0.36 * w) / 2 + 0.055
    head_c = 1.40             # head sphere centre height
    head_rz = 0.20 * s        # head sphere vertical radius
    head_top = head_c + head_rz

    bone("root", (0, 0, 0), (0, 0.25, 0))
    bone("hips", (0, 0, 0.72), (0, 0, 0.84), "root")
    bone("spine", (0, 0, 0.84), (0, 0, 1.00), "hips")
    bone("chest", (0, 0, 1.00), (0, 0, 1.16), "spine")
    bone("neck", (0, 0, 1.16), (0, 0, 1.21), "chest")
    bone("head", (0, 0, 1.21), (0, 0, head_top), "neck")
    for sgn, sd in ((1, "L"), (-1, "R")):
        bone("ear." + sd, (sgn * 0.135 * s, 0, head_top - 0.02),
             (sgn * 0.19 * s, 0, head_top + 0.33 * s), "head")
        bone("upper_arm." + sd, (sgn * shoulder_x, 0, 1.08),
             (sgn * (shoulder_x + 0.26), 0, 1.08), "chest")
        bone("forearm." + sd, (sgn * (shoulder_x + 0.26), 0, 1.08),
             (sgn * (shoulder_x + 0.50), 0, 1.08), "upper_arm." + sd)
        bone("hand." + sd, (sgn * (shoulder_x + 0.50), 0, 1.08),
             (sgn * (shoulder_x + 0.62), 0, 1.08), "forearm." + sd)
        bone("thigh." + sd, (sgn * 0.10, 0, 0.72), (sgn * 0.10, 0, 0.40), "hips")
        bone("shin." + sd, (sgn * 0.10, 0, 0.40), (sgn * 0.10, 0, 0.10), "thigh." + sd)
        bone("foot." + sd, (sgn * 0.10, 0, 0.10), (sgn * 0.10, -0.20, 0.05), "shin." + sd)

    # Tail chain — pronounced S-curve up and back (like the reference art)
    tail_pts = [(0, 0.10, 0.80)]
    ang = 8.0
    for i in range(tail_segs):
        a = math.radians(ang + i * 24.0)
        px, py, pz = tail_pts[-1]
        tail_pts.append((0, py + 0.23 * math.cos(a), pz + 0.23 * math.sin(a)))
    for i in range(tail_segs):
        bone("tail.%02d" % (i + 1), tail_pts[i], tail_pts[i + 1],
             "hips" if i == 0 else "tail.%02d" % i)

    bpy.ops.object.mode_set(mode='OBJECT')

    # ── Organic body — blobs grouped per colour region, each group gets
    # voxel-remeshed into ONE continuous smooth surface (no balloon joints)
    pieces = []        # (object, bone_name)  bone_name=None → envelope skin
    groups = {n: _Blob() for n in
              ("Body", "WhiteFur", "Shirt", "Jacket", "Pants", "Hair",
               "TailTip")}

    def gs(g, radii, center, rot=(0, 0, 0), seg=18, rings=12):
        groups[g].sphere(tuple(r * k for r in radii),
                         tuple(c * k for c in center), rot, seg, rings)

    def gc(g, r_base, depth, center, rot=(0, 0, 0), seg=12):
        groups[g].cone(r_base * k, 0.003, depth * k,
                       tuple(c * k for c in center), rot, seg)

    def sph(name, bname, radii, center, rot=(0, 0, 0), seg=20):
        o = _Blob().sphere(tuple(r * k for r in radii),
                           tuple(c * k for c in center), rot, seg).to_obj(name)
        pieces.append((o, bname))
        return o

    sx = shoulder_x

    # Body (black fur): head + neck + ears + hands + feet + tail — one piece
    gs("Body", (0.225 * s, 0.21 * s, 0.20 * s), (0, 0, head_c))
    gs("Body", (0.085 * s, 0.085 * s, 0.11), (0, 0.005, 1.21))            # neck
    for sgn in (1, -1):
        gc("Body", 0.095 * s, 0.36 * s,                                   # ear
           (sgn * 0.155 * s, 0.005 * s, head_top + 0.115 * s), (-6, sgn * 15, 0))
        gc("Body", 0.045 * s, 0.12 * s,                                   # ear tuft
           (sgn * 0.215 * s, 0.01 * s, head_top + 0.02 * s), (0, sgn * 115, 0), 8)
        gs("Body", (0.040, 0.042 * w, 0.045), (sgn * (sx + 0.495), 0, 1.078))
        gs("Body", (0.062, 0.056 * w, 0.066), (sgn * (sx + 0.555), 0, 1.072))
        gs("Body", (0.075 * w, 0.14 * w, 0.064), (sgn * 0.10, -0.06, 0.058))
        gs("Body", (0.068 * w, 0.075 * w, 0.075), (sgn * 0.10, 0.015, 0.10))

    # Tail — swelling chain of puffs; last segment is the grey TailTip piece
    widths = [0.13, 0.19, 0.18, 0.15, 0.11]
    for i in range(tail_segs):
        ty, tz = tail_pts[i + 1][1], tail_pts[i + 1][2]
        hy, hz = tail_pts[i][1], tail_pts[i][2]
        cy, cz = (hy + ty) / 2, (hz + tz) / 2
        seg_len = math.hypot(ty - hy, tz - hz)
        pitch = math.degrees(math.atan2(tz - hz, ty - hy)) - 90.0
        ww = widths[min(i, len(widths) - 1)] * s
        g = "TailTip" if i == tail_segs - 1 else "Body"
        gs(g, (ww, ww, seg_len * 0.85), (0, cy, cz), (pitch, 0, 0), 18, 12)
        if i == tail_segs - 1:
            gc(g, ww * 0.55, seg_len * 0.7, (0, ty, tz), (pitch, 0, 0), 12)

    # White fur: muzzle + cheek fluff + chest/belly fur + the big neck ruff
    gs("WhiteFur", (0.088 * s, 0.082 * s, 0.064 * s), (0, -0.185 * s, 1.345))
    for sgn in (1, -1):
        gs("WhiteFur", (0.055 * s, 0.095 * s, 0.072 * s),
           (sgn * 0.165 * s, -0.10 * s, 1.345), (0, 0, sgn * 18), 14, 10)
        gc("WhiteFur", 0.035 * s, 0.10 * s,
           (sgn * 0.215 * s, -0.06 * s, 1.33), (0, sgn * 95, 0), 8)
    gs("WhiteFur", (0.10 * w, 0.062 * w, 0.13), (0, -0.085 * w, 1.05))
    gs("WhiteFur", (0.095 * w, 0.058 * w, 0.095), (0, -0.072 * w, 0.885))
    for i in range(10):                                                   # ruff
        a = i / 10.0 * math.tau
        rx, ry = 0.165 * w, 0.125 * w
        gs("WhiteFur", (0.095, 0.095, 0.066),
           (math.cos(a) * rx, math.sin(a) * ry, 1.175),
           (0, 0, math.degrees(a)), 14, 10)
        if i % 2 == 0:
            gc("WhiteFur", 0.045, 0.13,
               (math.cos(a) * (rx + 0.06), math.sin(a) * (ry + 0.05), 1.185),
               (0, 90, math.degrees(a)), 8)
    gs("WhiteFur", (0.075, 0.06, 0.075), (0, -0.125 * w, 1.10), seg=14, rings=10)

    # Shirt core + waist (continuous body under the jacket)
    gs("Shirt", (0.165 * w, 0.11 * w, 0.165), (0, 0, 0.985))
    gs("Shirt", (0.15 * w, 0.10 * w, 0.105), (0, 0, 0.895))

    # Cropped biker jacket: shell + lapels + shoulders + tapered sleeves
    gs("Jacket", (0.20 * w, 0.132 * w, 0.135), (0, 0, 1.055))
    for sgn in (1, -1):
        gs("Jacket", (0.055 * w, 0.02 * w, 0.085),                       # lapel
           (sgn * 0.085 * w, -0.125 * w, 1.115), (0, sgn * -28, sgn * 18), 14, 10)
        gs("Jacket", (0.072, 0.068 * w, 0.072), (sgn * (sx + 0.02), 0, 1.08))
        gs("Jacket", (0.14, 0.058 * w, 0.058 * w), (sgn * (sx + 0.125), 0, 1.08))
        gs("Jacket", (0.05, 0.05 * w, 0.05 * w), (sgn * (sx + 0.26), 0, 1.08))
        gs("Jacket", (0.13, 0.048 * w, 0.048 * w), (sgn * (sx + 0.375), 0, 1.08))
        gs("Jacket", (0.035, 0.06 * w, 0.06 * w), (sgn * (sx + 0.475), 0, 1.08))

    # Pants: pelvis + legs fused into smooth continuous limbs
    gs("Pants", (0.165 * w, 0.125 * w, 0.125), (0, 0, 0.775))
    for sgn in (1, -1):
        gs("Pants", (0.077 * w, 0.088 * w, 0.195), (sgn * 0.10, 0, 0.555))
        gs("Pants", (0.060 * w, 0.070 * w, 0.062), (sgn * 0.10, 0, 0.40))
        gs("Pants", (0.064 * w, 0.074 * w, 0.175), (sgn * 0.10, 0, 0.245))

    # ── Hair — SUBTLE mesh base hugging the skull (remeshed into one flowing
    # piece so the .glb still has hair) — particle strands go on top of it ──
    def hpos(x, y, z):
        return (x * s, y * s, 1.40 + (z - 1.40) * s)

    gs("Hair", (0.23 * s, 0.215 * s, 0.155 * s), hpos(0, 0.015, 1.50))
    for hx, ln, rz in ((-0.135, 0.16, -12), (-0.05, 0.17, -4),
                       (0.03, 0.15, 4), (0.10, 0.14, 14)):                # bangs
        gc("Hair", 0.05 * s, ln * s, hpos(hx, -0.19, 1.455), (155, 0, rz), 10)
    gs("Hair", (0.095 * s, 0.04 * s, 0.05 * s), hpos(0, -0.185, 1.515))
    for sgn in (1, -1):                                                   # sides
        gs("Hair", (0.042 * s, 0.05 * s, 0.14 * s),
           hpos(sgn * 0.20, -0.055, 1.40), (-6, 0, sgn * -10), 14, 10)
    for hx, rz in ((-0.09, 10), (0.0, 0), (0.09, -10)):                   # back
        gc("Hair", 0.055 * s, 0.15 * s, hpos(hx, 0.185, 1.43), (-155, 0, rz), 10)
    gc("Hair", 0.035 * s, 0.09 * s, hpos(0.05, 0.03, 1.65), (10, 8, 0), 8)

    # ── Small rigid detail parts (one bone each, click-to-colour) ───────────
    sph("Belt", "hips", (0.182 * w, 0.137 * w, 0.036), (0, 0, 0.85))
    sph("Buckle", "hips", (0.038 * w, 0.022 * w, 0.030), (0, -0.135 * w, 0.85))
    zipper = _Blob()
    zipper.sphere((0.011 * k, 0.012 * k, 0.115 * k),
                  (0.035 * w * k, -0.131 * w * k, 1.03 * k), seg=10, rings=8)
    pieces.append((zipper.to_obj("Zipper"), "chest"))
    studs = _Blob()
    for px, pz in ((0.16, 1.155), (-0.16, 1.155), (0.185, 1.10), (-0.185, 1.10)):
        studs.sphere((0.014 * k,) * 3, (px * w * k, -0.07 * w * k, pz * k),
                     seg=10, rings=8)
    pieces.append((studs.to_obj("Studs"), "chest"))
    sph("Nose", "head", (0.024 * s, 0.018 * s, 0.016 * s), (0, -0.262 * s, 1.362))
    sph("Eye.L", "head", (0.050 * s, 0.016 * s, 0.072 * s), (0.088 * s, -0.186 * s, 1.432), rot=(0, 0, -7))
    sph("Eye.R", "head", (0.050 * s, 0.016 * s, 0.072 * s), (-0.088 * s, -0.186 * s, 1.432), rot=(0, 0, 7))
    sph("Iris.L", "head", (0.030 * s, 0.012 * s, 0.046 * s), (0.086 * s, -0.198 * s, 1.428), rot=(0, 0, -7))
    sph("Iris.R", "head", (0.030 * s, 0.012 * s, 0.046 * s), (-0.086 * s, -0.198 * s, 1.428), rot=(0, 0, 7))
    fangs = _Blob()
    for sgn in (1, -1):
        fangs.cone(0.011 * s * k, 0.002, 0.034 * s * k,
                   (sgn * 0.038 * s * k, -0.224 * s * k, 1.320 * k),
                   rot=(182, 0, 0), seg=8)
    pieces.append((fangs.to_obj("Fangs"), "head"))
    pierc = _Blob()
    for sgn in (1, -1):
        pierc.sphere((0.009 * s * k,) * 3,
                     (sgn * 0.022 * s * k, -0.245 * s * k, 1.301 * k),
                     seg=8, rings=6)
    pieces.append((pierc.to_obj("Piercings"), "head"))
    rings = _Blob()
    for dz in (0.0, 0.045):
        rings.sphere((0.016 * s * k, 0.016 * s * k, 0.007 * s * k),
                     (-0.205 * s * k, 0.0, (head_top + 0.06 * s + dz * s) * k),
                     rot=(0, 78, 0), seg=10, rings=8)
    pieces.append((rings.to_obj("EarRings"), "ear.R"))
    for sgn, sd in ((1, "L"), (-1, "R")):
        inner = _Blob()
        inner.cone(0.062 * s * k, 0.004, 0.26 * s * k,
                   (sgn * 0.150 * s * k, -0.022 * s * k, (head_top + 0.10 * s) * k),
                   rot=(-8, sgn * 15, 0), seg=10)
        pieces.append((inner.to_obj("EarInner." + sd), "ear." + sd))
        claws = _Blob()
        for cy in (-0.045, 0.0, 0.045):
            claws.cone(0.010 * k, 0.002, 0.045 * k,
                       (sgn * (sx + 0.615) * k, cy * w * k, 1.062 * k),
                       rot=(0, sgn * 96, 0), seg=8)
        pieces.append((claws.to_obj("Claws." + sd), "hand." + sd))

    # ── Remesh each group into one smooth organic surface ──────────────────
    RES = {"Body": (0.014, 6, 30000), "WhiteFur": (0.012, 4, 16000),
           "Shirt": (0.016, 8, 8000), "Jacket": (0.013, 8, 14000),
           "Pants": (0.014, 8, 12000), "Hair": (0.011, 6, 9000),
           "TailTip": (0.013, 5, 8000)}
    RIGID = {"Hair": "head", "TailTip": "tail.%02d" % tail_segs}
    gobjs = {}
    for gname, blob in groups.items():
        o = blob.to_obj(gname)
        vox, sm, faces = RES[gname]
        _organic(o, vox * k / max(detail, 0.1), sm, faces)
        gobjs[gname] = o
        pieces.append((o, RIGID.get(gname)))

    # Soft envelope weights from bone capsules → person-like smooth bending
    RADII = {"hips": 0.16, "spine": 0.15, "chest": 0.18, "neck": 0.10,
             "head": 0.21 * s, "ear": 0.07 * s, "upper_arm": 0.06,
             "forearm": 0.055, "hand": 0.075, "thigh": 0.09,
             "shin": 0.075, "foot": 0.085, "tail": 0.15 * s}
    caps = []
    for b in arm_data.bones:
        r = RADII.get(b.name.split(".")[0])
        if r is not None:
            caps.append((b.name, b.head_local.copy(), b.tail_local.copy(),
                         r * k, 0.085 * k))
    for gname in ("Body", "WhiteFur", "Shirt", "Jacket", "Pants"):
        _envelope_skin(gobjs[gname], caps)

    # ── Parent, deform, colour ──────────────────────────────────────────────
    for obj, bname in pieces:
        if bname is not None:
            vg = obj.vertex_groups.new(name=bname)
            vg.add(list(range(len(obj.data.vertices))), 1.0, 'REPLACE')
        mod = obj.modifiers.new("Armature", 'ARMATURE')
        mod.object = arm
        obj.parent = arm
        if precolored:
            obj.data.materials[0] = _mat_for(obj.name)

    # ── Real Blender hair & fur: particle strands with hair dynamics ───────
    if particles:
        _hair_psys(gobjs["Hair"], "HairStrands", 220, 0.13 * s * k,
                   children=15, clump=0.55, rough=0.035, radius=0.0045 * k,
                   steps=4, dynamics=hair_phys, stiffness=0.08)
        tvg = gobjs["Body"].vertex_groups.new(name="TailFluff")
        tvg.add([v.index for v in gobjs["Body"].data.vertices
                 if v.co.y > 0.16 * k and v.co.z > 0.68 * k], 1.0, 'REPLACE')
        _hair_psys(gobjs["Body"], "Fur", 450, 0.035 * k,
                   children=25, clump=0.25, rough=0.05, radius=0.003 * k,
                   steps=2, dynamics=fur_phys, stiffness=0.6)
        _hair_psys(gobjs["Body"], "TailFur", 220, 0.10 * s * k,
                   children=30, clump=0.4, rough=0.06, radius=0.004 * k,
                   steps=3, dynamics=fur_phys, stiffness=0.3,
                   density_vg="TailFluff")
        _hair_psys(gobjs["WhiteFur"], "RuffFur", 300, 0.055 * k,
                   children=25, clump=0.3, rough=0.06, radius=0.0035 * k,
                   steps=2, dynamics=fur_phys, stiffness=0.5)
        _hair_psys(gobjs["TailTip"], "TipFur", 120, 0.10 * s * k,
                   children=30, clump=0.4, rough=0.06, radius=0.004 * k,
                   steps=3, dynamics=fur_phys, stiffness=0.3)
        if hair_phys or fur_phys:
            # strands collide with the body instead of falling through it
            gobjs["Body"].modifiers.new("Collision", 'COLLISION')
            gobjs["Jacket"].modifiers.new("Collision", 'COLLISION')

    _stamp(arm, "character", height=height, head_size=head_size,
           tail_segs=tail_segs, bulk=bulk)
    return arm


# ═════════════════════════════════════════════════════════════════════════════
#  Animations
# ═════════════════════════════════════════════════════════════════════════════
# Every action keys rotation_euler (XYZ, degrees here) and optionally location
# on pose bones. Parts follow their bones rigidly, so this IS the final
# animation pipeline — tune curves in the Graph/Action editor.

def _reset_pose(arm):
    for pb in arm.pose.bones:
        pb.rotation_mode = 'XYZ'
        pb.rotation_euler = (0.0, 0.0, 0.0)
        pb.location = (0.0, 0.0, 0.0)


def _build_action(arm, name, bone_keys):
    old = bpy.data.actions.get(name)
    if old is not None:
        bpy.data.actions.remove(old)
    if arm.animation_data is None:
        arm.animation_data_create()
    _reset_pose(arm)
    act = bpy.data.actions.new(name)
    arm.animation_data.action = act
    for bname, chans in bone_keys.items():
        pb = arm.pose.bones.get(bname)
        if pb is None:
            continue
        for f in sorted(chans.get("rot", {})):
            rot = chans["rot"][f]
            pb.rotation_euler = tuple(math.radians(a) for a in rot)
            pb.keyframe_insert("rotation_euler", frame=f)
        for f in sorted(chans.get("loc", {})):
            pb.location = chans["loc"][f]
            pb.keyframe_insert("location", frame=f)
    act.use_fake_user = True
    for tr in list(arm.animation_data.nla_tracks):
        if tr.name == name:
            arm.animation_data.nla_tracks.remove(tr)
    track = arm.animation_data.nla_tracks.new()
    track.name = name
    track.strips.new(name, 1, act)
    track.mute = True
    arm.animation_data.action = None
    _reset_pose(arm)
    return act


def _mirror_cycle(keys, period=24, shift=None):
    """Mirrors a {frame: (x,y,z)} dict describing one side's cycle into
    the cycle for the opposite side: the same shape, played half a
    period later (e.g. the right leg repeats the left leg's motion a
    half-stride after it). `keys` should be a closed loop — frame 1 and
    frame `period + 1` carry the same value; the mirrored result is
    closed the same way."""
    if shift is None:
        shift = period // 2
    out = {}
    for f, v in keys.items():
        out[((f - 1 + shift) % period) + 1] = v
    if 1 in out:
        out[period + 1] = out[1]
    return out


def create_animations(arm, tail_segs):
    AD = ARMS_DOWN

    # ── Run — 24-frame loop ──────────────────────────────────────────────────
    # Left-side leg & arm cycles on a shared 1/7/13/19/25 frame grid for a
    # snappier contact → push-off → recovery → reach shape. The right side
    # is the same motion half a stride later via _mirror_cycle.
    thigh_l = {1: (-40, 0, 0), 7: (-4, 0, 0), 13: (42, 0, 0), 19: (58, 0, 0), 25: (-40, 0, 0)}
    shin_l  = {1: (18, 0, 0), 7: (74, 0, 0), 13: (8, 0, 0), 19: (34, 0, 0), 25: (18, 0, 0)}
    foot_l  = {1: (-12, 0, 0), 7: (24, 0, 0), 13: (16, 0, 0), 19: (-20, 0, 0), 25: (-12, 0, 0)}
    # Swing lives on the Z axis (sagittal: forward/back, beside the body);
    # X stays fixed at the "arms down" pose so the arms don't sweep
    # sideways into the torso.
    uarm_l  = {1: (AD, 0, 34), 7: (AD, 0, 8), 13: (AD, 0, -34), 19: (AD, 0, -10), 25: (AD, 0, 34)}
    farm_l  = {1: (-25, 0, -22), 7: (-25, 0, -48), 13: (-25, 0, -52), 19: (-25, 0, -28), 25: (-25, 0, -22)}
    hand_l  = {1: (0, 0, -6), 7: (0, 0, 10), 13: (0, 0, 14), 19: (0, 0, -4), 25: (0, 0, -6)}

    run = {
        "thigh.L": {"rot": thigh_l}, "thigh.R": {"rot": _mirror_cycle(thigh_l)},
        "shin.L":  {"rot": shin_l},  "shin.R":  {"rot": _mirror_cycle(shin_l)},
        "foot.L":  {"rot": foot_l},  "foot.R":  {"rot": _mirror_cycle(foot_l)},
        "upper_arm.L": {"rot": uarm_l}, "upper_arm.R": {"rot": _mirror_cycle(uarm_l)},
        "forearm.L": {"rot": farm_l},   "forearm.R": {"rot": _mirror_cycle(farm_l)},
        "hand.L": {"rot": hand_l},      "hand.R": {"rot": _mirror_cycle(hand_l)},
        # Torso counter-rotation: hips/chest twist opposite the spine for
        # that running-torque look; head stays roughly level against it.
        "hips":  {"loc": {1: (0, 0, 0), 4: (0, 0.04, 0), 7: (0, 0, 0),
                          10: (0, 0.05, 0), 13: (0, 0, 0), 16: (0, 0.04, 0),
                          19: (0, 0, 0), 22: (0, 0.05, 0), 25: (0, 0, 0)},
                  "rot": {1: (0, 0, 4), 13: (0, 0, -4), 25: (0, 0, 4)}},
        "spine": {"rot": {1: (8, 0, -3), 7: (12, 0, 3), 13: (8, 0, 3), 19: (12, 0, -3), 25: (8, 0, -3)}},
        "chest": {"rot": {1: (0, 0, -4), 13: (0, 0, 4), 25: (0, 0, -4)}},
        "head":  {"rot": {1: (-7, 0, 2), 13: (-7, 0, -2), 25: (-7, 0, 2)}},
        # Ears flop on each footfall, alternating left/right with the stride.
        "ear.L": {"rot": {1: (0, 0, 0), 4: (18, 0, 0), 7: (0, 0, 0), 13: (0, 0, 0), 25: (0, 0, 0)}},
        "ear.R": {"rot": {1: (0, 0, 0), 13: (0, 0, 0), 16: (18, 0, 0), 19: (0, 0, 0), 25: (0, 0, 0)}},
    }
    # Tail whip — side-to-side sway plus a vertical lift, amplitude growing
    # toward the tip for a follow-through look.
    for i in range(min(tail_segs, 5)):
        amp = 10.0 + i * 6.0
        lift = 4.0 + i * 3.0
        run["tail.%02d" % (i + 1)] = {"rot": {
            1: (lift, 0, amp), 7: (-lift * 0.6, 0, amp * 0.5),
            13: (-lift, 0, -amp), 19: (lift * 0.6, 0, -amp * 0.5),
            25: (lift, 0, amp),
        }}
    _build_action(arm, "Run", run)

    # ── Idle — 48-frame loop ─────────────────────────────────────────────────
    idle = {
        "hips":  {"loc": {1: (0, 0, 0), 24: (0, 0.012, 0), 48: (0, 0, 0)},
                  # slow side-to-side weight shift, a quarter-cycle ahead of breathing
                  "rot": {1: (0, 0, 0), 12: (0, 0, 2.5), 24: (0, 0, 0), 36: (0, 0, -2.5), 48: (0, 0, 0)}},
        "chest": {"rot": {1: (0, 0, 0), 24: (3, 0, 1), 48: (0, 0, 0)}},
        "head":  {"rot": {1: (0, 0, 0), 12: (1, 0, -1), 24: (-2, 0, 2), 36: (0, 0, -1), 48: (0, 0, 0)}},
        # Arms drift gently with the breath instead of sitting frozen.
        "upper_arm.L": {"rot": {1: (AD, 0, 0), 24: (AD - 3, 0, 1), 48: (AD, 0, 0)}},
        "upper_arm.R": {"rot": {1: (AD, 0, 0), 24: (AD - 3, 0, -1), 48: (AD, 0, 0)}},
        "forearm.L": {"rot": {1: (-25, 0, 0), 24: (-29, 0, 0), 48: (-25, 0, 0)}},
        "forearm.R": {"rot": {1: (-25, 0, 0), 24: (-29, 0, 0), 48: (-25, 0, 0)}},
        # Each ear gets two small twitches per cycle, offset from each other.
        "ear.L": {"rot": {6: (0, 0, 0), 10: (12, 0, 4), 14: (0, 0, 0),
                          26: (0, 0, 0), 30: (18, 0, 0), 34: (0, 0, 0)}},
        "ear.R": {"rot": {16: (0, 0, 0), 20: (0, 0, -10), 24: (0, 0, 0),
                          36: (0, 0, 0), 40: (0, 0, -16), 44: (0, 0, 0)}},
    }
    # Tail wave — the trough lands a couple frames earlier for each
    # successive segment, so the motion travels out toward the tip.
    for i in range(min(tail_segs, 5)):
        amp = 6.0 + i * 5.0
        lift = 3.0 + i * 2.0
        trough = 24 - i * 2
        idle["tail.%02d" % (i + 1)] = {"rot": {1: (lift, 0, amp), trough: (-lift, 0, -amp), 48: (lift, 0, amp)}}
    _build_action(arm, "Idle", idle)

    # ── Jump — 24 frames (crouch → launch → apex/tuck → land) ────────────────
    jump = {
        "hips":  {"loc": {1: (0, 0, 0), 5: (0, -0.13, 0), 9: (0, 0.07, 0), 24: (0, 0, 0)},
                  "rot": {1: (0, 0, 0), 5: (0, 0, 3), 9: (0, 0, -3), 24: (0, 0, 0)}},
        "thigh.L": {"rot": {1: (-8, 0, 0), 5: (-72, 0, 0), 9: (14, 0, 0), 15: (-50, 0, 0), 24: (-8, 0, 0)}},
        "thigh.R": {"rot": {1: (-8, 0, 0), 5: (-72, 0, 0), 9: (14, 0, 0), 15: (-50, 0, 0), 24: (-8, 0, 0)}},
        "shin.L":  {"rot": {1: (12, 0, 0), 5: (85, 0, 0), 9: (4, 0, 0), 15: (70, 0, 0), 24: (12, 0, 0)}},
        "shin.R":  {"rot": {1: (12, 0, 0), 5: (85, 0, 0), 9: (4, 0, 0), 15: (70, 0, 0), 24: (12, 0, 0)}},
        # Spine now arcs through the whole jump (lean → arch → float → recover)
        # with a touch of twist; head pitches with the motion instead of
        # sitting fixed.
        "spine": {"rot": {1: (6, 0, -2), 5: (24, 0, 4), 9: (-8, 0, -4), 15: (2, 0, 2), 24: (6, 0, -2)}},
        "head":  {"rot": {1: (-7, 0, 0), 5: (8, 0, 0), 9: (-15, 0, 0), 15: (-10, 0, 0), 24: (-7, 0, 0)}},
        # Arms windmill for momentum — left/right differ slightly so the
        # launch reads less like a mirrored pose-flip.
        "upper_arm.L": {"rot": {1: (AD, 0, 0), 5: (AD + 25, 0, 2), 9: (AD - 70, 0, -8), 15: (AD - 55, 0, -4), 24: (AD, 0, 0)}},
        "upper_arm.R": {"rot": {1: (AD, 0, 0), 5: (AD + 22, 0, -2), 9: (AD - 75, 0, 8), 15: (AD - 58, 0, 4), 24: (AD, 0, 0)}},
        "forearm.L": {"rot": {1: (-25, 0, 0), 5: (-15, 0, 0), 9: (-60, 0, 0), 15: (-40, 0, 0), 24: (-25, 0, 0)}},
        "forearm.R": {"rot": {1: (-25, 0, 0), 5: (-12, 0, 0), 9: (-65, 0, 0), 15: (-42, 0, 0), 24: (-25, 0, 0)}},
        "hand.L": {"rot": {1: (0, 0, 0), 9: (-20, 0, 0), 24: (0, 0, 0)}},
        "hand.R": {"rot": {1: (0, 0, 0), 9: (-20, 0, 0), 24: (0, 0, 0)}},
        # Ears whip back on launch and flick forward again as they settle.
        "ear.L": {"rot": {1: (0, 0, 0), 9: (-22, 0, 0), 15: (8, 0, 0), 24: (0, 0, 0)}},
        "ear.R": {"rot": {1: (0, 0, 0), 9: (-26, 0, 0), 15: (10, 0, 0), 24: (0, 0, 0)}},
    }
    # Tail whip on launch, amplitude growing toward the tip, with a side
    # component so it doesn't move purely in one plane.
    for i in range(min(tail_segs, 5)):
        amp  = 18.0 + i * 6.0
        amp2 = 22.0 + i * 8.0
        side = 6.0 + i * 4.0
        jump["tail.%02d" % (i + 1)] = {"rot": {
            1: (0, 0, 0), 5: (-amp, 0, side), 9: (amp2, 0, -side),
            15: (amp2 * 0.4, 0, side * 0.5), 24: (0, 0, 0),
        }}
    _build_action(arm, "Jump", jump)

    # ── Slide — 25-frame loop ─────────────────────────────────────────────────
    # Keeps the original held pose (one leg tucked, one leg forward, leaning
    # back) as the base, but adds a continuous low wobble/bounce as if riding
    # over the ground while sliding instead of freezing on one frame.
    slide = {
        "spine": {"rot": {1: (-48, 0, 0), 7: (-44, 0, 2), 13: (-50, 0, 0), 19: (-44, 0, -2), 25: (-48, 0, 0)}},
        "head":  {"rot": {1: (30, 0, 0), 7: (26, 0, 3), 13: (32, 0, 0), 19: (26, 0, -3), 25: (30, 0, 0)}},
        "thigh.L": {"rot": {1: (-75, 0, 0), 13: (-70, 0, 0), 25: (-75, 0, 0)}},
        "thigh.R": {"rot": {1: (-60, 0, 0), 13: (-65, 0, 0), 25: (-60, 0, 0)}},
        "shin.L":  {"rot": {1: (25, 0, 0), 13: (30, 0, 0), 25: (25, 0, 0)}},
        "shin.R":  {"rot": {1: (45, 0, 0), 13: (40, 0, 0), 25: (45, 0, 0)}},
        # Arms hold the balance pose but rock gently opposite the hips.
        "upper_arm.L": {"rot": {1: (AD + 45, 0, 0), 13: (AD + 50, 0, 5), 25: (AD + 45, 0, 0)}},
        "upper_arm.R": {"rot": {1: (AD + 45, 0, 0), 13: (AD + 50, 0, -5), 25: (AD + 45, 0, 0)}},
        "hips": {"loc": {1: (0, -0.30, 0), 7: (0, -0.30, 0.015), 13: (0, -0.30, 0),
                         19: (0, -0.30, -0.01), 25: (0, -0.30, 0)},
                 "rot": {1: (0, 0, 0), 13: (0, 0, 3), 25: (0, 0, 0)}},
    }
    # Tail rocks side to side for balance, amplitude growing toward the tip.
    for i in range(min(tail_segs, 5)):
        base = 14 + i * 6
        side = 4.0 + i * 2.0
        slide["tail.%02d" % (i + 1)] = {"rot": {
            1: (base, 0, 0), 7: (base - 4, 0, side), 13: (base + 4, 0, 0),
            19: (base - 4, 0, -side), 25: (base, 0, 0),
        }}
    _build_action(arm, "Slide", slide)

    # ── Grind — 25-frame loop ─────────────────────────────────────────────────
    # Keeps the original crouched, asymmetric grinding stance as the base,
    # but layers a continuous balance wobble — weight shifting between legs,
    # torso/arm counter-rocking, and a couple of small bumps — on top of it.
    grind = {
        "thigh.L": {"rot": {1: (-32, 0, 0), 13: (-38, 0, 0), 25: (-32, 0, 0)}},
        "thigh.R": {"rot": {1: (-18, 0, 0), 13: (-12, 0, 0), 25: (-18, 0, 0)}},
        "shin.L":  {"rot": {1: (42, 0, 0), 13: (48, 0, 0), 25: (42, 0, 0)}},
        "shin.R":  {"rot": {1: (26, 0, 0), 13: (20, 0, 0), 25: (26, 0, 0)}},
        "spine": {"rot": {1: (12, 0, 6), 7: (14, 0, 2), 13: (10, 0, -6), 19: (14, 0, -2), 25: (12, 0, 6)}},
        "head":  {"rot": {1: (-8, 0, -6), 7: (-6, 0, -2), 13: (-10, 0, 6), 19: (-6, 0, 2), 25: (-8, 0, -6)}},
        "upper_arm.L": {"rot": {1: (AD * 0.25, 0, 0), 13: (AD * 0.35, 0, 8), 25: (AD * 0.25, 0, 0)}},
        "upper_arm.R": {"rot": {1: (AD * 0.45, 0, 0), 13: (AD * 0.35, 0, -8), 25: (AD * 0.45, 0, 0)}},
        "forearm.L": {"rot": {1: (-20, 0, 0), 13: (-30, 0, 0), 25: (-20, 0, 0)}},
        "forearm.R": {"rot": {1: (-20, 0, 0), 13: (-30, 0, 0), 25: (-20, 0, 0)}},
        "hips": {"loc": {1: (0, 0, 0), 7: (0, 0.02, 0), 13: (0, 0, 0), 19: (0, 0.02, 0), 25: (0, 0, 0)},
                 "rot": {1: (0, 0, 0), 13: (0, 0, 4), 25: (0, 0, 0)}},
    }
    # Tail counter-swings for balance, amplitude growing toward the tip.
    for i in range(min(tail_segs, 5)):
        base = 12 + i * 8
        side = 6.0 + i * 3.0
        lift = 3.0 + i * 2.0
        grind["tail.%02d" % (i + 1)] = {"rot": {
            1: (lift, 0, base), 7: (-lift, 0, base - side), 13: (lift, 0, base + side),
            19: (-lift, 0, base - side), 25: (lift, 0, base),
        }}
    _build_action(arm, "Grind", grind)

    return ["Run", "Idle", "Jump", "Slide", "Grind"]


# ═════════════════════════════════════════════════════════════════════════════
#  Operators
# ═════════════════════════════════════════════════════════════════════════════

class SIAGCharSettings(bpy.types.PropertyGroup):
    height: FloatProperty(name="Height", default=1.6, min=0.8, max=2.4,
                          subtype='DISTANCE', description="Total height, feet to head top region")
    head_size: FloatProperty(name="Head size", default=1.0, min=0.6, max=1.6,
                             description="Chibi factor — head & face parts scale")
    bulk: FloatProperty(name="Bulk", default=1.0, min=0.7, max=1.5,
                        description="Body width/thickness scale")
    tail_segs: IntProperty(name="Tail segments", default=3, min=1, max=5)
    precolored: BoolProperty(name="Pre-coloured", default=True,
        description="Assign simple reference-palette materials (black/white fur, "
                    "blonde hair, red jacket, blue/purple eyes, silver metal). "
                    "Turn off for empty slots like the track pieces")
    detail: FloatProperty(name="Sculpt detail", default=1.0, min=0.5, max=2.0,
        description="Organic remesh resolution — higher is smoother but "
                    "slower to build")
    particles: BoolProperty(name="Hair & fur strands", default=True,
        description="Real Blender particle-hair systems: blonde hair, body "
                    "fur, white ruff fur and tail fluff. Viewport/render "
                    "only — glTF export keeps the mesh hair instead")
    hair_physics: BoolProperty(name="Hair physics", default=True,
        description="Hair dynamics on the blonde hair — press play and it "
                    "settles/flows with the animations")
    fur_physics: BoolProperty(name="Fur physics", default=True,
        description="Hair dynamics on fur/ruff/tail strands. Disable if "
                    "timeline playback gets slow")


class SIAG_OT_build_char(bpy.types.Operator):
    bl_idname = "siag.build_character"
    bl_label = "Build Character"
    bl_description = ("Smooth anime-style rigged runner character: every part "
                      "its own colourable object, skinned to a full armature. "
                      "T-pose, facing −Y, feet on the floor")
    bl_options = {'REGISTER', 'UNDO'}

    height: SIAGCharSettings.__annotations__["height"]
    head_size: SIAGCharSettings.__annotations__["head_size"]
    bulk: SIAGCharSettings.__annotations__["bulk"]
    tail_segs: SIAGCharSettings.__annotations__["tail_segs"]
    precolored: SIAGCharSettings.__annotations__["precolored"]
    detail: SIAGCharSettings.__annotations__["detail"]
    particles: SIAGCharSettings.__annotations__["particles"]
    hair_physics: SIAGCharSettings.__annotations__["hair_physics"]
    fur_physics: SIAGCharSettings.__annotations__["fur_physics"]
    with_anims: BoolProperty(name="Create animations too", default=True)

    @classmethod
    def poll(cls, context):
        return context.mode == 'OBJECT'

    def invoke(self, context, event):
        s = context.scene.siag_char
        self.height, self.head_size = s.height, s.head_size
        self.bulk, self.tail_segs = s.bulk, s.tail_segs
        self.precolored, self.detail = s.precolored, s.detail
        self.particles = s.particles
        self.hair_physics, self.fur_physics = s.hair_physics, s.fur_physics
        return self.execute(context)

    def execute(self, context):
        arm = build_character(self.height, self.head_size, self.tail_segs,
                              self.bulk, self.precolored, self.detail,
                              self.particles, self.hair_physics,
                              self.fur_physics)
        if self.with_anims:
            create_animations(arm, self.tail_segs)
        context.view_layer.objects.active = arm
        self.report({'INFO'}, "Character built — click any part to colour it")
        return {'FINISHED'}


class SIAG_OT_char_anims(bpy.types.Operator):
    bl_idname = "siag.char_animations"
    bl_label = "Create / Reset Animations"
    bl_description = ("(Re)generate the Idle, Run, Jump, Slide and Grind "
                      "actions on the selected SIAG character armature — "
                      "overwrites previous versions of those actions")
    bl_options = {'REGISTER', 'UNDO'}

    @classmethod
    def poll(cls, context):
        o = context.active_object
        return o is not None and o.type == 'ARMATURE'

    def execute(self, context):
        arm = context.active_object
        tail_segs = int(arm.get("siag_tail_segs", 3))
        names = create_animations(arm, tail_segs)
        self.report({'INFO'}, "Actions created: %s" % ", ".join(names))
        return {'FINISHED'}


class SIAG_OT_char_export(bpy.types.Operator, ExportHelper):
    bl_idname = "siag.export_character"
    bl_label = "Export Character → .glb"
    bl_description = ("Export the selected character (armature + all parts + "
                      "ALL animations + SIAG metadata) as .glb for Godot")
    filename_ext = ".glb"
    filter_glob: StringProperty(default="*.glb", options={'HIDDEN'})

    @classmethod
    def poll(cls, context):
        return len(context.selected_objects) > 0

    def execute(self, context):
        for obj in list(context.selected_objects):
            root = obj
            while root.parent is not None:
                root = root.parent
            stack = [root]
            while stack:
                o = stack.pop()
                o.select_set(True)
                stack.extend(o.children)
        # Ensure every selected mesh has a UV map — required for fur/custom shaders.
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
            export_extras=True,
            export_texcoords=True,   # ← UV maps (required for fur and custom shaders)
            export_yup=True,
            export_apply=True,        # (glTF skips armature modifiers here)
            export_animations=True,
            export_nla_strips=True,   # one Godot animation per stashed action
        )
        self.report({'INFO'}, "Character exported: %s" % self.filepath)
        return {'FINISHED'}


# ═════════════════════════════════════════════════════════════════════════════
#  UI
# ═════════════════════════════════════════════════════════════════════════════

class SIAG_PT_char(bpy.types.Panel):
    bl_label = "Character"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "SIAG"

    def draw(self, context):
        s = context.scene.siag_char
        col = self.layout.column(align=True)
        col.prop(s, "height")
        col.prop(s, "head_size", slider=True)
        col.prop(s, "bulk", slider=True)
        col.prop(s, "tail_segs")
        col.prop(s, "precolored")
        col.prop(s, "detail", slider=True)
        col.separator()
        col.prop(s, "particles")
        sub = col.column(align=True)
        sub.enabled = s.particles
        sub.prop(s, "hair_physics")
        sub.prop(s, "fur_physics")
        col.operator("siag.build_character", icon='OUTLINER_OB_ARMATURE')

        box = self.layout.box()
        for line in (
            "Organic sculpted body — each",
            "colour region is one smooth",
            "object (materials SIAG.*).",
            "Hair & fur are real particle",
            "systems with hair dynamics:",
            "press ▶ to watch them settle.",
            "glTF keeps the mesh hair",
            "(Godot can't import strands).",
        ):
            box.label(text=line)


class SIAG_PT_char_anim(bpy.types.Panel):
    bl_label = "Character Animations"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "SIAG"

    def draw(self, context):
        lay = self.layout
        lay.operator("siag.char_animations", icon='ARMATURE_DATA')
        lay.operator("siag.export_character", icon='EXPORT')
        box = lay.box()
        for line in (
            "Actions: Idle · Run · Jump",
            "· Slide · Grind (stashed in",
            "NLA → all export to Godot).",
            "Fine-tune in the Action",
            "editor; if a limb swings the",
            "wrong way flip the keyed",
            "sign (see ARMS_DOWN note",
            "at the top of the script).",
        ):
            box.label(text=line)


classes = (
    SIAGCharSettings,
    SIAG_OT_build_char, SIAG_OT_char_anims, SIAG_OT_char_export,
    SIAG_PT_char, SIAG_PT_char_anim,
)


def register():
    for c in classes:
        bpy.utils.register_class(c)
    bpy.types.Scene.siag_char = PointerProperty(type=SIAGCharSettings)


def unregister():
    del bpy.types.Scene.siag_char
    for c in reversed(classes):
        bpy.utils.unregister_class(c)


if __name__ == "__main__":
    try:
        unregister()
    except Exception:
        pass
    register()
# end of add-on
