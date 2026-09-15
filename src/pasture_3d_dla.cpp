// See pasture_3d_dla.h. Each function below names the GDScript function it mirrors; keep them in step.

#include "pasture_3d_dla.h"

#include <godot_cpp/classes/random_number_generator.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

namespace godot {

namespace {

// ---- Godot's RandomPCG (core/math/random_pcg.h), as RandomNumberGenerator exposes it ----------------

uint32_t dla_clz32(uint32_t p_x) {
	if (p_x == 0) {
		return 32;
	}
	uint32_t n = 0;
	while ((p_x & 0x80000000u) == 0) {
		p_x <<= 1;
		n++;
	}
	return n;
}

struct DLAPcg {
	uint64_t state = 0;
	uint64_t inc = 0;

	// pcg32_srandom_r(&pcg, seed, PCG_DEFAULT_INC_64)
	void seed(uint64_t p_seed) {
		const uint64_t initseq = 1442695040888963407ULL;
		state = 0u;
		inc = (initseq << 1u) | 1u;
		rand();
		state += p_seed;
		rand();
	}

	// pcg32_random_r
	uint32_t rand() {
		const uint64_t old = state;
		state = old * 6364136223846793005ULL + (inc | 1);
		const uint32_t xorshifted = (uint32_t)(((old >> 18u) ^ old) >> 27u);
		const uint32_t rot = (uint32_t)(old >> 59u);
		return (xorshifted >> rot) | (xorshifted << ((0u - rot) & 31u));
	}

	double randd() {
		const uint32_t proto_exp_offset = rand();
		if (proto_exp_offset == 0) {
			return 0;
		}
		const uint64_t significand = (((uint64_t)rand()) << 32) | rand() | 0x0000000000000001ULL;
		return std::ldexp((double)significand, -64 - (int)dla_clz32(proto_exp_offset));
	}

	float randf() {
		const uint32_t proto_exp_offset = rand();
		if (proto_exp_offset == 0) {
			return 0;
		}
		// The significand's top bit is FORCED, so it lies in [0.5, 1) and the leading zeros of the first draw
		// alone set the exponent. `| 1` without the top bit (the first version) was off by 2^-(clz+1) whenever
		// that bit happened to be clear. GraphDLANativeParityGate [R] measured the engine's value.
		return std::ldexp((float)(rand() | 0x80000001u), -32 - (int)dla_clz32(proto_exp_offset));
	}

	// randfn is NOT reimplemented: it is the engine's own, reached by handing it this stream's state and
	// taking the advanced state back. Reconstructing it got within two float32 ulps and no closer — its
	// real_t overload mixes float32 draws with library log/sqrt/cos whose rounding a port cannot promise to
	// match — and a two-ulp miss on a node position moves every particle after it. The increment needs no
	// handing over: both streams are seeded with the default one. randi/randf above ARE ported, because
	// GraphDLANativeParityGate [R] shows them exact and they sit in the per-step walk where a call through
	// the engine would cost.
	Ref<RandomNumberGenerator> engine;

	float randfn(float p_mean, float p_deviation) {
		if (engine.is_null()) {
			engine.instantiate();
			engine->set_seed(0); // establishes the default increment; the state is overwritten below
		}
		engine->set_state(state);
		const float v = (float)engine->randfn(p_mean, p_deviation);
		state = engine->get_state();
		return v;
	}
};

// Godot's Vector2 is real_t, so every one the script builds stores float32.
struct V2f {
	float x = 0;
	float y = 0;
};

double lerpd(double p_from, double p_to, double p_w) {
	return p_from + (p_to - p_from) * p_w;
}

// GDScript's round(): half away from zero, which is std::round.
int iround(double p_v) {
	return (int)std::round(p_v);
}

const double REF_DETAIL = 0.12;
const double REF_COVERAGE = 0.9;
const int REF_PARTICLES = 3000;
const int REF_RESOLUTION = 512;
const double REF_BLUR_SHARE = 0.3243;
const double BLUR_CEILING = 0.70;
const int FIELD_MIN = 8;
const double TAU_D = 6.283185307179586;

struct DLAGrower {
	const DLAParams &p;
	DLAPcg rng;
	std::vector<float> seed_samples; // scratch for _sample_seed

