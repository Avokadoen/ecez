const std = @import("std");
const builtin = @import("builtin");
const Pool = @This();
const ResetEvent = std.Thread.ResetEvent;

const ztracy = @import("ztracy");
const Color = @import("misc.zig").Color;

// Copy of zig master Thread.Pool

mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},
run_queue: RunQueue = .{},
is_running: bool = true,
allocator: std.mem.Allocator,
threads: []std.Thread,

const RunQueue = std.DoublyLinkedList(Runnable);
const Runnable = struct {
    runFn: RunProto,
};

const RunProto = *const fn (*Runnable) FnStatus;

const FnStatus = enum {
    yield,
    done,
};

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

    const thread_count = options.n_jobs orelse @max(1, std.Thread.getCpuCount() catch 1);

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

// TODO: we know statically how much memory is needed and should not need allocator
/// MODIFIED STD:
///
/// In the case that queuing the function call fails to allocate memory, or the
/// target is single-threaded, the function is called directly.
pub fn spawnRe(
    pool: *Pool,
    comptime event_dependency_indices: []const u32,
    event_collection: []ResetEvent,
    this_reset_event: *ResetEvent,
    comptime func: anytype,
    args: anytype,
) void {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
    defer zone.End();

    this_reset_event.reset();

    if (builtin.single_threaded) {
        @call(.auto, func, args);
        this_reset_event.set();
        return;
    }

    const Args = @TypeOf(args);
    const Closure = struct {
        arguments: Args,
        pool: *Pool,
        run_node: RunQueue.Node = .{ .data = .{ .runFn = runFn } },
        this_reset_event: *ResetEvent,
        event_dependency_indices: []const u32,
        event_collection: []ResetEvent,

        fn runFn(runnable: *Runnable) FnStatus {
            const thread_zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer thread_zone.End();
            const run_node: *RunQueue.Node = @fieldParentPtr("data", runnable);
            const closure: *@This() = @alignCast(@fieldParentPtr("run_node", run_node));

            // wait for system dependencies to complete
            for (closure.event_dependency_indices) |dependency_index| {
                if (false == closure.event_collection[dependency_index].isSet()) {
                    return .yield;
                }
            }

            @call(.auto, func, closure.arguments);
            closure.this_reset_event.set();

            // The thread pool's allocator is protected by the mutex.
            const mutex = &closure.pool.mutex;
            mutex.lock();
            defer mutex.unlock();

            closure.pool.allocator.destroy(closure);

            return .done;
        }
    };

    {
        pool.mutex.lock();

        // TODO: avoid constant alloc, pool previous allocs, or use a more fitting allocator for the pool
        const closure = pool.allocator.create(Closure) catch {
            pool.mutex.unlock();
            @call(.auto, func, args);
            this_reset_event.set();
            return;
        };
        closure.* = .{
            .arguments = args,
            .pool = pool,
            .this_reset_event = this_reset_event,
            .event_dependency_indices = event_dependency_indices,
            .event_collection = event_collection,
        };

        pool.run_queue.prepend(&closure.run_node);
        pool.mutex.unlock();
    }

    // Notify waiting threads outside the lock to try and keep the critical section small.
    pool.cond.signal();
}

fn worker(pool: *Pool) void {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
    defer zone.End();

    pool.mutex.lock();
    defer pool.mutex.unlock();

    while (true) {
        while (pool.run_queue.pop()) |run_node| {
            const fn_outcome = run_fn_blk: {
                // Temporarily unlock the mutex in order to execute the run_node
                pool.mutex.unlock();
                defer pool.mutex.lock();
                const runFn = run_node.data.runFn;
                break :run_fn_blk runFn(&run_node.data);
            };

            if (.yield == fn_outcome) {
                pool.run_queue.prepend(run_node);
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
