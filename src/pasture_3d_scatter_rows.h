// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include "pasture_3d_thread_pool.h"

#include <cstddef>
#include <memory>
#include <utility>

namespace godot {

// Threading a SCATTER sweep without changing a bit of its output.
//
// A scatter kernel walks the grid in raster order and pushes amounts into its neighbours (`next[ni] += x`).
// Every destination ends up a float sum, a float sum's bits depend on the ORDER its terms arrive in, and that
// order is the raster order of the cells that sent them — so letting threads add into shared cells as they go
// changes the result. The sweep is split in two instead:
//
//   p_compute(iz, records)           evaluates every SOURCE cell of row iz into a record. A pure function of
//                                    state the sweep only reads, so any thread may compute any row, twice.
//   p_gather(iz, above, row, below)  for every DESTINATION in row iz, replays the terms its sources sent in
//                                    their raster order, and writes the cell. `above` is null on the first
//                                    row and `below` on the last.
//
// A chunk keeps a three-row window of records and computes the rows just outside its range itself: two rows of
// repeated work per chunk, instead of a record buffer the size of the grid. So p_compute must never write, and
// p_gather must write every cell of the sweep's output — nothing is copied in beforehand.
template <typename Record, typename Compute, typename Gather>
inline void parallel_scatter_rows(int p_gw, int p_gh, Compute &&p_compute, Gather &&p_gather) {
	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int p_z0, int p_z1) {
		const size_t w = (size_t)p_gw;
		// Left uninitialised: p_compute sets every record's flags before p_gather reads any.
		std::unique_ptr<Record[]> window(new Record[w * 3]);
		Record *above = window.get();
		Record *row = above + w;
		Record *below = row + w;
		if (p_z0 > 0) {
			p_compute(p_z0 - 1, above);
		}
		p_compute(p_z0, row);
		for (int iz = p_z0; iz < p_z1; iz++) {
			const bool has_below = iz + 1 < p_gh;
			if (has_below) {
				p_compute(iz + 1, below);
			}
			p_gather(iz, iz > 0 ? above : nullptr, row, has_below ? below : nullptr);
			// Slide the window down a row; the old top row's storage becomes the next bottom row.
			std::swap(above, row);
			std::swap(row, below);
		}
	});
}

// The eight directions the scatter kernels push along, in the order their per-cell loops visit them:
// -x, +x, -z, +z, then the diagonals. A 4-neighbour kernel uses the first four.
constexpr int SCATTER_DX[8] = { -1, 1, 0, 0, -1, 1, -1, 1 };
constexpr int SCATTER_DZ[8] = { 0, 0, -1, 1, -1, -1, 1, 1 };

// The cells that can scatter into one destination, as offsets from it IN RASTER ORDER — the order a serial
// sweep delivered their terms — with the direction k each one sent along, which is the reverse of its offset.
// k = -1 is the destination itself. A gather that walks this table replays each destination's sum term for
// term; a 4-neighbour kernel skips the entries with k >= 4, which leaves the order intact.
struct ScatterSource {
	int dx;
	int dz;
	int k;
};

constexpr ScatterSource SCATTER_SOURCES[9] = {
	{ -1, -1, 7 }, { 0, -1, 3 }, { 1, -1, 6 },
	{ -1, 0, 1 }, { 0, 0, -1 }, { 1, 0, 0 },
	{ -1, 1, 5 }, { 0, 1, 2 }, { 1, 1, 4 },
};

constexpr bool scatter_sources_consistent() {
	for (int s = 0; s < 9; s++) {
		const ScatterSource &src = SCATTER_SOURCES[s];
		if (src.dx != s % 3 - 1 || src.dz != s / 3 - 1) {
			return false; // not raster order
		}
		if (src.k < 0 ? (src.dx != 0 || src.dz != 0)
					  : (SCATTER_DX[src.k] != -src.dx || SCATTER_DZ[src.k] != -src.dz)) {
			return false; // that direction does not lead from the source back to the destination
		}
	}
	return true;
}

static_assert(scatter_sources_consistent(),
		"SCATTER_SOURCES must list every source in raster order with the SCATTER_DX/DZ direction it sent along");

} // namespace godot
