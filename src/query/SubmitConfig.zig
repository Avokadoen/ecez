const storage = @import("../storage.zig");

pub fn verifyStorageType(comptime Storage: type) void {
    if (@inComptime() == false) {
        @compileError(@src().fn_name ++ " must be called with comptime"); // ecez bug!
    }

    const storage_info = @typeInfo(Storage);
    if (storage_info != .pointer) {
        // Submitted query with non storage type
        @compileError("Query storage must be pointer to ecez.Storage, got " ++ @typeName(Storage));
    }

    const StorageInnerType = storage_info.pointer.child;
    if (@hasDecl(StorageInnerType, "EcezType") == false or StorageInnerType.EcezType != storage.StorageType) {
        // Submitted query with non storage type
        @compileError("Query storage must be pointer to ecez.Storage, got " ++ @typeName(Storage));
    }
}
