const std = @import("std");
const os = std.os;
const log = std.log;
const c = @cImport({
    @cInclude("linux/videodev2.h");
});

const Buffer = struct {
    start: []align(std.mem.page_size) u8,
    length: usize,
};

pub const Capturer = struct {
    n_buffers: u32 = undefined,
    buffers: []Buffer = undefined,
    fd: os.fd_t = undefined,

    const MIN_BUFFERS = 3;
    const Self = @This();

    pub fn init() Capturer {
        return Capturer{};
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        //self.alc.free(self.err_msg_buf);
        //self.alc.free(self.dbuf);
        //self.alc.free(self.payload_buf);
    }

    fn xioctl(self: *Self, request: u32, arg: usize) !void {
        var rc: usize = undefined;
        while (true) {
            rc = os.linux.ioctl(self.fd, request, arg);
            switch (os.linux.getErrno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                else => |err| return os.unexpectedErrno(err),
            }
        }
    }

    fn openDevice(self: *Self, devname: []const u8) !void {
        self.fd = try os.open(devname, os.O.RDWR, 0o664);
    }

    fn capDevice(self: *Self) !void {
        var cap: c.struct_v4l2_capability = undefined;
        try self.xioctl(c.VIDIOC_QUERYCAP, @ptrToInt(&cap));
        if (0 == cap.capabilities & c.V4L2_CAP_VIDEO_CAPTURE) {
            log.err("no video capture\n", .{});
            unreachable;
        }
        if (0 == cap.capabilities & c.V4L2_CAP_STREAMING) {
            log.err("does not support stream\n", .{});
            unreachable;
        }
    }

    fn setDevice(self: *Self, width: u32, height: u32) !void {
        var fmt: c.struct_v4l2_format = undefined;
        @memset(@ptrCast([*]u8, &fmt), 0, @sizeOf(c.struct_v4l2_format));
        fmt.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        fmt.fmt.pix.width = width;
        fmt.fmt.pix.height = height;
        fmt.fmt.pix.pixelformat = c.V4L2_PIX_FMT_MJPEG;
        fmt.fmt.pix.field = c.V4L2_FIELD_ANY;
        try self.xioctl(c.VIDIOC_S_FMT, @ptrToInt(&fmt));
        @memset(@ptrCast([*]u8, &fmt), 0, @sizeOf(c.struct_v4l2_format));
        fmt.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        try self.xioctl(c.VIDIOC_G_FMT, @ptrToInt(&fmt));
        if (fmt.fmt.pix.width != width or fmt.fmt.pix.height != height or fmt.fmt.pix.pixelformat != c.V4L2_PIX_FMT_MJPEG) {
            log.err("Requested format is not supported\n", .{});
            unreachable;
        }
    }

    fn requestBuffer(self: *Self) !void {
        var req: c.struct_v4l2_requestbuffers = undefined;
        @memset(@ptrCast([*]u8, &req), 0, @sizeOf(c.struct_v4l2_requestbuffers));
        req.count = Capturer.MIN_BUFFERS;
        req.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        req.memory = c.V4L2_MEMORY_MMAP;
        try self.xioctl(c.VIDIOC_REQBUFS, @ptrToInt(&req));
        self.n_buffers = req.count;
        if (req.count < MIN_BUFFERS) {
            log.err("Insufficient buffer memory on camera\n", .{});
            unreachable;
        }
    }

    fn mapBuffer(self: *Self, alc: std.mem.Allocator) !void {
        self.buffers = try alc.alloc(Buffer, self.n_buffers);
        var n_buffer: u32 = 0;
        while (n_buffer < self.n_buffers) : (n_buffer += 1) {
            var buff: c.struct_v4l2_buffer = undefined;
            @memset(@ptrCast([*]u8, &buff), 0, @sizeOf(c.struct_v4l2_buffer));
            buff.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
            buff.memory = c.V4L2_MEMORY_MMAP;
            buff.index = @bitCast(c_uint, n_buffer);
            try self.xioctl(c.VIDIOC_QUERYBUF, @ptrToInt(&buff));
            self.buffers[n_buffer].length = buff.length;
            self.buffers[n_buffer].start = try os.mmap(null, buff.length, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED, self.fd, buff.m.offset);
        }
    }

    fn enqueueBuffer(self: *Self, index: u32) !void {
        var buf: c.struct_v4l2_buffer = undefined;
        @memset(@ptrCast([*]u8, &buf), 0, @sizeOf(c.struct_v4l2_buffer));
        buf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = c.V4L2_MEMORY_MMAP;
        buf.index = @bitCast(c_uint, index);
        try self.xioctl(c.VIDIOC_QBUF, @ptrToInt(&buf));
    }

    fn enqueueBuffers(self: *Self) !void {
        var n_buffer: u32 = 0;
        while (n_buffer < self.n_buffers) : (n_buffer += 1) {
            try self.enqueueBuffer(n_buffer);
        }
    }

    fn streamStart(self: *Self) !void {
        const t: c.enum_v4l2_buf_type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        try self.xioctl(c.VIDIOC_STREAMON, @ptrToInt(&t));
    }

    fn makeImage(self: *Self, out_fd: std.fs.File) !u32 {
        var fds: [1]os.pollfd = .{.{ .fd = self.fd, .events = os.linux.POLL.IN, .revents = 0 }};
        _ = try os.poll(&fds, 5000);
        var buf: c.struct_v4l2_buffer = undefined;
        buf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = c.V4L2_MEMORY_MMAP;
        try self.xioctl(c.VIDIOC_DQBUF, @ptrToInt(&buf));
        const w = out_fd.writer();
        try w.writeAll(self.buffers[buf.index].start[0..self.buffers[buf.index].length]);
        return buf.index;
    }

    fn streamStop(self: *Self) !void {
        const t: c.enum_v4l2_buf_type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        try self.xioctl(c.VIDIOC_STREAMOFF, @ptrToInt(&t));
    }

    fn munmapBuffer(self: *Self, alc: std.mem.Allocator) void {
        var i: usize = 0;
        while (i < self.n_buffers) : (i += 1) {
            os.munmap(self.buffers[i].start);
        }
        alc.free(self.buffers);
        self.buffers = undefined;
    }

    fn closeDevice(self: *Self) void {
        os.close(self.fd);
    }

    pub fn capture(self: *Self, alc: std.mem.Allocator, devname: []const u8, width: u32, height: u32, outfile: []const u8) !void {
        var out_fd = try std.fs.cwd().createFile(outfile, .{});
        defer out_fd.close();
        try self.openDevice(devname);
        defer self.closeDevice();
        try self.capDevice();
        try self.setDevice(width, height);
        try self.requestBuffer();
        try self.mapBuffer(alc);
        defer self.munmapBuffer(alc);
        try self.enqueueBuffers();
        try self.streamStart();
        defer self.streamStop() catch unreachable;
        for (0..599) |_| {
            var enqueue_index = try self.makeImage(out_fd);
            try self.enqueueBuffer(enqueue_index);
        }
    }
};
