# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# TestColorPreviewGate — Verification gate for ConstColor, ColorMix, and ColorBlend preview thumbnails.
#
# house discipline:
#   [A] ConstColor renders a solid square of its Value color + hex range chip (#RRGGBB / #RRGGBBAA).
#   [B] ColorMix renders a folded solid square color across modes + mode & hex range chip (MIX #RRGGBB).
#   [C] ColorBlend with unwired mask falls back to uniform color preview + 'BLEND (unwired)' chip.
#   [D] ColorBlend with wired mask piggybacks mask into background tap and renders a 2D blended color field.
#   [E] Nested ColorBlend chaining (ColorBlend A -> ColorBlend B) evaluates in topological order.
#   [F] Spec contract: PortType.COLOR declines scalar grid repr and static helpers produce correct RGBA8 images.
extends Node

const GraphEditorScript = preload("res://addons/pasture_3d/src/graph_editor.gd")

var _fail := 0
var _checks := 0


func _ready() -> void:
	print("=== TestColorPreviewGate: ConstColor, ColorMix, and ColorBlend Previews ===\n")
	_f_spec_and_static_helpers()
	_a_const_color_preview()
	_b_color_mix_preview()
	_c_color_blend_unwired()
	await _d_color_blend_wired_mask()
	await _e_nested_color_blend()

	print("\n=== %s (%d failures, %d checks) ===\n"
			% ["COLOR PREVIEW PASS" if _fail == 0 else "COLOR PREVIEW FAIL", _fail, _checks])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	_checks += 1
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])


func _panel():
	var ed = GraphEditorScript.new()
	add_child(ed)
	ed.initialize(null)
	return ed


func _connect(p_g: Pasture3DTerrainGraph, p_from: int, p_from_port: int, p_to: int, p_to_port: int) -> void:
	p_g.connections.append(PackedInt32Array([p_from, p_from_port, p_to, p_to_port]))


# --- F -------------------------------------------------------------------------------------------------
func _f_spec_and_static_helpers() -> void:
	print("[F] Spec contract: PortType.COLOR declines scalar grid repr and static helpers")

	# Criterion: COLOR is a sideband type with no scalar grid repr
	var repr_color: int = GraphEditorScript.preview_repr_for_type(Pasture3DGraphNode.PortType.COLOR)
	_check(repr_color < 0, "[F1] PortType.COLOR declines scalar grid repr (got %d, expected < 0)" % repr_color)

	# Static helper: solid color opaque
	var solid_red := GraphEditorScript.preview_image_solid_color(Color.RED, 16, 16)
	_check(solid_red != null and solid_red.get_width() == 16 and solid_red.get_height() == 16,
			"[F2] preview_image_solid_color returns valid 16x16 Image")
	_check(solid_red.get_pixel(0, 0) == Color.RED and solid_red.get_pixel(8, 8) == Color.RED,
			"[F2] solid opaque Image is entirely Color.RED")

	# Static helper: transparent color alpha composites over checkerboard
	var semi_red := GraphEditorScript.preview_image_solid_color(Color(1.0, 0.0, 0.0, 0.5), 16, 16)
	_check(semi_red != null and semi_red.get_width() == 16, "[F3] transparent preview image generated")
	var p_dark: Color = semi_red.get_pixel(0, 0)
	var p_light: Color = semi_red.get_pixel(8, 0)
	_check(p_dark != p_light, "[F3] alpha < 1.0 composites over alternating checkerboard tiles")
	_check(p_dark.a == 1.0 and p_light.a == 1.0, "[F3] output image is fully opaque RGBA8")


