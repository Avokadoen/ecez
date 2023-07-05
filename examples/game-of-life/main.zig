const std = @import("std");
const ecez = @import("ecez");

const ztracy = @import("ztracy");

pub const Color = struct {
    pub const red = 0x80_09_09;
    pub const green = 0x11_80_09;
    pub const turquoise = 0x09_5c_80;
    pub const purple = 0x64_09_80;
};

const spawn_threshold = 0.4;
const characters_per_cell = 3;
const dimension_x = 30;
const dimension_y = 30;

const Storage = ecez.CreateStorage(.{ GridPos, Health, LinePos, FlushTag }, .{ RenderTarget, GridConfig });

const CellIter = Storage.Query(
    .exclude_entity,
    .{ecez.include("health", Health)},
    .{},
).Iter;

const Scheduler = ecez.CreateScheduler(Storage, .{ecez.Event("loop", .{
    renderCell,
    renderLine,
    ecez.DependOn(flushBuffer, .{ renderCell, renderLine }),
    ecez.DependOn(tickCell, .{flushBuffer}),
}, .{})});

pub fn main() anyerror!void {
    ztracy.SetThreadName("main thread");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.log.err("leak detected", .{});
        }
    }
    var aa = std.heap.ArenaAllocator.init(gpa.allocator());
    var tracy_allocator = ecez.tracy_alloc.TracyAllocator(std.heap.ArenaAllocator).init(aa);
    // optionally profile memory usage with tracy
    const allocator = tracy_allocator.allocator();

    // initialize the output buffer on the stack
    var output_buffer: [dimension_x * dimension_y * characters_per_cell + dimension_y]u8 = undefined;
    const render_target = RenderTarget{
        .output_buffer = &output_buffer,
    };
    const grid_config = GridConfig{
        .dimension_x = dimension_x,
        .dimension_y = dimension_y,
        .cell_count = dimension_x * dimension_y,
    };

    var storage = try Storage.init(allocator, .{ render_target, grid_config });
    defer storage.deinit();

    var scheduler = Scheduler.init(&storage);
    defer scheduler.deinit();

    const init_seed: u64 = @intCast(std.time.timestamp());
    var rng = std.rand.DefaultPrng.init(init_seed);

    // create all cells
    {
        const cell_create_zone = ztracy.ZoneNC(@src(), "Create Cells", Color.purple);
        defer cell_create_zone.End();

        for (0..grid_config.cell_count) |i| {
            const alive = rng.random().float(f32) < spawn_threshold;
            _ = try storage.createEntity(.{
                GridPos{
                    .x = @intCast(i % grid_config.dimension_x),
                    .y = @intCast(i / grid_config.dimension_x),
                },
                Health{
                    .alive = [_]bool{ alive, alive },
                    .active_cell_index = 0,
                },
            });
        }
    }

    // create new lines
    {
        const line_create_zone = ztracy.ZoneNC(@src(), "Create New Lines", Color.green);
        defer line_create_zone.End();

        for (1..dimension_y + 1) |i| {
            _ = try storage.createEntity(.{
                LinePos{ .nth = @intCast(i) },
            });
        }
    }

    // create flush entity
    _ = try storage.createEntity(.{FlushTag{}});

    var refresh_delay = std.Thread.ResetEvent{};
    while (true) {
        ztracy.FrameMarkNamed("gameloop");

        // wait for previous update and render
        scheduler.waitEvent(.loop);
        // schedule a new update cycle
        scheduler.dispatchEvent(.loop, .{}, .{});

        refresh_delay.timedWait(std.time.ns_per_s) catch {};
    }
}

// Shared state
const RenderTarget = struct {
    output_buffer: []u8,
};
pub const GridConfig = struct {
    dimension_x: usize,
    dimension_y: usize,
    cell_count: usize,
};

// Components
const GridPos = packed struct {
    x: u8,
    y: u8,
};
const Health = struct {
    // We must store two health values per cell so that only previous cell state affect
    // neighbouring cells
    alive: [2]bool,
    active_cell_index: u2,
};
// new line line component
const LinePos = struct {
    nth: u8,
};
const FlushTag = struct {};

fn renderCell(
    pos: GridPos,
    health: Health,
    render_target: *ecez.SharedState(RenderTarget),
    grid_config: ecez.SharedState(GridConfig),
) void {
    const zone = ztracy.ZoneNC(@src(), "Render Cell", Color.red);
    defer zone.End();

    const cell_x: usize = @intCast(pos.x);
    const cell_y: usize = @intCast(pos.y);

    const new_line_count = cell_y;
    const start: usize = (cell_x + (cell_y * grid_config.dimension_x)) * characters_per_cell + new_line_count;

    const alive = health.alive[health.active_cell_index];
    if (alive) {
        const output = "[X]";
        inline for (output, 0..) |o, i| {
            render_target.output_buffer[start + i] = o;
        }
    } else {
        const output = "[ ]";
        inline for (output, 0..) |o, i| {
            render_target.output_buffer[start + i] = o;
        }
    }
}

fn renderLine(
    pos: LinePos,
    render_target: *ecez.SharedState(RenderTarget),
    grid_config: ecez.SharedState(GridConfig),
) void {
    const zone = ztracy.ZoneNC(@src(), "Render newline", Color.turquoise);
    defer zone.End();
    const nth: usize = @intCast(pos.nth);

    render_target.output_buffer[nth * grid_config.dimension_x * characters_per_cell + nth - 1] = '\n';
}

fn flushBuffer(
    flush: FlushTag,
    render_target: ecez.SharedState(RenderTarget),
) void {
    const zone = ztracy.ZoneNC(@src(), "Flush buffer", Color.turquoise);
    defer zone.End();

    _ = flush;
    std.debug.print("{s}\n\n", .{render_target.output_buffer});
}

