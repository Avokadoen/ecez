/// Entity ID type
pub const EntityId = u64;

/// An opaque representation of a entity which can be used to interact with it
pub const Entity = packed struct {
    /// Unique ID of the entity
    id: EntityId,
};

/// Used to retrieve the archetype of a specific entity
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
pub const Map = @import("std").ArrayHashMap(Entity, u32, MapContext, false);
