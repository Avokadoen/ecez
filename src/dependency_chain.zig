const std = @import("std");
const storage = @import("storage.zig");
const SubsetType = storage.SubsetType;

const QueryType = @import("query.zig").QueryType;
const QueryAnyType = @import("query.zig").QueryAnyType;

const Access = struct {
    const Right = enum(u2) {
        none,
        read,
        write,
    };

    type: type,
    right: Right,
};

pub const Dependency = struct {
    wait_on_indices: []const u32,
};

/// Must be called after verify systems on systems
///
pub fn buildDependencyList(
    comptime systems: anytype,
    comptime system_count: u32,
) [system_count]Dependency {
    @setEvalBranchQuota(50_000);

    if (@inComptime() == false) {
        @compileError(@src().fn_name ++ " can only be called in comptime");
    }

    const Node = struct {
        access: []const Access,
    };

    const systems_fields = @typeInfo(@TypeOf(systems)).@"struct".fields;

    const final_systems_dependencies = comptime calc_dependencies_blk: {
        var graph: [system_count]Node = undefined;
        system_loop: for (&graph, systems_fields) |*this_node, system_field_info| {
            const system_info = @typeInfo(system_field_info.type);
            if (system_info != .@"fn") {
                continue :system_loop;
            }

            const params = system_info.@"fn".params;
            var access_params: [params.len]std.builtin.Type.Fn.Param = undefined;
            var access_params_len: usize = 0;
            var access_count = 0;

            // For each system parameter, expect either a Query or Subset type.
            access_count_loop: for (params) |param| {
                const TypeParam = storage.CompileReflect.compactComponentRequest(param.type.?).type;
                if (@hasDecl(TypeParam, "EcezType") == false) {
                    continue :access_count_loop; // assume legal argument, but not query argument
                }

                access_params[access_params_len] = param;
                access_params_len += 1;
                switch (TypeParam.EcezType) {
                    QueryType, QueryAnyType => access_count += TypeParam._result_fields.len + TypeParam._include_types.len + TypeParam._exclude_types.len,
                    SubsetType => access_count += TypeParam.component_access.len,
                    else => |Type| @compileError("Unknown system argume type " ++ @typeName(Type)),
                }
                if (TypeParam.EcezType == QueryType) {}
            }

            // Compute each systems component access and store it in the system node
            const all_access = get_access_blk: {
                var access_index = 0;
                var access: [access_count]Access = undefined;
                for (access_params[0..access_params_len]) |param| {
                    const TypeParam = storage.CompileReflect.compactComponentRequest(param.type.?).type;

                    switch (TypeParam.EcezType) {
                        QueryType, QueryAnyType => {
                            for (TypeParam._result_fields) |component_field| {
                                const req = storage.CompileReflect.compactComponentRequest(component_field.type);
                                access[access_index] = Access{
                                    .type = req.type,
                                    .right = if (req.attr == .value or req.attr == .const_ptr) .read else .write,
                                };
                                access_index += 1;
                            }
                            for (TypeParam._include_types) |InclComp| {
                                access[access_index] = Access{
                                    .type = InclComp,
                                    .right = .read,
                                };
                                access_index += 1;
                            }
                            for (TypeParam._exclude_types) |ExclComp| {
                                access[access_index] = Access{
                                    .type = ExclComp,
                                    .right = .read,
                                };
                                access_index += 1;
                            }
                        },
                        SubsetType => {
                            for (TypeParam.component_access) |Component| {
                                const req = storage.CompileReflect.compactComponentRequest(Component);
                                access[access_index] = Access{
                                    .type = req.type,
                                    .right = if (req.attr == .value or req.attr == .const_ptr) .read else .write,
                                };
                                access_index += 1;
                            }
                        },
                        else => unreachable, // Already hit compile error on access_count
                    }
                }

                break :get_access_blk access;
            };

            this_node.* = Node{
                .access = &all_access,
            };
        }

        var systems_dependencies: [system_count]Dependency = undefined;
        systems_dependencies[0] = Dependency{ .wait_on_indices = &[_]u32{} };
        for (systems_dependencies[1..], graph[1..], 1..) |*system_dependencies, this_node, node_index| {
            var this_node_access_not_locked: [this_node.access.len]Access = undefined;
            var this_node_access_not_locked_len = this_node_access_not_locked.len;

            var access_not_locked_read_to_write = [_]bool{false} ** this_node.access.len;
            @memcpy(&this_node_access_not_locked, this_node.access);

            var dependencies, var dependencies_len = calc_deps_blk: {
                var dependency_len: u32 = 0;
                var dependency_slots: [node_index]u32 = undefined;

                // Loop all previous nodes
                for (0..node_index) |prev_node_index| {

                    // Reverse index to iterate backwards
                    const other_node_index = (node_index - prev_node_index) - 1;
                    const other_node = graph[other_node_index];

                    // foearch access in previous node
                    for (other_node.access) |other_access| {
                        var access_not_locked_index: u32 = 0;
                        access_loop: while (access_not_locked_index < this_node_access_not_locked_len) {
                            const this_access = this_node_access_not_locked[access_not_locked_index];

                            if (this_access.type != other_access.type) {
                                access_not_locked_index += 1;
                                continue :access_loop;
                            }

                            const is_read_to_write = other_access.right == .read and this_access.right == .write;
                            const is_any_write = this_access.right == .write or other_access.right == .write;

                            if (is_read_to_write) {
                                access_not_locked_read_to_write[access_not_locked_index] = true;
                            }

                            var remove_access_not_locked = is_read_to_write == false;
                            if (is_read_to_write or is_any_write) {
                                @branchHint(.unlikely);

                                // Store dependency
                                set_dependency_slot_blk: {
                                    // Check if dependency is already registered
                                    for (dependency_slots[0..dependency_len]) |dep_index| {
                                        if (dep_index == other_node_index) {
                                            break :set_dependency_slot_blk;
                                        }
                                    }

                                    // If we previously registered a read to write, and now are hitting a write to write, then we must track all current reads
                                    //
                                    // Example scenario:
                                    //
                                    //       nodes: a1(w) -> a2(r) -> a3(r) -> a4(w)
                                    //               ^        v ^     v ^       v
                                    //                \      /   \----/-\      /
                                    //                 -----/--------/   \----/
                                    //
                                    // Example showing a1 will wait for a2 and a3 and ignore a4 as there is a implicit dependency already.
                                    if (access_not_locked_read_to_write[access_not_locked_index] and this_access.right == .write and other_access.right == .write) {
                                        remove_access_not_locked = true;
                                        break :set_dependency_slot_blk;
                                    }

                                    dependency_slots[dependency_len] = other_node_index;
                                    dependency_len += 1;
                                }

                                // swap remove access if we hit a write
                                if (remove_access_not_locked) {
                                    this_node_access_not_locked[access_not_locked_index] = this_node_access_not_locked[this_node_access_not_locked_len - 1];
                                    access_not_locked_read_to_write[access_not_locked_index] = access_not_locked_read_to_write[this_node_access_not_locked_len - 1];
                                    this_node_access_not_locked_len -= 1;
                                }
                            }

                            // If we did not decrease access_not_locked_len, or did not hit any dependency
                            if (is_read_to_write or (!is_read_to_write and !is_any_write)) {
                                access_not_locked_index += 1;
                            }
                        }
                    }
                }
                break :calc_deps_blk .{ dependency_slots, dependency_len };
            };

            // Transitive dependency removal
            // Example:
            //      | Job ID | Wait on |                  | Job ID | Wait on |
            //      | A      |         |   -Reduce To->   | A      |         |
            //      | B      |    A    |                  | B      |    A    |
            //      | C      |  B, A   |                  | C      |    B    |
            //
            if (dependencies_len > 1) {
                var dep_index = 0;
                while (dep_index < dependencies_len - 1) : (dep_index += 1) {
                    const dependency = dependencies[dep_index];
                    var other_dep_index = 1;
                    while (other_dep_index < dependencies_len) : (other_dep_index += 1) {
                        const other_dependency = dependencies[other_dep_index];
                        if (locateDependency(systems_dependencies[0..node_index], dependency, other_dependency)) {
                            // remove dependency which is already transitively tracked
                            if (dependencies[other_dep_index..dependencies_len].len > 1) {
                                std.mem.rotate(u32, dependencies[other_dep_index..dependencies_len], dependencies[other_dep_index..dependencies_len].len - 1);
                            }

                            dependencies_len -= 1;
                        }
                    }
                }
            }

            system_dependencies.* = Dependency{
                .wait_on_indices = globalArrayVariableRefWorkaround(dependencies, dependencies_len)[0..dependencies_len],
            };
        }
        break :calc_dependencies_blk systems_dependencies;
    };

    return final_systems_dependencies;
}

