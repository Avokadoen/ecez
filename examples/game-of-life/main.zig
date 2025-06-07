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

const Components = struct {
    pub const GridPos = packed struct {
        x: u8,
        y: u8,
    };

    pub const Health = struct {
        // We must store two health values per cell so that only previous cell state affect
        // neighbouring cells
        alive: [2]bool,
        active_cell_index: u2,
    };

    // new line line component
    pub const LinePos = struct {
        nth: u8,
    };

    pub const RenderTarget = struct {
        output_buffer: []u8,
    };
};

// Event argument
const GridConfig = struct {
    dimension_x: usize,
    dimension_y: usize,
    cell_count: usize,
};

const Storage = ecez.CreateStorage(.{
    Components.GridPos,
    Components.Health,
    Components.LinePos,
    Components.RenderTarget,
});

const Scheduler = ecez.CreateScheduler(.{ecez.Event(
    "loop",
    .{
        renderCellSystem,
        renderLineSystem,
        busyWorkSystem,
        busyWorkSystem,
        busyWorkSystem,
        flushBufferSystem,
        updateCellSystem,
    },
    .{},
)});

const EventArgument = struct {
    grid_config: GridConfig,
    render_entity: ecez.Entity,
    entity_grid: []const ecez.Entity,
};

pub fn main() anyerror!void {
    ztracy.SetThreadName("main thread");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.log.err("leak detected", .{});
        }
    }
    var tracy_allocator = ztracy.TracyAllocator.init(gpa.allocator());

    // optionally profile memory usage with tracy
    const allocator = tracy_allocator.allocator();

    const grid_config = GridConfig{
        .dimension_x = dimension_x,
        .dimension_y = dimension_y,
        .cell_count = dimension_x * dimension_y,
    };

    var storage = try Storage.init(allocator);
    defer storage.deinit();

    var scheduler = try Scheduler.init(.{
        .pool_allocator = gpa.allocator(),
        .query_submit_allocator = gpa.allocator(),
    });
    defer scheduler.deinit();

    const init_seed: u64 = @intCast(std.time.timestamp());
    var rng = std.Random.DefaultPrng.init(init_seed);

    // initialize the output buffer on the stack
    var output_buffer: [dimension_x * dimension_y * characters_per_cell + dimension_y]u8 = undefined;
    const render_entity = try storage.createEntity(.{Components.RenderTarget{
        .output_buffer = &output_buffer,
    }});

    // create all cells
    const entity_grid = create_cell_blk: {
        const cell_create_zone = ztracy.ZoneNC(@src(), "Create Cells", Color.purple);
        defer cell_create_zone.End();

        const Cell = struct {
            pos: Components.GridPos,
            health: Components.Health,
        };

        var cells: [grid_config.cell_count]ecez.Entity = undefined;
        try storage.ensureUnusedCapacity(Cell, cells.len);
        for (&cells, 0..) |*cell, cell_index| {
            const alive = rng.random().float(f32) < spawn_threshold;
            cell.* = storage.createEntityAssumeCapacity(Cell{
                .pos = Components.GridPos{
                    .x = @intCast(cell_index % grid_config.dimension_x),
                    .y = @intCast(cell_index / grid_config.dimension_x),
                },
                .health = Components.Health{
                    .alive = [_]bool{ alive, alive },
                    .active_cell_index = 0,
                },
            });
        }

        break :create_cell_blk cells;
    };

    // create new lines
    {
        const line_create_zone = ztracy.ZoneNC(@src(), "Create New Lines", Color.green);
        defer line_create_zone.End();

        const Line = struct {
            pos: Components.LinePos,
        };

        try storage.ensureUnusedCapacity(Line, dimension_y + 1);
        for (1..dimension_y + 1) |i| {
            _ = storage.createEntityAssumeCapacity(.{
                .pos = Components.LinePos{ .nth = @intCast(i) },
            });
        }
    }

    while (true) {
        defer ztracy.FrameMark();

        // schedule a new update cycle
        scheduler.dispatchEvent(&storage, .loop, EventArgument{
            .grid_config = grid_config,
            .render_entity = render_entity,
            .entity_grid = &entity_grid,
        });

        // wait for previous update and render
        scheduler.waitEvent(.loop);
    }
}

