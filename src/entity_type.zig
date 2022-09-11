pub const EntityId = usize;
pub const Entity = struct {
    id: EntityId,
};
/// used to retrieve a specific entity
pub const EntityRef = packed struct {
    type_path_index: u16,
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
