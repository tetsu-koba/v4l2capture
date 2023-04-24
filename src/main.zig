const std = @import("std");
const log = std.log;
const mem = std.mem;
const os = std.os;
const time = std.time;
const v = @import("v4l2capture.zig");

const MAX_EVENT = 5;
var frame_count: i64 = 0;
var running: bool = false;
var outFile: ?std.fs.File = null;
var tcp: ?std.net.Stream = null;

fn createSignalfd() !os.fd_t {
    var mask = os.empty_sigset;
    os.linux.sigaddset(&mask, os.linux.SIG.INT);
    os.linux.sigaddset(&mask, os.linux.SIG.TERM);
    _ = os.linux.sigprocmask(os.linux.SIG.BLOCK, &mask, null);
    return try os.signalfd(-1, &mask, os.linux.SFD.CLOEXEC);
}

fn handleSignals(signal_fd: os.fd_t) !void {
    var buf: [@sizeOf(os.linux.signalfd_siginfo)]u8 align(8) = undefined;
    if (buf.len != try os.read(signal_fd, &buf)) {
        return os.ReadError.ReadError;
    }
    const info = @ptrCast(*os.linux.signalfd_siginfo, &buf);
    switch (info.signo) {
        os.linux.SIG.INT => {
            log.info("{d}:Got SIGINT", .{time.milliTimestamp()});
            running = false;
        },
        os.linux.SIG.TERM => {
            log.info("{d}:Got SIGTERM", .{time.milliTimestamp()});
            running = false;
        },
        else => unreachable,
    }
}

fn frameHandler(frame: []const u8) void {
    frame_count += 1;
    if (outFile) |f| {
        f.writeAll(frame) catch |err| {
            log.err("frameHandle: {s}", .{@errorName(err)});
            running = false;
        };
    } else if (tcp) |t| {
        t.writeAll(frame) catch |err| {
            log.err("frameHandle: {s}", .{@errorName(err)});
            running = false;
        };
    }
}

fn open(alc: std.mem.Allocator, url_string: []const u8) !bool {
    const uri = std.Uri.parse(url_string) catch std.Uri{
        .scheme = "file",
        .path = url_string,
        .host = null,
        .user = null,
        .password = null,
        .port = null,
        .query = null,
        .fragment = null,
    };
    if (mem.eql(u8, uri.scheme, "file")) {
        if (!mem.eql(u8, uri.path, "")) {
            log.info("uri.path={s}", .{uri.path});
            outFile = try std.fs.cwd().createFile(url_string, .{});
            return true;
        }
    } else if (mem.eql(u8, uri.scheme, "tcp")) {
        if (uri.host) |host| {
            if (uri.port) |port| {
                tcp = try std.net.tcpConnectToHost(alc, host, port);
                return true;
            }
        }
    }
    return false;
}

fn close() void {
    if (outFile) |f| {
        f.close();
    } else if (tcp) |t| {
        t.close();
    }
}

pub fn main() !void {
    const alc = std.heap.page_allocator;
    const args = try std.process.argsAlloc(alc);
    defer std.process.argsFree(alc, args);

    if (args.len < 3) {
        std.debug.print("Usage: {s} /dev/videoX URL [width height framerate]\ndefault is 640x480@30fps\nURL is 'file://filename', 'tcp://hostname:port' or just filename.\n", .{args[0]});
        os.exit(1);
    }
    const devname = std.mem.sliceTo(args[1], 0);
    const url_string = std.mem.sliceTo(args[2], 0);
    var width: u32 = 640;
    var height: u32 = 480;
    var framerate: u32 = 30;
    if (args.len >= 4) {
        width = try std.fmt.parseInt(u32, args[3], 10);
    }
    if (args.len >= 5) {
        height = try std.fmt.parseInt(u32, args[4], 10);
    }
    if (args.len >= 6) {
        framerate = try std.fmt.parseInt(u32, args[5], 10);
    }

    if (!try open(alc, url_string)) {
        log.err("Invalid URL: {s}", .{url_string});
        os.exit(1);
    }
    defer close();

    var cap = try v.Capturer.init(alc, devname, width, height, framerate);
    defer cap.deinit();

    try cap.start();
    defer cap.stop();

    const epoll_fd = try os.epoll_create1(os.linux.EPOLL.CLOEXEC);
    defer os.close(epoll_fd);
    var read_event = os.linux.epoll_event{
        .events = os.linux.EPOLL.IN,
        .data = os.linux.epoll_data{ .fd = cap.getFd() },
    };
    try os.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, read_event.data.fd, &read_event);

    const signal_fd = try createSignalfd();
    defer os.close(signal_fd);
    var signal_event = os.linux.epoll_event{
        .events = os.linux.EPOLL.IN,
        .data = os.linux.epoll_data{ .fd = signal_fd },
    };
    try os.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, signal_event.data.fd, &signal_event);
    const timeout = 5000;

    running = true;
    var start_time = time.milliTimestamp();
    while (running) {
        var events: [MAX_EVENT]os.linux.epoll_event = .{};
        const event_count = os.epoll_wait(epoll_fd, &events, timeout);
        if (event_count == 0) {
            log.info("{d}:timeout", .{time.milliTimestamp()});
            continue;
        }
        for (events[0..event_count]) |ev| {
            if (ev.data.fd == read_event.data.fd) {
                try cap.capture(&frameHandler);
            } else if (ev.data.fd == signal_event.data.fd) {
                try handleSignals(signal_event.data.fd);
            } else {
                unreachable;
            }
        }
    }
    const duration = time.milliTimestamp() - start_time;
    log.info("{d}:duration {d}ms, frame_count {d}, {d:.2}fps", .{ time.milliTimestamp(), duration, frame_count, @intToFloat(f32, frame_count) / @intToFloat(f32, duration) * 1000 });
}