# --- A -------------------------------------------------------------------------------------------------
func _a_const_color_preview() -> void:
	print("\n[A] ConstColor renders solid square + #RRGGBB chip")

	var g := Pasture3DTerrainGraph.new()
	var c_node := Pasture3DGraphNodeConstColor.new()
	c_node.value = Color(0.2, 0.8, 0.4, 1.0)
	c_node.preview_on = true
	g.add_node(c_node, Vector2.ZERO)

	var ed = _panel()
	ed.edit_graph(g, null, null)
	ed._refresh_previews()

	_check(int(ed.last_preview_taps.get("color_count", 0)) == 1,
			"[A1] ConstColor is counted in color_count (got %d)" % int(ed.last_preview_taps.get("color_count", 0)))
	_check(int(ed.last_preview_taps.get("count", -1)) == 0,
			"[A1] ConstColor requests ZERO grid taps (count=%d)" % int(ed.last_preview_taps.get("count", -1)))

	var tr: TextureRect = ed._preview_rects.get(0)
	_check(tr != null and tr.texture != null, "[A2] TextureRect received ImageTexture")
	if tr != null and tr.texture != null:
		var img: Image = tr.texture.get_image()
		_check(img != null and img.get_width() == GraphEditorScript.PREVIEW_SIZE,
				"[A2] preview image is PREVIEW_SIZE (%d px)" % img.get_width())
		var px_col: Color = img.get_pixel(0, 0)
		_check(absf(px_col.r - 0.2) < 0.02 and absf(px_col.g - 0.8) < 0.02 and absf(px_col.b - 0.4) < 0.02,
				"[A2] pixel color matches node value (got %s, expected %s)" % [px_col, c_node.value])

	var chip: Button = ed._preview_chips.get(0)
	_check(chip != null and chip.text.begins_with("#"),
			"[A3] range chip displays hex code: '%s'" % (chip.text if chip != null else ""))
	var expected_hex := "#%s" % c_node.value.to_html(false).to_upper()
	_check(chip != null and chip.text == expected_hex,
			"[A3] chip text '%s' matches expected '%s'" % [chip.text if chip != null else "", expected_hex])

	ed.queue_free()


# --- B -------------------------------------------------------------------------------------------------
func _b_color_mix_preview() -> void:
	print("\n[B] ColorMix renders folded solid square + mode & hex chip")

	var g := Pasture3DTerrainGraph.new()
	var c1 := Pasture3DGraphNodeConstColor.new()
	c1.value = Color(1.0, 0.0, 0.0, 1.0) # Red
	var c2 := Pasture3DGraphNodeConstColor.new()
	c2.value = Color(0.0, 0.0, 1.0, 1.0) # Blue
	var mix := Pasture3DGraphNodeColorMix.new()
	mix.mode = Pasture3DGraphNodeColorMix.Mode.MIX
	mix.factor = 0.5
	mix.preview_on = true

	g.add_node(c1, Vector2(0, 0))
	g.add_node(c2, Vector2(0, 100))
	g.add_node(mix, Vector2(200, 50))
	_connect(g, 0, 0, 2, 0) # c1 -> mix port a
	_connect(g, 1, 0, 2, 1) # c2 -> mix port b

	var ed = _panel()
	ed.edit_graph(g, null, null)
	ed._refresh_previews()

	_check(int(ed.last_preview_taps.get("color_count", 0)) == 1,
			"[B1] ColorMix counted in color_count (got %d)" % int(ed.last_preview_taps.get("color_count", 0)))
	_check(int(ed.last_preview_taps.get("count", -1)) == 0,
			"[B1] ColorMix requests ZERO grid taps (count=%d)" % int(ed.last_preview_taps.get("count", -1)))

	var tr: TextureRect = ed._preview_rects.get(2)
	_check(tr != null and tr.texture != null, "[B2] ColorMix TextureRect received ImageTexture")
	if tr != null and tr.texture != null:
		var img: Image = tr.texture.get_image()
		var col: Color = img.get_pixel(10, 10)
		_check(absf(col.r - 0.5) < 0.02 and absf(col.b - 0.5) < 0.02 and absf(col.g - 0.0) < 0.02,
				"[B2] 50%% mix of red and blue is purple (got %s)" % col)

	var chip: Button = ed._preview_chips.get(2)
	_check(chip != null and chip.text.begins_with("MIX #"),
			"[B3] chip text begins with mode 'MIX #' (got '%s')" % (chip.text if chip != null else ""))

	# Test ADD mode
	mix.mode = Pasture3DGraphNodeColorMix.Mode.ADD
	ed._refresh_previews()
	var chip_add: Button = ed._preview_chips.get(2)
	_check(chip_add != null and chip_add.text.begins_with("ADD #"),
			"[B4] mode change to ADD reflects on chip: '%s'" % (chip_add.text if chip_add != null else ""))

	ed.queue_free()


