const std = @import("std");
const ecez = @import("ecez");

const ztracy = @import("ztracy");

const Color = ecez.misc.Color;

const spawn_threshold = 0.5;
const characters_per_cell = 3;
const grid_dimensions = 40;
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
    const allocator = ecez.tracy_alloc.TracyAllocator(std.heap.ArenaAllocator).init(aa).allocator();

    var world = try ecez.CreateWorld(.{
        Cell.render,
        NewLine.render,
        Flush.buffer,
        Cell.tick,
    }).init(allocator);
    defer world.deinit();

    var rng = std.rand.DefaultPrng.init(@intCast(u64, std.time.timestamp()));

    // create all cells
    {
        const cell_create_zone = ztracy.ZoneNC(@src(), "Create Cells", Color.Light.purple);
        defer cell_create_zone.End();

        var i: usize = 0;
        while (i < cell_count) : (i += 1) {
            var builder = try world.entityBuilder();
            try builder.addComponent(Cell{
                .x = @intCast(u8, i % grid_dimensions),
                .y = @intCast(u8, i / grid_dimensions),
                .alive = rng.random().float(f32) < spawn_threshold,
            });
            _ = try world.fromEntityBuilder(&builder);
        }
    }

    // create new lines
    {
        const line_create_zone = ztracy.ZoneNC(@src(), "Create New Lines", Color.Light.green);
        defer line_create_zone.End();

        var i: u8 = 1;
        while (i <= new_lines) : (i += 1) {
            var builder = try world.entityBuilder();
            try builder.addComponent(NewLine{ .nth = i });
            _ = try world.fromEntityBuilder(&builder);
        }
    }

    // create flush entity
    {
        var builder = try world.entityBuilder();
        try builder.addComponent(Flush{});
        _ = try world.fromEntityBuilder(&builder);
    }

    while (true) {
        ztracy.FrameMarkNamed("gameloop");
        try world.dispatch();
    }
}

const Cell = struct {
    x: u8,
    y: u8,
    // TODO: when iterators are implemnted we can use tag components instead
    alive: bool,

    pub fn render(cell: Cell) void {
        const zone = ztracy.ZoneNC(@src(), "Render Cell", Color.Light.red);
        defer zone.End();

        const cell_x = @intCast(usize, cell.x);
        const cell_y = @intCast(usize, cell.y);

        const new_line_count = cell_y;
        const start: usize = (cell_x + (cell_y * grid_dimensions)) * characters_per_cell + new_line_count;
        if (cell.alive) {
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

    pub fn tick(cell: *Cell) void {
        const zone = ztracy.ZoneNC(@src(), "Update Cell", Color.Light.red);
        defer zone.End();

        const cell_x = @intCast(usize, cell.x);
        const cell_y = @intCast(usize, cell.y);

        // again here we have to cheat by reading the output buffer
        const new_line_count = cell_y;
        const start = (cell_x + (cell_y * grid_dimensions)) * characters_per_cell + new_line_count + 1;

        const up = -@intCast(i32, cell_y * grid_dimensions * characters_per_cell + 1);
        const down = -up;
        const left = -3;
        const right = 3;
        var index = @intCast(i32, start);

        var neighbour_sum: u8 = 0;
        for ([8]i32{
            left,
            up,
            right,
            right,
            down,
            down,
            left,
            left,
        }) |delta| {
            index += delta;
            if (index > 0 and index < output_buffer.len) {
                if (output_buffer[@intCast(usize, index)] == 'X') {
                    neighbour_sum += 1;
                }
            }
        }

        if (neighbour_sum == 2) {
            cell.alive = cell.alive;
        } else if (neighbour_sum == 3) {
            cell.alive = true;
        } else {
            cell.alive = false;
        }
    }
};
const Flush = struct {
    pub fn buffer(flush: Flush) void {
        const zone = ztracy.ZoneNC(@src(), "Flush buffer", Color.Light.turquoise);
        defer zone.End();

        _ = flush;
        std.debug.print("{s}\n", .{output_buffer});
        std.debug.print("-" ** (grid_dimensions * characters_per_cell) ++ "\n", .{});
    }
};
const NewLine = struct {
    nth: u8,

    pub fn render(new_line: NewLine) void {
        const zone = ztracy.ZoneNC(@src(), "Render newline", Color.Light.turquoise);
        defer zone.End();
        const nth = @intCast(usize, new_line.nth);

        output_buffer[nth * grid_dimensions * characters_per_cell + nth - 1] = '\n';
    }
};
