// mate_pv.sv
//
// Synthesizable INT8 P·V MAC tile — the token-reduction vector-MAC core of the
// LonghornSilicon "Lambda" MatE matrix engine. Computes one attention output row
//
//     o[n] = Σ_t  A[t] · V[t][n]        (n = 0 .. N-1 head-dim channels)
//
// in signed INT8 × INT8 → signed INT32, NO saturation — bit-exact to the ACU MAC
// array reference sw/reference_model/mac_array_ref.{hpp,py} `matmul_int8` for M=1.
//
// Why INT32 (not INT24): the P·V tile reduces over the TOKEN dimension, so the
// accumulator width scales with context length. A maximally-flat causal row of
// length L drives every code to ±127, so |acc| ≤ 127·127·L → 14+ceil(log2 L) bits;
// INT24 overflows past ~520 tokens, INT32 covers ~133k. The K-axis (hidden-dim)
// GEMM accumulators are INT24; the token-reduction P·V accumulator is INT32.
// See adaptive-precision-attention/analysis/pv_accumulator_width.py + arch.yml.
//
// This is the ACU's INT8 tile (precision_controller.d_fp16 == 0). The FP16 tile is
// tolerance-only (see MAC_ARRAY_DESIGN.md) and is not in this integer datapath.
//
// Interface (house style — streaming valid/last, 1-cycle result pulse, like
// precision_controller): present one token per clock with s_valid=1, its scalar
// A-code on a_data and its N-wide packed V-row on v_data; assert s_last=1 on the
// final token of the row. c_valid pulses the cycle after s_last with the N int32
// results on c_data. Accumulators auto-reset on s_last for the next row.
//
// Latency  : 1 cycle after s_last.  Throughput: 1 token/cycle, 1 row per K tokens.
// Synthesis: fully combinational MAC + registered int32 accumulators; no latches.

`timescale 1ns/1ps

module mate_pv #(
    parameter integer N     = 8,    // head-dim channels computed in parallel (lanes)
    parameter integer AW    = 8,    // A (attention-prob) code width, signed
    parameter integer VW    = 8,    // V (value) code width, signed
    parameter integer ACC_W = 32    // token-reduction accumulator width (INT32)
) (
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire                    s_valid,   // a token is being presented
    input  wire signed [AW-1:0]    a_data,    // A[t]      : this token's attention code
    input  wire        [N*VW-1:0]  v_data,    // V[t][0..N-1]: this token's value row (packed signed)
    input  wire                    s_last,    // last token of the output row

    output reg                     c_valid,   // pulses cycle after s_last
    output reg  signed [N*ACC_W-1:0] c_data   // N int32 dot-product results
);

    genvar gi;
    integer i;

    // Per-lane signed accumulators.
    reg signed [ACC_W-1:0] acc [0:N-1];

    // Per-lane combinational MAC: acc_next = acc + A·V (sign-extended to ACC_W).
    // int8×int8 → int16 product, sign-extended before the int32 add — exactly
    // matmul_int8's `int32(A)*int32(B)` accumulation (the product fits int16, so
    // promoting before vs after the multiply is identical).
    wire signed [ACC_W-1:0] acc_next [0:N-1];
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : g_mac
            wire signed [VW-1:0]     v_lane = $signed(v_data[gi*VW +: VW]);
            wire signed [AW+VW-1:0]  prod   = a_data * v_lane;          // signed int16
            assign acc_next[gi] = acc[gi] + $signed(prod);             // sign-extended add
        end
    endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            c_valid <= 1'b0;
            c_data  <= {N*ACC_W{1'b0}};
            for (i = 0; i < N; i = i + 1)
                acc[i] <= {ACC_W{1'b0}};
        end else begin
            c_valid <= 1'b0;                       // default: no result this cycle

            if (s_valid) begin
                if (s_last) begin
                    // Emit Σ_t A·V for every lane, then clear for the next row.
                    for (i = 0; i < N; i = i + 1) begin
                        c_data[i*ACC_W +: ACC_W] <= acc_next[i];
                        acc[i]                   <= {ACC_W{1'b0}};
                    end
                    c_valid <= 1'b1;
                end else begin
                    for (i = 0; i < N; i = i + 1)
                        acc[i] <= acc_next[i];
                end
            end
        end
    end

endmodule