# --- C -------------------------------------------------------------------------------------------------
func _c_color_blend_unwired() -> void:
	print("\n[C] ColorBlend with unwired mask falls back to uniform preview + 'BLEND (unwired)' chip")

	var g := Pasture3DTerrainGraph.new()
	var blend := Pasture3DGraphNodeColorBlend.new()
	blend.color_a = Color(0.1, 0.8, 0.3, 1.0)
	blend.color_b = Color(0.9, 0.2, 0.1, 1.0)
	blend.preview_on = true
	g.add_node(blend, Vector2.ZERO)

	var ed = _panel()
	ed.edit_graph(g, null, null)
	ed._refresh_previews()

	_check(int(ed.last_preview_taps.get("count", -1)) == 0,
			"[C1] unwired ColorBlend requests ZERO grid taps (count=%d)" % int(ed.last_preview_taps.get("count", -1)))

	var tr: TextureRect = ed._preview_rects.get(0)
	_check(tr != null and tr.texture != null, "[C2] unwired ColorBlend received ImageTexture")
	if tr != null and tr.texture != null:
		var img: Image = tr.texture.get_image()
		var col: Color = img.get_pixel(10, 10)
		_check(absf(col.r - 0.1) < 0.02 and absf(col.g - 0.8) < 0.02,
				"[C2] unwired blend falls back to Color A (got %s)" % col)

	var chip: Button = ed._preview_chips.get(0)
	_check(chip != null and chip.text == "BLEND (unwired)",
			"[C3] unwired blend chip text says 'BLEND (unwired)' (got '%s')" % (chip.text if chip != null else ""))

	ed.queue_free()


# --- D -------------------------------------------------------------------------------------------------
func _d_color_blend_wired_mask() -> void:
	print("\n[D] ColorBlend with wired mask piggybacks tap and renders 2D blended field")

	var g := Pasture3DTerrainGraph.new()
	# Node 0: Noise generator to feed mask
	var fnl := FastNoiseLite.new()
	fnl.seed = 42
	fnl.frequency = 0.08
	var noise := Pasture3DGraphNodeNoise.new()
	noise.noise = fnl
	noise.amplitude = 1.0
	g.add_node(noise, Vector2(0, 0))

	# Node 1: ConstColor Red
	var c1 := Pasture3DGraphNodeConstColor.new()
	c1.value = Color.RED
	g.add_node(c1, Vector2(0, 100))

	# Node 2: ConstColor Blue
	var c2 := Pasture3DGraphNodeConstColor.new()
	c2.value = Color.BLUE
	g.add_node(c2, Vector2(0, 200))

	# Node 3: ColorBlend
	var blend := Pasture3DGraphNodeColorBlend.new()
	blend.mode = Pasture3DGraphNodeColorBlend.Mode.MIX
	blend.strength = 1.0
	blend.preview_on = true
	g.add_node(blend, Vector2(250, 100))

	_connect(g, 1, 0, 3, 0) # c1 -> blend port a (Color)
	_connect(g, 2, 0, 3, 1) # c2 -> blend port b (Color)
	_connect(g, 0, 0, 3, 2) # noise -> blend port mask (Mask)

	var ed = _panel()
	ed.edit_graph(g, null, null)
	ed._refresh_previews()

	# Assert that the mask slot from Node 0 was piggybacked into tap_slots!
	_check(int(ed.last_preview_taps.get("count", -1)) == 1,
			"[D1] ColorBlend piggybacks mask node into tap_slots (count=%d, expected 1)"
			% int(ed.last_preview_taps.get("count", -1)))

	# Deterministically wait for background worker thread and call_deferred to complete
	var token: int = ed._preview_token
	var safety := 0
	while ed.last_preview_applied < token and safety < 200:
		await get_tree().process_frame
		safety += 1

	var tr: TextureRect = ed._preview_rects.get(3)
	_check(tr != null and tr.texture != null, "[D2] wired ColorBlend received ImageTexture after worker apply")
	if tr != null and tr.texture != null:
		var img: Image = tr.texture.get_image()
		_check(img != null and img.get_width() == GraphEditorScript.PREVIEW_SIZE,
				"[D2] blended image is full PREVIEW_SIZE (%d px)" % img.get_width())

		var varied := false
		var first_col: Color = img.get_pixel(0, 0)
		for y in range(0, img.get_height(), 16):
			for x in range(0, img.get_width(), 16):
				var c: Color = img.get_pixel(x, y)
				if absf(c.r - first_col.r) > 0.05 or absf(c.b - first_col.b) > 0.05:
					varied = true
					break
			if varied:
				break
		_check(varied, "[D3] ColorBlend produced a non-flat 2D blended color thumbnail across the domain")

	var chip: Button = ed._preview_chips.get(3)
	_check(chip != null and chip.text == "BLEND MIX",
			"[D4] chip text displays 'BLEND MIX' (got '%s')" % (chip.text if chip != null else ""))

	ed.queue_free()


