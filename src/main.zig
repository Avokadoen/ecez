const std = @import("std");
const testing = std.testing;

pub const CreateWorld = @import("world.zig").CreateWorld;
pub const ArcheTree = @import("ArcheTree.zig");
pub const Archetype = @import("Archetype.zig");
pub const misc = @import("misc.zig");

test {
    _ = @import("world.zig");
    _ = @import("ArcheTree.zig");
    _ = @import("Archetype.zig");
    _ = @import("query.zig");
}
