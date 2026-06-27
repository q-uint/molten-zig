const gpu = @import("gpu");

const In = extern struct { data: [4]f32 };
const Out = extern struct { data: [4]f32 };
const Params = extern struct { scale: f32 };
const Push = extern struct { offset: f32 };

const in_buf = gpu.storageBuffer(In, 0, 0, "in_buf");
const out_buf = gpu.storageBuffer(Out, 0, 1, "out_buf");
const params = gpu.uniformBuffer(Params, 0, 2, "params");
const push = gpu.pushConstant(Push, "push");

pub const Kernel = struct {
    pub fn entry() callconv(.{ .spirv_kernel = .{ .x = 4, .y = 1, .z = 1 } }) void {
        const i = gpu.global_invocation_id[0];
        if (i >= 4) return;
        out_buf.*.data[i] = in_buf.*.data[i] * params.*.scale + push.*.offset;
    }
};

comptime {
    @export(&Kernel.entry, .{ .name = "main" });
}
