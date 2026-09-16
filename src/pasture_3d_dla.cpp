// See pasture_3d_dla.h. Each function below names the GDScript function it mirrors; keep them in step.

#include "pasture_3d_dla.h"

#include "pasture_3d_thread_pool.h"

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
const double WINDOW_BAND = 0.05;
// The slope's run as a share of the massif's radius. See the script.
const double SLOPE_RUN = 0.18;
// How much of a crest's height its depth in the tree can take away. See the script.
const double DEPTH_BITE = 0.55;
const int SHAPE_DIRS = 64;
const int SHAPE_STEPS = 256;
// sqrt(2): the working grid is a SQUARE, so a march must be able to reach its corners. See the script.
const double SHAPE_REACH = 1.4142135623730951;
const double SHAPE_MIN_FRAC = 0.05;
const int FIELD_MIN = 8;
const double TAU_D = 6.283185307179586;

struct DLAGrower {
	const DLAParams &p;
	DLAPcg rng;
	std::vector<float> seed_samples; // scratch for _sample_seed
	mutable std::vector<float> shape_tbl; // the loop's outline, measured once (see shape_table)
	mutable bool shape_ready = false;

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

	// An envelope: the ellipse's semi-axes, plus a radius per direction that supersedes them when the loop's
	// outline is known. `tbl` empty = the ellipse, and that branch is the expression the script always used,
	// so an unhosted growth stays bit-identical. Mirrors the script's `[Vector2, PackedFloat32Array]`.
	struct Env {
		V2f semi;
		std::vector<float> tbl;
	};

	// _shape_table. Cached: the march is over the captured grid and does not depend on the level.
	const std::vector<float> &shape_table() const {
		if (shape_ready) {
			return shape_tbl;
		}
		shape_ready = true;
		shape_tbl.clear();
		const int gw = p.shape_gw;
		const int gh = p.shape_gh;
		if (p.shape_surface.size() != (int64_t)gw * gh || gw < 2 || gh < 2 || p.frame_size < 9) {
			return shape_tbl;
		}
		const double cx = p.frame[0];
		const double cz = p.frame[1];
		const double fcos = p.frame[2];
		const double fsin = p.frame[3];
		const double min_x = p.frame[6];
		const double min_z = p.frame[7];
		const double vs = p.frame[8];
		if (vs <= 0.0) {
			return shape_tbl;
		}
		const double side = std::max(p.frame[4], p.frame[5]);
		const float *g = p.shape_surface.ptr();
		if (!std::isfinite(bilinear(g, gw, gh, (cx - min_x) / vs, (cz - min_z) / vs))) {
			return shape_tbl; // no data at the centre: the ellipse, as the script falls back
		}
		shape_tbl.assign((size_t)SHAPE_DIRS, 0.0f);
		for (int k = 0; k < SHAPE_DIRS; k++) {
			const double ang = TAU_D * (double)k / (double)SHAPE_DIRS;
			const double ca = std::cos(ang);
			const double sa = std::sin(ang);
			double last = 0.0;
			for (int s = 1; s <= SHAPE_STEPS; s++) {
				const double f = (double)s / (double)SHAPE_STEPS * SHAPE_REACH;
				const double lx = f * side * ca;
				const double lz = f * side * sa;
				const double wx = cx + lx * fcos - lz * fsin;
				const double wz = cz + lx * fsin + lz * fcos;
				if (!std::isfinite(bilinear(g, gw, gh, (wx - min_x) / vs, (wz - min_z) / vs))) {
					break;
				}
				last = f;
			}
			shape_tbl[(size_t)k] = (float)std::max(last, SHAPE_MIN_FRAC);
		}
		return shape_tbl;
	}

	// _radius_at
	static double radius_at(const std::vector<float> &tbl, double ang) {
		const int k = (int)tbl.size();
		double m = std::fmod(ang, TAU_D);
		if (m < 0.0) {
			m += TAU_D; // GDScript's fposmod
		}
		const double t = m / TAU_D * (double)k;
		const int i0 = (int)t % k;
		const int i1 = (i0 + 1) % k;
		const double w = t - std::floor(t);
		return lerpd((double)tbl[(size_t)i0], (double)tbl[(size_t)i1], w);
	}

	// _reach_bins
	static int reach_bins(const Env &e) {
		return e.tbl.empty() ? 1 : (int)e.tbl.size();
	}

