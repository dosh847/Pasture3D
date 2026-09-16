extends SceneTree
# Throwaway probe: render the CURRENT massing and a candidate one as hillshaded PNGs, so "does it look like
# a mountain" can be answered by looking. Not a gate; delete after.

const N := 256
const OUT := "user://dla_look"


func _shade(p_label: String, h: PackedFloat32Array, n: int, p_file: String) -> void:
	var peak := 0.0
	for v in h:
		peak = maxf(peak, v)
	if peak <= 0.0:
		print("%s EMPTY" % p_label)
		return
	# Hillshade: sun low in the north-west, height exaggerated so ridges read.
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	var ex := 3.0 * float(n) / 256.0
	for y in range(n):
		for x in range(n):
			var l := h[y * n + maxi(x - 1, 0)] / peak
			var r := h[y * n + mini(x + 1, n - 1)] / peak
			var u := h[maxi(y - 1, 0) * n + x] / peak
			var d := h[mini(y + 1, n - 1) * n + x] / peak
			var nx := (l - r) * ex
			var ny := (u - d) * ex
			var inv := 1.0 / sqrt(nx * nx + ny * ny + 1.0)
			var lit := clampf((nx * -0.57 + ny * -0.57 + 0.59) * inv, 0.0, 1.0)
			var base := 0.25 + 0.75 * (h[y * n + x] / peak)
			var c := clampf(0.15 + 0.95 * lit * base, 0.0, 1.0)
			img.set_pixel(x, y, Color(c, c * 0.98, c * 0.92))
	img.save_png(p_file)
	# Ring profile, to keep the picture honest.
	var sum := PackedFloat64Array(); sum.resize(8)
	var cnt := PackedInt32Array(); cnt.resize(8)
	for y in range(n):
		for x in range(n):
			var uu := (float(x) + 0.5) / n * 2.0 - 1.0
			var vv := (float(y) + 0.5) / n * 2.0 - 1.0
			var b := clampi(int(sqrt(uu * uu + vv * vv) * 8.0), 0, 7)
			sum[b] += h[y * n + x]; cnt[b] += 1
	var line := "%-22s rings:" % p_label
	for b in range(8):
		line += " %.3f" % (sum[b] / maxf(float(cnt[b]), 1.0) / peak)
	print("%s  -> %s" % [line, p_file])


## Path length from each node to its root. Parents can point FORWARD (an upscale re-points a node at a
## midpoint appended later), so this walks and memoises instead of sweeping backwards.
func _depths(parents: PackedInt32Array) -> PackedInt32Array:
	var count := parents.size()
	var d := PackedInt32Array(); d.resize(count); d.fill(-1)
	var stack := PackedInt32Array()
	for i in range(count):
		if d[i] >= 0:
			continue
		stack.clear()
		var j := i
		while j >= 0 and j < count and d[j] < 0:
			stack.append(j)
			d[j] = -2 # on the stack, so a cycle cannot spin forever
			j = parents[j]
		var base := 0 if (j < 0 or j >= count or d[j] < 0) else d[j]
		for k in range(stack.size() - 1, -1, -1):
			base += 1
			d[stack[k]] = base
	return d


## SLOPE-LIMITED cones: every node paints a cone of the SAME large radius, so neighbouring cones merge into
## continuous slopes and a valley forms wherever two ridges' cones meet. A cone whose radius shrinks with
## the node's own height instead paints one bump per node, which is the cauliflower.
func _cones(cluster: Array, n: int, p_radius: float, p_shape: float) -> PackedFloat32Array:
	var xs: PackedFloat32Array = cluster[0]
	var ys: PackedFloat32Array = cluster[1]
	var parents: PackedInt32Array = cluster[2]
	var d := _depths(parents)
	var dmax := 1
	for v in d:
		dmax = maxi(dmax, v)
	var out := PackedFloat32Array(); out.resize(n * n)
	var count := xs.size()
	var ri := maxf(2.0, p_radius)
	for i in range(count):
		var hi := pow(1.0 - float(d[i]) / float(dmax + 1), p_shape)
		var pa := parents[i]
		var steps := 1
		var dx := 0.0
		var dy := 0.0
		if pa >= 0 and pa < count:
			dx = xs[pa] - xs[i]
			dy = ys[pa] - ys[i]
			steps = maxi(1, int(ceil(maxf(absf(dx), absf(dy)))))
		for s in range(steps):
			var t := float(s) / float(steps)
			var px := xs[i] + dx * t
			var py := ys[i] + dy * t
			var x0 := maxi(0, int(px - ri))
			var x1 := mini(n - 1, int(px + ri))
			var y0 := maxi(0, int(py - ri))
			var y1 := mini(n - 1, int(py + ri))
			for y in range(y0, y1 + 1):
				for x in range(x0, x1 + 1):
					var ddx := float(x) - px
					var ddy := float(y) - py
					var q := sqrt(ddx * ddx + ddy * ddy) / ri
					if q >= 1.0:
						continue
					# The crest height, minus a constant slope away from it.
					var v := hi - q
					if v > out[y * n + x]:
						out[y * n + x] = v
	var lo := 0.0
	for v in out:
		lo = minf(lo, v)
	if lo < 0.0:
		for i in range(n * n):
			out[i] = maxf(0.0, out[i] - lo * 0.0)
	return out


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var m := Pasture3DReliefDLA.new()
	m.resolution = 256
	m.hierarchy_levels = 5
	m.wander = 0.35
	m.coverage = 0.95
	m.detail_size = 0.23
	m.profile_power = 1.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 0
	var cluster: Array = m._grow(rng, maxi(256 >> 4, 16), N)
	_shade("cone massing", m._massif(cluster, N), N, OUT + "/a_today.png")
	print(ProjectSettings.globalize_path(OUT))
	quit(0)
