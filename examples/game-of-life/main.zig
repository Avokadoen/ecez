const std = @import("std");
const ecez = @import("ecez");

const ztracy = @import("ztracy");

const Color = ecez.misc.Color;

const spawn_threshold = 0.4;
const characters_per_cell = 3;
const grid_dimensions = 30;
const cell_count = grid_dimensions * grid_dimensions;
const new_lines = grid_dimensions;

pub fn main() anyerror!void {
    ztracy.SetThreadName("main thread");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit()) {
            std.log.err("leak detected", .{});
        }
    }
    var aa = std.heap.ArenaAllocator.init(gpa.allocator());
    var tracy_allocator = ecez.tracy_alloc.TracyAllocator(std.heap.ArenaAllocator).init(aa);
    // optionally profile memory usage with tracy
    const allocator = tracy_allocator.allocator();

    // initialize the output buffer on the stack
    const render_target = RenderTarget{
        .output_buffer = undefined,
    };

    var world = try ecez.WorldBuilder().WithComponents(.{
        GridPos,
        Health,
        LinePos,
        FlushTag,
    }).WithEvents(.{ecez.Event("loop", .{
        renderCell,
        renderLine,
        ecez.DependOn(flushBuffer, .{ renderCell, renderLine }),
        ecez.DependOn(tickCell, .{flushBuffer}),
    }, .{})}).WithSharedState(.{
        RenderTarget,
    }).init(allocator, .{render_target});
    defer world.deinit();

    var rng = std.rand.DefaultPrng.init(@intCast(u64, std.time.timestamp()));

    // create all cells
    {
        const cell_create_zone = ztracy.ZoneNC(@src(), "Create Cells", Color.Light.purple);
        defer cell_create_zone.End();

        // Workaround issue https://github.com/ziglang/zig/issues/3915 by declaring a type for entity,
        // should be valid to use createEntity(.{ Component1, Component2 }) in most cases ...
        const Cell = std.meta.Tuple(&[_]type{ GridPos, Health });

        var i: usize = 0;
        while (i < cell_count) : (i += 1) {
            _ = try world.createEntity(Cell{
                GridPos{
                    .x = @intCast(u8, i % grid_dimensions),
                    .y = @intCast(u8, i / grid_dimensions),
                },
                Health{ .alive = rng.random().float(f32) < spawn_threshold },
            });
        }
    }

    // create new lines
    {
        const line_create_zone = ztracy.ZoneNC(@src(), "Create New Lines", Color.Light.green);
        defer line_create_zone.End();

        const Line = std.meta.Tuple(&[_]type{LinePos});
        var i: u8 = 1;
        while (i <= new_lines) : (i += 1) {
            _ = try world.createEntity(Line{LinePos{ .nth = i }});
        }
    }

    // create flush entity
    _ = try world.createEntity(.{FlushTag{}});

    var refresh_delay = std.Thread.ResetEvent{};
    while (true) {
        ztracy.FrameMarkNamed("gameloop");

        // wait for previous update and render
        world.waitEvent(.loop);
        // schedule a new update cycle
        try world.triggerEvent(.loop, .{});

        refresh_delay.timedWait(std.time.ns_per_s) catch {};
    }
}

// Shared state
const RenderTarget = struct {
    output_buffer: [cell_count * characters_per_cell + new_lines]u8,
};

// Components
const GridPos = packed struct {
    x: u8,
    y: u8,
};
const Health = struct {
    alive: bool,
};
// new line line component
const LinePos = struct {
    nth: u8,
};
const FlushTag = struct {};

fn renderCell(pos: GridPos, health: Health, render_target: *ecez.SharedState(RenderTarget)) void {
    const zone = ztracy.ZoneNC(@src(), "Render Cell", Color.Light.red);
    defer zone.End();

    const cell_x = @intCast(usize, pos.x);
    const cell_y = @intCast(usize, pos.y);

    const new_line_count = cell_y;
    const start: usize = (cell_x + (cell_y * grid_dimensions)) * characters_per_cell + new_line_count;

    if (health.alive) {
        const output = "[X]";
        inline for (output) |o, i| {
            render_target.output_buffer[start + i] = o;
        }
    } else {
        const output = "[ ]";
        inline for (output) |o, i| {
            render_target.output_buffer[start + i] = o;
        }
    }
}

fn renderLine(pos: LinePos, render_target: *ecez.SharedState(RenderTarget)) void {
    const zone = ztracy.ZoneNC(@src(), "Render newline", Color.Light.turquoise);
    defer zone.End();
    const nth = @intCast(usize, pos.nth);

    render_target.output_buffer[nth * grid_dimensions * characters_per_cell + nth - 1] = '\n';
}

fn flushBuffer(flush: FlushTag, render_target: ecez.SharedState(RenderTarget)) void {
    const zone = ztracy.ZoneNC(@src(), "Flush buffer", Color.Light.turquoise);
    defer zone.End();

    _ = flush;
    std.debug.print("{s}\n", .{render_target.output_buffer});
    std.debug.print("-" ** (grid_dimensions * characters_per_cell) ++ "\n", .{});
}

fn tickCell(pos: GridPos, health: *Health, render_target: ecez.SharedState(RenderTarget)) void {
    const zone = ztracy.ZoneNC(@src(), "Update Cell", Color.Light.red);
    defer zone.End();

    const cell_x = @intCast(usize, pos.x);
    const cell_y = @intCast(usize, pos.y);

    // again here we have to cheat by reading the output buffer
    const new_line_count = cell_y;
    const start = (cell_x + (cell_y * grid_dimensions)) * characters_per_cell + new_line_count + 1;

    const up = -@intCast(i32, grid_dimensions * characters_per_cell + 1);
    const down = -up;
    const left = -characters_per_cell;
    const right = characters_per_cell;
    var index = @intCast(i32, start);

    var neighbour_sum: u8 = 0;
    for ([_]i32{ left, up, right, right, down, down, left, left }) |delta| {
        index += delta;
        if (index > 0 and index < render_target.output_buffer.len) {
            if (render_target.output_buffer[@intCast(usize, index)] == 'X') {
                neighbour_sum += 1;
            }
        }
    }

    health.alive = blk: {
        if (neighbour_sum == 2) {
            break :blk health.alive;
        } else if (neighbour_sum == 3) {
            break :blk true;
        } else {
            break :blk false;
        }
    };
}
