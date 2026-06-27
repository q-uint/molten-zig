// Tiled GEMM: C = A * B, all row-major, all f32.
// One workgroup -> one TILE x TILE output tile, one thread -> one output.
// K is iterated TILE at a time through shared A_tile and B_tile.

const gpu = @import("gpu");

const TILE: u32 = 16;
const Push = extern struct { m: u32, n: u32, k: u32 };
const Buf = extern struct { data: @SpirvType(.{ .runtime_array = f32 }) };

const a_buf = @extern(*addrspace(.storage_buffer) const Buf, .{ .name = "a_buf", .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } } });
const b_buf = @extern(*addrspace(.storage_buffer) const Buf, .{ .name = "b_buf", .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } } });
const c_buf = @extern(*addrspace(.storage_buffer) Buf, .{ .name = "c_buf", .decoration = .{ .descriptor = .{ .set = 0, .binding = 2 } } });
const push = gpu.pushConstant(Push, "push");

var a_tile: [TILE][TILE]f32 addrspace(.shared) = undefined;
var b_tile: [TILE][TILE]f32 addrspace(.shared) = undefined;

export fn main() callconv(.{ .spirv_kernel = .{ .x = TILE, .y = TILE, .z = 1 } }) void {
    const row = gpu.global_invocation_id[1];
    const col = gpu.global_invocation_id[0];
    const lr = gpu.local_invocation_id[1];
    const lc = gpu.local_invocation_id[0];

    const m = push.*.m;
    const n = push.*.n;
    const k_dim = push.*.k;

    var acc: f32 = 0.0;
    const num_tiles = (k_dim + TILE - 1) / TILE;
    var t: u32 = 0;
    while (t < num_tiles) : (t += 1) {
        const a_col = t * TILE + lc;
        const b_row = t * TILE + lr;

        a_tile[lr][lc] = if (row < m and a_col < k_dim)
            (&a_buf.data)[row * k_dim + a_col]
        else
            0.0;
        b_tile[lr][lc] = if (b_row < k_dim and col < n)
            (&b_buf.data)[b_row * n + col]
        else
            0.0;
        gpu.workgroupBarrier();

        var kk: u32 = 0;
        while (kk < TILE) : (kk += 1) {
            acc += a_tile[lr][kk] * b_tile[kk][lc];
        }
        gpu.workgroupBarrier();
    }

    if (row < m and col < n) {
        (&c_buf.data)[row * n + col] = acc;
    }
}
