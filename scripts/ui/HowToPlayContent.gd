class_name HowToPlayContent
extends RefCounted

## The game-rules part of HOW TO PLAY, shared by the tutorial screen
## (scripts/HowToPlay.gd) and the main menu's HOW TO PLAY panel
## (scenes/Main.gd). Both used to carry their own copy of these sections and
## both drifted out of date with the game, so the text lives here once.
##
## Each screen keeps its own look and its own controls table; it passes in its
## own section-heading and row builders and this fills in everything else.
## Numbers that come from settings (lives per song, the grind button) are read
## live, so they always match what the player has set.
##
##   section.call(parent, text, s)
##   row.call(parent, key, desc, s)


## The opening paragraph.
static func intro() -> String:
	return ("Echoes in my Blood is a neon rhythm runner. Meeko runs forward on his own "
		+ "down a track built from the song, and every obstacle lands on a beat of the "
		+ "music. Change lanes, jump, slide, grind, wall-jump and smash your way through "
		+ "in time with it to build your combo and keep your health up.")


## Everything after the controls: gates, the special moves, smash gates,
## electric zones, scoring and modes.
static func build(vbox: VBoxContainer, s: float, section: Callable, row: Callable) -> void:
	var grind_key: String = GameConfig.key_name("runner_grind")
	var jump_key: String = GameConfig.key_name("runner_jump")
	var wj_keys: String = "%s / %s" % [GameConfig.key_name("runner_lb"), GameConfig.key_name("runner_rb")]

	var g: VBoxContainer = _group(vbox, s, section, "GATES")
	row.call(g, "Lane gate",   "An arch over one lane — be in that lane when the beat hits", s)
	row.call(g, "Jump gate",   "A low barrier — be in its lane and in the air on the beat", s)
	row.call(g, "Slide gate",  "A high bar — be in its lane and sliding on the beat", s)
	row.call(g, "Patterns",    "Gates come in dozens of patterns fitted to each part of the song; "
		+ "fast passages get simpler ones so they stay readable", s)

	g = _group(vbox, s, section, "GRIND RAILS")
	row.call(g, "When",              "During rap sections — a glowing rail along the left of the track", s)
	row.call(g, "Hold " + grind_key, "Ride the rail", s)
	row.call(g, "Tap " + jump_key,   "Catch each spark on the beat — 750 pts each", s)
	row.call(g, "Flow",              "Sparks in a row build a flow multiplier up to ×8 · "
		+ "catch every spark on a rail for +5,000", s)
	row.call(g, "Careful",           "Miss 3 sparks in a row and you fall off the rail", s)

	g = _group(vbox, s, section, "WALL JUMPS")
	row.call(g, "Rare",         "At most one per song, and not every song has one", s)
	row.call(g, wj_keys,        "Kick off toward the next wall on the beat to climb up", s)
	row.call(g, "×2 bonus",     "Your multiplier is doubled for the whole climb", s)
	row.call(g, "Descent ramp", "One ramp back down, in a random lane — ride it and tap the "
		+ "sparks on its deck to the beat", s)

	g = _group(vbox, s, section, "⚡  CHARGE TUNNEL  →  ×100 OVERDRIVE")
	row.call(g, "Hold " + grind_key,     "Appears in a build-up before a drop — slide freely and steer "
		+ "left/right through the hoops", s)
	row.call(g, "Stay threaded",         "Lined up with the hoop fills your charge; clipping the edge drains it", s)
	row.call(g, "Let go early",          "The charge drains away — don't let go before the drop", s)
	row.call(g, "Release on drop",       "×100 OVERDRIVE — the fuller the charge, the longer it lasts", s)
	row.call(g, "In OVERDRIVE",          "A missed gate scores nothing but costs no health or combo", s)

	g = _group(vbox, s, section, "SMASH GATES")
	row.call(g, "The wall",        "A wall across all three lanes where the beats come too fast to tap "
		+ "— you can't dodge it, you break it", s)
	row.call(g, "GET READY",       "Shows one beat before it starts; then Meeko is held in the middle lane", s)
	row.call(g, "Mash",            "Mash any button to reach the target before the wall — the target comes from how many hits "
		+ "the drum roll has", s)
	row.call(g, "Beat target",     "No damage, and every extra press is OVERCHARGE: bonus score and up "
		+ "to 5 HP back", s)
	row.call(g, "Hit it exactly",  "Costs 2 HP", s)
	row.call(g, "Fall short",      "Costs up to 50 HP — less harsh on long rolls", s)
	row.call(g, "Read your pace",  "The light along the track edges fills toward the wall as fast as you "
		+ "mash — if it's ahead of you, you're ahead of pace", s)
	row.call(g, "After the wall",  "The first gate after a smash wall is always in the middle lane", s)

	g = _group(vbox, s, section, "ELECTRIC ZONES")
	row.call(g, "Blackout",      "Parts of a song where the power goes out and gates become live fences", s)
	row.call(g, "Double points", "Each gate is worth 1,000 instead of 500", s)
	row.call(g, "No healing",    "Clearing gates doesn't heal you inside a zone", s)
	row.call(g, "Miss",          "Electrocutes you — the lights flash back on for a moment, then it "
		+ "goes dark again", s)

	g = _group(vbox, s, section, "SCORING & HEALTH")
	row.call(g, "Gate hit",             "+500 pts × multiplier  (+1,000 in electric zones)", s)
	row.call(g, "Timing",               "PERFECT +50 %  ·  GREAT +20 %  ·  GOOD  —  be at the top of your jump, "
		+ "mid-slide or in the lane right as the beat hits", s)
	row.call(g, "Multiplier",           "+1 every 10 combo, up to ×20  ·  ×2 on a wall-jump climb  ·  "
		+ "×100 in OVERDRIVE", s)
	row.call(g, "Health",               "Starts at 25 %  ·  +5 % per gate (not in zones)  ·  –10 % per miss (–7.5 % in "
		+ "zones)  ·  0 % = wipe", s)
	row.call(g, "FEVER",                "PERFECTs fill the FEVER meter (a miss halves it)  ·  when it's full: "
		+ "7 seconds of ×2 score and golden gates", s)
	row.call(g, "Shields",              "Pick up the floating hex before a hard stretch  ·  it takes one miss: "
		+ "combo and health survive  ·  hold up to 2", s)
	row.call(g, "Near miss",            "+50 pts when you only just missed", s)
	row.call(g, "Lives",                "%d per song — when they're gone, a new layout is rolled"
		% GameConfig.lives_per_song, s)
	row.call(g, "Letter grade",         "S = no misses  ·  A 90 %+  ·  B 75 %+  ·  C 60 %+  ·  then D and F", s)
	row.call(g, "Results",              "Each section — gates, rails, wall jumps, charge, smash — gets its own "
		+ "grade and remembers your best  ·  your best moment replays behind it", s)

	g = _group(vbox, s, section, "MODES")
	row.call(g, "Story Mode", "Travel the city map — clearing a level reveals the next rift", s)
	row.call(g, "Freeplay",   "Pick any song from the list", s)
	row.call(g, "Tutorial",   "A fixed, hand-made layout — learn the mechanics", s)
	row.call(g, "Seeded",     "The same gate layout every time for a song", s)
	row.call(g, "Random",     "A fresh layout every attempt", s)
	row.call(g, "Practice",   "P / Y in the song list  ·  pick a part, slow it down, loop it  ·  "
		+ "nothing is saved and you can't fail", s)


static func _group(vbox: VBoxContainer, s: float, section: Callable, title: String) -> VBoxContainer:
	section.call(vbox, title, s)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", int(7 * s))
	vbox.add_child(box)
	return box
