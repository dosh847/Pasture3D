# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DSurfaceInfo — physics telemetry and surface properties for vehicle tyre interaction.
# Carried by Pasture3DRoadType, attached to chunk colliders as metadata (&"pasture3d_surface"),
# and queried by vehicle physics raycasts/shapecasts. See PASTURE3D_ROAD_SIMCADE_UPGRADE_SPEC.md §3.8.
@tool
class_name Pasture3DSurfaceInfo
extends Resource

## The physics surface identifier (&"tarmac", &"gravel", &"dirt", &"snow").
@export var surface_id: StringName = &"tarmac":
	set(v):
		surface_id = v
		emit_changed()

## Longitudinal tyre grip coefficient (Pacejka / peak friction multiplier).
@export var friction_longitudinal: float = 1.05:
	set(v):
		friction_longitudinal = maxf(v, 0.01)
		emit_changed()

## Lateral tyre cornering grip coefficient.
@export var friction_lateral: float = 1.00:
	set(v):
		friction_lateral = maxf(v, 0.01)
		emit_changed()

## Rolling resistance coefficient (drag on coasting wheels).
@export var rolling_resistance: float = 0.015:
	set(v):
		rolling_resistance = maxf(v, 0.0)
		emit_changed()

## High-frequency micro-bump displacement amplitude in metres.
@export var roughness_amplitude: float = 0.002:
	set(v):
		roughness_amplitude = maxf(v, 0.0)
		emit_changed()

## Micro-bump frequency (chatter wavelength) in Hz at 100 km/h.
@export var roughness_frequency: float = 18.0:
	set(v):
		roughness_frequency = maxf(v, 0.0)
		emit_changed()

## Audio surface tag for sound effects (e.g. &"asphalt", &"gravel", &"dirt", &"kerb", &"grass").
@export var audio_surface_type: StringName = &"asphalt":
	set(v):
		audio_surface_type = v
		emit_changed()

## Visual particle FX tag for tyre smoke, dust, gravel roost, water spray.
@export var particle_effect_type: StringName = &"tire_smoke":
	set(v):
		particle_effect_type = v
		emit_changed()
