class_name MenuNav
extends RefCounted

## Shared keyboard / gamepad / mouse plumbing for the menus.
##
## Two navigation models live in this project and both needed help:
##
##  * Focus-driven screens (main menu, options panels, tutorial) rely on Godot's
##    own focus traversal. They kept losing the focus owner whenever a panel was
##    hidden or swapped, which left keyboard and gamepad with nothing to move —
##    `focus_first()` and `wrap_column()` put it back.
##
##  * Index-driven overlays (pause, death, results, song list) drive their own
##    selection integer and set `focus_mode = FOCUS_NONE` so Godot's traversal
##    doesn't fight them. That model had no mouse path at all — `wire_pointer()`
##    hangs hover and click off the same selection integer, so all three devices
##    end up going through one code path.


## Every visible, focusable, non-disabled Control under `root`, in tree order.
##
## FOCUS_ALL only: Godot's own traversal skips FOCUS_CLICK controls, so handing
## focus to one would drop the player somewhere the arrow keys cannot leave in
## the usual way. `include_internal` reaches inside composite controls whose
## parts are internal children — the ColorPicker's sliders are the reason it
## exists, since get_children() hides all of them by default.
static func focusables(root: Node, include_internal: bool = false) -> Array[Control]:
	var out: Array[Control] = []
	_collect(root, out, include_internal)
	return out


static func _collect(node: Node, out: Array[Control], include_internal: bool) -> void:
	if node == null:
		return
	for child in node.get_children(include_internal):
		var c := child as Control
		if c == null:
			continue
		if not c.visible:
			continue
		if c.focus_mode == Control.FOCUS_ALL and not is_disabled(c):
			out.append(c)
		_collect(c, out, include_internal)


## Buttons keep `focus_mode` when disabled, so Godot's traversal will happily
## park on one. Everything here filters them out explicitly instead.
static func is_disabled(c: Control) -> bool:
	var bb := c as BaseButton
	if bb != null:
		return bb.disabled
	var sl := c as Slider
	if sl != null:
		return not sl.editable
	return false


## Focuses the first thing a keyboard or gamepad can reach inside `root`.
## Returns it, or null when the subtree holds nothing focusable.
static func focus_first(root: Node, include_internal: bool = false) -> Control:
	var list := focusables(root, include_internal)
	if list.is_empty():
		return null
	list[0].grab_focus()
	return list[0]


## Makes a vertical run of controls wrap: down from the last lands on the first
## and up from the first lands on the last. Without it the main menu simply
## stops dead at QUIT, which reads as "the input died".
## Both controls must already be inside the tree.
static func wrap_column(items: Array) -> void:
	var live: Array[Control] = []
	for it: Variant in items:
		var c := it as Control
		if c != null and c.visible and c.focus_mode == Control.FOCUS_ALL and not is_disabled(c):
			live.append(c)
	if live.size() < 2:
		return
	var first: Control = live[0]
	var last:  Control = live[live.size() - 1]
	if not (first.is_inside_tree() and last.is_inside_tree()):
		return
	first.focus_neighbor_top    = first.get_path_to(last)
	first.focus_previous        = first.get_path_to(last)
	last.focus_neighbor_bottom  = last.get_path_to(first)
	last.focus_next             = last.get_path_to(first)


## Gives an index-driven menu a mouse. `select` takes the button's index,
## `confirm` takes nothing, and `guard` (optional) returning false suppresses
## both — overlays that fade in need it so a click during the fade doesn't
## activate an entry the player cannot see yet.
static func wire_pointer(buttons: Array, select: Callable, confirm: Callable,
		guard: Callable = Callable()) -> void:
	for i in buttons.size():
		var btn := buttons[i] as BaseButton
		if btn == null:
			continue
		var idx: int = i
		btn.mouse_entered.connect(func() -> void:
			if guard.is_valid() and not bool(guard.call()):
				return
			select.call(idx))
		btn.pressed.connect(func() -> void:
			if guard.is_valid() and not bool(guard.call()):
				return
			select.call(idx)
			confirm.call())


# ── Analog stick ─────────────────────────────────────────────────────────────
# The D-pad and the keyboard arrive as discrete pressed/released events, which
# is what the index-driven menus listen for. A stick does not: it emits a stream
# of motion events while it moves and nothing at all while it is held still, so
# those menus simply ignored it and the left stick did nothing in any of them.
# Poll it per frame through AxisRepeat instead, which supplies the edge
# detection and the key-repeat the stick has no notion of.

## Strongest reading of `axis` across every connected pad, so it does not matter
## which controller the player picked up.
static func stick(axis: JoyAxis) -> float:
	var best: float = 0.0
	for dev: int in Input.get_connected_joypads():
		var v: float = Input.get_joy_axis(dev, axis)
		if absf(v) > absf(best):
			best = v
	return best


class AxisRepeat extends RefCounted:
	const DEADZONE:    float = 0.55
	const FIRST_DELAY: float = 0.40   # hold before it starts repeating
	const REPEAT:      float = 0.13   # and how fast once it does

	var _dir: int   = 0
	var _t:   float = 0.0

	## Steps to move this frame: -1, 0 or +1. Fires once the moment the stick
	## crosses the deadzone, then repeats while it stays there.
	func step(axis: float, delta: float) -> int:
		var d: int = 0
		if axis <= -DEADZONE:
			d = -1
		elif axis >= DEADZONE:
			d = 1
		if d == 0:
			_dir = 0
			_t   = 0.0
			return 0
		if d != _dir:
			_dir = d
			_t   = FIRST_DELAY
			return d
		_t -= delta
		if _t <= 0.0:
			_t = REPEAT
			return d
		return 0
