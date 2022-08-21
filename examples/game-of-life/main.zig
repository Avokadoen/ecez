const std = @import("std");
const ecez = @import("ecez");

const ztracy = @import("ztracy");

const Color = ecez.misc.Color;

const spawn_threshold = 0.4;
const characters_per_cell = 3;
const grid_dimensions = 30;
const cell_count = grid_dimensions * grid_dimensions;
const new_lines = grid_dimensions;

// Currently we have to "cheat" a bit by storing some global state
// add one character extra per line for newline
var output_buffer: [cell_count * characters_per_cell + new_lines]u8 = undefined;

pub fn main() anyerror!void {
    ztracy.SetThreadName("main thread");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit()) {
            std.log.err("leak detected", .{});
        }
    }
    var aa = std.heap.ArenaAllocator.init(gpa.allocator());
    // optionally profile memory usage with tracy
    const allocator = ecez.tracy_alloc.TracyAllocator(std.heap.ArenaAllocator).init(aa).allocator();

    var world = try ecez.WorldBuilder().WithArchetypes(.{
        Cell,
        Flush,
        NewLine,
    }).WithSystems(.{
        // systems are currently order-dependent
        // this will change in the future, but there will also be order forcing semantics
        Cell.render,
        NewLine.render,
        Flush,
        Cell.tick,
    }).init(allocator, .{});
    defer world.deinit();

    var rng = std.rand.DefaultPrng.init(@intCast(u64, std.time.timestamp()));

    // create all cells
    {
        const cell_create_zone = ztracy.ZoneNC(@src(), "Create Cells", Color.Light.purple);
        defer cell_create_zone.End();

        var i: usize = 0;
        while (i < cell_count) : (i += 1) {
            _ = try world.createEntity(Cell{
                .pos = .{
                    .x = @intCast(u8, i % grid_dimensions),
                    .y = @intCast(u8, i / grid_dimensions),
                },
                .health = .{ .alive = rng.random().float(f32) < spawn_threshold },
            });
        }
    }

    // create new lines
    {
        const line_create_zone = ztracy.ZoneNC(@src(), "Create New Lines", Color.Light.green);
        defer line_create_zone.End();

        var i: u8 = 1;
        while (i <= new_lines) : (i += 1) {
            _ = try world.createEntity(NewLine{ .pos = .{ .nth = i } });
        }
    }

    // create flush entity
    _ = try world.createEntity(Flush{});

    var refresh_delay = std.Thread.ResetEvent{};
    while (true) {
        ztracy.FrameMarkNamed("gameloop");
        try world.dispatch();

        refresh_delay.timedWait(std.time.ns_per_s) catch {};
    }
}

// Cell components
const GridPos = struct {
    x: u8,
    y: u8,
};
const Health = struct {
    alive: bool,
};

// The cell archetype
const Cell = struct {
    pos: GridPos,
    health: Health,

    // systems must work on components (not archetypes)
    pub fn render(pos: GridPos, health: Health) void {
        const zone = ztracy.ZoneNC(@src(), "Render Cell", Color.Light.red);
        defer zone.End();

        const cell_x = @intCast(usize, pos.x);
        const cell_y = @intCast(usize, pos.y);

        const new_line_count = cell_y;
        const start: usize = (cell_x + (cell_y * grid_dimensions)) * characters_per_cell + new_line_count;

        if (health.alive) {
            const output = "[X]";
            inline for (output) |o, i| {
                output_buffer[start + i] = o;
            }
        } else {
            const output = "[ ]";
            inline for (output) |o, i| {
                output_buffer[start + i] = o;
            }
        }
    }

    pub fn tick(pos: GridPos, health: *Health) void {
        const zone = ztracy.ZoneNC(@src(), "Update Cell", Color.Light.red);
        defer zone.End();

        const cell_x = @intCast(usize, pos.x);
        const cell_y = @intCast(usize, pos.y);

        // again here we have to cheat by reading the output buffer
        const new_line_count = cell_y;
        const start = (cell_x + (cell_y * grid_dimensions)) * characters_per_cell + new_line_count + 1;

        const up = -@intCast(i32, cell_y * grid_dimensions * characters_per_cell + 1);
        const down = -up;
        const left = -characters_per_cell;
        const right = characters_per_cell;
        var index = @intCast(i32, start);

        var neighbour_sum: u8 = 0;
        for ([_]i32{ left, up, right, right, down, down, left, left }) |delta| {
            index += delta;
            if (index > 0 and index < output_buffer.len) {
                if (output_buffer[@intCast(usize, index)] == 'X') {
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
};

const FlushTag = struct {};
const Flush = struct {
    tag: FlushTag = .{},

    pub fn buffer(flush: FlushTag) void {
        const zone = ztracy.ZoneNC(@src(), "Flush buffer", Color.Light.turquoise);
        defer zone.End();

        _ = flush;
        std.debug.print("{s}\n", .{output_buffer});
        std.debug.print("-" ** (grid_dimensions * characters_per_cell) ++ "\n", .{});
    }
};

// new line line component
const LinePos = struct {
    nth: u8,
};
// new line archetype
const NewLine = struct {
    pos: LinePos,

    pub fn render(pos: LinePos) void {
        const zone = ztracy.ZoneNC(@src(), "Render newline", Color.Light.turquoise);
        defer zone.End();
        const nth = @intCast(usize, pos.nth);

        output_buffer[nth * grid_dimensions * characters_per_cell + nth - 1] = '\n';
    }
};
