const std = @import("std");
const fs = std.fs;
const os = std.os;
const c = @cImport({
    @cDefine("_GNU_SOURCE", "");
    @cInclude("fcntl.h");
    @cInclude("sys/uio.h");
    @cInclude("errno.h");
});

pub fn vmspliceToFd(buf: []const u8, fd: c_int) !void {
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
        if ((n < 0) and (c.__errno_location().* == c.EINTR)) continue;
        return error.vmsplice;
    }
    unreachable;
}