	explicit DLAGrower(const DLAParams &p_params) :
			p(p_params) {}

	// _grid_size
	int grid_size() const {
		int n = 64;
		while (n * 2 <= p.resolution) {
			n *= 2;
		}
		return n;
	}

	// _field_dims
	Vector2i field_dims() const {
		const int n = grid_size();
		const double s = std::max(p.host_ex, p.host_ez);
		const int w = std::clamp(iround((double)n * p.host_ex / s) & ~1, FIELD_MIN, n);
		const int h = std::clamp(iround((double)n * p.host_ez / s) & ~1, FIELD_MIN, n);
		return Vector2i(w, h);
	}

	// _aspect_scale
	V2f aspect_scale() const {
		const int n = grid_size();
		const Vector2i d = field_dims();
		V2f v;
		v.x = (float)((double)(d.x - 1) / (double)(n - 1));
		v.y = (float)((double)(d.y - 1) / (double)(n - 1));
		return v;
	}

	// _outer: Vector2 * float converts the scalar to real_t first, then multiplies in float32.
	V2f outer(int n) const {
		const V2f a = aspect_scale();
		const float s = (float)(p.coverage * 0.5 * (double)n);
		V2f o;
		o.x = a.x * s;
		o.y = a.y * s;
		return o;
	}

	// _rho
	static double rho(double dx, double dy, const V2f &e) {
		const double u = dx / std::max((double)e.x, 0.001);
		const double v = dy / std::max((double)e.y, 0.001);
		return std::sqrt(u * u + v * v);
	}

	// _blur_budget
	int blur_budget(int n) const {
		const V2f o = outer(n);
		const double m = std::min((double)o.x, (double)o.y);
		const double ask = 4.0 * p.detail_size;
		return std::clamp((int)(m * std::min(ask / (1.0 + ask), BLUR_CEILING)), 1, std::max(1, (int)(m * BLUR_CEILING)));
	}

	// _grow_extent
	V2f grow_extent(int n) const {
		const V2f o = outer(n);
		const double b = (double)blur_budget(n);
		V2f e;
		e.x = (float)std::max(std::min(4.0, (double)o.x * 0.5), (double)o.x - b);
		e.y = (float)std::max(std::min(4.0, (double)o.y * 0.5), (double)o.y - b);
		return e;
	}

	// _particles
	int particles() const {
		const V2f e = grow_extent(grid_size());
		const double r = std::max((double)e.x, (double)e.y);
		const double ref_r = REF_COVERAGE * 0.5 * (double)REF_RESOLUTION * (1.0 - REF_BLUR_SHARE);
		return std::clamp((int)((double)REF_PARTICLES * (r / ref_r) * std::pow(REF_DETAIL / p.detail_size, 0.7)), 64, 24000);
	}

	// _bilinear (NaN-propagating)
	static double bilinear(const float *g, int gw, int gh, double fx, double fy) {
		if (fx < 0.0 || fy < 0.0 || fx > (double)(gw - 1) || fy > (double)(gh - 1)) {
			return std::numeric_limits<double>::quiet_NaN();
		}
		const int x0 = (int)fx;
		const int y0 = (int)fy;
		const int x1 = std::min(x0 + 1, gw - 1);
		const int y1 = std::min(y0 + 1, gh - 1);
		const double tx = fx - (double)x0;
		const double ty = fy - (double)y0;
		const double a = g[y0 * gw + x0];
		const double b = g[y0 * gw + x1];
		const double cc = g[y1 * gw + x0];
		const double d = g[y1 * gw + x1];
		if (!(std::isfinite(a) && std::isfinite(b) && std::isfinite(cc) && std::isfinite(d))) {
			return std::numeric_limits<double>::quiet_NaN();
		}
		return (a * (1.0 - tx) + b * tx) * (1.0 - ty) + (cc * (1.0 - tx) + d * tx) * ty;
	}

	bool has_seed() const {
		return p.ridge_seeding && !p.seed_surface.is_empty();
	}