	// _reach_bin
	static int reach_bin(double dx, double dy, int bins) {
		if (bins <= 1) {
			return 0;
		}
		double m = std::fmod(std::atan2(dy, dx), TAU_D);
		if (m < 0.0) {
			m += TAU_D;
		}
		return (int)(m / TAU_D * (double)bins) % bins;
	}

	// _env_typical: the median of an outline, the shorter semi-axis of an ellipse. See the script for why the
	// median and not the minimum — a non-convex loop's notch directions would otherwise set the blur.
	static double env_typical(const Env &e) {
		if (e.tbl.empty()) {
			return std::min((double)e.semi.x, (double)e.semi.y);
		}
		std::vector<float> v = e.tbl;
		std::sort(v.begin(), v.end());
		return (double)v[v.size() / 2];
	}

	// _env_max
	static double env_max(const Env &e) {
		if (e.tbl.empty()) {
			return std::max((double)e.semi.x, (double)e.semi.y);
		}
		double m = 0.0;
		for (float v : e.tbl) {
			m = std::max(m, (double)v);
		}
		return m;
	}

	// _env_launch
	static V2f env_launch(const Env &e, double ang) {
		if (e.tbl.empty()) {
			return e.semi;
		}
		const float r = (float)radius_at(e.tbl, ang);
		V2f v;
		v.x = r;
		v.y = r;
		return v;
	}

	// _outer: Vector2 * float converts the scalar to real_t first, then multiplies in float32.
	Env outer(int n) const {
		const V2f a = aspect_scale();
		const float s = (float)(p.coverage * 0.5 * (double)n);
		Env o;
		o.semi.x = a.x * s;
		o.semi.y = a.y * s;
		const std::vector<float> &t = shape_table();
		if (!t.empty()) {
			const double sc = p.coverage * 0.5 * (double)n;
			o.tbl.resize(t.size());
			for (size_t i = 0; i < t.size(); i++) {
				o.tbl[i] = (float)((double)t[i] * sc);
			}
		}
		return o;
	}

	// _rho
	static double rho(double dx, double dy, const Env &e) {
		if (e.tbl.empty()) {
			const double u = dx / std::max((double)e.semi.x, 0.001);
			const double v = dy / std::max((double)e.semi.y, 0.001);
			return std::sqrt(u * u + v * v);
		}
		return std::sqrt(dx * dx + dy * dy) / std::max(radius_at(e.tbl, std::atan2(dy, dx)), 0.001);
	}

	// _slope_run
	int slope_run(int n) const {
		return std::max(1, (int)(env_typical(outer(n)) * SLOPE_RUN));
	}

	// _grow_extent
	Env grow_extent(int n) const {
		const Env o = outer(n);
		const double b = (double)slope_run(n);
		Env e;
		e.semi.x = (float)std::max(std::min(4.0, (double)o.semi.x * 0.5), (double)o.semi.x - b);
		e.semi.y = (float)std::max(std::min(4.0, (double)o.semi.y * 0.5), (double)o.semi.y - b);
		if (!o.tbl.empty()) {
			e.tbl.resize(o.tbl.size());
			for (size_t i = 0; i < o.tbl.size(); i++) {
				const double r = (double)o.tbl[i];
				e.tbl[i] = (float)std::max(std::min(4.0, r * 0.5), r - b);
			}
		}
		return e;
	}

