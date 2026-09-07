# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphPng — a minimal PNG encoder/decoder for the B2 export sinks.
# PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §9.2.
#
# ---- WHY THIS EXISTS AT ALL, GIVEN Image.save_png() ----
#
# Because `Image.save_png()` writes 8 bits per channel and nothing else. Measured 2026-09-07 on Godot
# 4.7: a 0.25..0.75 ramp saved from FORMAT_RGBAH, FORMAT_RGBAF, FORMAT_RF and FORMAT_RGBA8 all came back
# with a worst-case error of ~0.0039 — 1/255 — and all four reloaded as FORMAT_RGBA8. Godot converts to
# RGBA8 on the way out. So "png16" through that door is png8 wearing a different format enum, which is
# precisely the kind of plausible-looking downgrade §4.4 is about: the file opens, the image looks right,
# and a heightmap has quietly lost eight bits.
#
# §9.2 lists png16 for three of the five sinks and criterion [C] tests a png16 round-trip against a png8
# control. That criterion is only meaningful if the two actually differ, so the depth has to be real.
#
# ---- WHY ONE WRITER SERVES BOTH DEPTHS ----
#
# `encode` takes `p_depth` as a parameter and changes nothing else. So [C]'s png8 control differs from its
# png16 subject in exactly one integer, which is what makes the criterion measure BIT DEPTH rather than
# "one of these two writers is broken" (`check-derived-values-outside-the-chain`).
#
# ---- WHAT THIS IS NOT ----
#
# Not a general PNG library. It writes ONE shape — a single IDAT, filter type 0 (None) on every row, no
# interlacing, no palette, no ancillary chunks — and `decode` REFUSES anything else by name rather than
# guessing. We are the only writer its reader has to understand; a reader that quietly mishandled an
# Adam7 file would be worse than one that says it cannot read it.
#
# It is also not a second export path in §12.8's sense. `Pasture3DData::export_image` exports a REGION MAP
# by map type over the region bounds; a graph export sink writes an arbitrary tapped field over an
# arbitrary world rect at an arbitrary resolution, and `_save_export_image` is private and unbound. The
# format DISPATCH in `graph_export_sinks.gd` mirrors that function deliberately (r16 by hand, exr and png
# through the format writers) so the two agree about what an extension means.
@tool
class_name Pasture3DGraphPng
extends RefCounted

## The 8-byte PNG signature. `static var`, not `const`: a PackedByteArray literal is not a constant
## expression in GDScript, and the compiler says so by name.
static var SIGNATURE := PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10])

static var _crc_table: PackedInt64Array = PackedInt64Array()


## Encode normalised samples as a PNG. `p_samples` is interleaved by channel, `p_channels` is 1
## (greyscale) or 4 (RGBA), `p_depth` is 8 or 16. Values are clamped to [0,1] — the CALLER owns the
## range that maps a field onto that interval, and writes it to the sidecar; see
## `calibration-constants-must-be-stored-not-printed`. Returns an empty array on bad arguments.
static func encode(p_samples: PackedFloat32Array, p_w: int, p_h: int, p_channels: int,
		p_depth: int) -> PackedByteArray:
	if p_w <= 0 or p_h <= 0 or (p_channels != 1 and p_channels != 4) or (p_depth != 8 and p_depth != 16):
		return PackedByteArray()
	if p_samples.size() != p_w * p_h * p_channels:
		return PackedByteArray()
	var max_val: float = 255.0 if p_depth == 8 else 65535.0
	var bpp: int = p_channels * (p_depth / 8)
	var raw := PackedByteArray()
	raw.resize(p_h * (1 + p_w * bpp))
	var o := 0
	for y in range(p_h):
		raw[o] = 0 # Filter type 0 (None), every row. `decode` asserts this rather than un-filtering.
		o += 1
		var row := y * p_w * p_channels
		for i in range(p_w * p_channels):
			var v: int = int(round(clampf(p_samples[row + i], 0.0, 1.0) * max_val))
			if p_depth == 8:
				raw[o] = v
				o += 1
			else:
				raw[o] = (v >> 8) & 0xFF # PNG is big-endian.
				raw[o + 1] = v & 0xFF
				o += 2

	var out := PackedByteArray()
	out.append_array(SIGNATURE)
	var ihdr := PackedByteArray()
	_be32(ihdr, p_w)
	_be32(ihdr, p_h)
	ihdr.append(p_depth)
	ihdr.append(0 if p_channels == 1 else 6) # colour type: 0 greyscale, 6 RGBA
	ihdr.append_array(PackedByteArray([0, 0, 0])) # deflate / filter method 0 / no interlace
	_chunk(out, "IHDR", ihdr)
	_chunk(out, "IDAT", _zlib(raw))
	_chunk(out, "IEND", PackedByteArray())
	return out


