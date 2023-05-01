const std = @import("std");
const os = std.os;
const log = std.log;
const time = std.time;
const c = @cImport({
    @cInclude("linux/videodev2.h");
});

const Buffer = struct {
    start: []align(std.mem.page_size) u8,
    length: usize,
};

pub const Capturer = struct {
    verbose: bool = false,
    buffers: []Buffer = undefined,
    fd: os.fd_t = undefined,
    alc: std.mem.Allocator,
    devname: []const u8,
    width: u32,
    height: u32,
    framerate: u32,
    pixelformat: u32,

    const MIN_BUFFERS = 3;
    const Self = @This();

    pub fn init(
        alc: std.mem.Allocator,
        devname: []const u8,
        width: u32,
        height: u32,
        framerate: u32,
        pixelformat: []const u8,
    ) !Capturer {
        var self = Capturer{
            .alc = alc,
            .devname = devname,
            .width = width,
            .height = height,
            .framerate = framerate,
            .pixelformat = try fourcc(pixelformat),
        };
        try self.openDevice();
        errdefer self.closeDevice();
        try self.capDevice();
        try self.setDevice();
        try self.setFramerate();
        try self.prepareBuffers();
        errdefer self.munmapBuffer();
        try self.enqueueBuffers();
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.munmapBuffer();
        self.closeDevice();
    }

    pub inline fn getWidth(self: *Self) u32 {
        return self.width;
    }

    pub inline fn getHeight(self: *Self) u32 {
        return self.height;
    }

    fn fourcc(f: []const u8) !u32 {
        if (f.len != 4) {
            log.err("Illegal fourcc format: {s}\n", .{f});
            unreachable;
        }
        return @intCast(u32, f[0]) | @intCast(u32, f[1]) << 8 | @intCast(u32, f[2]) << 16 | @intCast(u32, f[3]) << 24;
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

    fn openDevice(self: *Self) !void {
        self.fd = try os.open(self.devname, os.O.RDWR, 0o664);
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

    fn setDevice(self: *Self) !void {
        var fmt: c.struct_v4l2_format = undefined;
        @memset(@ptrCast([*]u8, &fmt)[0..@sizeOf(c.struct_v4l2_format)], 0);
        fmt.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        fmt.fmt.pix.width = self.width;
        fmt.fmt.pix.height = self.height;
        fmt.fmt.pix.pixelformat = self.pixelformat;
        fmt.fmt.pix.field = c.V4L2_FIELD_ANY;
        try self.xioctl(c.VIDIOC_S_FMT, @ptrToInt(&fmt));
        @memset(@ptrCast([*]u8, &fmt)[0..@sizeOf(c.struct_v4l2_format)], 0);
        fmt.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        try self.xioctl(c.VIDIOC_G_FMT, @ptrToInt(&fmt));
        if (fmt.fmt.pix.pixelformat != self.pixelformat) {
            const p = self.pixelformat;
            log.err("pixelformat {c}{c}{c}{c} is not supported\n", .{ @truncate(u8, p), @truncate(u8, p >> 8), @truncate(u8, p >> 16), @truncate(u8, p >> 24) });
            unreachable;
        }
        if (fmt.fmt.pix.width != self.width or fmt.fmt.pix.height != self.height) {
            if (fmt.fmt.pix.pixelformat == c.V4L2_PIX_FMT_MJPEG) {
                log.warn("Requested format is {d}x{d} but set to {d}x{d}.", .{ self.width, self.height, fmt.fmt.pix.width, fmt.fmt.pix.height });
                self.width = fmt.fmt.pix.width;
                self.height = fmt.fmt.pix.height;
            } else {
                log.err("Requested format {d}x{d} is not supported.", .{ self.width, self.height });
                unreachable;
            }
        }
    }

    fn setFramerate(self: *Self) !void {
        var streamparm: c.struct_v4l2_streamparm = undefined;
        @memset(@ptrCast([*]u8, &streamparm)[0..@sizeOf(c.struct_v4l2_streamparm)], 0);
        streamparm.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        try self.xioctl(c.VIDIOC_G_PARM, @ptrToInt(&streamparm));
        if (streamparm.parm.capture.capability & c.V4L2_CAP_TIMEPERFRAME != 0) {
            streamparm.parm.capture.timeperframe.numerator = 1;
            streamparm.parm.capture.timeperframe.denominator = self.framerate;
            try self.xioctl(c.VIDIOC_S_PARM, @ptrToInt(&streamparm));
            @memset(@ptrCast([*]u8, &streamparm)[0..@sizeOf(c.struct_v4l2_streamparm)], 0);
            streamparm.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
            try self.xioctl(c.VIDIOC_G_PARM, @ptrToInt(&streamparm));
            const r = streamparm.parm.capture.timeperframe.denominator;
            if (r != self.framerate) {
                log.warn("Requested framerate is {d} but set to {d}.", .{ self.framerate, r });
                self.framerate = r;
            }
        } else {
            log.warn("Framerate cannot be set.", .{});
        }
    }

    fn prepareBuffers(self: *Self) !void {
        var req: c.struct_v4l2_requestbuffers = undefined;
        @memset(@ptrCast([*]u8, &req)[0..@sizeOf(c.struct_v4l2_requestbuffers)], 0);
        req.count = Capturer.MIN_BUFFERS;
        req.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        req.memory = c.V4L2_MEMORY_MMAP;
        try self.xioctl(c.VIDIOC_REQBUFS, @ptrToInt(&req));
        if (req.count < MIN_BUFFERS) {
            log.err("Insufficient buffer memory on camera\n", .{});
            unreachable;
        }
        self.buffers = try self.alc.alloc(Buffer, req.count);
        for (self.buffers, 0..) |_, i| {
            var buff: c.struct_v4l2_buffer = undefined;
            @memset(@ptrCast([*]u8, &buff)[0..@sizeOf(c.struct_v4l2_buffer)], 0);
            buff.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
            buff.memory = c.V4L2_MEMORY_MMAP;
            buff.index = @intCast(c_uint, i);
            try self.xioctl(c.VIDIOC_QUERYBUF, @ptrToInt(&buff));
            self.buffers[i].length = buff.length;
            self.buffers[i].start = try os.mmap(null, buff.length, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED, self.fd, buff.m.offset);
        }
    }

    fn enqueueBuffer(self: *Self, index: usize) !void {
        var buf: c.struct_v4l2_buffer = undefined;
        @memset(@ptrCast([*]u8, &buf)[0..@sizeOf(c.struct_v4l2_buffer)], 0);
        buf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = c.V4L2_MEMORY_MMAP;
        buf.index = @intCast(c_uint, index);
        try self.xioctl(c.VIDIOC_QBUF, @ptrToInt(&buf));
    }

    fn enqueueBuffers(self: *Self) !void {
        for (self.buffers, 0..) |_, i| {
            try self.enqueueBuffer(i);
        }
    }

    fn streamStart(self: *Self) !void {
        const t: c.enum_v4l2_buf_type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        try self.xioctl(c.VIDIOC_STREAMON, @ptrToInt(&t));
    }

    fn streamStop(self: *Self) !void {
        const t: c.enum_v4l2_buf_type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        try self.xioctl(c.VIDIOC_STREAMOFF, @ptrToInt(&t));
    }

    fn munmapBuffer(self: *Self) void {
        for (self.buffers, 0..) |_, i| {
            os.munmap(self.buffers[i].start);
        }
        self.alc.free(self.buffers);
    }

    fn closeDevice(self: *Self) void {
        os.close(self.fd);
    }

    pub fn start(self: *Self) !void {
        try self.streamStart();
    }

    pub fn stop(self: *Self) void {
        self.streamStop() catch unreachable;
    }

    pub fn getFd(self: *Self) os.fd_t {
        return self.fd;
    }

    pub fn capture(self: *Self, frameHandler: *const fn (*Self, []const u8) void) !void {
        var buf: c.struct_v4l2_buffer = undefined;
        buf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = c.V4L2_MEMORY_MMAP;

        try self.xioctl(c.VIDIOC_DQBUF, @ptrToInt(&buf));
        const b = self.buffers[buf.index];
        frameHandler(self, b.start[0..b.length]);
        try self.enqueueBuffer(buf.index);
    }
};
