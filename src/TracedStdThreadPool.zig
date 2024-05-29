const std = @import("std");
const Pool = @import("StdThreadPool.zig");
const ResetEvent = std.Thread.ResetEvent;

const ztracy = @import("ztracy");

const Color = @import("misc.zig").Color;

const TracedThreadPool = @This();

pub const Options = Pool.Options;

pub fn init(pool: *Pool, options: Options) !void {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
    defer zone.End();

    try pool.init(options);
}

pub fn deinit(pool: *Pool) void {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
    defer zone.End();

    pool.deinit();
}

pub fn spawnRe(pool: *Pool, comptime event_dependency_indices: []const u32, event_collection: []ResetEvent, this_reset_event: *ResetEvent, comptime func: anytype, args: anytype) void {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
    defer zone.End();

    pool.spawnRe(event_dependency_indices, event_collection, this_reset_event, func, args);
}

pub fn spawn(pool: *Pool, comptime func: anytype, args: anytype) !void {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.job_queue);
    defer zone.End();

    pool.spawn(func, args);
}
