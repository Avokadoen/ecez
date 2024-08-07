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

const Storage = ecez.CreateStorage(.{ GridPos, Health, LinePos, FlushTag });

const CellIter = Storage.Query(
    struct { health: Health },
    .{},
).Iter;

const EventArg = struct {
    render_target: *RenderTarget,
    grid_config: GridConfig,
};
const Scheduler = ecez.CreateScheduler(Storage, .{ecez.Event("loop", .{
    RenderCellSystem,
    RenderLineSystem,
    BusyWorkSystem,
    BusyWorkSystem,
    BusyWorkSystem,
    ecez.DependOn(FlushBufferSystem, .{ RenderCellSystem, RenderLineSystem }),
    ecez.DependOn(UpdateCellSystem, .{FlushBufferSystem}),
}, EventArg)});

const Cell = struct {
    pos: GridPos,
    health: Health,
};

const Line = struct {
    pos: LinePos,
};

pub fn main() anyerror!void {
    ztracy.SetThreadName("main thread");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.log.err("leak detected", .{});
        }
    }
    const aa = std.heap.ArenaAllocator.init(gpa.allocator());
    var tracy_allocator = ecez.tracy_alloc.TracyAllocator(std.heap.ArenaAllocator).init(aa);
    // optionally profile memory usage with tracy
    const allocator = tracy_allocator.allocator();

    // initialize the output buffer on the stack
    var output_buffer: [dimension_x * dimension_y * characters_per_cell + dimension_y]u8 = undefined;
    var render_target = RenderTarget{
        .output_buffer = &output_buffer,
    };
    const grid_config = GridConfig{
        .dimension_x = dimension_x,
        .dimension_y = dimension_y,
        .cell_count = dimension_x * dimension_y,
    };

    var storage = try Storage.init(allocator);
    defer storage.deinit();

    var scheduler = try Scheduler.init(allocator, .{});
    defer scheduler.deinit();

    const init_seed: u64 = @intCast(std.time.timestamp());
    var rng = std.rand.DefaultPrng.init(init_seed);

    // create all cells
    {
        const cell_create_zone = ztracy.ZoneNC(@src(), "Create Cells", Color.purple);
        defer cell_create_zone.End();

        for (0..grid_config.cell_count) |i| {
            const alive = rng.random().float(f32) < spawn_threshold;
            _ = try storage.createEntity(Cell{
                .pos = GridPos{
                    .x = @intCast(i % grid_config.dimension_x),
                    .y = @intCast(i / grid_config.dimension_x),
                },
                .health = Health{
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
            _ = try storage.createEntity(Line{
                .pos = LinePos{ .nth = @intCast(i) },
            });
        }
    }

    // create flush entity
    const Flush = struct {
        tag: FlushTag,
    };
    _ = try storage.createEntity(Flush{ .tag = FlushTag{} });

    var event_arg = EventArg{
        .render_target = &render_target,
        .grid_config = grid_config,
    };

    while (true) {
        defer ztracy.FrameMark();

        // schedule a new update cycle
        scheduler.dispatchEvent(&storage, .loop, &event_arg);

        // wait for previous update and render
        scheduler.waitEvent(.loop);
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

const RenderCellSystem = struct {
    pub fn system(pos: GridPos, health: Health, event_arg: *EventArg) void {
        const zone = ztracy.ZoneNC(@src(), "Render Cell", Color.red);
        defer zone.End();

        const cell_x: usize = @intCast(pos.x);
        const cell_y: usize = @intCast(pos.y);

        const new_line_count = cell_y;
        const start: usize = (cell_x + (cell_y * event_arg.grid_config.dimension_x)) * characters_per_cell + new_line_count;

        const alive = health.alive[health.active_cell_index];
        if (alive) {
            const output = "[X]";
            inline for (output, 0..) |o, i| {
                event_arg.render_target.output_buffer[start + i] = o;
            }
        } else {
            const output = "[ ]";
            inline for (output, 0..) |o, i| {
                event_arg.render_target.output_buffer[start + i] = o;
            }
        }
    }
};

const RenderLineSystem = struct {
    pub fn system(pos: LinePos, event_arg: *EventArg) void {
        const zone = ztracy.ZoneNC(@src(), "Render newline", Color.turquoise);
        defer zone.End();
        const nth: usize = @intCast(pos.nth);

        const new_line_index = nth * event_arg.grid_config.dimension_x * characters_per_cell + nth - 1;
        event_arg.render_target.output_buffer[new_line_index] = '\n';
    }
};

const BusyWorkSystem = struct {
    pub fn system(
        pos: GridPos,
    ) void {
        const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.turquoise);
        defer zone.End();

        for (0..10_000) |index| {
            if (index == pos.x and index == pos.y) {
                break;
            }
        }
    }
};

const FlushBufferSystem = struct {
    pub fn system(flush: FlushTag, event_arg: *EventArg) void {
        const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.turquoise);
        defer zone.End();

        _ = flush;
        std.log.info("\n{s}\n\n", .{event_arg.render_target.output_buffer});
    }
};

const UpdateCellSystem = struct {
    pub fn system(
        pos: GridPos,
        health: *Health,
        cell_iter: *CellIter,
        invocation_id: ecez.InvocationCount,
        event_arg: *EventArg,
    ) void {
        const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.turquoise);
        defer zone.End();

        const cell_x: i32 = @intCast(pos.x);
        const cell_y: i32 = @intCast(pos.y);

        const current_index = cell_x + (cell_y * @as(i32, @intCast(event_arg.grid_config.dimension_x)));
        std.debug.assert(invocation_id.number == @as(u64, @intCast(current_index)));

        const up = -@as(i32, @intCast(event_arg.grid_config.dimension_x));
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
                if (cursor >= 0 and cursor < event_arg.grid_config.cell_count) {
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
        if (cell_x < event_arg.grid_config.dimension_x - 1) {
            var cursor = current_index + right;
            for ([_]i32{ down, up, up }) |offset| {
                cursor += offset;
                if (cursor >= 0 and cursor < event_arg.grid_config.cell_count) {
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
            if (cursor >= 0 and cursor < event_arg.grid_config.cell_count) {
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
};

test "systems produce expected 3x3 grid state" {
    var output_buffer: [3 * 3 * characters_per_cell + 3]u8 = undefined;
    // initialize the output buffer on the stack
    var render_target = RenderTarget{
        .output_buffer = &output_buffer,
    };
    const grid_config = GridConfig{
        .dimension_x = 3,
        .dimension_y = 3,
        .cell_count = 3 * 3,
    };

    var storage = try Storage.init(std.testing.allocator);
    defer storage.deinit();

    var scheduler = try Scheduler.init(std.testing.allocator, .{});
    defer scheduler.deinit();

    var cell_entities: [3 * 3]ecez.Entity = undefined;

    var event_arg = EventArg{
        .render_target = &render_target,
        .grid_config = grid_config,
    };

    { // Still life: Block
        for ([_]bool{
            true,  true,  false,
            true,  true,  false,
            false, false, false,
        }, &cell_entities, 0..) |alive, *entity, i| {
            entity.* = try storage.createEntity(Cell{
                .pos = GridPos{
                    .x = @intCast(i % grid_config.dimension_x),
                    .y = @intCast(i / grid_config.dimension_x),
                },
                .health = Health{
                    .alive = [_]bool{ alive, alive },
                    .active_cell_index = 0,
                },
            });
        }

        scheduler.dispatchEvent(&storage, .loop, &event_arg);
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

        for (&cell_entities, state_1) |entity, alive| {
            storage.setComponent(
                entity,
                Health{
                    .alive = [_]bool{ alive, alive },
                    .active_cell_index = 0,
                },
            ) catch unreachable;
        }

        scheduler.dispatchEvent(&storage, .loop, &event_arg);
        scheduler.waitEvent(.loop);

        for (&cell_entities, state_2) |entity, alive| {
            const health = try storage.getComponent(entity, Health);
            try std.testing.expectEqual(alive, health.alive[0]);
        }

        scheduler.dispatchEvent(&storage, .loop, &event_arg);
        scheduler.waitEvent(.loop);

        for (&cell_entities, state_1) |entity, alive| {
            const health = try storage.getComponent(entity, Health);
            try std.testing.expectEqual(alive, health.alive[1]);
        }
    }
}
