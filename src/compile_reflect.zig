const std = @import("std");
const sparse_set = @import("sparse_set.zig");
const EntityId = @import("entity_type.zig").EntityId;

pub const SpecialArguments = struct {
    pub const Type = enum {
        event,
        invocation_number,
        presumed_component,
        query,
        exclude_entities_with,
    };

    /// A function to tag individual component types in a tuple as excluded from the system dispatch.
    /// In other words: the system will not be called on entities that also owns component types in components.
    pub fn ExcludeEntitiesWith(comptime components: anytype) type {
        const Components = @TypeOf(components);
        const component_types = reflect_components_blk: {
            const components_info = @typeInfo(Components);
            if (components_info != .Struct) {
                @compileError("ExcludeEntitiesWith argument expects a tuple of component(s), got " ++ @typeName(Components));
            }

            var component_types_: [components_info.Struct.fields.len]type = undefined;
            for (&component_types_, components_info.Struct.fields, 0..) |*component_type, field, field_index| {
                if (type != field.type) {
                    @compileError(std.fmt.comptimePrint("ExcludeEntitiesWith components field {d} was of type {s} expected type", .{ field_index, @typeName(field.type) }));
                }

                component_type.* = components[field_index];
            }

            break :reflect_components_blk component_types_;
        };

        return struct {
            pub const secret_field: Type = .exclude_entities_with;
            pub const exclude_components = component_types;
        };
    }

    /// Special system argument that tells the system how many times the
    /// system has been invoced before in current dispatch
    pub const InvocationCount = struct {
        pub const secret_field: Type = .invocation_number;
        number: u64,
    };

    /// Extract the argument "category" given the argument type T
    pub fn extractType(comptime EventArgument: type, comptime T: type) Type {
        // TODO: should we verify that type is not identified as another special argument?
        if (T == EventArgument) {
            return Type.event;
        }

        const info = @typeInfo(T);
        if (info == .Struct) {
            for (info.Struct.decls) |decl| {
                const decl_value = @field(EventArgument, decl.name);
                if (@TypeOf(decl_value) == Type) {
                    return decl_value;
                }
            }
        }
        return .presumed_component;
    }
};

pub fn GroupSparseSets(comptime components: []const type) type {
    var struct_fields: [components.len]std.builtin.Type.StructField = undefined;
    inline for (&struct_fields, components) |*field, component| {
        const SparseSet = sparse_set.SparseSet(EntityId, component);
        const default_value = SparseSet{};
        field.* = std.builtin.Type.StructField{
            .name = @typeName(component),
            .type = SparseSet,
            .default_value = @ptrCast(&default_value),
            .is_comptime = false,
            .alignment = @alignOf(SparseSet),
        };
    }
    const group_type = std.builtin.Type{ .Struct = .{
        .layout = .auto,
        .fields = &struct_fields,
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_tuple = false,
    } };
    return @Type(group_type);
}

pub fn GroupSparseSetsPtr(comptime components: []const type) type {
    var struct_fields: [components.len]std.builtin.Type.StructField = undefined;
    inline for (&struct_fields, components) |*field, component| {
        const SparseSet = sparse_set.SparseSet(EntityId, component);
        field.* = std.builtin.Type.StructField{
            .name = @typeName(component),
            .type = *SparseSet,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(*SparseSet),
        };
    }
    const group_type = std.builtin.Type{ .Struct = .{
        .layout = .auto,
        .fields = &struct_fields,
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_tuple = false,
    } };
    return @Type(group_type);
}

pub const FieldAttr = enum {
    value,
    ptr,
};
pub const CompactComponentRequest = struct {
    type: type,
    attr: FieldAttr,
};
pub fn compactComponentRequest(comptime ComponentPtrOrValueType: type) CompactComponentRequest {
    const type_info = @typeInfo(ComponentPtrOrValueType);

    return switch (type_info) {
        .Struct => .{
            .type = ComponentPtrOrValueType,
            .attr = FieldAttr.value,
        },
        .Pointer => |ptr_info| .{
            .type = ptr_info.child,
            .attr = FieldAttr.ptr,
        },
        else => @compileError(@typeName(ComponentPtrOrValueType) ++ " is not pointer, nor struct."),
    };
}

pub inline fn comptimeOnlyFn(comptime caller: std.builtin.SourceLocation) void {
    if (@inComptime() == false) {
        @compileError(caller.fn_name ++ " can only be called in comptime");
    }
}
