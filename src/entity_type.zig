pub const EntityId = u64;
pub const Entity = packed struct {
    id: EntityId,
};

/// used to retrieve a specific entity
pub const EntityRef = u16;

pub const MapContext = struct {
    pub fn hash(self: MapContext, e: Entity) u32 {
        _ = self;
        // id is already unique
        return @intCast(e.id);
    }
    pub fn eql(self: MapContext, e1: Entity, e2: Entity, index: usize) bool {
        _ = self;
        _ = index;
        return e1.id == e2.id;
    }
};
pub const Map = @import("std").ArrayHashMap(Entity, usize, MapContext, false);
