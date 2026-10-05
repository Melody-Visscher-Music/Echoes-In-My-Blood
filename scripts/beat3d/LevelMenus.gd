extends Node
class_name LevelMenus

## The three screens a level puts up when it is not being played: the pause
## menu, the death card and the results panel.
##
## They came out of Section_BeatRunner3d, where they sat between the track
## generator and the scoring. The split is on what each half knows: this builds
## the overlays, remembers which entry is lit, and reads the keys, the stick and
## the mouse that move between them. It never decides what an entry DOES —
## picking one emits a signal and the level acts on it, because resuming,
## spending a life and changing scene are the level's business, not a menu's.
##
## A Node, and PROCESS_MODE_ALWAYS: the pause menu has to keep taking input
## while the tree it hangs over is frozen.

## The chosen entry, by index into the menu that was up.
signal pause_chosen(index: int)
signal death_chosen(index: int)
signal results_chosen(index: int)

const PAUSE_OPTIONS: Array[String] = [
	"▶  RESUME", "↻  RESTART", "⌂  MAIN MENU", "⏹  SONG SELECT", "♪  CALIBRATE AUDIO",
]

var _pause_root: Control = null
var _pause_buttons: Array[PlateButton] = []
var _pause_option: int = 0

var _death_root: Control = null
var _death_buttons: Array[PlateButton] = []
var _death_sel: int = 0
var _death_open: bool = false

var _results_buttons: Array[PlateButton] = []
var _results_sel: int = 0
var _results_open: bool = false

## Stick-to-step repeaters, so holding a direction walks the list at a readable
## pace instead of flying down it.
var _menu_stick_v := MenuNav.AxisRepeat.new()
var _menu_stick_h := MenuNav.AxisRepeat.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


# ── What is up ───────────────────────────────────────────────────────────────

func is_pause_open() -> bool:
	return _pause_root != null


func is_death_open() -> bool:
	return _death_open


func is_results_open() -> bool:
	return _results_open


# ── Input ────────────────────────────────────────────────────────────────────
# One handler per screen, each returning true when it used the event, so the
# level can keep the order it had: results first, then its own pause toggle,
# then the pause and death menus.

func handle_results_key(event: InputEvent) -> bool:
	if not _results_open:
		return false
	var count: int = maxi(_results_buttons.size(), 1)
	if event.is_action("ui_left"):
		_results_sel = posmod(_results_sel - 1, count)
		_light_results()
	elif event.is_action("ui_right"):
		_results_sel = posmod(_results_sel + 1, count)
		_light_results()
	elif event.is_action("ui_accept"):
		results_chosen.emit(_results_sel)
	elif event.is_action("ui_cancel"):
		# Esc backs out the way the level was entered.
		_results_sel = 1
		results_chosen.emit(_results_sel)
	else:
		return false
	return true


func handle_pause_key(event: InputEvent) -> bool:
	if _pause_root == null:
		return false
	if event.is_action("ui_cancel"):
		# Gamepad B backs out of the pause menu the way it backs out of every
		# other screen. (Esc never reaches here — the level claims it.)
		pause_chosen.emit(0)
	elif event.is_action("ui_up"):
		_pause_option = posmod(_pause_option - 1, PAUSE_OPTIONS.size())
		_light_pause()
	elif event.is_action("ui_down"):
		_pause_option = posmod(_pause_option + 1, PAUSE_OPTIONS.size())
		_light_pause()
	elif event.is_action("ui_accept"):
		pause_chosen.emit(_pause_option)
	else:
		return false
	return true


func handle_death_key(event: InputEvent) -> bool:
	if not _death_open or _death_buttons.is_empty():
		return false
	if event.is_action("ui_up"):
		_death_sel = posmod(_death_sel - 1, _death_buttons.size())
		_light_death()
	elif event.is_action("ui_down"):
		_death_sel = posmod(_death_sel + 1, _death_buttons.size())
		_light_death()
	elif event.is_action("ui_accept"):
		death_chosen.emit(_death_sel)
	else:
		return false
	return true


func _vp() -> Vector2:
	return get_viewport().get_visible_rect().size


