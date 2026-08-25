class_name PlateChassis
extends RefCounted

## Shared plumbing for the chamfered neon chassis behind PlateButton and
## PlatePanel.
##
## The chassis is a ColorRect running shaders/hud_plate.gdshader. Nothing here
## draws by itself — callers own the node and just ask this for a configured
## plate and for the state colours to write into it.

const PLATE_SHADER: String = "res://shaders/hud_plate.gdshader"

static var _shader: Shader = null


static func shader() -> Shader:
	if _shader == null:
		_shader = load(PLATE_SHADER) as Shader
		if _shader == null:
			push_error("[PlateChassis] Could not load %s" % PLATE_SHADER)
	return _shader


## A full-rect plate ColorRect ready to be parented.
##
## `behind` sets show_behind_parent, which is what lets a plate sit under a
## Button's own text: children normally draw ON TOP of their parent, so without
## it the chassis would cover the label it is supposed to frame.
static func make_plate(cut_size: float = 16.0, behind: bool = false) -> ColorRect:
	var r := ColorRect.new()
	r.name  = "Plate"
	r.color = Color.WHITE          # unused — the shader drives every visible pixel
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.show_behind_parent = behind
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var m := ShaderMaterial.new()
	m.shader = shader()
	m.set_shader_parameter("cut_size", cut_size)
	m.set_shader_parameter("cut_tl", 1.0)
	m.set_shader_parameter("cut_tr", 0.0)
	m.set_shader_parameter("cut_br", 1.0)
	m.set_shader_parameter("cut_bl", 0.0)
	m.set_shader_parameter("fill_color", UiStyle.INK)
	# Menus and overlays have no beat to follow, so the plate animates itself.
	m.set_shader_parameter("idle_pulse", 1.0)
	r.material = m
	return r


## Keeps the plate's `rect_size` uniform in step with the node it frames. The
## shader's whole silhouette is derived from it, so a stale value means chamfers
## at the wrong scale.
static func resize(plate: ColorRect, size: Vector2) -> void:
	if plate == null:
		return
	var m := plate.material as ShaderMaterial
	if m != null:
		m.set_shader_parameter("rect_size", size)


static func set_param(plate: ColorRect, name: String, value: Variant) -> void:
	if plate == null:
		return
	var m := plate.material as ShaderMaterial
	if m != null:
		m.set_shader_parameter(name, value)


# ── Interaction states ───────────────────────────────────────────────────────
# One place to define how a plate reacts, so buttons, song cards and mode
# toggles all respond identically.

enum State { NORMAL, HOVER, PRESSED, DISABLED }


static func apply_state(plate: ColorRect, state: int, accent: Color) -> void:
	if plate == null:
		return
	var m := plate.material as ShaderMaterial
	if m == null:
		return
	match state:
		State.HOVER:
			m.set_shader_parameter("edge_color",  accent.lightened(0.35))
			m.set_shader_parameter("edge_color2", UiStyle.CYAN.lightened(0.20))
			m.set_shader_parameter("edge_px",     2.2)
			m.set_shader_parameter("glow_px",     20.0)
			# Menu plates are far larger than HUD plates, so the same grid
			# density that read as texture on a 270px card reads as graph paper
			# on a 340px button. Kept low and let the edge falloff carry it.
			m.set_shader_parameter("grid_amount", 0.22)
			m.set_shader_parameter("fill_amount", 1.0)
		State.PRESSED:
			m.set_shader_parameter("edge_color",  Color(1.0, 0.92, 1.0))
			m.set_shader_parameter("edge_color2", Color(1.0, 0.92, 1.0))
			m.set_shader_parameter("edge_px",     2.6)
			m.set_shader_parameter("glow_px",     26.0)
			m.set_shader_parameter("grid_amount", 0.30)
			m.set_shader_parameter("fill_amount", 1.0)
		State.DISABLED:
			var dim: Color = accent.lerp(Color(0.35, 0.32, 0.45), 0.75)
			m.set_shader_parameter("edge_color",  Color(dim.r, dim.g, dim.b, 0.35))
			m.set_shader_parameter("edge_color2", Color(dim.r, dim.g, dim.b, 0.35))
			m.set_shader_parameter("edge_px",     1.2)
			m.set_shader_parameter("glow_px",     0.0)
			m.set_shader_parameter("grid_amount", 0.10)
			m.set_shader_parameter("fill_amount", 0.55)
			m.set_shader_parameter("idle_pulse",  0.0)   # a dead control shouldn't breathe
		_:
			m.set_shader_parameter("edge_color",  accent)
			m.set_shader_parameter("edge_color2", UiStyle.signature_color(0.55))
			m.set_shader_parameter("edge_px",     1.7)
			m.set_shader_parameter("glow_px",     10.0)
			m.set_shader_parameter("grid_amount", 0.14)
			m.set_shader_parameter("fill_amount", 1.0)
			m.set_shader_parameter("idle_pulse",  1.0)
