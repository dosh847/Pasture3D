// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <thread>
#include <vector>

namespace godot {

// Row- and element-parallel loops over ONE persistent set of worker threads.
//
// This used to start fresh std::threads for every region and join them at its end. That is fine for a
// kernel that runs once per bake and wrong for a solver that runs a region per iteration: thirty
// iterations of a diffusion step paid for thirty rounds of thread creation. The workers now start on the
// first region that splits and stay parked on a condition variable until `shutdown`.
//
// THE CONTRACT IS UNCHANGED, and all of the below leans on it: a region's result must not depend on how it
// is chunked. That is what lets a region reached from INSIDE another region's chunk run serial rather than
// queue behind itself, and what lets a thread waiting on its own chunks run queued ones meanwhile — so a
// region started on a Godot WorkerThreadPool task (the brush deferred solve) can never deadlock waiting on
// threads that are all waiting too. Every chunk is either queued or on a thread that is running it.
class Pasture3DThreadPool {
public:
	// The most threads one parallel region may use; 0, the default, means every hardware thread. Set through
	// Pasture3DUtil.set_max_threads — to leave cores free for other work on the machine, and so a gate can
	// run a kernel at 1 thread and at N and compare the two bit for bit.
	static inline std::atomic<int> s_max_threads{ 0 };
	// Parallel regions that actually SPLIT into more than one chunk. A threaded-vs-serial gate reads it to
	// prove its threaded arm ran threaded: a fixture under the row threshold silently runs serial, and a
	// comparison of serial against serial passes having measured nothing.
	static inline std::atomic<int64_t> s_dispatches{ 0 };

	static inline unsigned int thread_count() {
		const unsigned int hw = std::max(1u, std::thread::hardware_concurrency());
		const int cap = s_max_threads.load(std::memory_order_relaxed);
		return cap > 0 ? std::min(hw, (unsigned int)cap) : hw;
	}

	// Joins the workers; every region after it runs serial. Called from the module's uninitialize, which
	// runs before the library is unloaded: a worker still parked in this library's code at unload would
	// crash, and joining from a static destructor instead would run under the Windows loader lock.
	static void shutdown();

	template <typename F>
	static inline void parallel_for_rows(int p_gh, int p_min_rows_per_chunk, F &&p_func) {
		if (p_gh < 128 || p_gh < p_min_rows_per_chunk * 2) {
			p_func(0, p_gh);
			return;
		}
		_dispatch(p_gh, p_min_rows_per_chunk, p_func);
	}

	template <typename F>
	static inline void parallel_for_elements(int p_total_count, int p_min_elements_per_chunk, F &&p_func) {
		if (p_total_count < 16384 || p_total_count < p_min_elements_per_chunk * 2) {
			p_func(0, p_total_count);
			return;
		}
		_dispatch(p_total_count, p_min_elements_per_chunk, p_func);
	}

private:
	using ChunkFn = void (*)(void *, int, int);

	template <typename F>
	static void _call(void *p_ctx, int p_begin, int p_end) {
		(*static_cast<F *>(p_ctx))(p_begin, p_end);
	}

	template <typename F>
	static inline void _dispatch(int p_total, int p_min_per_chunk, F &p_func) {
		const int num_chunks = _chunk_count(p_total, p_min_per_chunk);
		if (num_chunks <= 1) {
			p_func(0, p_total);
			return;
		}
		s_dispatches.fetch_add(1, std::memory_order_relaxed);
		_run(&_call<F>, (void *)std::addressof(p_func), p_total, num_chunks);
	}

	// 1 — run it serial — when called from inside a region, after shutdown, or capped to one thread.
	static int _chunk_count(int p_total, int p_min_per_chunk);
	// Queues chunks 1..n-1, runs chunk 0 on the calling thread, then helps until the last chunk is done.
	static void _run(ChunkFn p_fn, void *p_ctx, int p_total, int p_num_chunks);
};

} // namespace godot
