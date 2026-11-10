# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Writes the golden program fingerprints `GraphPortDescriptorGate` [B] compares against.
#
# Run it ONLY when a change to what a node lowers to is intended, and read the diff before keeping it.
# A path after `--` writes THERE and leaves the golden alone.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project --script bench/GraphPortProgramsWrite.gd
extends SceneTree

const Programs := preload("res://bench/GraphPortPrograms.gd")


func _init() -> void:
	var rows := Programs.table()
	var args := OS.get_cmdline_user_args()
	var target: String = args[0] if args.size() > 0 else Programs.GOLDEN
	var f := FileAccess.open(target, FileAccess.WRITE)
	if f == null:
		printerr("GraphPortProgramsWrite: cannot open %s" % target)
		quit(1)
		return
	f.store_string("\n".join(rows) + "\n")
	f.close()
	var lowered := 0
	for r in rows:
		if not r.ends_with("|none"):
			lowered += 1
	print("GraphPortProgramsWrite: %d rows, %d lowered -> %s" % [rows.size(), lowered, target])
	quit(0)
