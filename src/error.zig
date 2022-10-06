pub const ArchetypeError = error{ ComponentMissing, EntityMissing };
pub const OutOfMemory = error{OutOfMemory};
pub const StorageError = ArchetypeError || OutOfMemory;