const RenderTargetWriteView = Storage.Subset(
    .{*Components.RenderTarget},
);
const RenderCellQuery = ecez.Query(
    struct {
        pos: Components.GridPos,
        health: Components.Health,
    },
    .{},
    .{},
);
pub fn renderCellSystem(
    query: *RenderCellQuery,
    render_view: *RenderTargetWriteView,
    event_arg: EventArgument,
) void {
    const zone = ztracy.ZoneNC(@src(), "Render Cell", Color.red);
    defer zone.End();

    const render = render_view.getComponent(event_arg.render_entity, *Components.RenderTarget) catch unreachable;
    while (query.next()) |cell| {
        const cell_x: usize = @intCast(cell.pos.x);
        const cell_y: usize = @intCast(cell.pos.y);

        const new_line_count = cell_y;
        const start: usize = (cell_x + (cell_y * event_arg.grid_config.dimension_x)) * characters_per_cell + new_line_count;

        const alive = cell.health.alive[cell.health.active_cell_index];
        if (alive) {
            const output = "[X]";
            inline for (output, 0..) |o, i| {
                render.output_buffer[start + i] = o;
            }
        } else {
            const output = "[ ]";
            inline for (output, 0..) |o, i| {
                render.output_buffer[start + i] = o;
            }
        }
    }
}

const LinePosQuery = ecez.Query(
    struct {
        pos: Components.LinePos,
    },
    .{},
    .{},
);
pub fn renderLineSystem(
    query: *LinePosQuery,
    render_view: *RenderTargetWriteView,
    event_arg: EventArgument,
) void {
    const zone = ztracy.ZoneNC(@src(), "Render newline", Color.turquoise);
    defer zone.End();

    const render = render_view.getComponent(event_arg.render_entity, *Components.RenderTarget) catch unreachable;
    while (query.next()) |line| {
        const nth: usize = @intCast(line.pos.nth);

        const new_line_index = nth * event_arg.grid_config.dimension_x * characters_per_cell + nth - 1;
        render.output_buffer[new_line_index] = '\n';
    }
}

const GridPosQuery = ecez.Query(
    struct { pos: Components.GridPos },
    .{},
    .{},
);
pub fn busyWorkSystem(query: *GridPosQuery) void {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.turquoise);
    defer zone.End();

    while (query.next()) |cell| {
        for (0..10_000) |index| {
            if (index == cell.pos.x and index == cell.pos.y) {
                break;
            }
        }
    }
}

const RenderTargetReadView = Storage.Subset(
    .{Components.RenderTarget},
);
pub fn flushBufferSystem(
    render_view: *RenderTargetReadView,
    event_arg: EventArgument,
) void {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.turquoise);
    defer zone.End();

    const render = render_view.getComponent(event_arg.render_entity, Components.RenderTarget) catch unreachable;
    std.log.info("\n{s}\n\n", .{render.output_buffer});
}

const PosHealthQuery = ecez.Query(
    struct {
        pos: Components.GridPos,
        health: *Components.Health,
    },
    .{},
    .{},
);
const HealthView = Storage.Subset(
    .{Components.Health},
);
pub fn updateCellSystem(
    pos_health_query: *PosHealthQuery,
    health_view: *HealthView,
    event_arg: EventArgument,
) void {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.turquoise);
    defer zone.End();

    while (pos_health_query.next()) |cell| {
        const cell_x: i32 = @intCast(cell.pos.x);
        const cell_y: i32 = @intCast(cell.pos.y);

        const current_index = cell_x + (cell_y * @as(i32, @intCast(event_arg.grid_config.dimension_x)));

        const up = -@as(i32, @intCast(event_arg.grid_config.dimension_x));
        const left = -1;
        const right = -left;
        const down = -up;

        const neighbour_index: usize = @intCast((cell.health.active_cell_index + 1) % 2);
        const write_index: usize = @intCast(cell.health.active_cell_index);
        defer cell.health.active_cell_index = @intCast(neighbour_index);

        var neighbour_sum: u8 = 0;

        // check left neighbours
        if (cell_x > 0) {
            var cursor = current_index + left;
            for ([_]i32{ down, up, up }) |offset| {
                cursor += offset;
                if (cursor >= 0 and cursor < event_arg.grid_config.cell_count) {
                    const neighbour_entity = event_arg.entity_grid[@intCast(cursor)];
                    const neighbour_health = health_view.getComponent(neighbour_entity, Components.Health) catch unreachable;
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
                    const neighbour_entity = event_arg.entity_grid[@intCast(cursor)];
                    const neighbour_health = health_view.getComponent(neighbour_entity, Components.Health) catch unreachable;
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
                const neighbour_entity = event_arg.entity_grid[@intCast(cursor)];
                const neighbour_health = health_view.getComponent(neighbour_entity, Components.Health) catch unreachable;
                const alive = neighbour_health.alive[neighbour_index];
                if (alive) {
                    neighbour_sum += 1;
                }
            }
        }

        cell.health.alive[write_index] = blk: {
            if (neighbour_sum == 2) {
                break :blk cell.health.alive[neighbour_index];
            } else if (neighbour_sum == 3) {
                break :blk true;
            } else {
                break :blk false;
            }
        };
    }
}

