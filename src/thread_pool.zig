const std = @import("std");
const builtin = @import("builtin");

const ztracy = @import("ecez_ztracy.zig");
const Color = @import("misc.zig").Color;

const Dependency = @import("dependency_chain.zig").Dependency;

pub const RunQueue = std.DoublyLinkedList(Runnable);
const RunProto = *const fn (*Runnable) void;
pub const Runnable = struct {
    pub const Index = u32;
    pub const is_done_value = std.math.maxInt(u32);

    entry_index: Index,
    dependencies: []const Dependency,
    other_runnables: []*RunQueue.Node,
    prereq_jobs_inflight: std.atomic.Value(Index),
    grouped_runnables_done: *std.atomic.Value(u32),

    runFn: RunProto,

    pub fn getNode(runnable: *Runnable) *RunQueue.Node {
        return @as(*RunQueue.Node, @fieldParentPtr("data", runnable));
    }
};

// Based on zig std.Thread.Pool
pub fn Create() type {
    return struct {
        const Pool = @This();

        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        run_queue: RunQueue = .{},
        is_running: bool = true,
        allocator: std.mem.Allocator,
        threads: []std.Thread,

        pub const Options = struct {
            allocator: std.mem.Allocator,
            n_jobs: ?u32 = null,
        };

        pub fn init(pool: *Pool, options: Options) !void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            const allocator = options.allocator;

            pool.* = .{
                .allocator = allocator,
                .threads = &[_]std.Thread{},
            };

            if (builtin.single_threaded) {
                return;
            }

            const core_count = std.Thread.getCpuCount() catch 1;
            const thread_count = options.n_jobs orelse @max(1, core_count - 1);

            // kill and join any threads we spawned and free memory on error.
            pool.threads = try allocator.alloc(std.Thread, thread_count);

            var spawned: usize = 0;
            errdefer pool.join(spawned);

            for (pool.threads) |*thread| {
                thread.* = try std.Thread.spawn(.{}, worker, .{pool});
                spawned += 1;
            }
        }

        pub fn deinit(pool: *Pool) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            pool.join(pool.threads.len); // kill and join all threads.

            // TODO: we dont free the allocated thread due to some segfaul, set as undefined instead for now
            pool.threads = undefined;
        }

        fn join(pool: *Pool, spawned: usize) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            if (builtin.single_threaded) {
                return;
            }

            {
                pool.mutex.lock();
                defer pool.mutex.unlock();

                // ensure future worker threads exit the dequeue loop
                pool.is_running = false;
            }

            // wake up any sleeping threads (this can be done outside the mutex)
            // then wait for all the threads we know are spawned to complete.
            pool.cond.broadcast();
            for (pool.threads[0..spawned]) |thread| {
                thread.join();
            }

            pool.allocator.free(pool.threads);
        }

        pub fn Closure(comptime Args: type, comptime func: anytype) type {
            return struct {
                pub const is_done_value = std.math.maxInt(u32);

                arguments: Args,
                pool: *Pool,
                run_node: RunQueue.Node,

                pub fn runFn(runnable: *Runnable) void {
                    const thread_zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
                    defer thread_zone.End();
                    const run_node: *RunQueue.Node = Runnable.getNode(runnable);
                    const closure: *@This() = @alignCast(@fieldParentPtr("run_node", run_node));

                    @call(.auto, func, .{closure.arguments});

                    // The thread pool's allocator is protected by the mutex.
                    const mutex = &closure.pool.mutex;
                    mutex.lock();
                    defer mutex.unlock();
                    closure.pool.allocator.destroy(closure);
                }
            };
        }

        pub fn allocClosure(
            pool: *Pool,
            entry_index: Runnable.Index,
            dependencies: []const Dependency,
            event_runnables: []*RunQueue.Node,
            grouped_runnables_done: *std.atomic.Value(u32),
            args: anytype,
        ) !type_blk: {
            const Args = @TypeOf(args);
            const dispatch_exec_func = Args.exec;
            break :type_blk *Closure(Args, dispatch_exec_func);
        } {
            const Args = @TypeOf(args);
            const dispatch_exec_func = Args.exec;

            const ClosureT = Closure(Args, dispatch_exec_func);

            pool.mutex.lock();
            const closure = try pool.allocator.create(ClosureT);
            pool.mutex.unlock();

            const prereq_jobs_inflight = dependencies[entry_index].prereq_count;
            closure.* = .{ .arguments = args, .pool = pool, .run_node = .{ .data = .{
                .entry_index = entry_index,
                .dependencies = dependencies,
                .other_runnables = event_runnables,
                .prereq_jobs_inflight = std.atomic.Value(Runnable.Index).init(prereq_jobs_inflight),
                .grouped_runnables_done = grouped_runnables_done,
                .runFn = ClosureT.runFn,
            } } };

            return closure;
        }

        // TODO: we know statically how much memory is needed and should not need allocator
        /// MODIFIED STD:
        ///
        /// In the case that queuing the function call fails to allocate memory, or the
        /// target is single-threaded, the function is called directly.
        pub fn spawn(
            pool: *Pool,
            dependendency: Dependency,
            run_node: *RunQueue.Node,
        ) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            if (dependendency.prereq_count == 0) {
                pool.mutex.lock();
                pool.run_queue.prepend(run_node);
                pool.mutex.unlock();

                // Notify waiting threads outside the lock to try and keep the critical section small.
                pool.cond.signal();
            }
        }

        fn worker(pool: *Pool) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            pool.mutex.lock();
            defer pool.mutex.unlock();

            while (true) {
                while (pool.run_queue.pop()) |run_node| {
                    // Temporarily unlock the mutex in order to execute the run_node
                    pool.mutex.unlock();
                    defer pool.mutex.lock();

                    // Grab pointers before closure is destroyed by runFn
                    const signal_indices = run_node.data.dependencies[run_node.data.entry_index].signal_indices;
                    const grouped_runnables_done = run_node.data.grouped_runnables_done;
                    const other_runnables = run_node.data.other_runnables;
                    const runFn = run_node.data.runFn;
                    runFn(&run_node.*.data);

                    _ = grouped_runnables_done.fetchSub(1, .monotonic);

                    for (signal_indices) |signal_index| {
                        const blocking_count = other_runnables[signal_index].data.prereq_jobs_inflight.fetchSub(1, .acq_rel);
                        if (blocking_count == 1) {
                            pool.mutex.lock();
                            pool.run_queue.prepend(other_runnables[signal_index]);
                            pool.mutex.unlock();

                            // Notify waiting threads outside the lock to try and keep the critical section small.
                            pool.cond.signal();
                        }
                    }
                }

                // Stop executing instead of waiting if the thread pool is no longer running.
                if (pool.is_running) {
                    pool.cond.wait(&pool.mutex);
                } else {
                    break;
                }
            }
        }
    };
}
