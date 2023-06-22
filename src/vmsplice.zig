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

pub fn vmspliceSingleBuffer(buf: []const u8, fd: os.fd_t) !void {
    var iov: c.struct_iovec = .{
        .iov_base = @ptrCast(?*anyopaque, @constCast(buf.ptr)),
        .iov_len = buf.len,
    };
    while (true) {
        const n = c.vmsplice(fd, &iov, 1, @bitCast(c_uint, c.SPLICE_F_GIFT));
        if (n < 0) {
            const errno = getErrno();
            switch (errno) {
                c.EINTR => continue,
                c.EAGAIN => unreachable,
                c.EPIPE => return error.BrokenPipe,
                c.EBADF => return error.InvalidFileDescriptor,
                c.EINVAL => return error.InvalidArgument,
                c.ENOMEM => return error.SystemResources,
                else => std.log.err("vmsplice: errno={d}", .{errno}),
            }
        } else if (@bitCast(usize, n) == iov.iov_len) {
            return;
        } else if (n != 0) {
            //std.log.info("vmsplice: return value mismatch: n={d}, iov_len={d}", .{ n, iov.iov_len });
            const un = @bitCast(usize, n);
            iov.iov_len -= un;
            iov.iov_base = @ptrFromInt(?*anyopaque, @intFromPtr(iov.iov_base) + un);
            continue;
        }
        return error.Vmsplice;
    }
    unreachable;
}
