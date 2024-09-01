const std = @import("std");
const storage = @import("storage.zig");
const QueryType = @import("storage.zig").QueryType;

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
    if (@inComptime() == false) {
        @compileError(@src().fn_name ++ " can only be called in comptime");
    }

    const Node = struct {
        access: []const Access,
    };

    const systems_fields = @typeInfo(@TypeOf(systems)).Struct.fields;

    const final_systems_dependencies = calc_dependencies_blk: {
        var graph: [system_count]Node = undefined;
        system_loop: inline for (&graph, systems_fields) |*this_node, system_field_info| {
            const system_info = @typeInfo(system_field_info.type);
            if (system_info != .Fn) {
                continue :system_loop;
            }

            const params = system_info.Fn.params;
            var access_count = 0;
            inline for (params) |param| {
                const QueryTypeParam = storage.CompileReflect.compactComponentRequest(param.type.?).type;
                access_count += QueryTypeParam._include_fields.len;
            }

            const all_access = get_access_blk: {
                var access_index = 0;
                var access: [access_count]Access = undefined;
                inline for (params) |param| {
                    const QueryTypeParam = storage.CompileReflect.compactComponentRequest(param.type.?).type;
                    inline for (QueryTypeParam._include_fields) |componenet_field| {
                        const req = storage.CompileReflect.compactComponentRequest(componenet_field.type);
                        access[access_index] = Access{
                            .type = req.type,
                            .right = if (req.attr == .value) .read else .write,
                        };
                        access_index += 1;
                    }
                }

                break :get_access_blk access;
            };

            this_node.* = Node{
                .access = &all_access,
            };
        }

        var systems_dependencies: [system_count]Dependency = undefined;
        systems_dependencies[0] = Dependency{ .wait_on_indices = &[0]u32{} };
        inline for (systems_dependencies[1..], graph[1..], 1..) |*system_dependencies, this_node, node_index| {
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
            a: Testing.Component.B,
        }, .{});

        pub const WriteB = StorageStub.Query(struct {
            a: *Testing.Component.B,
        }, .{});

        pub const ReadAReadB = StorageStub.Query(struct {
            a: Testing.Component.A,
            b: Testing.Component.B,
        }, .{});

        pub const WriteAWriteB = StorageStub.Query(struct {
            a: *Testing.Component.A,
            b: *Testing.Component.B,
        }, .{});
    };

    const Systems = struct {
        pub fn readA(a: *Queries.ReadA) void {
            _ = a; // autofix
        }
        pub fn writeA(a: *Queries.WriteA) void {
            _ = a; // autofix
        }
        pub fn readB(b: *Queries.ReadB) void {
            _ = b; // autofix
        }
        pub fn writeB(b: *Queries.WriteB) void {
            _ = b; // autofix
        }
        pub fn readAreadB(ab: *Queries.ReadAReadB) void {
            _ = ab; // autofix
        }
        // pub fn readAWriteB(a: Testing.Component.A, b: *Testing.Component.B) void {
        //     _ = b; // autofix
        //     _ = a; // autofix
        // }
        // pub fn writeAReadB(a: *Testing.Component.A, b: Testing.Component.B) void {
        //     _ = b; // autofix
        //     _ = a; // autofix
        // }
        pub fn writeAwriteB(ab: *Queries.WriteAWriteB) void {
            _ = ab; // autofix
        }
    };

    // Single type testing
    {
        // Read to write
        {
            const dependencies = comptime buildDependencyList(.{
                Systems.readA,
                Systems.writeA,
            }, 2);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[0]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
            };

            for (dependencies, expected_dependencies) |system_dependencies, expected_system_dependencies| {
                try std.testing.expectEqualSlices(u32, system_dependencies.wait_on_indices, expected_system_dependencies.wait_on_indices);
            }
        }

        // Read to read
        {
            const dependencies = comptime buildDependencyList(.{
                Systems.readA,
                Systems.readA,
            }, 2);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[0]u32{} },
                Dependency{ .wait_on_indices = &[0]u32{} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Write to read
        {
            const dependencies = comptime buildDependencyList(.{
                Systems.writeA,
                Systems.readA,
            }, 2);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[0]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{0} },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Read, read, write
        {
            const dependencies = comptime buildDependencyList(.{
                Systems.readA,
                Systems.readA,
                Systems.writeA,
            }, 3);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[0]u32{} },
                Dependency{ .wait_on_indices = &[0]u32{} },
                Dependency{ .wait_on_indices = &[2]u32{ 1, 0 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Write, read, read, write
        {
            const dependencies = comptime buildDependencyList(.{
                Systems.writeA,
                Systems.readA,
                Systems.readA,
                Systems.writeA,
            }, 4);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[0]u32{} },
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
                Systems.writeA,
                Systems.readA,
                Systems.readA,
                Systems.writeA,
                Systems.writeA,
            }, 5);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[0]u32{} },
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
                Systems.writeA,
                Systems.readA,
                Systems.readA,
                Systems.writeA,
                Systems.writeA,
            }, 5);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[0]u32{} },
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
        // Single type writes to multiple reads
        {
            const dependencies = comptime buildDependencyList(.{
                Systems.writeA,
                Systems.writeB,
                Systems.readAreadB,
            }, 3);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[0]u32{} },
                Dependency{ .wait_on_indices = &[0]u32{} },
                Dependency{ .wait_on_indices = &[_]u32{ 1, 0 } },
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }

        // Artibtrary order (0)
        {
            const dependencies = comptime buildDependencyList(.{
                Systems.writeA,
                Systems.readB,
                Systems.readA,
                Systems.writeA,
                Systems.readB,
                Systems.writeB,
                Systems.readAreadB,
                Systems.readAreadB,
                Systems.writeAwriteB,
            }, 9);
            const expected_dependencies = [_]Dependency{
                Dependency{ .wait_on_indices = &[0]u32{} }, // 0: Systems.writeA,
                Dependency{ .wait_on_indices = &[0]u32{} }, // 1: Systems.readB,
                Dependency{ .wait_on_indices = &[_]u32{0} }, // 2: Systems.readA,
                Dependency{ .wait_on_indices = &[_]u32{2} }, // 3: Systems.writeA,
                Dependency{ .wait_on_indices = &[0]u32{} }, // 4: Systems.readB,
                Dependency{ .wait_on_indices = &[_]u32{ 4, 1 } }, // 5: Systems.writeB,
                Dependency{ .wait_on_indices = &[_]u32{ 5, 3 } }, // 6: Systems.readAreadB,
                Dependency{ .wait_on_indices = &[_]u32{ 5, 3 } }, // 7: Systems.readAreadB,
                Dependency{ .wait_on_indices = &[_]u32{ 7, 6 } }, // 8: Systems.writeAwriteB,
            };

            for (expected_dependencies, dependencies) |expected_system_dependencies, system_dependencies| {
                try std.testing.expectEqualSlices(u32, expected_system_dependencies.wait_on_indices, system_dependencies.wait_on_indices);
            }
        }
    }
}
