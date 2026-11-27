extends RefCounted
class_name SkyClock

## The level's time of day, on the story map's clock.
##
## The map keeps a running day (StoryMap.DAY_LENGTH_S for a full turn through
## DAWN, DAY, DUSK, NIGHT) and saves where it was with a wall-clock stamp, so it
## keeps turning while you are off in a level. This reads the same save, works
## out what time it is on the map RIGHT NOW, starts the level's sky there and
## lets it run on at the map's own rate — so a song started at dusk sinks into
## night while it plays, and the map you come back to is at the hour the song
## ended on.
##
## The city is neon, so the looks below stay dark enough for the gates to read
## at every hour: day is a hazy blue rather than bright noon. Only the sky, the
## ambient light and the fog move; nothing in a lane does.

## Must match StoryMap: same ring, same length of day.
const DAY_LENGTH_S: float = 900.0
const N: int = 4   # DAWN, DAY, DUSK, NIGHT — StoryMap.TIME_PRESETS order
const NAMES: PackedStringArray = ["DAWN", "DAY", "DUSK", "NIGHT"]

const LOOKS: Array[Dictionary] = [
	{   # DAWN — a pink-gold rim under a cold blue top, sun just up.
		"horizon": Color(0.22, 0.10, 0.20), "zenith": Color(0.035, 0.04, 0.12),
		"glow": Color(1.0, 0.50, 0.40), "glow_amt": 0.34,
		"nebula": Color(0.30, 0.18, 0.45), "neb_amt": 0.10, "stars": 0.35,
		"sun": Color(1.0, 0.62, 0.40), "sun_amt": 0.8, "sun_pitch": 4.0,
		"amb": Color(0.34, 0.22, 0.40), "amb_e": 0.22,
		"fog": Color(0.15, 0.08, 0.16),
	},
	{   # DAY — hazy blue, no stars. Lighter, not light: the neon must still win.
		"horizon": Color(0.17, 0.22, 0.36), "zenith": Color(0.05, 0.11, 0.26),
		"glow": Color(0.70, 0.80, 1.0), "glow_amt": 0.18,
		"nebula": Color(0.5, 0.6, 0.8), "neb_amt": 0.0, "stars": 0.0,
		"sun": Color(1.0, 0.95, 0.85), "sun_amt": 0.5, "sun_pitch": 48.0,
		"amb": Color(0.38, 0.42, 0.58), "amb_e": 0.28,
		"fog": Color(0.11, 0.14, 0.23),
	},
	{   # DUSK — orange and magenta into violet, sun on the skyline.
		"horizon": Color(0.28, 0.09, 0.13), "zenith": Color(0.045, 0.02, 0.10),
		"glow": Color(1.0, 0.34, 0.45), "glow_amt": 0.40,
		"nebula": Color(0.40, 0.12, 0.45), "neb_amt": 0.18, "stars": 0.45,
		"sun": Color(1.0, 0.45, 0.25), "sun_amt": 0.9, "sun_pitch": 3.0,
		"amb": Color(0.34, 0.13, 0.34), "amb_e": 0.21,
		"fog": Color(0.15, 0.05, 0.13),
	},
	{   # NIGHT — the level's original look, exactly.
		"horizon": Color(0.105, 0.035, 0.215), "zenith": Color(0.012, 0.006, 0.038),
		"glow": Color(0.62, 0.14, 0.85), "glow_amt": 0.42,
		"nebula": Color(0.30, 0.10, 0.55), "neb_amt": 0.35, "stars": 1.0,
		"sun": Color(0.6, 0.7, 1.0), "sun_amt": 0.0, "sun_pitch": -20.0,
		"amb": Color(0.22, 0.06, 0.40), "amb_e": 0.18,
		"fog": Color(0.12, 0.04, 0.25),
	},
]

var time: float = 3.0           # position in the ring, as on the map
var fog_color: Color = LOOKS[3]["fog"]
var ambient_energy: float = 0.18

var _env: Environment = null
var _sky: ShaderMaterial = null
var _bearing: Vector3 = Vector3.FORWARD


## `bearing`: a flat world direction the sun rises and sets toward (the track's
## opening direction, turned aside so it is not dead ahead behind the moon).
func setup(env: Environment, sky: ShaderMaterial, bearing: Vector3) -> void:
	_env = env
	_sky = sky
	var b := Vector3(bearing.x, 0.0, bearing.z)
	_bearing = b.normalized() if b.length() > 0.01 else Vector3.FORWARD
	_bearing = _bearing.rotated(Vector3.UP, deg_to_rad(38.0))
	time = map_time_now()
	apply()


## Where the story map's clock is at this moment: its saved position plus the
## time since it was saved, exactly as StoryMap._load_time_of_day() works it out.
## A save that has never been to the map opens at midday, as the map does.
static func map_time_now() -> float:
	var saved: Dictionary = Save.get_story_time()
	var t: float = float(saved.get("time", -1.0))
	if t < 0.0:
		return 1.0
	return fposmod(t + float(saved.get("elapsed", 0.0)) * float(N) / DAY_LENGTH_S, float(N))


func advance(delta: float) -> void:
	time = fposmod(time + delta * float(N) / DAY_LENGTH_S, float(N))
	apply()


## The hour's name for a readout: the nearest keyframe, or "A → B" between them.
func hour_name() -> String:
	var i: int = int(time) % N
	var k: float = time - floorf(time)
	if k < 0.1:
		return NAMES[i]
	if k > 0.9:
		return NAMES[(i + 1) % N]
	return "%s → %s" % [NAMES[i], NAMES[(i + 1) % N]]


func apply() -> void:
	var i: int = int(floorf(time)) % N
	var a: Dictionary = LOOKS[i]
	var b: Dictionary = LOOKS[(i + 1) % N]
	var k: float = time - floorf(time)
	k = k * k * (3.0 - 2.0 * k)
	fog_color = (a["fog"] as Color).lerp(b["fog"], k)
	ambient_energy = lerpf(a["amb_e"], b["amb_e"], k)
	if _sky != null:
		_sky.set_shader_parameter("horizon_col", _c(a, b, "horizon", k))
		_sky.set_shader_parameter("zenith_col", _c(a, b, "zenith", k))
		_sky.set_shader_parameter("glow_col", _c(a, b, "glow", k))
		_sky.set_shader_parameter("nebula_col", _c(a, b, "nebula", k))
		_sky.set_shader_parameter("glow_amount", lerpf(a["glow_amt"], b["glow_amt"], k))
		_sky.set_shader_parameter("nebula_amount", lerpf(a["neb_amt"], b["neb_amt"], k))
		_sky.set_shader_parameter("star_amount", lerpf(a["stars"], b["stars"], k))
		_sky.set_shader_parameter("sun_col", _c(a, b, "sun", k))
		_sky.set_shader_parameter("sun_amount", lerpf(a["sun_amt"], b["sun_amt"], k))
		var pitch: float = deg_to_rad(lerpf(a["sun_pitch"], b["sun_pitch"], k))
		_sky.set_shader_parameter("sun_dir", (_bearing * cos(pitch) + Vector3.UP * sin(pitch)).normalized())
	if _env != null:
		_env.ambient_light_color = (a["amb"] as Color).lerp(b["amb"], k)


## A Color, not a Vector3: the sky's colour uniforms are source_color, and only
## a Color gets the sRGB-to-linear conversion — a Vector3 went in raw and
## rendered every hour about twice as bright as written.
static func _c(a: Dictionary, b: Dictionary, key: String, k: float) -> Color:
	return (a[key] as Color).lerp(b[key], k)