## Puts the pause card up on `host` — the level's own overlay layer, so it sits
## above every readout.
func open_pause(host: Control) -> void:
	var hud_root: Control = host
	# Built on the HUD's own CanvasLayer, so it sits above every readout.
	if hud_root == null:
		return

	_pause_option = 0
	_pause_buttons.clear()

	var s: float = UiStyle.scale_for(_vp())

	var veil := ColorRect.new()
	veil.name = "PauseVeil"
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.color = Color(0.02, 0.01, 0.07, 0.86)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(veil)
	_pause_root = veil

	# One centred chassis instead of the old four-loose-border-rects frame.
	var card := PlatePanel.create(int(34 * s), UiStyle.VIOLET, 26.0 * s)
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical   = Control.GROW_DIRECTION_BOTH
	card.custom_minimum_size = Vector2(520 * s, 0)
	veil.add_child(card)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(10 * s))
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.content.add_child(vbox)

	var title: Label = UiStyle.label("PAUSED", UiStyle.caption(7.0), int(34 * s), Color.WHITE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.self_modulate = UiStyle.signature_color(0.15)
	vbox.add_child(title)

	var rule := ColorRect.new()
	rule.color = Color(UiStyle.VIOLET.r, UiStyle.VIOLET.g, UiStyle.VIOLET.b, 0.55)
	rule.custom_minimum_size = Vector2(0, maxf(1.0, 2.0 * s))
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(rule)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 8 * s)
	vbox.add_child(gap)

	for i in PAUSE_OPTIONS.size():
		# RESTART costs a life, so it wears the warning accent rather than the
		# signature one - the cost should be visible before it is confirmed.
		var accent: Color = Color(1.00, 0.52, 0.16) if i == 1 else UiStyle.PINK
		# Entry 3 is the "back to where this level was started from" exit, so its
		# wording follows the run: the song list in Freeplay, the map in a story run.
		var opt_text: String = PAUSE_OPTIONS[i]
		if i == 3:
			opt_text = "⏹  %s" % Run.level_exit_name()
		var btn := PlateButton.create(opt_text, Callable(), int(19 * s), accent)
		btn.name = "PauseOpt%d" % i
		# Selection is driven by _pause_option, not by Godot focus - otherwise
		# ui_up/ui_down would move both and the highlight would skip entries.
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(0, 52 * s)
		vbox.add_child(btn)
		_pause_buttons.append(btn)

	# The overlay drives its own selection index, which left it with no mouse
	# support whatsoever — the entries lit up on hover and did nothing on click.
	# Route hover and click through the same index the keys and the pad use.
	MenuNav.wire_pointer(_pause_buttons,
		func(i: int) -> void:
			_pause_option = i
			_light_pause(),
		func() -> void: pause_chosen.emit(_pause_option),
		func() -> bool: return _pause_root != null)

	var hint_gap := Control.new()
	hint_gap.custom_minimum_size = Vector2(0, 10 * s)
	vbox.add_child(hint_gap)

	var hint: Label = UiStyle.label(
		"ESC / START / B  ·  ↑↓ NAVIGATE  ·  CLICK OR ENTER / A CONFIRM",
		UiStyle.caption(2.0), int(11 * s), Color.WHITE)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.self_modulate = Color(0.62, 0.55, 0.78, 0.75)
	vbox.add_child(hint)

	veil.modulate.a = 0.0
	create_tween().tween_property(veil, "modulate:a", 1.0, 0.18)

	_light_pause()


## Analog-stick navigation for whichever overlay is currently up.


## Fades the pause card out. The level calls this when it resumes, whatever the
## resume came from.
func close_pause() -> void:
	if _pause_root == null:
		return
	var root: Control = _pause_root
	_pause_root = null
	_pause_buttons.clear()
	var ftw := create_tween()
	ftw.tween_property(root, "modulate:a", 0.0, 0.14)
	ftw.tween_callback(root.queue_free)


## Hides the card while the audio calibrator is up, and brings it back after.
func set_pause_visible(shown: bool) -> void:
	if _pause_root != null:
		_pause_root.visible = shown


