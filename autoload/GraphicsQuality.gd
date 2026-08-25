extends Node
## Auto-detects a sensible graphics quality tier the first time the game
## ever runs (a quick GPU/CPU heuristic — no benchmark scene, so there's no
## added load time), and lets the player override it afterward from
## Options > Display > Quality (same pattern as Fullscreen/V-Sync/Max FPS).
##
## The tier drives:
##   - 3D render resolution scale + antialiasing on the main viewport
##   - SSR/SSAO/SSIL/SDFGI on the runner's world environment
##   - directional + positional shadow atlas resolution
##   - fur shell count (so_fluffy density)
##
## …and, since the CPU (not the GPU) is what actually caps this game's frame
## rate, a matching set of CPU-side knobs consumed by Section_BeatRunner3d:
##   - deco_update_hz           how many times a SECOND the world-decoration pass
##                              runs. Replaces the old deco_update_divisor frame
##                              counter, which meant "max" (divisor 1) ran the
##                              whole pass 120x a second purely because the
##                              render rate happened to be 120 fps. A wall-clock
##                              rate also makes the decoration lerps converge at
##                              the same speed on every machine.
##   - deco_window_ahead_m      how far ahead decorations are kept live at all
##   - ambient_light_spacing_m  metres between overhead track spot lights
##   - gem_spacing_m            metres between gem/arch/pad decoration clusters
##   - fx_step_lights           per-footstep floor glow lights on/off
##   - world_fx_wisps           melody wisps spawned per track side, per event
##   - world_fx_spires          melody light spires on/off
##   - city_buildings_per_side  skyline density
##   - fur_physics              so_fluffy spring simulation on/off
## Without these, every tier from "low" to "max" ran the exact same per-frame
## script workload and only the render resolution changed — which is why
## dropping the quality setting used to do so little for a CPU-bound frame.
##
## It does NOT touch Engine.max_fps except as a one-time suggestion the very
## first time a tier is auto-detected — the existing Max FPS dropdown in
## Options > Display is the source of truth for that after first launch.

signal tier_changed(tier: String)

const TIERS: Array[String] = ["low", "medium", "high", "ultra", "max"]

