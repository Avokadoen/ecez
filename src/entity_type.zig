pub const EntityId = u32;
pub const Entity = struct {
    id: EntityId,
};

/// used to retrieve a specific entity
pub const EntityRef = union(enum) {
    void,
    type_index: u15,
};

pub const MapContext = struct {
    pub fn hash(self: MapContext, e: Entity) u32 {
        _ = self;
        // id is already unique
        return @intCast(u32, e.id);
    }
    pub fn eql(self: MapContext, e1: Entity, e2: Entity, index: usize) bool {
        _ = self;
        _ = index;
        return e1.id == e2.id;
    }
};
pub const Map = @import("std").ArrayHashMap(Entity, usize, MapContext, false);
