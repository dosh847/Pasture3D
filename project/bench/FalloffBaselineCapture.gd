# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# FalloffBaselineCapture — records Falloff's output BEFORE the shared distance-metric refactor
# (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §3.4 DM-A / DM-B).
#
# Run ONCE, on the pre-refactor build, and commit the JSON it writes. GraphDistanceMetricGate reads it and
# never regenerates it: a gate that rewrites its own baseline compares the new code with itself.
#
# What is stored is a SHA-256 of each case's output bytes, not the grids. The criterion is bit-identity, so
# a hash is the whole question, and 64 cases of 129x129 float32 per route would be megabytes of fixture.
# A handful of sampled cells is stored beside each hash, so a failure can say HOW FAR off it is, not only
# that it moved.
#
# WINDOWED for the GPU half. Headless, the GPU hashes are recorded as "" and the gate skips DM-B.
#   Godot_v4.7-stable_win64_console.exe --path project bench/FalloffBaselineCapture.tscn
extends Node

const OUT_PATH := "res://bench/fixtures/falloff_metric_baseline.json"
const Fixture := preload("res://bench/FalloffMetricFixture.gd")


func _ready() -> void:
	print("=== FalloffBaselineCapture ===")
	var fx := Fixture.new()
	var surf := fx.terrain()
	var gpu_live := not Pasture3DUtil.graph_eval_grid_gpu(fx.io_graph().compile_graph_program(),
			fx.GW, fx.GH, fx.RECT, surf).is_empty()
	print("    GPU route live: %s" % gpu_live)

	var cases := []
	for c in fx.cases():
		var prog := fx.graph(c).compile_graph_program()
		var cpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(prog, fx.GW, fx.GH, fx.RECT, surf)
		var gpu := PackedFloat32Array()
		if gpu_live:
			gpu = Pasture3DUtil.graph_eval_grid_gpu(prog, fx.GW, fx.GH, fx.RECT, surf)
		cases.append({
			"name": fx.case_name(c),
			"cfg": c,
			"cpu_sha": fx.sha(cpu),
			"gpu_sha": fx.sha(gpu) if not gpu.is_empty() else "",
			"cpu_samples": fx.samples(cpu),
			"gpu_samples": fx.samples(gpu) if not gpu.is_empty() else [],
		})

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://bench/fixtures"))
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		print("!! could not write %s" % OUT_PATH)
		get_tree().quit(1)
		return
	f.store_string(JSON.stringify({
		"gw": fx.GW, "gh": fx.GH, "rect": [fx.RECT.position.x, fx.RECT.position.y, fx.RECT.size.x, fx.RECT.size.y],
		"gpu_live": gpu_live,
		"cases": cases,
	}, "\t"))
	f.close()
	print("    wrote %d cases to %s" % [cases.size(), OUT_PATH])
	print("=== CAPTURE DONE ===")
	get_tree().quit(0)