# --- E -------------------------------------------------------------------------------------------------
func _e_nested_color_blend() -> void:
	print("\n[E] Nested ColorBlend chaining evaluates in topological order")

	var g := Pasture3DTerrainGraph.new()
	var fnl := FastNoiseLite.new()
	fnl.seed = 99
	var noise := Pasture3DGraphNodeNoise.new()
	noise.noise = fnl
	noise.amplitude = 1.0
	g.add_node(noise, Vector2(0, 0)) # Node 0

	var c_green := Pasture3DGraphNodeConstColor.new()
	c_green.value = Color.GREEN
	g.add_node(c_green, Vector2(0, 100)) # Node 1

	var c_brown := Pasture3DGraphNodeConstColor.new()
	c_brown.value = Color(0.6, 0.3, 0.1)
	g.add_node(c_brown, Vector2(0, 200)) # Node 2

	var c_white := Pasture3DGraphNodeConstColor.new()
	c_white.value = Color.WHITE
	g.add_node(c_white, Vector2(0, 300)) # Node 3

	# Blend 1: Green + Brown masked by Noise
	var blend1 := Pasture3DGraphNodeColorBlend.new()
	blend1.preview_on = true
	g.add_node(blend1, Vector2(250, 100)) # Node 4
	_connect(g, 1, 0, 4, 0)
	_connect(g, 2, 0, 4, 1)
	_connect(g, 0, 0, 4, 2)

	# Blend 2: Blend 1 + White (snow) masked by Noise
	var blend2 := Pasture3DGraphNodeColorBlend.new()
	blend2.preview_on = true
	g.add_node(blend2, Vector2(450, 150)) # Node 5
	_connect(g, 4, 0, 5, 0) # Blend 1 into port a
	_connect(g, 3, 0, 5, 1) # White into port b
	_connect(g, 0, 0, 5, 2) # Noise into mask

	var ed = _panel()
	ed.edit_graph(g, null, null)
	ed._refresh_previews()

	var token: int = ed._preview_token
	var safety := 0
	while ed.last_preview_applied < token and safety < 200:
		await get_tree().process_frame
		safety += 1

	var tr4: TextureRect = ed._preview_rects.get(4)
	var tr5: TextureRect = ed._preview_rects.get(5)
	_check(tr4 != null and tr4.texture != null and tr5 != null and tr5.texture != null,
			"[E1] both nested ColorBlend nodes received ImageTextures")

	if tr5 != null and tr5.texture != null:
		var img5: Image = tr5.texture.get_image()
		var varied5 := false
		var first_col5: Color = img5.get_pixel(0, 0)
		for y in range(0, img5.get_height(), 8):
			for x in range(0, img5.get_width(), 8):
				var c: Color = img5.get_pixel(x, y)
				if absf(c.r - first_col5.r) > 0.05 or absf(c.g - first_col5.g) > 0.05:
					varied5 = true
					break
			if varied5:
				break
		_check(varied5, "[E2] downstream ColorBlend receives per-cell upstream colors in topological order")

	ed.queue_free()
