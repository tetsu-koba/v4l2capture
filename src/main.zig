const std = @import("std");
const log = std.log;
const mem = std.mem;
const os = std.os;
const time = std.time;
const v = @import("v4l2capture.zig");

var frame_count: i64 = 0;
var running: bool = false;
var outFile: ?std.fs.File = null;
var tcp: ?std.net.Stream = null;

fn signalHandler(signo: c_int) align(1) callconv(.C) void {
    switch (signo) {
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

fn frameHandler(frame: []const u8) bool {
    frame_count += 1;
    if (outFile) |f| {
        f.writeAll(frame) catch |err| {
            log.err("frameHandle: {s}", .{@errorName(err)});
            return false;
        };
    } else if (tcp) |t| {
        t.writeAll(frame) catch |err| {
            log.err("frameHandle: {s}", .{@errorName(err)});
            return false;
        };
    }
    return running;
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
        } else {
            log.err("Invalid URL: {s}", .{url_string});
            os.exit(1);
        }
    } else if (mem.eql(u8, uri.scheme, "tcp")) {
        if (uri.host) |host| {
            if (uri.port) |port| {
                tcp = try std.net.tcpConnectToHost(alc, host, port);
            } else {
                log.err("Invalid URL: {s}", .{url_string});
                os.exit(1);
            }
        } else {
            log.err("Invalid URL: {s}", .{url_string});
            os.exit(1);
        }
    }
    defer close();

    var cap = try v.Capturer.init(alc, devname, width, height, framerate);
    defer cap.deinit();

    const action = os.linux.Sigaction{
        .handler = .{ .handler = &signalHandler },
        .mask = os.empty_sigset,
        .flags = 0,
    };
    _ = os.linux.sigaction(os.linux.SIG.INT, &action, null);
    _ = os.linux.sigaction(os.linux.SIG.TERM, &action, null);
    running = true;
    var start_time = time.milliTimestamp();
    try cap.capture(&frameHandler);
    const duration = time.milliTimestamp() - start_time;
    log.info("{d}:duration {d}ms, frame_count {d}, {d:.2}fps", .{ time.milliTimestamp(), duration, frame_count, @intToFloat(f32, frame_count) / @intToFloat(f32, duration) * 1000 });
}