## Analog-stick navigation for whichever overlay is currently up.
func stick_poll(delta: float) -> void:
	var v: int = _menu_stick_v.step(MenuNav.stick(JOY_AXIS_LEFT_Y), delta)
	var h: int = _menu_stick_h.step(MenuNav.stick(JOY_AXIS_LEFT_X), delta)

	if _results_open:
		if h != 0 and not _results_buttons.is_empty():
			_results_sel = posmod(_results_sel + h, _results_buttons.size())
			_light_results()
	elif _pause_root != null:
		if v != 0:
			_pause_option = posmod(_pause_option + v, PAUSE_OPTIONS.size())
			_light_pause()
	elif _death_open:
		if v != 0 and not _death_buttons.is_empty():
			_death_sel = posmod(_death_sel + v, _death_buttons.size())
			_light_death()


func _light_pause() -> void:
	for i in _pause_buttons.size():
		var btn: PlateButton = _pause_buttons[i]
		if btn != null:
			btn.set_highlight(i == _pause_option)


## The death card. `ctx` carries what it shows: score, lives_left, lives_max and
## whether this was the last try — the level works those out, this draws them.
func open_death(host: Control, ctx: Dictionary) -> void:
	if host == null:
		return
	var root: Control = host
	var lives_exhausted: bool = bool(ctx.get("exhausted", false))

	var s: float = UiStyle.scale_for(_vp())

	# ── Phase 1: fade to solid black ────────────────────────────────
	var blackout := ColorRect.new()
	blackout.color        = Color(0.02, 0.01, 0.04, 1.0)
	blackout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blackout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blackout.modulate.a   = 0.0
	root.add_child(blackout)

	# ── Phase 2: the card, built now and revealed once the blackout lands ───
	var card := PlatePanel.create(int(36 * s), UiStyle.DANGER, 28.0 * s)
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical   = Control.GROW_DIRECTION_BOTH
	card.custom_minimum_size = Vector2(600 * s, 0)
	card.modulate.a = 0.0
	root.add_child(card)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(6 * s))
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.content.add_child(vbox)

	var title_col: Color = Color(1.00, 0.62, 0.12) if lives_exhausted else UiStyle.DANGER
	var title: Label = UiStyle.label(
		"OUT OF TRIES" if lives_exhausted else "FAILED",
		UiStyle.display(900, 3.0), int((52 if lives_exhausted else 64) * s), Color.WHITE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.self_modulate = title_col
	vbox.add_child(title)

	var score_cap: Label = UiStyle.label("SCORE", UiStyle.caption(4.0), int(11 * s), Color.WHITE)
	score_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_cap.self_modulate = Color(0.70, 0.62, 0.88, 0.80)
	vbox.add_child(score_cap)

	var score_lbl: Label = UiStyle.label(
		UiStyle.group_digits(int(ctx.get("score", 0))), UiStyle.display(800),
		int(34 * s), Color.WHITE)
	score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_lbl.self_modulate = UiStyle.signature_color(0.30)
	vbox.add_child(score_lbl)

	# Lives remaining, as the same pips the HUD uses — so the two readouts of the
	# same number look like the same thing.
	if lives_exhausted:
		var note: Label = UiStyle.label(
			"ALL TRIES USED — A BRAND NEW ROUTE HAS BEEN GENERATED",
			UiStyle.caption(1.5), int(11 * s), Color.WHITE)
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.self_modulate = Color(1.00, 0.78, 0.24, 0.95)
		vbox.add_child(note)
	else:
		vbox.add_child(_life_pips(int(ctx.get("lives_left", 0)),
			int(ctx.get("lives_max", 3)), s))

	var rule := ColorRect.new()
	rule.color = Color(UiStyle.VIOLET.r, UiStyle.VIOLET.g, UiStyle.VIOLET.b, 0.50)
	rule.custom_minimum_size = Vector2(0, maxf(1.0, 2.0 * s))
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(rule)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 10 * s)
	vbox.add_child(gap)

	var opt_texts: Array[String] = [
		"▶  PLAY NEW SEED" if lives_exhausted else "▶  RETRY",
		"↩  %s" % Run.level_exit_name(),
		"⌂  MAIN MENU",
	]
	_death_buttons.clear()
	for i in opt_texts.size():
		var btn := PlateButton.create(opt_texts[i], Callable(), int(19 * s), UiStyle.PINK)
		btn.focus_mode = Control.FOCUS_NONE   # selection is driven by _death_sel
		btn.custom_minimum_size = Vector2(0, 52 * s)
		vbox.add_child(btn)
		_death_buttons.append(btn)
	_death_sel = 0

	# Mouse rides the same selection index. Gated on _death_open so a
	# click landing during the fade-to-black cannot pick an entry that is not
	# on screen yet.
	MenuNav.wire_pointer(_death_buttons,
		func(i: int) -> void:
			_death_sel = i
			_light_death(),
		func() -> void: death_chosen.emit(_death_sel),
		func() -> bool: return _death_open)

	var hint_gap := Control.new()
	hint_gap.custom_minimum_size = Vector2(0, 8 * s)
	vbox.add_child(hint_gap)

	var hint: Label = UiStyle.label(
		"↑↓ / D-PAD CHOOSE  ·  CLICK OR ENTER / A CONFIRM",
		UiStyle.caption(2.0), int(11 * s), Color.WHITE)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.self_modulate = Color(0.58, 0.52, 0.72, 0.75)
	vbox.add_child(hint)

	# ── Sequence: fade to black → reveal the card on top ───────────────
	var ftw := create_tween()
	ftw.tween_property(blackout, "modulate:a", 1.0, 0.55)
	ftw.tween_property(card, "modulate:a", 1.0, 0.32)
	ftw.tween_callback(func() -> void:
		_death_open = true
		_light_death()
	)


