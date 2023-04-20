const std = @import("std");
const v = @import("v4l2capture.zig");

pub fn main() !void {
    const alc = std.heap.page_allocator;
    const args = try std.process.argsAlloc(alc);
    defer std.process.argsFree(alc, args);

    if (args.len < 5) {
        std.debug.print("Usage: {s} /dev/videoX width height out.mjpg\n", .{args[0]});
        std.os.exit(1);
    }
    const devname = std.mem.sliceTo(args[1], 0);
    const width = try std.fmt.parseInt(u32, args[2], 10);
    const height = try std.fmt.parseInt(u32, args[3], 10);
    const outfile = std.mem.sliceTo(args[4], 0);

    try v.capture(alc, devname, width, height, outfile);
}
