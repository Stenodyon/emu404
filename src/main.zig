const std = @import("std");

usingnamespace @import("emulator.zig");

pub fn main() anyerror!void {
    const args = try std.process.argsAlloc(std.heap.c_allocator);
    defer std.process.argsFree(std.heap.c_allocator, args);

    if (args.len != 2) {
        std.debug.warn("Usage: {} rom-file\n", args[0]);
        std.process.exit(1);
    }
    const filename = args[1];
    const rom = try std.io.readFileAlloc(std.heap.c_allocator, filename);
    defer std.heap.c_allocator.free(rom);

    var mmu = MMU.init(std.heap.c_allocator);
    defer mmu.deinit();
    try mmu.map_ROM(rom, 0);
    try mmu.map_DBGOUT(0x100);

    var emu = Emulator.init(mmu);
    emu.run();
}
