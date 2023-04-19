const std = @import("std");
const os = std.os;
const log = std.log;
const c = @cImport({
    @cInclude("linux/videodev2.h");
});

const buffer = struct {
    start: []align(std.mem.page_size) u8,
    length: usize,
};

const MIN_BUFFERS = 3;
var n_buffers: u32 = undefined;
var buffers: []buffer = undefined;
var fd: os.fd_t = undefined;

fn xioctl(fd0: os.fd_t, request: u32, arg: usize) !void {
    var rc: usize = undefined;
    while (true) {
        rc = os.linux.ioctl(fd0, request, arg);
        switch (os.linux.getErrno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return os.unexpectedErrno(err),
        }
    }
}

fn openDevice(devname: []const u8) !void {
    fd = try os.open(devname, os.O.RDWR, 0o664);
}

fn capDevice() !void {
    var cap: c.struct_v4l2_capability = undefined;
    try xioctl(fd, c.VIDIOC_QUERYCAP, @ptrToInt(&cap));
    if (0 == cap.capabilities & c.V4L2_CAP_VIDEO_CAPTURE) {
        log.err("no video capture\n", .{});
        unreachable;
    }
    if (0 == cap.capabilities & c.V4L2_CAP_STREAMING) {
        log.err("does not support stream\n", .{});
        unreachable;
    }
}

fn setDevice(width: u32, height: u32) !void {
    var fmt: c.struct_v4l2_format = undefined;
    @memset(@ptrCast([*]u8, &fmt), 0, @sizeOf(c.struct_v4l2_format));
    fmt.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = width;
    fmt.fmt.pix.height = height;
    fmt.fmt.pix.pixelformat = c.V4L2_PIX_FMT_MJPEG;
    fmt.fmt.pix.field = c.V4L2_FIELD_ANY;
    try xioctl(fd, c.VIDIOC_S_FMT, @ptrToInt(&fmt));
    @memset(@ptrCast([*]u8, &fmt), 0, @sizeOf(c.struct_v4l2_format));
    fmt.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    try xioctl(fd, c.VIDIOC_G_FMT, @ptrToInt(&fmt));
    if (fmt.fmt.pix.width != width or fmt.fmt.pix.height != height or fmt.fmt.pix.pixelformat != c.V4L2_PIX_FMT_MJPEG) {
        log.err("Requested format is not supported\n", .{});
        unreachable;
    }
}

fn requestBuffer() !void {
    var req: c.struct_v4l2_requestbuffers = undefined;
    @memset(@ptrCast([*]u8, &req), 0, @sizeOf(c.struct_v4l2_requestbuffers));
    req.count = MIN_BUFFERS;
    req.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = c.V4L2_MEMORY_MMAP;
    try xioctl(fd, c.VIDIOC_REQBUFS, @ptrToInt(&req));
    n_buffers = req.count;
    if (req.count < MIN_BUFFERS) {
        log.err("Insufficient buffer memory on camera\n", .{});
        unreachable;
    }
}

fn mapBuffer(alc: std.mem.Allocator) !void {
    buffers = try alc.alloc(buffer, n_buffers);
    var n_buffer: u32 = 0;
    while (n_buffer < n_buffers) : (n_buffer += 1) {
        var buff: c.struct_v4l2_buffer = undefined;
        @memset(@ptrCast([*]u8, &buff), 0, @sizeOf(c.struct_v4l2_buffer));
        buff.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buff.memory = c.V4L2_MEMORY_MMAP;
        buff.index = @bitCast(c_uint, n_buffer);
        try xioctl(fd, c.VIDIOC_QUERYBUF, @ptrToInt(&buff));
        buffers[n_buffer].length = buff.length;
        buffers[n_buffer].start = try os.mmap(null, buff.length, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED, fd, buff.m.offset);
    }
}

fn enqueueBuffer(index: u32) !void {
    var buf: c.struct_v4l2_buffer = undefined;
    @memset(@ptrCast([*]u8, &buf), 0, @sizeOf(c.struct_v4l2_buffer));
    buf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = c.V4L2_MEMORY_MMAP;
    buf.index = @bitCast(c_uint, index);
    try xioctl(fd, c.VIDIOC_QBUF, @ptrToInt(&buf));
}

fn enqueueBuffers() !void {
    var n_buffer: u32 = 0;
    while (n_buffer < n_buffers) : (n_buffer += 1) {
        try enqueueBuffer(n_buffer);
    }
}

fn streamStart() !void {
    const t: c.enum_v4l2_buf_type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    try xioctl(fd, c.VIDIOC_STREAMON, @ptrToInt(&t));
}

fn makeImage(outfile: []const u8) !u32 {
    var fds: [1]os.pollfd = .{.{ .fd = fd, .events = os.linux.POLL.IN, .revents = 0 }};
    _ = try os.poll(&fds, 5000);
    var buf: c.struct_v4l2_buffer = undefined;
    buf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = c.V4L2_MEMORY_MMAP;
    try xioctl(fd, c.VIDIOC_DQBUF, @ptrToInt(&buf));
    var out = try std.fs.cwd().createFile(outfile, .{});
    defer out.close();
    const w = out.writer();
    try w.writeAll(buffers[buf.index].start[0..buffers[buf.index].length]);
    return buf.index;
}

fn streamStop() !void {
    const t: c.enum_v4l2_buf_type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    try xioctl(fd, c.VIDIOC_STREAMOFF, @ptrToInt(&t));
}

fn munmapBuffer(alc: std.mem.Allocator) void {
    var i: usize = 0;
    while (i < n_buffers) : (i += 1) {
        os.munmap(buffers[i].start);
    }
    alc.free(buffers);
    buffers = undefined;
}

fn closeDevice() void {
    os.close(fd);
}

pub fn capture(alc: std.mem.Allocator, devname: []const u8, width: u32, height: u32, outfile: []const u8) !void {
    try openDevice(devname);
    defer closeDevice();
    try capDevice();
    try setDevice(width, height);
    try requestBuffer();
    try mapBuffer(alc);
    defer munmapBuffer(alc);
    try enqueueBuffers();
    try streamStart();
    defer streamStop() catch unreachable;
    var buf: [128]u8 = undefined;
    for (0..599) |i| {
        var fname = try std.fmt.bufPrint(&buf, "{s}_{d:0>4}.jpg", .{ outfile, i });
        var enqueue_index = try makeImage(fname);
        try enqueueBuffer(enqueue_index);
    }
}
