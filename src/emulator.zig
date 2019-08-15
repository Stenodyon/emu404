const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const MMURange = struct {
    base: usize,
    len: usize,
};

const MMUTarget = union(enum) {
    ROM: []const u8,
    RAM: []u4,
    DBGOUT: u4,
};

const MMULink = struct {
    range: MMURange,
    target: MMUTarget,
};

fn read_target(target: MMUTarget, offset: usize) u4 {
    switch (target) {
        .ROM => |data| {
            const byte_index = offset >> 1;
            if (offset & 1 > 0) { // lower nibble
                return @intCast(u4, data[byte_index] & 0xF);
            } else {
                return @intCast(u4, (data[byte_index] & 0xF0) >> 4);
            }
        },
        .RAM => |data| return data[offset],
        .DBGOUT => return 0,
    }
}

fn write_target(target: *MMUTarget, offset: usize, value: u4) void {
    switch (target.*) {
        .ROM => |data| {
            std.debug.warn("attempt to write to ROM at offset 0x{X}\n", offset);
        },
        .RAM => |data| data[offset] = value,
        .DBGOUT => |*val| {
            val.* = value;
            std.debug.warn("wrote {X} to DBGOUT\n", value);
        },
    }
}

pub const MMU = struct {
    mappings: ArrayList(MMULink),

    pub fn init(allocator: *Allocator) MMU {
        return MMU{
            .mappings = ArrayList(MMULink).init(allocator),
        };
    }

    pub fn deinit(self: *MMU) void {
        self.mappings.deinit();
    }

    pub fn map_ROM(self: *MMU, data: []const u8, address: usize) !void {
        const target = MMUTarget{ .ROM = data };
        const range = MMURange{ .base = address, .len = 2 * data.len };
        const link = MMULink{ .range = range, .target = target };
        try self.mappings.append(link);
    }

    pub fn map_DBGOUT(self: *MMU, address: usize) !void {
        const target = MMUTarget{ .DBGOUT = undefined };
        const range = MMURange{ .base = address, .len = 1 };
        const link = MMULink{ .range = range, .target = target };
        try self.mappings.append(link);
    }

    pub fn read(self: *MMU, address: usize) u4 {
        for (self.mappings.toSlice()) |*link| {
            if (address < link.range.base)
                continue;
            const offset = address - link.range.base;
            if (offset < link.range.len)
                return read_target(link.target, offset);
        }
        return undefined;
    }

    pub fn write(self: *MMU, address: usize, value: u4) void {
        for (self.mappings.toSlice()) |*link| {
            if (address < link.range.base)
                continue;
            const offset = address - link.range.base;
            if (offset < link.range.len)
                write_target(&link.target, offset, value);
        }
    }
};

pub const Emulator = struct {
    mmu: MMU,
    A: u4,
    B: u4,
    C: u4,
    D: u4,
    IAR: [3]u4,
    ADDR: [3]u4,

    pub fn init(mmu: MMU) Emulator {
        return Emulator{
            .mmu = mmu,
            .A = undefined,
            .B = undefined,
            .C = undefined,
            .D = undefined,
            .IAR = [3]u4{ 0, 0, 0 },
            .ADDR = [3]u4{ 0, 0, 0 },
        };
    }

    fn set_IAR(self: *Emulator, value: usize) void {
        self.IAR[0] = @intCast(u4, value & 0xF);
        self.IAR[1] = @intCast(u4, (value & 0xF0) >> 4);
        self.IAR[2] = @intCast(u4, (value & 0xF00) >> 8);
    }

    fn get_IAR(self: *Emulator) usize {
        var value = @intCast(usize, self.IAR[0]);
        value |= @intCast(usize, self.IAR[1]) << 4;
        value |= @intCast(usize, self.IAR[2]) << 8;
        return value;
    }

    fn get_ADDR(self: *Emulator) usize {
        var value = @intCast(usize, self.ADDR[0]);
        value |= @intCast(usize, self.ADDR[1]) << 4;
        value |= @intCast(usize, self.ADDR[2]) << 8;
        return value;
    }

    fn fetch(self: *Emulator) u4 {
        var IAR = self.get_IAR();
        const value = self.mmu.read(self.get_IAR());
        IAR += 1;
        self.set_IAR(IAR);
        return value;
    }

    pub fn run(self: *Emulator) void {
        while (true) {
            const instruction = self.fetch();

            switch (instruction) {
                1 => { // LDI
                    self.A = self.fetch();
                },
                2 => { // LOD
                    self.A = self.mmu.read(self.get_ADDR());
                },
                3 => { // STR
                    self.mmu.write(self.get_ADDR(), self.A);
                },
                4 => { // SAR
                    self.ADDR[1] = self.A;
                    self.ADDR[0] = self.B;
                },
                5 => { // SAP
                    self.ADDR[2] = self.A;
                },
                6 => { // MOV
                    const regs = [4]*u4{ &self.A, &self.B, &self.C, &self.D };
                    const AABB = self.fetch();
                    const AA = (AABB & 0xC) >> 2;
                    const BB = AABB & 0x3;
                    const reg_A = regs[AA];
                    const reg_B = regs[BB];
                    reg_B.* = reg_A.*;
                },
                8 => { // JMP
                    const A2 = self.fetch();
                    const A1 = self.fetch();
                    const A0 = self.fetch();
                    self.IAR[0] = A0;
                    self.IAR[1] = A1;
                    self.IAR[2] = A2;
                },
                9 => { // RJP
                    self.IAR[0] = self.B;
                    self.IAR[1] = self.A;
                    self.IAR[2] = self.D;
                },
                0xA => { // JZ
                    const A2 = self.fetch();
                    const A1 = self.fetch();
                    const A0 = self.fetch();
                    if (self.A == 0) {
                        self.IAR[0] = A0;
                        self.IAR[1] = A1;
                        self.IAR[2] = A2;
                    }
                },
                0xD => { // NAND
                    const regs = [4]*u4{ &self.A, &self.B, &self.C, &self.D };
                    const AABB = self.fetch();
                    const AA = (AABB & 0xC) >> 2;
                    const BB = AABB & 0x3;
                    const reg_A = regs[AA];
                    const reg_B = regs[BB];
                    reg_A.* = ~(reg_B.* & reg_A.*);
                },
                else => {
                    std.debug.panic(
                        "illegal instruction {X} at 0x{X}\n",
                        instruction,
                        self.get_IAR() - 1,
                    );
                },
            }
        }
    }
};
