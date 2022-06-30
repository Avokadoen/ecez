const std = @import("std");
const testing = std.testing;

// TODO: export types :)

test {
    _ = @import("World.zig");
    _ = @import("ArcheTree.zig");
    _ = @import("Archetype.zig");
    _ = @import("query.zig");
}