pub fn locateDependency(systems_dependencies: []const Dependency, higher_dependency: u32, lower_dependency: u32) bool {
    for (systems_dependencies[higher_dependency].wait_on_indices) |high_dep| {
        // if we have found dependency
        if (high_dep == lower_dependency) {
            return true;
        }

        if (locateDependency(systems_dependencies, high_dep, lower_dependency)) {
            return true;
        }
    }

    return false;
}

fn globalArrayVariableRefWorkaround(comptime array: anytype, comptime len: u32) @TypeOf(array) {
    const ArrayType = @TypeOf(array);
    const arr_info = @typeInfo(ArrayType);

    var tmp: ArrayType = undefined;
    switch (arr_info) {
        .array => {
            @memcpy(tmp[0..len], array[0..len]);
        },
        else => @compileError("ecez bug: invalid " ++ @src().fn_name ++ " array type" ++ @typeName(ArrayType)),
    }

    const const_local = tmp;
    return const_local;
}

const Testing = @import("Testing.zig");

const D = struct { value: u128 };
const StorageStub = storage.CreateStorage(.{
    Testing.Component.A,
    Testing.Component.B,
    Testing.Component.C,
    D,
});

test buildDependencyList {
    const Queries = struct {
        // Use entity for some queries to ensure it does not affect dependency tracking
        const Entity = @import("entity_type.zig").Entity;

        pub const ReadAValue = Testing.QueryAndQueryAny(
            StorageStub,
            struct {
                entitiy: Entity,
                a: Testing.Component.A,
            },
            .{},
            .{},
        );

        pub const ReadAConstPtr = Testing.QueryAndQueryAny(
            StorageStub,
            struct {
                entitiy: Entity,
                a: *const Testing.Component.A,
            },
            .{},
            .{},
        );

        pub const WriteA = Testing.QueryAndQueryAny(
            StorageStub,
            struct {
                entitiy: Entity,
                a: *Testing.Component.A,
            },
            .{},
            .{},
        );

        pub const ReadB = Testing.QueryAndQueryAny(
            StorageStub,
            struct {
                entitiy: Entity,
                b: Testing.Component.B,
            },
            .{},
            .{},
        );

        pub const WriteB = Testing.QueryAndQueryAny(
            StorageStub,
            struct {
                entitiy: Entity,
                b: *Testing.Component.B,
            },
            .{},
            .{},
        );

        pub const ReadD = Testing.QueryAndQueryAny(
            StorageStub,
            struct {
                d: D,
            },
            .{},
            .{},
        );

        pub const WriteD = Testing.QueryAndQueryAny(
            StorageStub,
            struct {
                d: *D,
            },
            .{},
            .{},
        );

        pub const ReadAReadB = Testing.QueryAndQueryAny(
            StorageStub,
            struct {
                a: Testing.Component.A,
                b: Testing.Component.B,
            },
            .{},
            .{},
        );

        pub const InclAInclB = Testing.QueryAndQueryAny(
            StorageStub,
            struct {
                a: Testing.Component.A,
                b: Testing.Component.B,
            },
            .{},
            .{},
        );

        pub const WriteAWriteB = Testing.QueryAndQueryAny(
            StorageStub,
            struct {
                a: *Testing.Component.A,
                b: *Testing.Component.B,
            },
            .{},
            .{},
        );

        pub const ReadAReadBInclD = Testing.QueryAndQueryAny(
            StorageStub,
            struct {
                a: Testing.Component.A,
                b: Testing.Component.B,
            },
            .{D},
            .{},
        );

        pub const WriteAWriteBWriteD = Testing.QueryAndQueryAny(
            StorageStub,
            struct {
                a: *Testing.Component.A,
                b: *Testing.Component.B,
                d: *D,
            },
            .{},
            .{},
        );

        // cant request entity only for QueryAny
        pub const EntityOnly = StorageStub.Query(
            struct {
                entity: @import("entity_type.zig").Entity,
            },
            .{},
            .{},
        );

        pub const EntityExclA = Testing.QueryAndQueryAny(
            StorageStub,
            struct {
                entity: @import("entity_type.zig").Entity,
            },
            .{},
            .{
                Testing.Component.A,
            },
        );

        pub const EntityExclAB = Testing.QueryAndQueryAny(
            StorageStub,
            struct {
                entity: @import("entity_type.zig").Entity,
            },
            .{},
            .{
                Testing.Component.A,
                Testing.Component.B,
            },
        );

        pub const EntityInclAB = Testing.QueryAndQueryAny(
            StorageStub,
            struct {
                entity: @import("entity_type.zig").Entity,
            },
            .{
                Testing.Component.A,
                Testing.Component.B,
            },
            .{},
        );
    };

    const SubStorages = struct {
        const ReadA = StorageStub.Subset(.{Testing.Component.A});

        const WriteA = StorageStub.Subset(.{*Testing.Component.A});

        const WriteB = StorageStub.Subset(.{*Testing.Component.B});

        const WriteC = StorageStub.Subset(.{*Testing.Component.C});

        const WriteAB = StorageStub.Subset(.{ *Testing.Component.A, *Testing.Component.B });

        const WriteABC = StorageStub.Subset(.{ *Testing.Component.A, *Testing.Component.B, *Testing.Component.C });

        const ReadABC = StorageStub.Subset(.{ Testing.Component.A, Testing.Component.B, Testing.Component.C });

        const ReadAWriteBReadC = StorageStub.Subset(.{ Testing.Component.A, *Testing.Component.B, Testing.Component.C });
    };

    const SingleQuerySystems = [2]type{
        struct {
            pub fn readAValue(a: *Queries.ReadAValue[0]) void {
                _ = a;
            }
            pub fn readAConstPtr(a: *Queries.ReadAConstPtr[0]) void {
                _ = a;
            }
            pub fn writeA(a: *Queries.WriteA[0]) void {
                _ = a;
            }
            pub fn readB(b: *Queries.ReadB[0]) void {
                _ = b;
            }
            pub fn writeB(b: *Queries.WriteB[0]) void {
                _ = b;
            }
            pub fn readD(c: *Queries.ReadD[0]) void {
                _ = c;
            }
            pub fn writeD(c: *Queries.WriteD[0]) void {
                _ = c;
            }
            pub fn readAReadB(ab: *Queries.ReadAReadB[0]) void {
                _ = ab;
            }
            pub fn writeAWriteB(ab: *Queries.WriteAWriteB[0]) void {
                _ = ab;
            }
            pub fn readAReadBInclD(abc: *Queries.ReadAReadBInclD[0]) void {
                _ = abc;
            }
            pub fn writeAWriteBWriteD(abc: *Queries.WriteAWriteBWriteD[0]) void {
                _ = abc;
            }
            pub fn entityOnly(e: *Queries.EntityOnly) void {
                _ = e;
            }
            pub fn exclReadA(a: *Queries.EntityExclA[0]) void {
                _ = a;
            }
            pub fn exclReadAexclReadB(a: *Queries.EntityExclAB[0]) void {
                _ = a;
            }
            pub fn inclAInclB(ab: *Queries.ReadAReadB[0]) void {
                _ = ab;
            }
        },
        struct {
            pub fn readAValue(a: *Queries.ReadAValue[1]) void {
                _ = a;
            }
            pub fn readAConstPtr(a: *Queries.ReadAConstPtr[1]) void {
                _ = a;
            }
            pub fn writeA(a: *Queries.WriteA[1]) void {
                _ = a;
            }
            pub fn readB(b: *Queries.ReadB[1]) void {
                _ = b;
            }
            pub fn writeB(b: *Queries.WriteB[1]) void {
                _ = b;
            }
            pub fn readD(c: *Queries.ReadD[1]) void {
                _ = c;
            }
            pub fn writeD(c: *Queries.WriteD[1]) void {
                _ = c;
            }
            pub fn readAReadB(ab: *Queries.ReadAReadB[1]) void {
                _ = ab;
            }
            pub fn writeAWriteB(ab: *Queries.WriteAWriteB[1]) void {
                _ = ab;
            }
            pub fn readAReadBInclD(abc: *Queries.ReadAReadBInclD[1]) void {
                _ = abc;
            }
            pub fn writeAWriteBWriteD(abc: *Queries.WriteAWriteBWriteD[1]) void {
                _ = abc;
            }
            pub fn exclReadA(a: *Queries.EntityExclA[1]) void {
                _ = a;
            }
            pub fn exclReadAexclReadB(a: *Queries.EntityExclAB[1]) void {
                _ = a;
            }
            pub fn inclAInclB(ab: *Queries.ReadAReadB[1]) void {
                _ = ab;
            }
        },
    };

    const TwoQuerySystems = [2]type{
        struct {
            pub fn readAReadB(a: *Queries.ReadAValue[0], b: *Queries.ReadB[0]) void {
                _ = a;
                _ = b;
            }
            pub fn writeAWriteB(a: *Queries.WriteA[0], b: *Queries.WriteB[0]) void {
                _ = a;
                _ = b;
            }
        },
        struct {
            pub fn readAReadB(a: *Queries.ReadAValue[1], b: *Queries.ReadB[1]) void {
                _ = a;
                _ = b;
            }
            pub fn writeAWriteB(a: *Queries.WriteA[1], b: *Queries.WriteB[1]) void {
                _ = a;
                _ = b;
            }
        },
    };

    const ThreeQuerySystems = [2]type{
        struct {
            pub fn readAReadBReadD(a: *Queries.ReadAValue[0], b: *Queries.ReadB[0], d: *Queries.ReadD[0]) void {
                _ = a;
                _ = b;
                _ = d;
            }
            pub fn writeAWriteBWriteD(a: *Queries.WriteA[0], b: *Queries.WriteB[0], d: *Queries.WriteD[0]) void {
                _ = a;
                _ = b;
                _ = d;
            }
        },
        struct {
            pub fn readAReadBReadD(a: *Queries.ReadAValue[1], b: *Queries.ReadB[1], d: *Queries.ReadD[1]) void {
                _ = a;
                _ = b;
                _ = d;
            }
            pub fn writeAWriteBWriteD(a: *Queries.WriteA[1], b: *Queries.WriteB[1], d: *Queries.WriteD[1]) void {
                _ = a;
                _ = b;
                _ = d;
            }
        },
    };

    const SingleSubStorageSystems = struct {
        pub fn writeA(a: *SubStorages.WriteA) void {
            _ = a;
        }
        pub fn writeB(b: *SubStorages.WriteB) void {
            _ = b;
        }
        pub fn writeC(c: *SubStorages.WriteC) void {
            _ = c;
        }
        pub fn writeAWriteB(ab: *SubStorages.WriteAB) void {
            _ = ab;
        }
        pub fn writeAWriteBWriteC(abc: *SubStorages.WriteABC) void {
            _ = abc;
        }
        pub fn readAReadBReadC(abc: *SubStorages.ReadABC) void {
            _ = abc;
        }
        pub fn readAWriteBReadC(abc: *SubStorages.ReadAWriteBReadC) void {
            _ = abc;
        }
    };

    const MiscSystems = [2]type{
        struct {
            pub fn SpamA(
                qa_0: *Queries.WriteA[0],
                qa_1: *Queries.WriteA[0],
                qa_2: *Queries.ReadAValue[0],
                sa_0: *SubStorages.WriteA,
                sa_1: *SubStorages.WriteA,
                sa_2: *SubStorages.ReadA,
            ) void {
                _ = qa_0;
                _ = qa_1;
                _ = qa_2;
                _ = sa_0;
                _ = sa_1;
                _ = sa_2;
            }
        },
        struct {
            pub fn SpamA(
                qa_0: *Queries.WriteA[1],
                qa_1: *Queries.WriteA[1],
                qa_2: *Queries.ReadAValue[1],
                sa_0: *SubStorages.WriteA,
                sa_1: *SubStorages.WriteA,
                sa_2: *SubStorages.ReadA,
            ) void {
                _ = qa_0;
                _ = qa_1;
                _ = qa_2;
                _ = sa_0;
                _ = sa_1;
                _ = sa_2;
            }
        },
    };

    // Single type testing
    {
        // Read value to write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.writeA,
            }, 2);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
            };

            for (dependencies, expected_dependencies) |system_dependencies, expected_system_dependencies| {
                try std.testing.expectEqualSlices(u32, system_dependencies.wait_on_indices, expected_system_dependencies.wait_on_indices);
            }
        }

        // Read const ptr to write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.readAConstPtr,
                SingleQuerySystemsT.writeA,
            }, 2);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
            };

            for (dependencies, expected_dependencies) |system_dependencies, expected_system_dependencies| {
                try std.testing.expectEqualSlices(u32, system_dependencies.wait_on_indices, expected_system_dependencies.wait_on_indices);
            }
        }

        // Read value to read value
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.readAValue,
            }, 2);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Read const ptr to read const ptr
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.readAConstPtr,
                SingleQuerySystemsT.readAConstPtr,
            }, 2);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Write to read value
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.readAValue,
            }, 2);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Write to read const ptr
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.readAConstPtr,
            }, 2);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Read value, read value, write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.writeA,
            }, 3);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[2]u32{ 1, 0 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Read const ptr, read const ptr, write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.readAConstPtr,
                SingleQuerySystemsT.readAConstPtr,
                SingleQuerySystemsT.writeA,
            }, 3);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[2]u32{ 1, 0 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Write, read value, read value, write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.writeA,
            }, 4);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{ 2, 1 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Write, const ptr value, const ptr value, write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.readAConstPtr,
                SingleQuerySystemsT.readAConstPtr,
                SingleQuerySystemsT.writeA,
            }, 4);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{ 2, 1 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // NOTE: From here on out, we assume access by value and by const ptr is functionally the same ...

        // Write, read, read, write, write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.writeA,
            }, 5);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{ 2, 1 } },
                Dependency{ .wait_on_indices = &[_]u32{3} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Write, read, read, write, write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.writeA,
            }, 5);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{ 2, 1 } },
                Dependency{ .wait_on_indices = &[_]u32{3} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }
    }

    // Two types
    {
        // single type writes to double read
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.writeB,
                SingleQuerySystemsT.readAReadB,
            }, 3);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{ 1, 0 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // double reads to single type writes
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.writeB,
            }, 3);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // double type writes to single reads
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeAWriteB,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.readB,
            }, 3);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // single type reads to double writes
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.readB,
                SingleQuerySystemsT.writeAWriteB,
            }, 3);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{ 1, 0 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Write, read, read, write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeAWriteB,
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.writeAWriteB,
            }, 4);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{ 2, 1 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Write, read, read, write, write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeAWriteB,
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.writeAWriteB,
                SingleQuerySystemsT.writeAWriteB,
            }, 5);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{ 2, 1 } },
                Dependency{ .wait_on_indices = &[_]u32{3} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Write, read, read, write, write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeAWriteB,
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.writeAWriteB,
                SingleQuerySystemsT.writeAWriteB,
            }, 5);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{ 2, 1 } },
                Dependency{ .wait_on_indices = &[_]u32{3} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Artibtrary order (0)
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.readB,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.readB,
                SingleQuerySystemsT.writeB,
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.writeAWriteB,
            }, 9);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} }, // 0: writeA,
                Dependency{ .wait_on_indices = &[_]u32{} }, // 1: readB,
                Dependency{ .wait_on_indices = &[_]u32{0} }, // 2: readA,
                Dependency{ .wait_on_indices = &[_]u32{2} }, // 3: writeA,
                Dependency{ .wait_on_indices = &[_]u32{} }, // 4: readB,
                Dependency{ .wait_on_indices = &[_]u32{ 4, 1 } }, // 5: writeB,
                Dependency{ .wait_on_indices = &[_]u32{ 5, 3 } }, // 6: readAreadB,
                Dependency{ .wait_on_indices = &[_]u32{ 5, 3 } }, // 7: readAreadB,
                Dependency{ .wait_on_indices = &[_]u32{ 7, 6 } }, // 8: writeAwriteB,
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }
    }

    // Three types
    {
        // single writes to triple read
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.writeB,
                SingleQuerySystemsT.writeD,
                SingleQuerySystemsT.readAReadBInclD,
            }, 4);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{ 2, 1, 0 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // triple reads to single type writes
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.readAReadBInclD,
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.writeB,
                SingleQuerySystemsT.writeD,
            }, 4);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // triple type writes to single reads
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeAWriteBWriteD,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.readB,
                SingleQuerySystemsT.readD,
            }, 4);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // single type reads to triple writes
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.readB,
                SingleQuerySystemsT.readD,
                SingleQuerySystemsT.writeAWriteBWriteD,
            }, 4);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{ 2, 1, 0 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Artibtrary order (0)
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.writeAWriteBWriteD,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.readD,
                SingleQuerySystemsT.readB,
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.writeAWriteB,
                SingleQuerySystemsT.writeAWriteBWriteD,
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.readAReadBInclD,
            }, 11);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} }, // 0: writeA,
                Dependency{ .wait_on_indices = &[_]u32{0} }, // 1: writeAWriteBWriteD,
                Dependency{ .wait_on_indices = &[_]u32{1} }, // 2: readA,
                Dependency{ .wait_on_indices = &[_]u32{1} }, // 3: readD,
                Dependency{ .wait_on_indices = &[_]u32{1} }, // 4: readB,
                Dependency{ .wait_on_indices = &[_]u32{1} }, // 5: readAReadB,
                Dependency{ .wait_on_indices = &[_]u32{1} }, // 6: readAReadB,
                Dependency{ .wait_on_indices = &[_]u32{ 6, 5, 4, 2 } }, // 7: writeAWriteB,
                Dependency{ .wait_on_indices = &[_]u32{ 7, 3 } }, // 8: writeAWriteBWriteD,
                Dependency{ .wait_on_indices = &[_]u32{8} }, // 9: readAReadB,
                Dependency{ .wait_on_indices = &[_]u32{8} }, // 10: readAReadBInclD,
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }
    }

    // Multiple types using multiple queries
    {
        // Write, read, read, write, two
        inline for (TwoQuerySystems) |TwoQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                TwoQuerySystemsT.writeAWriteB,
                TwoQuerySystemsT.readAReadB,
                TwoQuerySystemsT.readAReadB,
                TwoQuerySystemsT.writeAWriteB,
            }, 4);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{ 2, 1 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // single type writes to double read
        inline for (SingleQuerySystems, TwoQuerySystems) |SingleQuerySystemsT, TwoQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.writeB,
                TwoQuerySystemsT.readAReadB,
            }, 3);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{ 1, 0 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // single type reads to double writes
        inline for (SingleQuerySystems, TwoQuerySystems) |SingleQuerySystemsT, TwoQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.readB,
                TwoQuerySystemsT.writeAWriteB,
            }, 3);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{ 1, 0 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Artibtrary order (0)
        inline for (SingleQuerySystems, TwoQuerySystems, ThreeQuerySystems) |SingleQuerySystemsT, TwoQuerySystemsT, ThreeQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeA,
                ThreeQuerySystemsT.writeAWriteBWriteD,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.readD,
                SingleQuerySystemsT.readB,
                TwoQuerySystemsT.readAReadB,
                TwoQuerySystemsT.readAReadB,
                TwoQuerySystemsT.writeAWriteB,
                ThreeQuerySystemsT.writeAWriteBWriteD,
                TwoQuerySystemsT.readAReadB,
                SingleQuerySystemsT.readAReadBInclD,
            }, 11);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} }, // 0: writeA,
                Dependency{ .wait_on_indices = &[_]u32{0} }, // 1: writeAWriteBWriteC,
                Dependency{ .wait_on_indices = &[_]u32{1} }, // 2: readA,
                Dependency{ .wait_on_indices = &[_]u32{1} }, // 3: readC,
                Dependency{ .wait_on_indices = &[_]u32{1} }, // 4: readB,
                Dependency{ .wait_on_indices = &[_]u32{1} }, // 5: readAReadB,
                Dependency{ .wait_on_indices = &[_]u32{1} }, // 6: readAReadB,
                Dependency{ .wait_on_indices = &[_]u32{ 6, 5, 4, 2 } }, // 7: writeAWriteB,
                Dependency{ .wait_on_indices = &[_]u32{ 7, 3 } }, // 8: writeAWriteBWriteC,
                Dependency{ .wait_on_indices = &[_]u32{8} }, // 9: readAReadB,
                Dependency{ .wait_on_indices = &[_]u32{8} }, // 10: readAReadBInclD,
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }
    }

    // SingleSubStorageSystems
    {
        // single type writes to double read
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeA,
                SingleSubStorageSystems.writeB,
                SingleQuerySystemsT.readAReadB,
            }, 3);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{ 1, 0 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // double reads to single type writes
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.readAReadB,
                SingleSubStorageSystems.writeA,
                SingleSubStorageSystems.writeB,
            }, 3);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // double type writes to single reads
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeAWriteB,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.readB,
            }, 3);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // single type reads to double writes
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.readB,
                SingleSubStorageSystems.writeAWriteB,
            }, 3);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{ 1, 0 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Write, read, read, write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeAWriteB,
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.readAReadB,
                SingleSubStorageSystems.writeAWriteB,
            }, 4);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{ 2, 1 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Write, read, read, write, write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeAWriteB,
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.readAReadB,
                SingleSubStorageSystems.writeAWriteB,
                SingleSubStorageSystems.writeAWriteB,
            }, 5);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{ 2, 1 } },
                Dependency{ .wait_on_indices = &[_]u32{3} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Write, read, read, write, write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeAWriteB,
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.readAReadB,
                SingleSubStorageSystems.writeAWriteB,
                SingleSubStorageSystems.writeAWriteB,
            }, 5);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{ 2, 1 } },
                Dependency{ .wait_on_indices = &[_]u32{3} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Artibtrary order (0)
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeA,
                SingleQuerySystemsT.readB,
                SingleQuerySystemsT.readAValue,
                SingleSubStorageSystems.writeA,
                SingleQuerySystemsT.readB,
                SingleSubStorageSystems.writeB,
                SingleQuerySystemsT.readAReadB,
                SingleQuerySystemsT.readAReadB,
                SingleSubStorageSystems.writeAWriteB,
            }, 9);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} }, // 0: writeA,
                Dependency{ .wait_on_indices = &[_]u32{} }, // 1: readB,
                Dependency{ .wait_on_indices = &[_]u32{0} }, // 2: readA,
                Dependency{ .wait_on_indices = &[_]u32{2} }, // 3: writeA,
                Dependency{ .wait_on_indices = &[_]u32{} }, // 4: readB,
                Dependency{ .wait_on_indices = &[_]u32{ 4, 1 } }, // 5: writeB,
                Dependency{ .wait_on_indices = &[_]u32{ 5, 3 } }, // 6: readAreadB,
                Dependency{ .wait_on_indices = &[_]u32{ 5, 3 } }, // 7: readAreadB,
                Dependency{ .wait_on_indices = &[_]u32{ 7, 6 } }, // 8: writeAwriteB,
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Artibtrary order (1)
        inline for (SingleQuerySystems, TwoQuerySystems) |SingleQuerySystemsT, TwoQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeA,
                SingleSubStorageSystems.writeAWriteBWriteC,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.readD,
                SingleQuerySystemsT.readB,
                TwoQuerySystemsT.readAReadB,
                TwoQuerySystemsT.readAReadB,
                SingleSubStorageSystems.writeAWriteB,
                SingleSubStorageSystems.writeAWriteBWriteC,
                TwoQuerySystemsT.readAReadB,
                SingleSubStorageSystems.readAReadBReadC,
            }, 11);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} }, // 0: writeA,
                Dependency{ .wait_on_indices = &[_]u32{0} }, // 1: writeAWriteBWriteC,
                Dependency{ .wait_on_indices = &[_]u32{1} }, // 2: readA,
                Dependency{ .wait_on_indices = &[_]u32{} }, // 3: readD,
                Dependency{ .wait_on_indices = &[_]u32{1} }, // 4: readB,
                Dependency{ .wait_on_indices = &[_]u32{1} }, // 5: readAReadB,
                Dependency{ .wait_on_indices = &[_]u32{1} }, // 6: readAReadB,
                Dependency{ .wait_on_indices = &[_]u32{ 6, 5, 4, 2 } }, // 7: writeAWriteB,
                Dependency{ .wait_on_indices = &[_]u32{7} }, // 8: writeAWriteBWriteC,
                Dependency{ .wait_on_indices = &[_]u32{8} }, // 9: readAReadB,
                Dependency{ .wait_on_indices = &[_]u32{8} }, // 10: readAReadBReadC,
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }
    }

    // Spam single access
    inline for (SingleQuerySystems, MiscSystems) |SingleQuerySystemsT, MiscSystemsT| {
        const dependencies = comptime buildDependencyList(.{
            SingleSubStorageSystems.writeA,
            SingleQuerySystemsT.writeA,
            SingleQuerySystemsT.readAValue,
            MiscSystemsT.SpamA,
            SingleQuerySystemsT.writeA,
        }, 5);
        const expected_dependencies = [_]Dependency{
            Dependency{ .wait_on_indices = &[_]u32{} },
            Dependency{ .wait_on_indices = &[_]u32{0} },
            Dependency{ .wait_on_indices = &[_]u32{1} },
            Dependency{ .wait_on_indices = &[_]u32{2} },
            Dependency{ .wait_on_indices = &[_]u32{3} },
        };

        for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
            try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
        }
    }

    inline for (SingleQuerySystems) |SingleQuerySystemsT| {
        const dependencies = comptime buildDependencyList(.{
            SingleQuerySystemsT.writeA,
            SingleQuerySystemsT.readAReadB,
            SingleSubStorageSystems.readAWriteBReadC,
            SingleQuerySystemsT.writeA,
            SingleQuerySystemsT.writeB,
        }, 5);
        const expected_dependencies = [_]Dependency{
            Dependency{ .wait_on_indices = &[_]u32{} },
            Dependency{ .wait_on_indices = &[_]u32{0} },
            Dependency{ .wait_on_indices = &[_]u32{1} },
            Dependency{ .wait_on_indices = &[_]u32{2} },
            Dependency{ .wait_on_indices = &[_]u32{2} },
        };

        for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
            try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
        }
    }

    // Entity only
    inline for (SingleQuerySystems) |SingleQuerySystemsT| {
        const dependencies = comptime buildDependencyList(.{
            SingleQuerySystems[0].entityOnly,
            SingleQuerySystems[0].entityOnly,
            SingleQuerySystems[0].entityOnly,
            SingleQuerySystemsT.readAReadB,
        }, 4);
        const expected_dependencies = [_]Dependency{
            Dependency{ .wait_on_indices = &[_]u32{} },
            Dependency{ .wait_on_indices = &[_]u32{} },
            Dependency{ .wait_on_indices = &[_]u32{} },
            Dependency{ .wait_on_indices = &[_]u32{} },
        };

        for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
            try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
        }
    }

    // Exclude
    inline for (SingleQuerySystems) |SingleQuerySystemsT| {
        const dependencies = comptime buildDependencyList(.{
            SingleQuerySystemsT.writeA,
            SingleQuerySystemsT.readAReadB,
            SingleQuerySystemsT.exclReadA,
            SingleQuerySystemsT.exclReadAexclReadB,
            SingleQuerySystemsT.writeA,
            SingleQuerySystemsT.writeB,
        }, 6);
        const expected_dependencies = [_]Dependency{
            Dependency{ .wait_on_indices = &[_]u32{} },
            Dependency{ .wait_on_indices = &[_]u32{0} },
            Dependency{ .wait_on_indices = &[_]u32{0} },
            Dependency{ .wait_on_indices = &[_]u32{0} },
            Dependency{ .wait_on_indices = &[_]u32{ 3, 2, 1 } },
            Dependency{ .wait_on_indices = &[_]u32{ 3, 1 } },
        };

        for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
            try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
        }
    }

    // Include
    {
        // Write, read, read, write, write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeAWriteB,
                SingleQuerySystemsT.inclAInclB,
                SingleQuerySystemsT.inclAInclB,
                SingleSubStorageSystems.writeAWriteB,
                SingleSubStorageSystems.writeAWriteB,
            }, 5);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{ 2, 1 } },
                Dependency{ .wait_on_indices = &[_]u32{3} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Write, read, read, write, write
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeAWriteB,
                SingleQuerySystemsT.inclAInclB,
                SingleQuerySystemsT.inclAInclB,
                SingleSubStorageSystems.writeAWriteB,
                SingleSubStorageSystems.writeAWriteB,
            }, 5);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
                Dependency{ .wait_on_indices = &[_]u32{ 2, 1 } },
                Dependency{ .wait_on_indices = &[_]u32{3} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }
    }

    // Implicit dependency removal
    {
        // Artibtrary order (1)
        inline for (SingleQuerySystems) |SingleQuerySystemsT| {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystemsT.writeAWriteB,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.readAValue,
                SingleQuerySystemsT.writeA,
                SingleQuerySystemsT.readB,
                SingleQuerySystemsT.writeB,
                SingleQuerySystemsT.readB,
                SingleQuerySystemsT.writeB,
                SingleQuerySystemsT.readB,
                SingleQuerySystemsT.writeB,
                SingleQuerySystemsT.writeAWriteB,
            }, 14);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} }, // 0: writeAWriteB,
                Dependency{ .wait_on_indices = &[_]u32{0} }, // 1: readA,
                Dependency{ .wait_on_indices = &[_]u32{1} }, // 2: writeA,
                Dependency{ .wait_on_indices = &[_]u32{2} }, // 3: readA,
                Dependency{ .wait_on_indices = &[_]u32{3} }, // 4: writeA,
                Dependency{ .wait_on_indices = &[_]u32{4} }, // 5: readA,
                Dependency{ .wait_on_indices = &[_]u32{5} }, // 6: writeA,
                Dependency{ .wait_on_indices = &[_]u32{0} }, // 7: readBValue,
                Dependency{ .wait_on_indices = &[_]u32{7} }, // 8: writeB,
                Dependency{ .wait_on_indices = &[_]u32{8} }, // 9: readBValue,
                Dependency{ .wait_on_indices = &[_]u32{9} }, // 10: writeB,
                Dependency{ .wait_on_indices = &[_]u32{10} }, // 11: readBValue,
                Dependency{ .wait_on_indices = &[_]u32{11} }, // 12: writeB,
                Dependency{ .wait_on_indices = &[_]u32{ 12, 6 } }, // 13: writeAWriteB,
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }
    }
}