	// _sample_seed. Empty when the surface or frame is unusable.
	bool sample_seed(int n, std::vector<float> &r_out) const {
		const int gw = p.seed_gw;
		const int gh = p.seed_gh;
		if (p.seed_surface.size() != (int64_t)gw * gh || gw < 2 || gh < 2 || p.frame_size < 9) {
			return false;
		}
		const double cx = p.frame[0];
		const double cz = p.frame[1];
		const double fcos = p.frame[2];
		const double fsin = p.frame[3];
		const double ex = p.frame[4];
		const double ez = p.frame[5];
		const double min_x = p.frame[6];
		const double min_z = p.frame[7];
		const double vs = p.frame[8];
		if (vs <= 0.0) {
			return false;
		}
		const double side = std::max(ex, ez);
		const float *g = p.seed_surface.ptr();
		r_out.assign((size_t)n * n, 0.0f);
		for (int y = 0; y < n; y++) {
			const double nv = ((double)y / (double)(n - 1)) * 2.0 - 1.0;
			for (int x = 0; x < n; x++) {
				const double nu = ((double)x / (double)(n - 1)) * 2.0 - 1.0;
				const double lx = nu * side;
				const double lz = nv * side;
				const double wx = cx + lx * fcos - lz * fsin;
				const double wz = cz + lx * fsin + lz * fcos;
				r_out[(size_t)y * n + x] = (float)bilinear(g, gw, gh, (wx - min_x) / vs, (wz - min_z) / vs);
			}
		}
		return true;
	}

	// _seed_ridges
	bool seed_ridges(int n, std::vector<float> &xs, std::vector<float> &ys, std::vector<int32_t> &parents,
			std::vector<int32_t> &owner) {
		if (!has_seed()) {
			return false;
		}
		if (!sample_seed(n, seed_samples)) {
			return false;
		}
		const std::vector<float> &h = seed_samples;
		const double c = (double)n * 0.5;
		const V2f limit = grow_extent(n);
		std::vector<float> ridge((size_t)n * n, -std::numeric_limits<float>::infinity());
		std::vector<float> live;
		const int nbr[4] = { -1, 1, -n, n };
		for (int y = 1; y < n - 1; y++) {
			for (int x = 1; x < n - 1; x++) {
				if (rho((double)x - c, (double)y - c, limit) > 1.0) {
					continue;
				}
				const int i = y * n + x;
				const double v = h[(size_t)i];
				if (!std::isfinite(v)) {
					continue;
				}
				double ring = 0.0;
				int k = 0;
				for (int d : nbr) {
					const double nvv = h[(size_t)(i + d)];
					if (std::isfinite(nvv)) {
						ring += nvv;
						k += 1;
					}
				}
				if (k == 0) {
					continue;
				}
				ridge[(size_t)i] = (float)(v - ring / (double)k);
				live.push_back(ridge[(size_t)i]);
			}
		}
		if (live.size() < 16) {
			return false;
		}
		std::sort(live.begin(), live.end());
		const int li = std::clamp((int)((double)live.size() * (1.0 - p.ridge_amount)), 0, (int)live.size() - 1);
		const double cut = live[(size_t)li];
		if (cut <= 0.0) {
			return false;
		}
		for (int y = 1; y < n - 1; y++) {
			for (int x = 1; x < n - 1; x++) {
				const int i = y * n + x;
				if ((double)ridge[(size_t)i] < cut) {
					continue;
				}
				if (owner[(size_t)i] >= 0) {
					continue;
				}
				owner[(size_t)i] = (int32_t)xs.size();
				xs.push_back((float)x);
				ys.push_back((float)y);
				parents.push_back(-1);
			}
		}
		return !xs.empty();
	}

	// _neighbour_owner
	static int neighbour_owner(const std::vector<int32_t> &owner, int n, int px, int py) {
		int o = owner[(size_t)(py * n + px - 1)];
		if (o >= 0) {
			return o;
		}
		o = owner[(size_t)(py * n + px + 1)];
		if (o >= 0) {
			return o;
		}
		o = owner[(size_t)((py - 1) * n + px)];
		if (o >= 0) {
			return o;
		}
		return owner[(size_t)((py + 1) * n + px)];
	}

