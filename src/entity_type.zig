/// Entity ID type
pub const EntityId = u32;

/// An opaque representation of a entity which can be used to interact with it
pub const Entity = packed struct {
    /// Unique ID of the entity
    id: EntityId,
};

/// Used to retrieve the archetype of a specific entity
pub const EntityRef = u16;
