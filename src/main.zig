const std = @import("std");
const log = std.log;
const os = std.os;
const time = std.time;
const v = @import("v4l2capture.zig");

var running: bool = false;
var outFile: std.fs.File = undefined;

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
    outFile.writeAll(frame) catch {
        // TODO err handling
        return false;
    };
    return running;
}

pub fn main() !void {
    const alc = std.heap.page_allocator;
    const args = try std.process.argsAlloc(alc);
    defer std.process.argsFree(alc, args);

    if (args.len < 3) {
        std.debug.print("Usage: {s} /dev/videoX out.mjpg [width height framerate]\ndefault is 640x480@30fps\n", .{args[0]});
        std.os.exit(1);
    }
    const devname = std.mem.sliceTo(args[1], 0);
    const outfile = std.mem.sliceTo(args[2], 0);
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

    outFile = try std.fs.cwd().createFile(outfile, .{});
    defer outFile.close();

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
    try cap.capture(&frameHandler);
}