test "systems produce expected 3x3 grid state" {
    const grid_config = GridConfig{
        .dimension_x = 3,
        .dimension_y = 3,
        .cell_count = 3 * 3,
    };

    var storage = try Storage.init(std.testing.allocator);
    defer storage.deinit();

    var scheduler = try Scheduler.init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    var output_buffer: [3 * 3 * characters_per_cell + 3]u8 = undefined;
    const render_entity = try storage.createEntity(.{Components.RenderTarget{
        .output_buffer = &output_buffer,
    }});

    var cell_entities: [3 * 3]ecez.Entity = undefined;

    const event_arg = EventArgument{
        .grid_config = grid_config,
        .render_entity = render_entity,
        .entity_grid = &cell_entities,
    };

    { // Still life: Block
        for ([_]bool{
            true,  true,  false,
            true,  true,  false,
            false, false, false,
        }, &cell_entities, 0..) |alive, *entity, i| {
            entity.* = try storage.createEntity(.{
                .pos = Components.GridPos{
                    .x = @intCast(i % grid_config.dimension_x),
                    .y = @intCast(i / grid_config.dimension_x),
                },
                .health = Components.Health{
                    .alive = [_]bool{ alive, alive },
                    .active_cell_index = 0,
                },
            });
        }

        scheduler.dispatchEvent(&storage, .loop, event_arg);
        scheduler.waitEvent(.loop);

        for ([_]bool{
            true,  true,  false,
            true,  true,  false,
            false, false, false,
        }, &cell_entities) |alive, entity| {
            const cell = try storage.getComponents(entity, struct { h: Components.Health });
            try std.testing.expectEqual(alive, cell.h.alive[0]);
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
            storage.setComponents(
                entity,
                .{
                    Components.Health{
                        .alive = [_]bool{ alive, alive },
                        .active_cell_index = 0,
                    },
                },
            ) catch unreachable;
        }

        scheduler.dispatchEvent(&storage, .loop, event_arg);
        scheduler.waitEvent(.loop);

        for (&cell_entities, state_2) |entity, alive| {
            const cell = try storage.getComponents(entity, struct { h: Components.Health });
            try std.testing.expectEqual(alive, cell.h.alive[0]);
        }

        scheduler.dispatchEvent(&storage, .loop, event_arg);
        scheduler.waitEvent(.loop);

        for (&cell_entities, state_1) |entity, alive| {
            const cell = try storage.getComponents(entity, struct { h: Components.Health });
            try std.testing.expectEqual(alive, cell.h.alive[1]);
        }
    }

    { // 2 edge lines, len 2, y axis
        const state_1 = [_]bool{
            false, false, false,
            true,  false, true,
            true,  false, true,
        };

        const state_2 = [_]bool{
            false, false, false,
            false, false, false,
            false, false, false,
        };

        for (&cell_entities, state_1) |entity, alive| {
            storage.setComponents(
                entity,
                .{
                    Components.Health{
                        .alive = [_]bool{ alive, alive },
                        .active_cell_index = 0,
                    },
                },
            ) catch unreachable;
        }

        scheduler.dispatchEvent(&storage, .loop, event_arg);
        scheduler.waitEvent(.loop);

        for (&cell_entities, state_2) |entity, alive| {
            const cell = try storage.getComponents(entity, struct { h: Components.Health });
            try std.testing.expectEqual(alive, cell.h.alive[0]);
        }
    }

    { // middle line, len 2, y axis
        const state_1 = [_]bool{
            false, false, false,
            false, true,  false,
            false, true,  false,
        };

        const state_2 = [_]bool{
            false, false, false,
            false, false, false,
            false, false, false,
        };

        for (&cell_entities, state_1) |entity, alive| {
            storage.setComponents(
                entity,
                .{
                    Components.Health{
                        .alive = [_]bool{ alive, alive },
                        .active_cell_index = 0,
                    },
                },
            ) catch unreachable;
        }

        scheduler.dispatchEvent(&storage, .loop, event_arg);
        scheduler.waitEvent(.loop);

        for (&cell_entities, state_2) |entity, alive| {
            const cell = try storage.getComponents(entity, struct { h: Components.Health });
            try std.testing.expectEqual(alive, cell.h.alive[0]);
        }
    }
}