# Highlight the currently selected death-menu option.


func _light_death() -> void:
	for i in range(_death_buttons.size()):
		var btn := _death_buttons[i] as PlateButton
		if btn != null:
			btn.set_highlight(i == _death_sel)


## The results panel. `ctx` carries the finished score — see
## Section_BeatRunner3d._finalise_score(), which is what writes the high score.
func open_results(host: Control, ctx: Dictionary) -> void:
	var hud_root: Control = host
	if hud_root == null:
		return

	var s: float = UiStyle.scale_for(_vp())

	# The scoring itself lives in Section_BeatRunner3d._finalise_score() — Story
	# Mode reports the same numbers on the map, and neither screen may work them
	# out for itself.
	var result: Dictionary = ctx.get("result", {}) as Dictionary
	var is_perfect: bool = bool(result["is_perfect"])
	var is_new_hs: bool  = bool(result["is_new_high"])
	var acc: float       = float(result["accuracy"])
	var grade: String    = String(result["grade"])
	var grade_col: Color = result["grade_color"] as Color
	var hs: Dictionary   = {"score": int(result["best"])}

	# Backdrop
	var overlay := ColorRect.new()
	overlay.color = Color(0.015, 0.008, 0.045, 0.94)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.modulate.a   = 0.0
	hud_root.add_child(overlay)

	# Card — accent follows the grade, so an S run and an F run do not look alike
	var card := PlatePanel.create(int(38 * s), grade_col, 32.0 * s)
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical   = Control.GROW_DIRECTION_BOTH
	card.custom_minimum_size = Vector2(840 * s, 0)
	card.modulate.a = 0.0
	hud_root.add_child(card)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(4 * s))
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.content.add_child(vbox)

	if is_perfect:
		var perf: Label = UiStyle.label("\u2726  PERFECT  \u2726", UiStyle.caption(6.0), int(22 * s), Color.WHITE)
		perf.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		perf.self_modulate = Color(0.40, 1.00, 0.60)
		vbox.add_child(perf)
		var ptw := perf.create_tween().set_loops()
		ptw.tween_property(perf, "modulate", Color(1.25, 1.25, 1.0), 0.70)
		ptw.tween_property(perf, "modulate", Color(1.0, 1.0, 1.0), 0.70)

	var score_cap: Label = UiStyle.label(
		"SCORE  \u00b7  \u00d71.5 PERFECT BONUS" if is_perfect else "SCORE",
		UiStyle.caption(5.0), int(11 * s), Color.WHITE)
	score_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_cap.self_modulate = Color(0.40, 0.95, 0.60) if is_perfect else Color(0.65, 0.58, 0.85, 0.85)
	vbox.add_child(score_cap)

	var score_val: Label = UiStyle.label(
		UiStyle.group_digits(int(ctx.get("score", 0))), UiStyle.display(800),
		int(72 * s), Color.WHITE)
	score_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_val.self_modulate = Color(1.00, 0.95, 0.42)
	vbox.add_child(score_val)

	# Grade on its own chip
	var grade_row := HBoxContainer.new()
	grade_row.alignment = BoxContainer.ALIGNMENT_CENTER
	grade_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(grade_row)

	var grade_chip := PlatePanel.create(int(10 * s), grade_col, 18.0 * s)
	grade_chip.custom_minimum_size = Vector2(150 * s, 0)
	grade_row.add_child(grade_chip)

	var grade_box := VBoxContainer.new()
	grade_box.add_theme_constant_override("separation", 0)
	grade_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grade_chip.content.add_child(grade_box)

	var grade_lbl: Label = UiStyle.label(grade, UiStyle.display(900), int(58 * s), Color.WHITE)
	grade_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	grade_lbl.self_modulate = grade_col
	grade_box.add_child(grade_lbl)

	var acc_lbl: Label = UiStyle.label("%.1f%%" % (acc * 100.0), UiStyle.display(700), int(15 * s), Color.WHITE)
	acc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	acc_lbl.self_modulate = grade_col.lightened(0.20)
	grade_box.add_child(acc_lbl)

	if grade == "S":
		var gtw := grade_lbl.create_tween().set_loops()
		gtw.tween_property(grade_lbl, "modulate", Color(1.45, 1.35, 0.65), 0.60)
		gtw.tween_property(grade_lbl, "modulate", Color(1.0, 1.0, 1.0), 0.60)

	# Record line
	if is_new_hs:
		var hs_lbl: Label = UiStyle.label("\u2605  NEW HIGH SCORE  \u2605", UiStyle.caption(5.0), int(17 * s), Color.WHITE)
		hs_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hs_lbl.self_modulate = Color(1.00, 0.38, 0.68)
		vbox.add_child(hs_lbl)
		var htw := hs_lbl.create_tween().set_loops()
		htw.tween_property(hs_lbl, "modulate", Color(1.35, 0.9, 1.35), 0.55)
		htw.tween_property(hs_lbl, "modulate", Color(1.0, 1.0, 1.0), 0.55)
	else:
		var prev: Label = UiStyle.label(
			"BEST  %s" % UiStyle.group_digits(int(hs.get("score", 0))),
			UiStyle.caption(3.0), int(12 * s), Color.WHITE)
		prev.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		prev.self_modulate = Color(0.58, 0.52, 0.75, 0.85)
		vbox.add_child(prev)

	vbox.add_child(_rule(s))

	# Stats row
	var stat_row := HBoxContainer.new()
	stat_row.alignment = BoxContainer.ALIGNMENT_CENTER
	stat_row.add_theme_constant_override("separation", int(70 * s))
	stat_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(stat_row)

	var missed: int = int(ctx.get("gates_missed", 0))
	var miss_col: Color = UiStyle.DANGER if missed > 0 else Color(0.50, 0.46, 0.68)
	var stats: Array = [
		["BEST COMBO", "\u00d7%d" % int(ctx.get("max_combo", 0)), UiStyle.CYAN],
		["HIT", str(int(ctx.get("gates_hit", 0))), Color(0.40, 1.00, 0.55)],
		["MISSED", str(missed), miss_col],
	]
	for st in stats:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 0)
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var val: Label = UiStyle.label(String(st[1]), UiStyle.display(800), int(40 * s), Color.WHITE)
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		val.self_modulate = st[2]
		col.add_child(val)
		var key: Label = UiStyle.label(String(st[0]), UiStyle.caption(3.0), int(10 * s), Color.WHITE)
		key.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		key.self_modulate = Color(0.58, 0.52, 0.75, 0.85)
		col.add_child(key)
		stat_row.add_child(col)

	vbox.add_child(_rule(s))

	# Navigation
	var nav_row := HBoxContainer.new()
	nav_row.alignment = BoxContainer.ALIGNMENT_CENTER
	nav_row.add_theme_constant_override("separation", int(16 * s))
	nav_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(nav_row)

	_results_buttons.clear()
	for txt in ["\u25b6  PLAY AGAIN", "\u21a9  %s" % Run.level_exit_name(), "\u2302  MAIN MENU"]:
		var btn := PlateButton.create(txt, Callable(), int(16 * s), UiStyle.PINK)
		btn.focus_mode = Control.FOCUS_NONE   # selection is driven by _results_sel
		btn.custom_minimum_size = Vector2(230 * s, 50 * s)
		nav_row.add_child(btn)
		_results_buttons.append(btn)

	MenuNav.wire_pointer(_results_buttons,
		func(i: int) -> void:
			_results_sel = i
			_light_results(),
		func() -> void: results_chosen.emit(_results_sel),
		func() -> bool: return _results_open)

	var hint: Label = UiStyle.label(
		"\u25c0\u25b6 / D-PAD CHOOSE  \u00b7  CLICK OR ENTER / A CONFIRM",
		UiStyle.caption(2.0), int(11 * s), Color.WHITE)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.self_modulate = Color(0.55, 0.50, 0.70, 0.75)
	vbox.add_child(hint)

	# Fade in
	var itw := create_tween()
	itw.parallel().tween_property(overlay, "modulate:a", 1.0, 0.40)
	itw.parallel().tween_property(card, "modulate:a", 1.0, 0.40)
	itw.tween_callback(func() -> void:
		_results_sel = 0
		_light_results()
		_results_open = true
	)


