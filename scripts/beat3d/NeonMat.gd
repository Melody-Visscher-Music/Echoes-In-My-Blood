class_name NeonMat
extends RefCounted

## Factory and tint seam for the world's neon materials.
##
## Two jobs:
##
## 1. **Build materials** on the shared spatial shaders in res://shaders/world/,
##    so hundreds of gate posts are one shader pipeline instead of hundreds of
##    separate StandardMaterial3Ds.
##
## 2. **Own the tint seam.** The colour cycle, the electric pulse and the
##    hit/miss flash all reach into materials and write `albedo_color` /
##    `emission` directly — 60-odd sites. A ShaderMaterial has neither property,
##    so without a seam those writes would silently do nothing and the gates
##    would just stop reacting, with no error to notice. Everything that mutates
##    a world material at runtime goes through lerp_tint / set_energy here.
##
## ── On sharing ───────────────────────────────────────────────────────────────
## The *Shader* is shared; the *ShaderMaterial* usually is not. Gates flash
## individually on a hit, and the colour cycle walks per-gate material lists, so
## a shared material instance would flash every gate on screen at once. What
## actually costs is the shader pipeline, and that is shared either way — the
## per-instance allocation count is unchanged from the StandardMaterial3D it
## replaces. Use shared() only for decor that never animates on its own.

const DIR: String = "res://shaders/world/"

const TUBE:  String = "neon_tube.gdshader"    # rails, posts, beams, arcs
const PANEL: String = "neon_panel.gdshader"   # blockers, hurdles, slide bars, plates
const ORB:   String = "energy_orb.gdshader"   # sparks, wisps, gems
const RING:  String = "fx_ring.gdshader"      # halos, echoes, hold tunnels

static var _shaders: Dictionary = {}
static var _shared: Dictionary = {}
static var _detail: float = 2.0


## Called once per level from the quality tier, before any material is built.
static func set_detail(level: float) -> void:
	_detail = clampf(level, 0.0, 2.0)
	# Materials already built keep their own copy of the uniform, so refresh them.
	for m in _shared.values():
		(m as ShaderMaterial).set_shader_parameter("detail", _detail)


static func shader(file: String) -> Shader:
	if _shaders.has(file):
		return _shaders[file]
	var sh: Shader = load(DIR + file) as Shader
	if sh == null:
		push_error("[NeonMat] Could not load %s%s" % [DIR, file])
	_shaders[file] = sh
	return sh


## A fresh material on a shared shader. `energy` is the emission multiplier —
## the same number the StandardMaterial3D path passed to
## emission_energy_multiplier, so call sites port across unchanged.
static func make(file: String, col: Color, energy: float = 4.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader(file)
	m.set_shader_parameter("tint", col)
	m.set_shader_parameter("energy", energy)
	m.set_shader_parameter("detail", _detail)
	return m


static func tube(col: Color, energy: float = 4.0) -> ShaderMaterial:
	return make(TUBE, col, energy)


static func panel(col: Color, energy: float = 2.2) -> ShaderMaterial:
	return make(PANEL, col, energy)


static func orb(col: Color, energy: float = 8.0) -> ShaderMaterial:
	return make(ORB, col, energy)


static func ring(col: Color, energy: float = 5.0) -> ShaderMaterial:
	return make(RING, col, energy)


## Cached, shared instance — for static decor that never animates individually.
## Colour is quantised so near-identical requests collapse onto one material.
static func shared(file: String, col: Color, energy: float = 4.0) -> ShaderMaterial:
	var key: String = "%s|%d,%d,%d|%.1f" % [
		file, int(col.r * 32.0), int(col.g * 32.0), int(col.b * 32.0), energy]
	if _shared.has(key):
		return _shared[key]
	var m: ShaderMaterial = make(file, col, energy)
	_shared[key] = m
	return m


## Levels are rebuilt on retry; drop the cache so it does not pin materials from
## a previous run (and their colours) into the next one.
static func clear_cache() -> void:
	_shared.clear()


# ── Tint seam ────────────────────────────────────────────────────────────────
# Every runtime write to a world material goes through these. They accept both
# material families so a half-migrated scene keeps working: gates on the new
# shaders and city decor still on StandardMaterial3D both respond correctly.

static func get_tint(m: Material) -> Color:
	var sm := m as ShaderMaterial
	if sm != null:
		var v: Variant = sm.get_shader_parameter("tint")
		return v if v is Color else Color.WHITE
	var bm := m as BaseMaterial3D
	return bm.albedo_color if bm != null else Color.WHITE


static func set_tint(m: Material, col: Color) -> void:
	var sm := m as ShaderMaterial
	if sm != null:
		sm.set_shader_parameter("tint", col)
		return
	var bm := m as BaseMaterial3D
	if bm != null:
		bm.albedo_color = col
		if bm.emission_enabled:
			bm.emission = col


## Eases a material's colour toward `col` by `k`. This is the shape the colour
## cycle already used (`mat.albedo_color.lerp(live_col, k)`), preserved exactly
## so the cycle's feel does not change.
static func lerp_tint(m: Material, col: Color, k: float) -> void:
	set_tint(m, get_tint(m).lerp(col, k))


static func get_energy(m: Material) -> float:
	var sm := m as ShaderMaterial
	if sm != null:
		var v: Variant = sm.get_shader_parameter("energy")
		return float(v) if v != null else 0.0
	var bm := m as BaseMaterial3D
	return bm.emission_energy_multiplier if bm != null else 0.0


static func set_energy(m: Material, e: float) -> void:
	var sm := m as ShaderMaterial
	if sm != null:
		sm.set_shader_parameter("energy", e)
		return
	var bm := m as BaseMaterial3D
	if bm != null:
		bm.emission_energy_multiplier = e


static func lerp_energy(m: Material, e: float, k: float) -> void:
	set_energy(m, lerpf(get_energy(m), e, k))


## Per-frame reactive uniforms. No-ops on a StandardMaterial3D, so call sites do
## not have to care which family a material belongs to.
static func set_param(m: Material, name: String, value: Variant) -> void:
	var sm := m as ShaderMaterial
	if sm != null:
		sm.set_shader_parameter(name, value)
