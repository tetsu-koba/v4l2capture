const std = @import("std");
const fs = std.fs;
const os = std.os;
const c = @cImport({
    @cDefine("_GNU_SOURCE", "");
    @cInclude("fcntl.h");
    @cInclude("sys/uio.h");
    @cInclude("errno.h");
});

fn getErrno() c_int {
    return c.__errno_location().*;
}

pub fn vmspliceSingleBuffer(buf: []const u8, fd: c_int) !void {
    var iov: c.struct_iovec = .{
        .iov_base = @ptrCast(?*anyopaque, @constCast(buf.ptr)),
        .iov_len = buf.len,
    };
    var n: isize = undefined;
    while (true) {
        n = c.vmsplice(fd, &iov, 1, @bitCast(c_uint, c.SPLICE_F_GIFT));
        if (n == buf.len) {
            return;
        }
        if (n < 0) {
            const errno = getErrno();
            switch (errno) {
                c.EINTR => {
                    continue;
                },
                else => {
                    std.log.err("vmsplice: errno={d}", .{errno});
                },
            }
        } else {
            std.log.err("vmsplice: return value mismatch: n={d}, buf.len={d}", .{ n, buf.len });
        }
        return error.vmsplice;
    }
    unreachable;
}
