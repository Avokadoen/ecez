const ztracy = @import("ztracy");
const zjobs = @import("zjobs");

const Color = @import("misc.zig").Color;

pub const JobId = zjobs.JobId;
pub const Error = zjobs.Error;

/// Used to trace zjobs without injecting tracy as a dependency to zjobs
pub fn TracedJobQueue(comptime config: zjobs.QueueConfig) type {
    return struct {
        const Self = @This();

        const JobQueue = zjobs.JobQueue(config);

        queue: JobQueue,

        /// Initializes the `JobQueue`, required before calling `start()`.
        pub inline fn init() Self {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            return Self{
                .queue = JobQueue.init(),
            };
        }

        /// Calls `stop()` and `join()` as needed.
        pub inline fn deinit(self: *Self) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            self.queue.deinit();
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Spawn threads and begin executing jobs.
        /// `JobQueue` must be initialized, and not yet started or stopped.
        pub inline fn start(self: *Self) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            self.queue.start();
        }

        /// Signals threads to stop running, and prevents scheduling more jobs.
        /// Call `stop()` from any thread.
        pub inline fn stop(self: *Self) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            self.queue.stop();
        }

        /// Waits for all threads to finish, then executes any remaining jobs
        /// before returning.  After `join()` returns, the `JobQueue` has been
        /// reset to its default, uninitialized state.
        /// Call `join()` from the same thread that called `start()`.
        /// `JobQueue` must be initialized and started before calling `join()`.
        /// You may call `join()` before calling `stop()`, but since `join()`
        /// will not return until after `stop()` is called, you must then call
        /// `stop()` from another thread, e.g. from a job.
        pub inline fn join(self: *Self) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            self.queue.join();
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Returns `true` if `init()` has been called, and `join()` has not
        /// yet run to completion.
        pub inline fn isInitialized(self: *const Self) bool {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            return self.queue.isInitialized();
        }

        /// Returns `true` if `start()` has been called, and `join()` has not
        /// yet run to completion.
        pub inline fn isStarted(self: *const Self) bool {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            return self.queue.isStarted();
        }

        /// Returns `true` if `start()` has been called, and `stop()` has not
        /// yet been called.
        pub inline fn isRunning(self: *const Self) bool {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            return self.queue.isRunning();
        }

        /// Returns `true` if `stop()` has been called, and `join()` has not
        /// yet run to completion.
        pub inline fn isStopping(self: *const Self) bool {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            return self.queue.isStopping();
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Returns `true` if the provided `JobId` identifies a job that has
        /// been completed.
        /// Returns `false` for a `JobId` that is scheduled and has not yet
        /// completed execution.
        /// Always returns `true` for `JobId.none`, which is always considered
        /// trivially complete.
        pub inline fn isComplete(self: *const Self, id: JobId) bool {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            return self.queue.isComplete(id);
        }

        /// Returns `true` if the provided `JobId` identifies a job that has
        /// been scheduled and has not yet completed execution.  The job may or
        /// may not already be executing on a background thread.
        /// Returns `false` for a JobId that has not been scheduled, or has
        /// already completed.
        /// Always returns false for `JobId.none`, which is considered
        /// trivially complete.
        pub inline fn isPending(self: *const Self, id: JobId) bool {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            return self.queue.isPending(id);
        }

        /// Returns the number of jobs waiting in the queue.
        /// Only includes jobs that have not yet begun execution.
        pub inline fn numWaiting(self: *const Self) usize {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            return self.queue.numWaiting();
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Inserts a job into the queue, and returns a `JobId` that can be
        /// used to specify dependencies between jobs.
        ///
        /// `prereq` - specifies a job that must run to completion before the
        /// job being scheduled can begin.  To schedule a job that must wait
        /// for more than one job to complete, call `combine()` to consolidate
        /// a set of `JobIds` into a single `JobId` that can be provided as the
        /// `prereq` argument to `schedule()`.
        ///
        /// `job` - provides an instance of a struct that captures the context
        /// and provides a function that will be executed on a separate thread.
        /// The provided `job` must satisfy the following requirements:
        /// * The total size of the job must not exceed `config.max_job_size`
        /// * The job must be an instance of a struct
        /// * The job must declare a function named `exec` with one of the
        ///   following supported signatures:
        /// ```
        ///   fn exec(*@This())
        ///   fn exec(*const @This())
        /// ```
        pub inline fn schedule(self: *Self, prereq: JobId, job: anytype) Error!JobId {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            return self.queue.schedule(prereq, job);
        }

        /// Combines zero or more `JobIds` into a single `JobId` that can be
        /// provided to the `prereq` argument when calling `schedule()`.
        /// This enables scheduling jobs that must wait on the completion of
        /// an arbitrary number of other jobs.
        /// Returns `JobId.none` when `prereqs` is empty.
        /// Returns `prereqs[0]` when `prereqs` contains only one element.
        pub inline fn combine(self: *Self, prereqs: []const JobId) Error!JobId {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            return self.queue.combine(prereqs);
        }

        /// Waits until the specified `prereq` is completed.
        pub inline fn wait(self: *Self, prereq: JobId) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
            defer zone.End();

            return self.queue.wait(prereq);
        }
    };
}
