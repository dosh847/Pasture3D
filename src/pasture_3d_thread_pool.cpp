// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_thread_pool.h"

#include <condition_variable>
#include <deque>
#include <mutex>

using namespace godot;

namespace {

struct Region {
	int pending = 0; // chunks queued or running; guarded by PoolState::mutex
};

struct Job {
	void (*fn)(void *, int, int);
	void *ctx;
	int begin;
	int end;
	Region *region;
};

struct PoolState {
	std::mutex mutex;
	std::condition_variable work_cv; // a worker waits here for a chunk
	std::condition_variable done_cv; // a region's caller waits here for its last chunk
	std::deque<Job> queue;
	std::vector<std::thread> workers;
	bool started = false;
	bool stopping = false;
};

// Never destroyed. As a plain static it would be torn down at library unload with its threads still
// joinable whenever `shutdown` did not run first — std::terminate on the way out — so it lives on the heap
// and the process reclaims it.
PoolState &pool() {
	static PoolState *s = new PoolState();
	return *s;
}

std::atomic<bool> s_shut_down{ false };

// How many regions THIS thread is inside. Workers sit at 1 for life and a caller is at 1 while its region
// runs, so a parallel loop reached from inside a chunk sees > 0 and runs serial: queueing it would have the
// chunk wait on a pool it is occupying.
thread_local int t_depth = 0;

// Runs the chunk at the front of the queue with the lock released, then counts it done. `p_lock` is held
// on entry and on return.
void run_front(PoolState &p_pool, std::unique_lock<std::mutex> &p_lock) {
	const Job job = p_pool.queue.front();
	p_pool.queue.pop_front();
	p_lock.unlock();
	job.fn(job.ctx, job.begin, job.end);
	p_lock.lock();
	if (--job.region->pending == 0) {
		p_pool.done_cv.notify_all();
	}
}

void worker_main() {
	t_depth = 1;
	PoolState &p = pool();
	std::unique_lock<std::mutex> lock(p.mutex);
	while (true) {
		p.work_cv.wait(lock, [&p] { return p.stopping || !p.queue.empty(); });
		if (p.queue.empty()) {
			return; // stopping, and nothing left to finish
		}
		run_front(p, lock);
	}
}

} // namespace

int Pasture3DThreadPool::_chunk_count(int p_total, int p_min_per_chunk) {
	if (t_depth > 0 || s_shut_down.load(std::memory_order_relaxed)) {
		return 1;
	}
	const unsigned int threads = thread_count();
	if (threads <= 1) {
		return 1;
	}
	const int per = std::max(p_min_per_chunk, 1);
	return std::min((int)threads, (p_total + per - 1) / per);
}

void Pasture3DThreadPool::_run(ChunkFn p_fn, void *p_ctx, int p_total, int p_num_chunks) {
	PoolState &p = pool();
	const int per = (p_total + p_num_chunks - 1) / p_num_chunks;
	Region region;
	{
		std::lock_guard<std::mutex> lock(p.mutex);
		if (!p.started && !p.stopping) {
			// One fewer than the hardware threads: the caller always runs a chunk itself.
			p.started = true;
			const unsigned int hw = std::max(1u, std::thread::hardware_concurrency());
			const unsigned int count = std::max(1u, hw - 1);
			p.workers.reserve(count);
			for (unsigned int t = 0; t < count; t++) {
				p.workers.emplace_back(worker_main);
			}
		}
		for (int c = 1; c < p_num_chunks; c++) {
			const int begin = c * per;
			if (begin >= p_total) {
				break;
			}
			p.queue.push_back({ p_fn, p_ctx, begin, std::min(begin + per, p_total), &region });
			region.pending++;
		}
	}
	p.work_cv.notify_all();

	t_depth++;
	p_fn(p_ctx, 0, std::min(per, p_total));
	{
		// HELP rather than sleep while anything is queued — this region's chunks or another's. The caller
		// only sleeps once the queue is empty, when every chunk it is waiting for is already running on some
		// thread, so the wait always ends. After `shutdown` there are no workers and this loop runs them all.
		std::unique_lock<std::mutex> lock(p.mutex);
		while (region.pending > 0) {
			if (!p.queue.empty()) {
				run_front(p, lock);
			} else {
				p.done_cv.wait(lock);
			}
		}
	}
	t_depth--;
}

void Pasture3DThreadPool::shutdown() {
	s_shut_down.store(true, std::memory_order_relaxed);
	PoolState &p = pool();
	std::vector<std::thread> workers;
	{
		std::lock_guard<std::mutex> lock(p.mutex);
		p.stopping = true;
		workers.swap(p.workers);
	}
	p.work_cv.notify_all();
	for (std::thread &t : workers) {
		if (t.joinable()) {
			t.join();
		}
	}
}
