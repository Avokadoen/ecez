/// Entity ID type
pub const EntityId = u64;

/// An opaque representation of a entity which can be used to interact with it
pub const Entity = packed struct {
    /// Unique ID of the entity
    id: EntityId,
};