fn tickCell(
    pos: GridPos,
    health: *Health,
    cell_iter: *CellIter,
    invocation_id: ecez.InvocationCount,
    grid_config: ecez.SharedState(GridConfig),
) void {
    const zone = ztracy.ZoneNC(@src(), "Update Cell", Color.red);
    defer zone.End();

    const cell_x: i32 = @intCast(pos.x);
    const cell_y: i32 = @intCast(pos.y);

    const current_index = cell_x + (cell_y * @as(i32, @intCast(grid_config.dimension_x)));
    std.debug.assert(invocation_id.number == @as(u64, @intCast(current_index)));

    const up = -@as(i32, @intCast(grid_config.dimension_x));
    const left = -1;
    const right = -left;
    const down = -up;

    const neighbour_index: usize = @intCast((health.active_cell_index + 1) % 2);
    const write_index: usize = @intCast(health.active_cell_index);
    defer health.active_cell_index = @intCast(neighbour_index);

    var neighbour_sum: u8 = 0;

    // check left neighbours
    if (cell_x > 0) {
        var cursor = current_index + left;
        for ([_]i32{ down, up, up }) |offset| {
            cursor += offset;
            if (cursor >= 0 and cursor < grid_config.cell_count) {
                cell_iter.skip(@intCast(cursor));
                defer cell_iter.reset();

                const neighbour_health = cell_iter.next().?.health;
                const alive = neighbour_health.alive[neighbour_index];
                if (alive) {
                    neighbour_sum += 1;
                }
            }
        }
    }

    // check right neighbours
    if (cell_x < grid_config.dimension_x - 1) {
        var cursor = current_index + right;
        for ([_]i32{ down, up, up }) |offset| {
            cursor += offset;
            if (cursor >= 0 and cursor < grid_config.cell_count) {
                cell_iter.skip(@intCast(cursor));
                defer cell_iter.reset();

                const neighbour_health = cell_iter.next().?.health;
                const alive = neighbour_health.alive[neighbour_index];
                if (alive) {
                    neighbour_sum += 1;
                }
            }
        }
    }

    // check up & down neighbours
    for ([_]i32{ current_index + up, current_index + down }) |cursor| {
        if (cursor >= 0 and cursor < grid_config.cell_count) {
            cell_iter.skip(@intCast(cursor));
            defer cell_iter.reset();

            const neighbour_health = cell_iter.next().?.health;
            const alive = neighbour_health.alive[neighbour_index];
            if (alive) {
                neighbour_sum += 1;
            }
        }
    }

    health.alive[write_index] = blk: {
        if (neighbour_sum == 2) {
            break :blk health.alive[neighbour_index];
        } else if (neighbour_sum == 3) {
            break :blk true;
        } else {
            break :blk false;
        }
    };
}

test "systems produce expected 3x3 grid state" {
    var output_buffer: [3 * 3 * characters_per_cell + 3]u8 = undefined;
    // initialize the output buffer on the stack
    const render_target = RenderTarget{
        .output_buffer = &output_buffer,
    };
    const grid_config = GridConfig{
        .dimension_x = 3,
        .dimension_y = 3,
        .cell_count = 3 * 3,
    };

    var storage = try Storage.init(std.testing.allocator, .{ render_target, grid_config });
    defer storage.deinit();

    var scheduler = Scheduler.init(&storage);
    defer scheduler.deinit();

    for (1..grid_config.dimension_y + 1) |i| {
        _ = try storage.createEntity(.{
            LinePos{ .nth = @intCast(i) },
        });
    }

    var cell_entities: [3 * 3]ecez.Entity = undefined;

    { // Still life: Block
        for ([_]bool{
            true,  true,  false,
            true,  true,  false,
            false, false, false,
        }, &cell_entities, 0..) |alive, *entity, i| {
            entity.* = try storage.createEntity(.{
                GridPos{
                    .x = @intCast(i % grid_config.dimension_x),
                    .y = @intCast(i / grid_config.dimension_x),
                },
                Health{
                    .alive = [_]bool{ alive, alive },
                    .active_cell_index = 0,
                },
            });
        }

        scheduler.dispatchEvent(.loop, .{}, .{});
        scheduler.waitEvent(.loop);

        for ([_]bool{
            true,  true,  false,
            true,  true,  false,
            false, false, false,
        }, &cell_entities) |alive, entity| {
            const health = try storage.getComponent(entity, Health);
            try std.testing.expectEqual(alive, health.alive[0]);
        }
    }

    { // Oscillator: blinker
        const state_1 = [_]bool{
            false, false, false,
            true,  true,  true,
            false, false, false,
        };

        const state_2 = [_]bool{
            false, true, false,
            false, true, false,
            false, true, false,
        };

        for (&state_1, &cell_entities) |alive, entity| {
            storage.setComponent(
                entity,
                Health{
                    .alive = [_]bool{ alive, alive },
                    .active_cell_index = 0,
                },
            ) catch unreachable;
        }

        scheduler.dispatchEvent(.loop, .{}, .{});
        scheduler.waitEvent(.loop);

        for (&state_2, &cell_entities) |alive, entity| {
            const health = try storage.getComponent(entity, Health);
            try std.testing.expectEqual(alive, health.alive[0]);
        }

        scheduler.dispatchEvent(.loop, .{}, .{});
        scheduler.waitEvent(.loop);

        for (&state_1, &cell_entities) |alive, entity| {
            const health = try storage.getComponent(entity, Health);
            try std.testing.expectEqual(alive, health.alive[1]);
        }
    }
}