	// _grow_level
	void grow_level(int n, double p_frac, int p_particles, std::vector<float> &xs, std::vector<float> &ys,
			std::vector<int32_t> &parents, std::vector<int32_t> &owner) {
		const double c = (double)n * 0.5;
		const V2f env = grow_extent(n);
		const double limit = p_frac;
		const double per_cell = 1.0 / std::max(std::min((double)env.x, (double)env.y), 1.0);
		double reach = per_cell;
		for (size_t i = 0; i < xs.size(); i++) {
			reach = std::max(reach, rho((double)xs[i] - c, (double)ys[i] - c, env));
		}
		const int budget = n * 4;
		for (int pi = 0; pi < p_particles; pi++) {
			const bool growing = reach < limit && pi * 10 < p_particles * 7;
			const double base = std::min(reach + 3.0 * per_cell, limit);
			const double launch = base * ((growing || (pi & 1) == 0) ? 1.0 : std::sqrt((double)rng.randf()));
			const double ang = (double)rng.randf() * TAU_D;
			int px = iround(c + std::cos(ang) * launch * (double)env.x);
			int py = iround(c + std::sin(ang) * launch * (double)env.y);
			const double kill = limit + 6.0 * per_cell;
			int stuck = -1;
			for (int s = 0; s < budget; s++) {
				if (px < 1 || py < 1 || px >= n - 1 || py >= n - 1) {
					break;
				}
				if (rho((double)px - c, (double)py - c, env) > kill) {
					break;
				}
				stuck = neighbour_owner(owner, n, px, py);
				if (stuck >= 0) {
					break;
				}
				switch (rng.rand() & 3u) {
					case 0:
						px += 1;
						break;
					case 1:
						px -= 1;
						break;
					case 2:
						py += 1;
						break;
					default:
						py -= 1;
						break;
				}
			}
			if (stuck < 0) {
				continue;
			}
			if (rho((double)px - c, (double)py - c, env) > limit) {
				continue;
			}
			const int32_t id = (int32_t)xs.size();
			xs.push_back((float)px);
			ys.push_back((float)py);
			parents.push_back(stuck);
			owner[(size_t)(py * n + px)] = id;
			reach = std::max(reach, rho((double)px - c, (double)py - c, env));
		}
	}

	// _stamp_edge
	static void stamp_edge(std::vector<int32_t> &owner, int n, const std::vector<float> &xs,
			const std::vector<float> &ys, const std::vector<int32_t> &parents, int i) {
		const int pa = parents[(size_t)i];
		const int cx = iround(xs[(size_t)i]);
		const int cy = iround(ys[(size_t)i]);
		if (cx >= 0 && cy >= 0 && cx < n && cy < n) {
			owner[(size_t)(cy * n + cx)] = i;
		}
		if (pa < 0) {
			return;
		}
		const double dx = (double)xs[(size_t)pa] - (double)xs[(size_t)i];
		const double dy = (double)ys[(size_t)pa] - (double)ys[(size_t)i];
		const int steps = (int)std::ceil(std::max(std::fabs(dx), std::fabs(dy)));
		if (steps < 1) {
			return;
		}
		for (int s = 1; s < steps; s++) {
			const double t = (double)s / (double)steps;
			const int x = iround((double)xs[(size_t)i] + dx * t);
			const int y = iround((double)ys[(size_t)i] + dy * t);
			if (x < 0 || y < 0 || x >= n || y >= n) {
				continue;
			}
			if (owner[(size_t)(y * n + x)] < 0) {
				owner[(size_t)(y * n + x)] = i;
			}
		}
	}

