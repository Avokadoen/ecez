const builtin = @import("builtin");
const std = @import("std");
const Src = std.builtin.SourceLocation;

const ztracy = @import("ztracy");

pub const ecez_dev_markers_enabled = blk: {
    var dev_markers_enabled: ?bool = null;

    if (!builtin.is_test) {
        const options = @import("ecez_options");

        const tracy_enabled = check_if_enabled_blk: {
            if (@hasDecl(options, "enable_ztracy")) {
                break :check_if_enabled_blk options.enable_ztracy;
            }
            break :check_if_enabled_blk false;
        };

        if (@hasDecl(options, "enable_ecez_dev_markers")) {
            if (options.enable_ecez_dev_markers and tracy_enabled == false) {
                @compileError("enable_ecez_dev_markers cannot be true if tracy_enabled is false");
            }

            dev_markers_enabled = options.enable_ecez_dev_markers;
        }
    }

    break :blk dev_markers_enabled orelse false;
};

pub const ZoneCtx = create_ctx_type_blk: {
    if (ecez_dev_markers_enabled) {
        break :create_ctx_type_blk struct {
            ztracy_zonectx: ztracy.ZoneCtx,

            pub fn End(self: ZoneCtx) void {
                self.ztracy_zonectx.End();
            }
        };
    } else {
        break :create_ctx_type_blk struct {
            pub fn End(self: ZoneCtx) void {
                _ = self;
            }
        };
    }
};

pub inline fn ZoneNC(comptime src: Src, name: [*:0]const u8, color: u32) ZoneCtx {
    if (ecez_dev_markers_enabled) {
        return ZoneCtx{
            .ztracy_zonectx = ztracy.ZoneNC(src, name, color),
        };
    } else {
        return ZoneCtx{};
    }
}