const PRESETS: Dictionary = {
	"low": {
		"scaling_3d_scale": 0.65,
		"msaa_3d": Viewport.MSAA_DISABLED,
		"screen_space_aa": Viewport.SCREEN_SPACE_AA_DISABLED,
		"ssr": false, "ssr_steps": 0,
		"ssao": false, "ssil": false, "sdfgi": false, "sdfgi_bounce": 0.0,
		"volumetric_fog": false,
		"directional_shadow_size": 1024, "positional_shadow_atlas_size": 512,
		"shadow_soft_quality": RenderingServer.SHADOW_QUALITY_HARD,
		"mesh_lod_threshold": 16.0,
		"fur_scale": 0.45,
		# ── CPU-side cost (see Section_BeatRunner3d) ──────────────────────
		"deco_window_ahead_m": 140.0,
		"deco_update_hz": 15,
		"world_fx_wisps": 1,
		"world_fx_spires": false,
		"city_buildings_per_side": 8,
		"fur_physics": false,
		"ambient_light_spacing_m": 50.0,
		"gem_spacing_m": 64.0,
		"fx_step_lights": false,
		"initial_max_fps": 60,
	},
	"medium": {
		"scaling_3d_scale": 0.85,
		"msaa_3d": Viewport.MSAA_DISABLED,
		"screen_space_aa": Viewport.SCREEN_SPACE_AA_FXAA,
		"ssr": false, "ssr_steps": 0,
		"ssao": true, "ssil": false, "sdfgi": false, "sdfgi_bounce": 0.0,
		"volumetric_fog": false,
		"directional_shadow_size": 1536, "positional_shadow_atlas_size": 768,
		"shadow_soft_quality": RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		"mesh_lod_threshold": 12.0,
		"fur_scale": 0.70,
		# ── CPU-side cost (see Section_BeatRunner3d) ──────────────────────
		"deco_window_ahead_m": 180.0,
		"deco_update_hz": 20,
		"world_fx_wisps": 2,
		"world_fx_spires": true,
		"city_buildings_per_side": 12,
		"fur_physics": false,
		"ambient_light_spacing_m": 35.0,
		"gem_spacing_m": 48.0,
		"fx_step_lights": true,
		"initial_max_fps": 60,
	},
	"high": {
		"scaling_3d_scale": 1.0,
		"msaa_3d": Viewport.MSAA_DISABLED,
		"screen_space_aa": Viewport.SCREEN_SPACE_AA_FXAA,
		"ssr": true, "ssr_steps": 32,
		"ssao": true, "ssil": false, "sdfgi": false, "sdfgi_bounce": 0.0,
		"volumetric_fog": false,
		"directional_shadow_size": 2048, "positional_shadow_atlas_size": 1024,
		"shadow_soft_quality": RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM,
		"mesh_lod_threshold": 8.0,   # matches the project's original static default
		"fur_scale": 1.0,
		# ── CPU-side cost (see Section_BeatRunner3d) ──────────────────────
		"deco_window_ahead_m": 220.0,
		"deco_update_hz": 30,
		"world_fx_wisps": 4,
		"world_fx_spires": true,
		"city_buildings_per_side": 18,
		"fur_physics": true,
		"ambient_light_spacing_m": 25.0,
		"gem_spacing_m": 32.0,
		"fx_step_lights": true,
		"initial_max_fps": 120,
	},
	"ultra": {
		# Supersampled 3D res, 4x MSAA, full SSR/SSAO/SSIL, real-time SDFGI
		# (dynamic bounce lighting — the single heaviest Godot 4 feature), and
		# big shadow atlases. Deliberately a lot more than "high" — meant for
		# headroom on a strong GPU, not a safe default, which is why it's
		# opt-in via the Options dropdown rather than something auto-detection
		# would ever pick on its own.
		"scaling_3d_scale": 1.2,
		"msaa_3d": Viewport.MSAA_4X,
		"screen_space_aa": Viewport.SCREEN_SPACE_AA_FXAA,
		"ssr": true, "ssr_steps": 64,
		"ssao": true, "ssil": true, "sdfgi": true, "sdfgi_bounce": 0.6,
		"volumetric_fog": false,
		"directional_shadow_size": 4096, "positional_shadow_atlas_size": 2048,
		"shadow_soft_quality": RenderingServer.SHADOW_QUALITY_SOFT_HIGH,
		"mesh_lod_threshold": 4.0,
		"fur_scale": 1.0,
		# ── CPU-side cost (see Section_BeatRunner3d) ──────────────────────
		"deco_window_ahead_m": 260.0,
		"deco_update_hz": 30,
		"world_fx_wisps": 5,
		"world_fx_spires": true,
		"city_buildings_per_side": 18,
		"fur_physics": true,
		"ambient_light_spacing_m": 25.0,
		"gem_spacing_m": 32.0,
		"fx_step_lights": true,
		"initial_max_fps": 120,
	},
	"max": {
		# The practical ceiling: 1.75x supersampling + 4x MSAA (originally
		# pushed to 2.0x/8x, but stacking that much supersampling with that
		# much MSAA on top of SDFGI + volumetric fog GI-inject caused a real
		# GPU device-lost crash (Vulkan fence_wait failure / Windows TDR
		# reset) during a busy scene — dialed back the redundant AA stacking
		# and turned off fog GI-inject, kept everything else), deep SSR
		# raymarching, real-time SDFGI with strong bounce feedback, volumetric
		# fog (the one thing no lower tier has at all — real light shafts
		# through the neon, not just sharper pixels), ultra soft-shadow
		# filtering, max shadow atlases, LOD almost fully held off, and the
		# densest fur. Never auto-detected, never the default recommendation
		# — this is for a confirmed strong rig only.
		"scaling_3d_scale": 1.75,
		"msaa_3d": Viewport.MSAA_4X,
		"screen_space_aa": Viewport.SCREEN_SPACE_AA_FXAA,
		"ssr": true, "ssr_steps": 256,
		"ssao": true, "ssil": true, "sdfgi": true, "sdfgi_bounce": 1.5,
		"volumetric_fog": true,
		"directional_shadow_size": 8192, "positional_shadow_atlas_size": 4096,
		"shadow_soft_quality": RenderingServer.SHADOW_QUALITY_SOFT_ULTRA,
		"mesh_lod_threshold": 1.0,
		"fur_scale": 1.3,
		# ── CPU-side cost (see Section_BeatRunner3d) ──────────────────────
		"deco_window_ahead_m": 300.0,
		"deco_update_hz": 60,
		"world_fx_wisps": 5,
		"world_fx_spires": true,
		"city_buildings_per_side": 18,
		"fur_physics": true,
		"ambient_light_spacing_m": 20.0,
		"gem_spacing_m": 32.0,
		"fx_step_lights": true,
		"initial_max_fps": 120,
	},
}

## Convenience accessor for a preset key, with a fallback for older saved
## configs / tiers that predate a newly added key.
func get_setting(key: String, fallback: Variant) -> Variant:
	var p: Dictionary = PRESETS.get(tier, {})
	return p.get(key, fallback)


var tier: String = "medium"
var _ever_detected: bool = false

const _PATH: String = "user://graphics_quality.cfg"


func _ready() -> void:
	_load()
	if not _ever_detected:
		tier = _detect_tier()
		_ever_detected = true
		Engine.max_fps = int(PRESETS[tier].initial_max_fps)
		_save()
	_apply_viewport_settings()