	// _upscale
	void upscale(int n, std::vector<float> &xs, std::vector<float> &ys, std::vector<int32_t> &parents,
			std::vector<int32_t> &r_owner) {
		const int count = (int)xs.size();
		const float jit = (float)(p.wander * 0.75);
		for (int i = 0; i < count; i++) {
			xs[(size_t)i] = (float)((double)xs[(size_t)i] * 2.0 + (double)rng.randfn(0.0f, jit));
			ys[(size_t)i] = (float)((double)ys[(size_t)i] * 2.0 + (double)rng.randfn(0.0f, jit));
		}
		const double lo = 1.0;
		const double hi = (double)(n - 2);
		for (int i = 0; i < count; i++) {
			const int pa = parents[(size_t)i];
			if (pa < 0) {
				continue;
			}
			const double dx = (double)xs[(size_t)i] - (double)xs[(size_t)pa];
			const double dy = (double)ys[(size_t)i] - (double)ys[(size_t)pa];
			const double seg = std::sqrt(dx * dx + dy * dy);
			double mx = ((double)xs[(size_t)i] + (double)xs[(size_t)pa]) * 0.5;
			double my = ((double)ys[(size_t)i] + (double)ys[(size_t)pa]) * 0.5;
			if (seg > 0.0001 && p.wander > 0.0) {
				const double thr = (double)rng.randfn(0.0f, (float)(seg * p.wander * 0.5));
				mx += (-dy / seg) * thr;
				my += (dx / seg) * thr;
			}
			const int32_t mid = (int32_t)xs.size();
			xs.push_back((float)std::clamp(mx, lo, hi));
			ys.push_back((float)std::clamp(my, lo, hi));
			parents.push_back(pa);
			parents[(size_t)i] = mid;
		}
		r_owner.assign((size_t)n * n, -1);
		for (int i = 0; i < (int)xs.size(); i++) {
			stamp_edge(r_owner, n, xs, ys, parents, i);
		}
	}

	// _grow
	void grow(int p_n0, int p_res, std::vector<float> &xs, std::vector<float> &ys, std::vector<int32_t> &parents) {
		int n = p_n0;
		int rounds = 0;
		int probe = p_n0;
		while (probe < p_res) {
			probe *= 2;
			rounds += 1;
		}
		std::vector<int32_t> owner((size_t)n * n, -1);
		const bool seeded = seed_ridges(n, xs, ys, parents, owner);
		if (!seeded) {
			xs.push_back((float)((double)n * 0.5));
			ys.push_back((float)((double)n * 0.5));
			parents.push_back(-1);
			owner[(size_t)((int)(n * 0.5) * n + (int)(n * 0.5))] = 0;
		}
		int level = 0;
		while (true) {
			grow_level(n, lerpd(0.7, 1.0, (double)level / (double)std::max(rounds, 1)),
					std::max(24, particles() * n / p_res), xs, ys, parents, owner);
			if (n >= p_res) {
				break;
			}
			n *= 2;
			level += 1;
			upscale(n, xs, ys, parents, owner);
			if (seeded) {
				seed_ridges(n, xs, ys, parents, owner);
			}
		}
	}

	// _plot
	static void plot(std::vector<float> &g, int n, double x, double y) {
		const int ix = iround(x);
		const int iy = iround(y);
		if (ix >= 0 && iy >= 0 && ix < n && iy < n) {
			g[(size_t)(iy * n + ix)] = 1.0f;
		}
	}

	// _rasterise
	static std::vector<float> rasterise(const std::vector<float> &xs, const std::vector<float> &ys,
			const std::vector<int32_t> &parents, int p_res) {
		std::vector<float> out((size_t)p_res * p_res, 0.0f);
		for (size_t i = 0; i < xs.size(); i++) {
			const int pa = parents[i];
			if (pa < 0) {
				plot(out, p_res, xs[i], ys[i]);
				continue;
			}
			const double dx = (double)xs[(size_t)pa] - (double)xs[i];
			const double dy = (double)ys[(size_t)pa] - (double)ys[i];
			const int steps = std::max(1, (int)std::ceil(std::max(std::fabs(dx), std::fabs(dy))));
			for (int s = 0; s < steps + 1; s++) {
				const double t = (double)s / (double)steps;
				plot(out, p_res, (double)xs[i] + dx * t, (double)ys[i] + dy * t);
			}
		}
		return out;
	}

	// _blur_radii
	std::vector<int> blur_radii(int n) const {
		const int budget = blur_budget(n);
		const int span = (1 << p.blur_levels) - 1;
		const int r0 = std::max(1, budget / span);
		std::vector<int> out;
		int used = 0;
		for (int k = 0; k < p.blur_levels; k++) {
			const int r = r0 << k;
			if (used + r > budget && !out.empty()) {
				break;
			}
			out.push_back(r);
			used += r;
		}
		return out;
	}

