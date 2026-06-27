const gpu = @import("gpu");

const N: u32 = 256;

const Buf = extern struct { data: [N]f32 };

const in_buf = gpu.storageBuffer(Buf, 0, 0, "in_buf");
const out_buf = gpu.storageBuffer(Buf, 0, 1, "out_buf");

pub const Kernel = struct {
    pub fn entry() callconv(.{ .spirv_kernel = .{ .x = N, .y = 1, .z = 1 } }) void {
        const i = gpu.global_invocation_id[0];
        if (i >= N) return;
        out_buf.*.data[i] = in_buf.*.data[i] * 2.0;
    }
};

comptime {
    @export(&Kernel.entry, .{ .name = "main" });
}