	// _particles
	int particles() const {
		const double r = env_max(grow_extent(grid_size()));
		const double ref_r = REF_COVERAGE * 0.5 * (double)REF_RESOLUTION * (1.0 - REF_BLUR_SHARE);
		return std::clamp((int)((double)REF_PARTICLES * (r / ref_r) * std::pow(REF_DETAIL / p.detail_size, 0.45)), 64, 24000);
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
		const Env limit = grow_extent(n);
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
		const Env env = grow_extent(n);
		const double limit = p_frac;
		const double per_cell = 1.0 / std::max(env_typical(env), 1.0);
		// The cluster's reach PER DIRECTION — one bin for an ellipse, one per outline entry. See the script
		// for why a single scalar stalls an outlined growth.
		const int dirs = reach_bins(env);
		std::vector<float> reach((size_t)dirs, (float)per_cell);
		for (size_t i = 0; i < xs.size(); i++) {
			const double dx = (double)xs[i] - c;
			const double dy = (double)ys[i] - c;
			const int b = reach_bin(dx, dy, dirs);
			reach[(size_t)b] = (float)std::max((double)reach[(size_t)b], rho(dx, dy, env));
		}
		const int budget = n * 4;
		const double kill = limit + 6.0 * per_cell;
		// BATCHED WALKS (see the script's _grow_level for why each rule is what it is). A batch walks against
		// the cluster as it stood when the batch began — `owner` is only read — each particle on its own stream,
		// so the batch splits on the pool with nothing shared. The commit is serial and in particle order.
		std::vector<int32_t> result;
		int pi = 0;
		while (pi < p_particles) {
			const int batch = std::min(std::clamp((int)(xs.size() >> 3), 1, 256), p_particles - pi);
			const std::vector<float> reach0 = reach;
			const int first = pi;
			result.assign((size_t)batch * 3, -1);
			const int64_t d0 = Pasture3DThreadPool::s_dispatches.load(std::memory_order_relaxed);
			Pasture3DThreadPool::parallel_for_rows(batch, 8, [&](int b0, int b1) {
				DLAPcg prng;
				for (int b = b0; b < b1; b++) {
					const int q = first + b;
					prng.seed(walk_seed(n, q));
					// The ellipse draws in the original order (interior factor, then angle); an outline must
					// know the angle before it can read the reach in that direction, so it draws the angle
					// first. Different streams on purpose — see the script's _walk.
					int px = 0;
					int py = 0;
					if (!env.tbl.empty()) {
						const double oang = (double)prng.randf() * TAU_D;
						const double olr = (double)reach0[(size_t)reach_bin(std::cos(oang), std::sin(oang), (int)reach0.size())];
						const bool ogrowing = olr < limit && q * 10 < p_particles * 7;
						const double olaunch = std::min(olr + 3.0 * per_cell, limit) * ((ogrowing || (q & 1) == 0) ? 1.0 : std::sqrt((double)prng.randf()));
						const double orad = radius_at(env.tbl, oang);
						px = iround(c + std::cos(oang) * olaunch * orad);
						py = iround(c + std::sin(oang) * olaunch * orad);
					} else {
						const bool growing = (double)reach0[0] < limit && q * 10 < p_particles * 7;
						const double base = std::min((double)reach0[0] + 3.0 * per_cell, limit);
						const double launch = base * ((growing || (q & 1) == 0) ? 1.0 : std::sqrt((double)prng.randf()));
						const double ang = (double)prng.randf() * TAU_D;
						const V2f lv = env_launch(env, ang);
						px = iround(c + std::cos(ang) * launch * (double)lv.x);
						py = iround(c + std::sin(ang) * launch * (double)lv.y);
					}
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
						switch (prng.rand() & 3u) {
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
					result[(size_t)b * 3] = stuck;
					result[(size_t)b * 3 + 1] = px;
					result[(size_t)b * 3 + 2] = py;
				}
			});
			walk_dispatches += Pasture3DThreadPool::s_dispatches.load(std::memory_order_relaxed) - d0;
			for (int b = 0; b < batch; b++) {
				const int stuck = result[(size_t)b * 3];
				if (stuck < 0) {
					continue;
				}
				const int px = result[(size_t)b * 3 + 1];
				const int py = result[(size_t)b * 3 + 2];
				if (rho((double)px - c, (double)py - c, env) > limit) {
					continue;
				}
				if (owner[(size_t)(py * n + px)] >= 0) {
					continue; // an earlier particle of this batch took the cell
				}
				const int32_t id = (int32_t)xs.size();
				xs.push_back((float)px);
				ys.push_back((float)py);
				parents.push_back(stuck);
				owner[(size_t)(py * n + px)] = id;
				const int rb = reach_bin((double)px - c, (double)py - c, dirs);
				reach[(size_t)rb] = (float)std::max((double)reach[(size_t)rb], rho((double)px - c, (double)py - c, env));
			}
			pi += batch;
		}
	}

	// _walk_seed: one stream per (level grid, particle). Shifted clear of the seed's low bits, then XORed in,
	// on uint64 so the script's wrapping int64 and this agree.
	uint64_t walk_seed(int n, int q) const {
		return (uint64_t)p.seed ^ ((((uint64_t)n << 20) | (uint64_t)q) << 24);
	}

	int64_t walk_dispatches = 0;

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
			if (pa < 0 || (size_t)pa >= xs.size()) {
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

	static constexpr int k_rows_per_chunk = 16;

	// The peak of a field, by rows. Row-parallel and then reduced in row order, so the answer does not
	// depend on how the pool split the work.
	static double max_of(const std::vector<float> &g, int n) {
		std::vector<double> row_max((size_t)n, 0.0);
		Pasture3DThreadPool::parallel_for_rows(n, k_rows_per_chunk, [&](int y0, int y1) {
			for (int y = y0; y < y1; y++) {
				double m = 0.0;
				for (int x = 0; x < n; x++) {
					m = std::max(m, (double)g[(size_t)(y * n + x)]);
				}
				row_max[(size_t)y] = m;
			}
		});
		double m = 0.0;
		for (double v : row_max) {
			m = std::max(m, v);
		}
		return m;
	}

	// _massif -- the mountain: every point of the ridge tree is a crest whose height falls with how central
	// it is, and the ground away from a crest falls to nothing over one slope run. A max-plus distance
	// transform, two chamfer sweeps, carrying the crest AND the distance so every crest's foot lands at the
	// same radius. See the script for why a sum of blurred skeletons could not make this shape.
	std::vector<float> massif(const std::vector<float> &xs, const std::vector<float> &ys,
			const std::vector<int32_t> &parents, int n) const {
		const size_t nn = (size_t)n * n;
		std::vector<float> out(nn, 0.0f);
		const int count = (int)xs.size();
		if (count < 1) {
			return out;
		}
		const double run = (double)slope_run(n);
		const Env env = outer(n);
		const double c = (double)n * 0.5;
		const std::vector<int32_t> depth = depths(parents);
		int deepest = 1;
		for (int32_t v : depth) {
			deepest = std::max(deepest, (int)v);
		}
		const double span = (double)(deepest + 1);
		for (int i = 0; i < count; i++) {
			const int pa = parents[(size_t)i];
			if (pa < 0 || pa >= count) {
				crest(out, n, xs[(size_t)i], ys[(size_t)i],
						crest_height((double)xs[(size_t)i] - c, (double)ys[(size_t)i] - c, env,
								(double)depth[(size_t)i] / span));
				continue;
			}
			const double dx = (double)xs[(size_t)pa] - (double)xs[(size_t)i];
			const double dy = (double)ys[(size_t)pa] - (double)ys[(size_t)i];
			const int steps = std::max(1, (int)std::ceil(std::max(std::fabs(dx), std::fabs(dy))));
			const double fi = (double)depth[(size_t)i] / span;
			const double fp = (double)depth[(size_t)pa] / span;
			for (int st = 0; st < steps + 1; st++) {
				const double t = (double)st / (double)steps;
				const double px = (double)xs[(size_t)i] + dx * t;
				const double py = (double)ys[(size_t)i] + dy * t;
				crest(out, n, px, py, crest_height(px - c, py - c, env, lerpd(fi, fp, t)));
			}
		}
		std::vector<float> src = out;
		std::vector<float> dist(nn, std::numeric_limits<float>::infinity());
		for (size_t i = 0; i < nn; i++) {
			if (out[i] > 0.0f) {
				dist[i] = 0.0f;
			}
		}
		const double diag = 1.4142135623730951;
		// SERIAL, both sweeps: a chamfer carries each cell's answer to the next one, so splitting it by rows
		// would change the result at every chunk boundary and the script could not be matched.
		for (int y = 0; y < n; y++) {
			for (int x = 0; x < n; x++) {
				const int i = y * n + x;
				if (x > 0) {
					relax(src, dist, i, i - 1, 1.0, run);
				}
				if (y > 0) {
					relax(src, dist, i, i - n, 1.0, run);
					if (x > 0) {
						relax(src, dist, i, i - n - 1, diag, run);
					}
					if (x < n - 1) {
						relax(src, dist, i, i - n + 1, diag, run);
					}
				}
			}
		}
		for (int y = n - 1; y >= 0; y--) {
			for (int x = n - 1; x >= 0; x--) {
				const int i = y * n + x;
				if (x < n - 1) {
					relax(src, dist, i, i + 1, 1.0, run);
				}
				if (y < n - 1) {
					relax(src, dist, i, i + n, 1.0, run);
					if (x < n - 1) {
						relax(src, dist, i, i + n + 1, diag, run);
					}
					if (x > 0) {
						relax(src, dist, i, i + n - 1, diag, run);
					}
				}
			}
		}
		for (size_t i = 0; i < nn; i++) {
			out[i] = (float)std::max(0.0, (double)src[i] * (1.0 - std::min((double)dist[i], run) / run));
		}
		return finish(std::move(out), n);
	}

	// _relax
	static void relax(std::vector<float> &src, std::vector<float> &dist, int i, int j, double w, double run) {
		const double d = (double)dist[(size_t)j] + w;
		if (d >= run) {
			return;
		}
		const double v = (double)src[(size_t)j] * (1.0 - d / run);
		if (v > (double)src[(size_t)i] * (1.0 - std::min((double)dist[(size_t)i], run) / run)) {
			src[(size_t)i] = src[(size_t)j];
			dist[(size_t)i] = (float)d;
		}
	}

	// _crest
	static void crest(std::vector<float> &g, int n, double x, double y, double v) {
		const int ix = iround(x);
		const int iy = iround(y);
		if (ix >= 0 && iy >= 0 && ix < n && iy < n && v > (double)g[(size_t)(iy * n + ix)]) {
			g[(size_t)(iy * n + ix)] = (float)v;
		}
	}

	// _crest_height
	static double crest_height(double dx, double dy, const Env &e, double p_depth) {
		const double radial = std::sqrt(std::max(0.0, 1.0 - std::min(1.0, rho(dx, dy, e))));
		return radial * (1.0 - DEPTH_BITE * std::clamp(p_depth, 0.0, 1.0));
	}

	// _depths -- path length to the root. Walks and memoises: an upscale re-points a node at a midpoint it
	// appends later, so parents can point FORWARD and a backward sweep would get those subtrees wrong.
	static std::vector<int32_t> depths(const std::vector<int32_t> &parents) {
		const int count = (int)parents.size();
		std::vector<int32_t> d((size_t)count, -1);
		std::vector<int32_t> stack;
		for (int i = 0; i < count; i++) {
			if (d[(size_t)i] >= 0) {
				continue;
			}
			stack.clear();
			int j = i;
			// -2 marks "on the stack", so a cycle cannot spin here forever.
			while (j >= 0 && j < count && d[(size_t)j] == -1) {
				stack.push_back((int32_t)j);
				d[(size_t)j] = -2;
				j = parents[(size_t)j];
			}
			int base = 0;
			if (j >= 0 && j < count && d[(size_t)j] >= 0) {
				base = d[(size_t)j];
			}
			for (int k = (int)stack.size() - 1; k >= 0; k--) {
				base += 1;
				d[(size_t)stack[(size_t)k]] = (int32_t)base;
			}
		}
		return d;
	}

	// _finish
	std::vector<float> finish(std::vector<float> out, int n) const {
		const double peak = max_of(out, n);
		if (peak <= 0.0) {
			return out;
		}
		const double inv = 1.0 / peak;
		const double pw = p.profile_power;
		// The envelope is ENFORCED here, matching the oracle: the cluster grows to what the blur spends, and
		// the cascade's faint tail past `coverage` is windowed to zero on the envelope rather than left to
		// be cropped square by a FIT-mapped brush. Applied after the profile power so the power cannot lift
		// the tail back over the edge.
		const Env env = outer(n);
		const double c = (double)n * 0.5;
		Pasture3DThreadPool::parallel_for_rows(n, k_rows_per_chunk, [&](int y0, int y1) {
			for (int y = y0; y < y1; y++) {
				for (int x = 0; x < n; x++) {
					const size_t i = (size_t)y * n + x;
					double v = (double)out[i] * inv;
					v = pw == 1.0 ? v : std::pow(v, pw);
					const double r = rho((double)x - c, (double)y - c, env);
					if (r >= 1.0) {
						v = 0.0;
					} else if (r > 1.0 - WINDOW_BAND) {
						const double t = (1.0 - r) / WINDOW_BAND;
						v *= t * t * (3.0 - 2.0 * t);
					}
					out[i] = (float)v;
				}
			}
		});
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
	const std::vector<float> field = g.massif(xs, ys, parents, res);

	DLAResult out;
	out.n = res;
	out.dims = g.field_dims();
	out.walk_dispatches = g.walk_dispatches;
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
