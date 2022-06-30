pub const EntityId = u32;
pub const Entity = struct {
    id: EntityId,
};
/// used to retrieve a specific entity
pub const EntityRef = struct {
    /// index to the archetype that contain the entity
    tree_node_index: usize,
};