## Lightweight hardware read — GPU name string + CPU core count. No
## benchmark scene, so first launch has zero added load time. GPU name
## matching is inherently fuzzy; an unrecognized adapter is scored as
## mid-range rather than punished, since a false "low" is more annoying
## than a false "medium" (see set_tier() for the manual override escape hatch).
##
## Caps out at "high" — Ultra now includes SDFGI (the heaviest Godot 4
## feature) and supersampled resolution, deliberately more than a safe
## default should reach for on its own. It's there for someone to pick by
## hand once they know their rig handles it, not something auto-detect
## should guess at from a GPU name string alone.
func _detect_tier() -> String:
	var adapter: String = RenderingServer.get_video_adapter_name().to_lower()
	var cores: int = OS.get_processor_count()

	var score: int = 0
	if adapter.find("rtx") >= 0 or adapter.find("radeon rx") >= 0 or adapter.find("arc a") >= 0:
		score += 3
	elif adapter.find("gtx") >= 0 or (adapter.find("radeon") >= 0 and adapter.find("vega") < 0):
		score += 2
	elif adapter.find("iris xe") >= 0 or adapter.find("vega") >= 0 or adapter.find("apple m") >= 0:
		score += 1
	elif adapter.find("uhd") >= 0 or adapter.find("hd graphics") >= 0 or adapter.find("intel") >= 0:
		score += 0
	else:
		score += 1   # empty or unrecognized adapter string — assume mid-range

	if cores >= 12:
		score += 2
	elif cores >= 6:
		score += 1

	if score >= 3:
		return "high"
	elif score >= 1:
		return "medium"
	return "low"


## Manual override from Options > Display > Quality. Applies immediately;
## does not touch Engine.max_fps (that dropdown owns fps after first launch).
func set_tier(t: String) -> void:
	if not PRESETS.has(t) or t == tier:
		return
	tier = t
	_apply_viewport_settings()
	tier_changed.emit(tier)
	_save()


func _apply_viewport_settings() -> void:
	var p: Dictionary = PRESETS[tier]
	var vp: Viewport = get_viewport()
	if vp == null:
		return
	vp.scaling_3d_scale = p.scaling_3d_scale
	vp.msaa_3d = p.msaa_3d
	vp.screen_space_aa = p.screen_space_aa
	vp.mesh_lod_threshold = p.mesh_lod_threshold

	# Shadow atlas sizes are global RenderingServer state, not per-viewport —
	# re-applying them on every tier change keeps them in sync with whichever
	# tier is currently active (so switching back down actually shrinks them
	# again, not just the first switch up).
	RenderingServer.directional_shadow_atlas_set_size(int(p.directional_shadow_size), true)
	vp.positional_shadow_atlas_size = int(p.positional_shadow_atlas_size)

	# PCSS soft-shadow filter quality — also global RenderingServer state.
	# Higher quality = more shadow-map samples per pixel (softer, less banded
	# penumbras), independent of atlas resolution.
	RenderingServer.directional_soft_shadow_filter_set_quality(p.shadow_soft_quality)
	RenderingServer.positional_soft_shadow_filter_set_quality(p.shadow_soft_quality)


## Called by Section_BeatRunner3d right after it builds its Environment —
## see that file for why this (not the .tscn-authored Environment resource)
## is the one that actually matters at runtime.
func apply_environment_overrides(env: Environment) -> void:
	var p: Dictionary = PRESETS[tier]
	env.ssr_enabled = p.ssr
	if p.ssr:
		env.ssr_max_steps = int(p.ssr_steps)
	env.ssao_enabled = p.ssao
	env.ssil_enabled = p.ssil
	env.sdfgi_enabled = p.sdfgi
	if p.sdfgi:
		env.sdfgi_bounce_feedback = p.sdfgi_bounce

	env.volumetric_fog_enabled = p.volumetric_fog
	if p.volumetric_fog:
		# Matches the base fog color set in _setup_world_environment() (deep
		# purple/neon). Density kept low — this is meant to add light shafts
		# and depth, not haze that would obscure gameplay-critical gates.
		env.volumetric_fog_density = 0.02
		env.volumetric_fog_albedo = Color(0.12, 0.04, 0.25, 1.0)
		env.volumetric_fog_gi_inject = 0.0   # was 0.4 — stacked with SDFGI, likely a factor in the device-lost crash


## Called by BeatRunnerPlayer when it sizes the fur. Never below 8 shells —
## so_fluffy's own documented floor for the effect to still read as fur.
func scale_fur_shells(base_count: int) -> int:
	var p: Dictionary = PRESETS[tier]
	return maxi(8, int(round(base_count * float(p.fur_scale))))


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("quality", "tier", tier)
	cfg.set_value("quality", "ever_detected", _ever_detected)
	if cfg.save(_PATH) != OK:
		push_warning("[GraphicsQuality] Failed to save.")


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_PATH) != OK:
		return   # first launch — will auto-detect in _ready()
	tier           = cfg.get_value("quality", "tier", tier)
	_ever_detected = cfg.get_value("quality", "ever_detected", false)
