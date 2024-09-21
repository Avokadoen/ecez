const std = @import("std");
const storage = @import("storage.zig");
const QueryType = storage.QueryType;
const SubsetType = storage.SubsetType;

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

    const systems_fields = @typeInfo(@TypeOf(systems)).Struct.fields;

    const final_systems_dependencies = comptime calc_dependencies_blk: {
        var graph: [system_count]Node = undefined;
        system_loop: for (&graph, systems_fields) |*this_node, system_field_info| {
            const system_info = @typeInfo(system_field_info.type);
            if (system_info != .Fn) {
                continue :system_loop;
            }

            const params = system_info.Fn.params;
            var access_params: [params.len]std.builtin.Type.Fn.Param = undefined;
            var access_params_len: usize = 0;
            var access_count = 0;

            access_count_loop: for (params) |param| {
                const TypeParam = storage.CompileReflect.compactComponentRequest(param.type.?).type;
                if (@hasDecl(TypeParam, "EcezType") == false) {
                    continue :access_count_loop; // assume legal argument, but not query argument
                }

                access_params[access_params_len] = param;
                access_params_len += 1;
                switch (TypeParam.EcezType) {
                    QueryType => access_count += TypeParam._include_fields.len,
                    SubsetType => access_count += TypeParam.component_subset_arr.len,
                    else => |Type| @compileError("Unknown system argume type " ++ @typeName(Type)),
                }
                if (TypeParam.EcezType == QueryType) {}
            }

            const all_access = get_access_blk: {
                var access_index = 0;
                var access: [access_count]Access = undefined;
                for (access_params[0..access_params_len]) |param| {
                    const TypeParam = storage.CompileReflect.compactComponentRequest(param.type.?).type;

                    switch (TypeParam.EcezType) {
                        QueryType => {
                            for (TypeParam._include_fields) |component_field| {
                                const req = storage.CompileReflect.compactComponentRequest(component_field.type);
                                access[access_index] = Access{
                                    .type = req.type,
                                    .right = if (req.attr == .value) .read else .write,
                                };
                                access_index += 1;
                            }
                        },
                        SubsetType => {
                            // if storage subset is specified as read_and_write, then we must assume all access as write, read otherwise
                            const right = if (TypeParam.track_access == .read_and_write) .write else .read;

                            for (TypeParam.component_subset_arr) |Component| {
                                access[access_index] = Access{
                                    .type = Component,
                                    .right = right,
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
            var access_not_locked: [this_node.access.len]Access = undefined;
            var access_not_locked_len = access_not_locked.len;

            var access_not_locked_read_to_write = [_]bool{false} ** this_node.access.len;

            @memcpy(&access_not_locked, this_node.access);

            const dependencies = calc_deps_blk: {
                var dependency_len: u32 = 0;
                var dependency_slots: [node_index]u32 = undefined;
                for (0..node_index) |prev_node_index| {

                    // Reverse index to iterate backwards
                    const other_node_index = (node_index - prev_node_index) - 1;
                    const other_node = graph[other_node_index];

                    for (other_node.access) |other_access| {
                        var access_not_locked_index: u32 = 0;
                        access_loop: while (access_not_locked_index < access_not_locked_len) {
                            const this_access = access_not_locked[access_not_locked_index];

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
                                // TODO: potentially mark unlikely branch

                                // Store dependency
                                set_dependency_slot_blk: {
                                    // Check if dependency is already registered
                                    for (dependency_slots[0..dependency_len]) |dep_index| {
                                        if (dep_index == other_node_index) {
                                            break :set_dependency_slot_blk;
                                        }
                                    }

                                    // If we have registered a read to write, and now are hitting a write to write,
                                    // then we skip write to write since the read is already blocked on the write
                                    //
                                    // Example scenario:
                                    //
                                    //       nodes: a(w) -> a(r) -> a(r) -> a(w)
                                    //               ^       v ^    v ^       v
                                    //                \     /   \---/-\      /
                                    //                 ----/-------/   \----/
                                    if (access_not_locked_read_to_write[access_not_locked_index] and this_access.right == .write and other_access.right == .write) {
                                        remove_access_not_locked = true;
                                        break :set_dependency_slot_blk;
                                    }

                                    dependency_slots[dependency_len] = other_node_index;
                                    dependency_len += 1;
                                }

                                // swap remove access if we hit a write
                                if (remove_access_not_locked) {
                                    access_not_locked[access_not_locked_index] = access_not_locked[access_not_locked_len - 1];
                                    access_not_locked_read_to_write[access_not_locked_index] = access_not_locked_read_to_write[access_not_locked_len - 1];
                                    access_not_locked_len -= 1;
                                }
                            }

                            // If we did not decrease access_not_locked_len, or did not hit any dependency
                            if (is_read_to_write or (!is_read_to_write and !is_any_write)) {
                                access_not_locked_index += 1;
                            }
                        }
                    }
                }
                break :calc_deps_blk globalArrayVariableRefWorkaround(dependency_slots)[0..dependency_len];
            };
            system_dependencies.* = Dependency{ .wait_on_indices = dependencies };
        }
        break :calc_dependencies_blk systems_dependencies;
    };

    return final_systems_dependencies;
}

fn globalArrayVariableRefWorkaround(array: anytype) @TypeOf(array) {
    const ArrayType = @TypeOf(array);
    const arr_info = @typeInfo(ArrayType);

    var tmp: ArrayType = undefined;
    switch (arr_info) {
        .Array => {
            @memcpy(&tmp, &array);
        },
        else => @compileError("ecez bug: invalid " ++ @src().fn_name ++ " array type" ++ @typeName(ArrayType)),
    }
    const const_local = tmp;
    return const_local;
}

const Testing = @import("Testing.zig");
const StorageStub = storage.CreateStorage(Testing.AllComponentsTuple);

test buildDependencyList {
    const Queries = struct {
        pub const ReadA = StorageStub.Query(struct {
            a: Testing.Component.A,
        }, .{});

        pub const WriteA = StorageStub.Query(struct {
            a: *Testing.Component.A,
        }, .{});

        pub const ReadB = StorageStub.Query(struct {
            b: Testing.Component.B,
        }, .{});

        pub const WriteB = StorageStub.Query(struct {
            b: *Testing.Component.B,
        }, .{});

        pub const ReadC = StorageStub.Query(struct {
            c: Testing.Component.C,
        }, .{});

        pub const WriteC = StorageStub.Query(struct {
            c: *Testing.Component.C,
        }, .{});

        pub const ReadAReadB = StorageStub.Query(struct {
            a: Testing.Component.A,
            b: Testing.Component.B,
        }, .{});

        pub const WriteAWriteB = StorageStub.Query(struct {
            a: *Testing.Component.A,
            b: *Testing.Component.B,
        }, .{});

        pub const ReadAReadBReadC = StorageStub.Query(struct {
            a: Testing.Component.A,
            b: Testing.Component.B,
            c: Testing.Component.C,
        }, .{});

        pub const WriteAWriteBWriteC = StorageStub.Query(struct {
            a: *Testing.Component.A,
            b: *Testing.Component.B,
            c: *Testing.Component.C,
        }, .{});
    };

    const SubStorages = struct {
        const ReadA = StorageStub.Subset(.{Testing.Component.A}, .read_only);

        const WriteA = StorageStub.Subset(.{Testing.Component.A}, .read_and_write);

        const WriteB = StorageStub.Subset(.{Testing.Component.B}, .read_and_write);

        const WriteC = StorageStub.Subset(.{Testing.Component.C}, .read_and_write);

        const WriteAB = StorageStub.Subset(.{ Testing.Component.A, Testing.Component.B }, .read_and_write);

        const WriteABC = StorageStub.Subset(.{ Testing.Component.A, Testing.Component.B, Testing.Component.C }, .read_and_write);

        const ReadABC = StorageStub.Subset(.{ Testing.Component.A, Testing.Component.B, Testing.Component.C }, .read_only);
    };

    const SingleQuerySystems = struct {
        pub fn readA(a: *Queries.ReadA) void {
            _ = a;
        }
        pub fn writeA(a: *Queries.WriteA) void {
            _ = a;
        }
        pub fn readB(b: *Queries.ReadB) void {
            _ = b;
        }
        pub fn writeB(b: *Queries.WriteB) void {
            _ = b;
        }
        pub fn readC(c: *Queries.ReadC) void {
            _ = c;
        }
        pub fn writeC(c: *Queries.WriteC) void {
            _ = c;
        }
        pub fn readAReadB(ab: *Queries.ReadAReadB) void {
            _ = ab;
        }
        pub fn writeAWriteB(ab: *Queries.WriteAWriteB) void {
            _ = ab;
        }
        pub fn readAReadBReadC(abc: *Queries.ReadAReadBReadC) void {
            _ = abc;
        }
        pub fn writeAWriteBWriteC(abc: *Queries.WriteAWriteBWriteC) void {
            _ = abc;
        }
    };

    const TwoQuerySystems = struct {
        pub fn readAReadB(a: *Queries.ReadA, b: *Queries.ReadB) void {
            _ = a;
            _ = b;
        }
        pub fn writeAWriteB(a: *Queries.WriteA, b: *Queries.WriteB) void {
            _ = a;
            _ = b;
        }
    };

    const ThreeQuerySystems = struct {
        pub fn readAReadBReadC(a: *Queries.ReadA, B: *Queries.ReadB, c: *Queries.ReadC) void {
            _ = a;
            _ = B;
            _ = c;
        }
        pub fn writeAWriteBWriteC(a: *Queries.WriteA, b: *Queries.WriteB, c: *Queries.WriteC) void {
            _ = a;
            _ = b;
            _ = c;
        }
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
    };

    const MiscSystems = struct {
        pub fn SpamA(
            qa_0: *Queries.WriteA,
            qa_1: *Queries.WriteA,
            qa_2: *Queries.ReadA,
            sa_0: *SubStorages.WriteA,
            sa_1: *SubStorages.WriteA,
            sa_2: *SubStorages.ReadA,
        ) void {
            _ = qa_0; // autofix
            _ = qa_1; // autofix
            _ = qa_2; // autofix
            _ = sa_0; // autofix
            _ = sa_1; // autofix
            _ = sa_2; // autofix
        }
    };

    // Single type testing
    {
        // Read to write
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.readA,
                SingleQuerySystems.writeA,
            }, 2);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
            };

            for (dependencies, expected_dependencies) |system_dependencies, expected_system_dependencies| {
                try std.testing.expectEqualSlices(u32, system_dependencies.wait_on_indices, expected_system_dependencies.wait_on_indices);
            }
        }

        // Read to read
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.readA,
                SingleQuerySystems.readA,
            }, 2);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Write to read
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.writeA,
                SingleQuerySystems.readA,
            }, 2);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[_]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Read, read, write
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.readA,
                SingleQuerySystems.readA,
                SingleQuerySystems.writeA,
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

        // Write, read, read, write
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.writeA,
                SingleQuerySystems.readA,
                SingleQuerySystems.readA,
                SingleQuerySystems.writeA,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.writeA,
                SingleQuerySystems.readA,
                SingleQuerySystems.readA,
                SingleQuerySystems.writeA,
                SingleQuerySystems.writeA,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.writeA,
                SingleQuerySystems.readA,
                SingleQuerySystems.readA,
                SingleQuerySystems.writeA,
                SingleQuerySystems.writeA,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.writeA,
                SingleQuerySystems.writeB,
                SingleQuerySystems.readAReadB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.writeA,
                SingleQuerySystems.writeB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.writeAWriteB,
                SingleQuerySystems.readA,
                SingleQuerySystems.readB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.readA,
                SingleQuerySystems.readB,
                SingleQuerySystems.writeAWriteB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.writeAWriteB,
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.writeAWriteB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.writeAWriteB,
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.writeAWriteB,
                SingleQuerySystems.writeAWriteB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.writeAWriteB,
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.writeAWriteB,
                SingleQuerySystems.writeAWriteB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.writeA,
                SingleQuerySystems.readB,
                SingleQuerySystems.readA,
                SingleQuerySystems.writeA,
                SingleQuerySystems.readB,
                SingleQuerySystems.writeB,
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.writeAWriteB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.writeA,
                SingleQuerySystems.writeB,
                SingleQuerySystems.writeC,
                SingleQuerySystems.readAReadBReadC,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.readAReadBReadC,
                SingleQuerySystems.writeA,
                SingleQuerySystems.writeB,
                SingleQuerySystems.writeC,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.writeAWriteBWriteC,
                SingleQuerySystems.readA,
                SingleQuerySystems.readB,
                SingleQuerySystems.readC,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.readA,
                SingleQuerySystems.readB,
                SingleQuerySystems.readC,
                SingleQuerySystems.writeAWriteBWriteC,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.writeA,
                SingleQuerySystems.writeAWriteBWriteC,
                SingleQuerySystems.readA,
                SingleQuerySystems.readC,
                SingleQuerySystems.readB,
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.writeAWriteB,
                SingleQuerySystems.writeAWriteBWriteC,
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.readAReadBReadC,
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
                Dependency{ .wait_on_indices = &[_]u32{8} }, // 10: readAReadBReadC,
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }
    }

    // Multiple types using multiple queries
    {
        // Write, read, read, write, two
        {
            const dependencies = comptime buildDependencyList(.{
                TwoQuerySystems.writeAWriteB,
                TwoQuerySystems.readAReadB,
                TwoQuerySystems.readAReadB,
                TwoQuerySystems.writeAWriteB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.writeA,
                SingleQuerySystems.writeB,
                TwoQuerySystems.readAReadB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.readA,
                SingleQuerySystems.readB,
                TwoQuerySystems.writeAWriteB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.writeA,
                ThreeQuerySystems.writeAWriteBWriteC,
                SingleQuerySystems.readA,
                SingleQuerySystems.readC,
                SingleQuerySystems.readB,
                TwoQuerySystems.readAReadB,
                TwoQuerySystems.readAReadB,
                TwoQuerySystems.writeAWriteB,
                ThreeQuerySystems.writeAWriteBWriteC,
                TwoQuerySystems.readAReadB,
                SingleQuerySystems.readAReadBReadC,
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
                Dependency{ .wait_on_indices = &[_]u32{8} }, // 10: readAReadBReadC,
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }
    }

    // SingleSubStorageSystems
    {
        // single type writes to double read
        {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeA,
                SingleSubStorageSystems.writeB,
                SingleQuerySystems.readAReadB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.readAReadB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeAWriteB,
                SingleQuerySystems.readA,
                SingleQuerySystems.readB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleQuerySystems.readA,
                SingleQuerySystems.readB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeAWriteB,
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.readAReadB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeAWriteB,
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.readAReadB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeAWriteB,
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.readAReadB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeA,
                SingleQuerySystems.readB,
                SingleQuerySystems.readA,
                SingleSubStorageSystems.writeA,
                SingleQuerySystems.readB,
                SingleSubStorageSystems.writeB,
                SingleQuerySystems.readAReadB,
                SingleQuerySystems.readAReadB,
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
        {
            const dependencies = comptime buildDependencyList(.{
                SingleSubStorageSystems.writeA,
                SingleSubStorageSystems.writeAWriteBWriteC,
                SingleQuerySystems.readA,
                SingleQuerySystems.readC,
                SingleQuerySystems.readB,
                TwoQuerySystems.readAReadB,
                TwoQuerySystems.readAReadB,
                SingleSubStorageSystems.writeAWriteB,
                SingleSubStorageSystems.writeAWriteBWriteC,
                TwoQuerySystems.readAReadB,
                SingleSubStorageSystems.readAReadBReadC,
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
                Dependency{ .wait_on_indices = &[_]u32{8} }, // 10: readAReadBReadC,
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }
    }

    // Spam single access
    {
        const dependencies = comptime buildDependencyList(.{
            SingleSubStorageSystems.writeA,
            SingleQuerySystems.writeA,
            SingleQuerySystems.readA,
            MiscSystems.SpamA,
            SingleQuerySystems.writeA,
        }, 5);
        const expected_dependencies = [_]Dependency{
            Dependency{ .wait_on_indices = &[_]u32{} },
            Dependency{ .wait_on_indices = &[_]u32{0} },
            Dependency{ .wait_on_indices = &[_]u32{1} },
            Dependency{ .wait_on_indices = &[_]u32{ 2, 1 } },
            Dependency{ .wait_on_indices = &[_]u32{3} },
        };

        for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
            try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
        }
    }
}
