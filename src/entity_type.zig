pub const EntityId = usize;
pub const Entity = struct {
    id: EntityId,
};
/// used to retrieve a specific entity
pub const EntityRef = struct {
    /// index to the archetype that contain the entity
    index: usize,
};