## Thin signature-band rule. Replaces HSeparator, whose theme colour is one flat
## line with no way to carry the palette.


func _light_results() -> void:
	for i in _results_buttons.size():
		var btn := _results_buttons[i]
		if btn != null:
			btn.set_highlight(i == _results_sel)


func _rule(s: float) -> Control:
	var rule := ColorRect.new()
	rule.color = Color(UiStyle.VIOLET.r, UiStyle.VIOLET.g, UiStyle.VIOLET.b, 0.50)
	rule.custom_minimum_size = Vector2(0, maxf(1.0, 2.0 * s))
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rule


# (Results nav pills are PlateButtons now — see _spawn_results_panel.)


## Lives left, as the same pips the HUD uses.
func _life_pips(left: int, total: int, s: float) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(8 * s))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bar_shader: Shader = load("res://shaders/hud_bar.gdshader") as Shader
	for i in maxi(total, 0):
		var spent: bool = i >= left
		var pip := ColorRect.new()
		pip.color = Color.WHITE
		pip.custom_minimum_size = Vector2(46 * s, 12 * s)
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var m := ShaderMaterial.new()
		m.shader = bar_shader
		m.set_shader_parameter("rect_size",   Vector2(46 * s, 12 * s))
		m.set_shader_parameter("skew_px",     5.0)
		m.set_shader_parameter("tick_count",  0.0)
		m.set_shader_parameter("bolt_amount", 0.0)
		m.set_shader_parameter("fill_pct",    0.0 if spent else 1.0)
		m.set_shader_parameter("ghost_pct",   0.0)
		m.set_shader_parameter("ghost_color", Color(0, 0, 0, 0))
		m.set_shader_parameter("fill_color",  UiStyle.PINK)
		m.set_shader_parameter("fill_color2", UiStyle.VIOLET)
		m.set_shader_parameter("edge_color",  UiStyle.PINK)
		pip.material = m
		pip.modulate = Color(1, 1, 1, 0.55) if spent else Color.WHITE
		row.add_child(pip)
	return row


## Pushes the current life count to the HUD's pips. Called wherever
## Run.song_lives changes while a level is still on screen.