	// _box_blur
	static std::vector<float> box_blur(const std::vector<float> &src, int n, int r) {
		std::vector<float> tmp((size_t)n * n);
		const double inv = 1.0 / (double)(2 * r + 1);
		for (int y = 0; y < n; y++) {
			const int row = y * n;
			double acc = (double)src[(size_t)row] * (double)(r + 1);
			for (int i = 1; i < r + 1; i++) {
				acc += (double)src[(size_t)(row + std::min(i, n - 1))];
			}
			for (int x = 0; x < n; x++) {
				tmp[(size_t)(row + x)] = (float)(acc * inv);
				acc += (double)src[(size_t)(row + std::min(x + r + 1, n - 1))] - (double)src[(size_t)(row + std::max(x - r, 0))];
			}
		}
		std::vector<float> out((size_t)n * n);
		for (int x = 0; x < n; x++) {
			double acc = (double)tmp[(size_t)x] * (double)(r + 1);
			for (int i = 1; i < r + 1; i++) {
				acc += (double)tmp[(size_t)(std::min(i, n - 1) * n + x)];
			}
			for (int y = 0; y < n; y++) {
				out[(size_t)(y * n + x)] = (float)(acc * inv);
				acc += (double)tmp[(size_t)(std::min(y + r + 1, n - 1) * n + x)] - (double)tmp[(size_t)(std::max(y - r, 0) * n + x)];
			}
		}
		return out;
	}

	// _mass
	std::vector<float> mass(const std::vector<float> &raster, int n) const {
		const size_t nn = (size_t)n * n;
		std::vector<float> out(nn, 0.0f);
		std::vector<float> img = raster;
		double weight = 1.0;
		double total = 0.0;
		for (int r : blur_radii(n)) {
			img = box_blur(img, n, r);
			double lvl = 0.0;
			for (size_t i = 0; i < nn; i++) {
				lvl = std::max(lvl, (double)img[i]);
			}
			if (lvl <= 0.0) {
				continue;
			}
			const double k = weight / lvl;
			for (size_t i = 0; i < nn; i++) {
				out[i] = (float)((double)out[i] + (double)img[i] * k);
			}
			total += weight;
			weight *= p.blur_growth;
		}
		if (total <= 0.0) {
			return out;
		}
		double peak = 0.0;
		for (size_t i = 0; i < nn; i++) {
			peak = std::max(peak, (double)out[i]);
		}
		if (peak <= 0.0) {
			return out;
		}
		const double inv = 1.0 / peak;
		const double pw = p.profile_power;
		for (size_t i = 0; i < nn; i++) {
			const double v = (double)out[i] * inv;
			out[i] = (float)(pw == 1.0 ? v : std::pow(v, pw));
		}
		return out;
	}
};

} // namespace

DLAResult dla_grow(const DLAParams &p_params) {
	DLAGrower g(p_params);
	g.rng.seed((uint64_t)p_params.seed);
	const int res = g.grid_size();
	const int n0 = std::max(res >> (std::max(p_params.hierarchy_levels, 1) - 1), 16);
	std::vector<float> xs;
	std::vector<float> ys;
	std::vector<int32_t> parents;
	g.grow(n0, res, xs, ys, parents);
	const std::vector<float> field = g.mass(DLAGrower::rasterise(xs, ys, parents, res), res);

	DLAResult out;
	out.n = res;
	out.dims = g.field_dims();
	out.field.resize((int64_t)field.size());
	std::copy(field.begin(), field.end(), out.field.ptrw());
	return out;
}

PackedFloat64Array dla_rng_probe(int64_t p_seed, int p_count, double p_dev) {
	DLAPcg rng;
	rng.seed((uint64_t)p_seed);
	PackedFloat64Array out;
	out.resize((int64_t)std::max(p_count, 0) * 3);
	double *w = out.ptrw();
	for (int i = 0; i < p_count; i++) {
		w[i * 3] = (double)rng.rand();
		w[i * 3 + 1] = (double)rng.randf();
		w[i * 3 + 2] = (double)rng.randfn(0.0f, (float)p_dev);
	}
	return out;
}

} // namespace godot
