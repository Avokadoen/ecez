const std = @import("std");
const ecez = @import("ecez");

const ztracy = @import("ztracy");

const Color = struct {
    const light_blue = 0x5d_88_de;
    const light_green = 0x5d_de_6b;
};

const spawn_threshold = 0.45;
const characters_per_cell = 3;
const grid_dimensions = 20;
const cell_count = grid_dimensions * grid_dimensions;
const new_lines = grid_dimensions;

// Currently we have to "cheat" a bit by storing some global state
// add one character extra per line for newline
var output_buffer: [cell_count * characters_per_cell + new_lines]u8 = undefined;

pub fn main() anyerror!void {
    ztracy.SetThreadName("main thread");

    var allocator_buffer: [8192 * 24]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buffer);
    const allocator = fba.allocator();

    var world = try ecez.CreateWorld(.{ Cell.render, NewLine.render, Flush.buffer, Cell.tick }).init(allocator);
    defer world.deinit();

    var rng = std.rand.DefaultPrng.init(@intCast(u64, std.time.timestamp()));

    // create all cells
    {
        const cell_create_zone = ztracy.ZoneNC(@src(), "Create Cells", 0x5d_88_de);
        defer cell_create_zone.End();

        var i: usize = 0;
        while (i < cell_count) : (i += 1) {
            var builder = try world.entityBuilder();
            try builder.addComponent(Cell{
                .x = i % grid_dimensions,
                .y = i / grid_dimensions,
                .alive = rng.random().float(f32) < spawn_threshold,
            });
            _ = try world.fromEntityBuilder(&builder);
        }
    }

    // create new lines
    {
        const line_create_zone = ztracy.ZoneNC(@src(), "Create New Lines", 0x5d_de_6b);
        defer line_create_zone.End();

        var i: usize = 1;
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

    var refresh_delay = std.Thread.ResetEvent{};
    while (true) {
        ztracy.FrameMarkNamed("gameloop");

        try world.dispatch();

        refresh_delay.timedWait(std.time.ns_per_s) catch {};
    }
}

const Cell = struct {
    x: usize,
    y: usize,
    // TODO: when iterators are implemnted we can use tag components instead
    alive: bool,

    pub fn render(cell: Cell) void {
        const new_line_count = cell.y;
        const start = (cell.x + (cell.y * grid_dimensions)) * characters_per_cell + new_line_count;
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
        // again here we have to cheat by reading the output buffer
        const new_line_count = cell.y;
        const start = (cell.x + (cell.y * grid_dimensions)) * characters_per_cell + new_line_count + 1;

        const up = -@intCast(i32, cell.y * grid_dimensions * characters_per_cell + 1);
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
        _ = flush;
        std.debug.print("{s}\n", .{output_buffer});
        std.debug.print("-" ** (grid_dimensions * characters_per_cell) ++ "\n", .{});
    }
};
const NewLine = struct {
    nth: usize,

    pub fn render(new_line: NewLine) void {
        output_buffer[new_line.nth * grid_dimensions * characters_per_cell + new_line.nth - 1] = '\n';
    }
};
