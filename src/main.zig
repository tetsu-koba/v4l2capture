const std = @import("std");
const os = std.os;
const v = @import("v4l2capture.zig");

pub fn main() !void {
    const alc = std.heap.page_allocator;
    const args = try std.process.argsAlloc(alc);
    defer std.process.argsFree(alc, args);

    if (args.len < 5) {
        std.debug.print("Usage: {s} /dev/videoX width height out.jpg\n", .{args[0]});
        os.exit(1);
    }
    const devname = std.mem.sliceTo(args[1], 0);
    const width = try std.fmt.parseInt(u32, args[2], 10);
    const height = try std.fmt.parseInt(u32, args[3], 10);
    const outfile = std.mem.sliceTo(args[4], 0);

    try v.capture(alc, devname, width, height, outfile);
}

// pub fn main() !void {
//     // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
//     std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

//     // stdout is for the actual output of your application, for example if you
//     // are implementing gzip, then only the compressed bytes should be sent to
//     // stdout, not any debugging messages.
//     const stdout_file = std.io.getStdOut().writer();
//     var bw = std.io.bufferedWriter(stdout_file);
//     const stdout = bw.writer();

//     try stdout.print("Run `zig build test` to run the tests.\n", .{});

//     try bw.flush(); // don't forget to flush!
// }

// test "simple test" {
//     var list = std.ArrayList(i32).init(std.testing.allocator);
//     defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
//     try list.append(42);
//     try std.testing.expectEqual(@as(i32, 42), list.pop());
// }