## Read back a PNG this encoder wrote. Returns {"w","h","channels","depth","samples"} with samples
## normalised to [0,1], or {"error": String}. Refuses by name anything outside the shape `encode`
## produces — see the header.
static func decode(p_bytes: PackedByteArray) -> Dictionary:
	if p_bytes.size() < 8 or p_bytes.slice(0, 8) != SIGNATURE:
		return {"error": "not a PNG (signature mismatch)"}
	var pos := 8
	var w := 0
	var h := 0
	var depth := 0
	var channels := 0
	var idat := PackedByteArray()
	while pos + 8 <= p_bytes.size():
		var len_ := _rd32(p_bytes, pos)
		var tag := p_bytes.slice(pos + 4, pos + 8).get_string_from_ascii()
		var body := p_bytes.slice(pos + 8, pos + 8 + len_)
		pos += 12 + len_
		match tag:
			"IHDR":
				w = _rd32(body, 0)
				h = _rd32(body, 4)
				depth = body[8]
				var ctype: int = body[9]
				if ctype == 0:
					channels = 1
				elif ctype == 6:
					channels = 4
				else:
					return {"error": "colour type %d is not one this reader writes (0 or 6)" % ctype}
				if body[12] != 0:
					return {"error": "interlaced PNGs are not read here"}
			"IDAT":
				idat.append_array(body)
			"IEND":
				break
	if w <= 0 or h <= 0 or (depth != 8 and depth != 16):
		return {"error": "unsupported header: %dx%d at %d bpc" % [w, h, depth]}
	var bpp: int = channels * (depth / 8)
	var raw := _unzlib(idat, h * (1 + w * bpp))
	if raw.size() < h * (1 + w * bpp):
		return {"error": "the pixel data did not inflate to the size the header declares"}
	var max_val: float = 255.0 if depth == 8 else 65535.0
	var samples := PackedFloat32Array()
	samples.resize(w * h * channels)
	var o := 0
	for y in range(h):
		if raw[o] != 0:
			# Refused rather than un-filtered: see the header. A wrong un-filter is silent and looks
			# like noise in the data, which is the failure mode hardest to attribute.
			return {"error": "row %d uses filter %d; only filter 0 is read here" % [y, raw[o]]}
		o += 1
		var row := y * w * channels
		for i in range(w * channels):
			if depth == 8:
				samples[row + i] = float(raw[o]) / max_val
				o += 1
			else:
				samples[row + i] = float((raw[o] << 8) | raw[o + 1]) / max_val
				o += 2
	return {"w": w, "h": h, "channels": channels, "depth": depth, "samples": samples}


static func _be32(p_out: PackedByteArray, p_v: int) -> void:
	p_out.append((p_v >> 24) & 0xFF)
	p_out.append((p_v >> 16) & 0xFF)
	p_out.append((p_v >> 8) & 0xFF)
	p_out.append(p_v & 0xFF)


static func _rd32(p_b: PackedByteArray, p_at: int) -> int:
	return (p_b[p_at] << 24) | (p_b[p_at + 1] << 16) | (p_b[p_at + 2] << 8) | p_b[p_at + 3]


static func _chunk(p_out: PackedByteArray, p_tag: String, p_body: PackedByteArray) -> void:
	_be32(p_out, p_body.size())
	var tagged := p_tag.to_ascii_buffer()
	tagged.append_array(p_body)
	p_out.append_array(tagged)
	_be32(p_out, crc32(tagged))


## Godot's COMPRESSION_DEFLATE is RAW deflate (negative windowBits), which is exactly what a zlib stream
## carries between its 2-byte header and its trailing Adler-32. So a zlib stream is three concatenations,
## not a different compressor.
static func _zlib(p_raw: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([0x78, 0x01])
	out.append_array(p_raw.compress(FileAccess.COMPRESSION_DEFLATE))
	var a: int = 1
	var b: int = 0
	for byte in p_raw:
		a = (a + byte) % 65521
		b = (b + a) % 65521
	_be32(out, (b << 16) | a)
	return out


static func _unzlib(p_z: PackedByteArray, p_expect: int) -> PackedByteArray:
	if p_z.size() < 6:
		return PackedByteArray()
	return p_z.slice(2, p_z.size() - 4).decompress_dynamic(p_expect + 64, FileAccess.COMPRESSION_DEFLATE)


## CRC-32 as PNG specifies it.
static func crc32(p_bytes: PackedByteArray) -> int:
	if _crc_table.is_empty():
		_crc_table.resize(256)
		for n in range(256):
			var c: int = n
			for _k in range(8):
				c = (0xEDB88320 ^ (c >> 1)) if (c & 1) != 0 else (c >> 1)
			_crc_table[n] = c
	var crc: int = 0xFFFFFFFF
	for byte in p_bytes:
		crc = _crc_table[(crc ^ byte) & 0xFF] ^ (crc >> 8)
	return crc ^ 0xFFFFFFFF
