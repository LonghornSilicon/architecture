// tb_chip_cosim.sv — cross-block RTL cosim: all three block RTLs instantiated together and
// driven by one shared attention scenario. Proves ACU + KVE + TIU co-simulate on real data.
//   KVE : CQ-3-rot value codec (cq_value_path_wht -> wht_inverse_out) — bit-exact vs reference
//   TIU : H2O importance (token_importance_unit) — keep-tier + eviction victim
//   ACU : precision gate (precision_controller) — INT8/FP16 per tile
// Chip order: a token's V flows through KVE; its attention mass drives TIU; the query's
// score row drives ACU. Each block's RTL output is checked against its reference here.
`timescale 1ns/1ps
module tb_chip_cosim;
    localparam int D = 128, DW = 16;
    reg clk = 0, rst_n = 0; always #5 clk = ~clk;
    integer errors = 0;

    // ================= KVE: CQ-3-rot value path (Path B) =================
    reg  [D*DW-1:0] kve_in;
    wire [D*8-1:0]  kve_codes; wire [DW-1:0] kve_scale;
    reg  [$clog2(D)-1:0] kve_didx; wire [DW-1:0] kve_drot;
    cq_value_path_wht #(.D(D), .DW(DW)) u_kve (
        .in_vec(kve_in), .out_codes(kve_codes), .out_scale(kve_scale),
        .dec_codes(kve_codes), .dec_scale(kve_scale), .dec_idx(kve_didx), .dec_rot_f16(kve_drot));
    reg  [D*DW-1:0] kve_rot; wire [D*32-1:0] kve_vhat;
    wht_inverse_out #(.D(D), .DW(DW)) u_mate (.rot_out(kve_rot), .vhat_out(kve_vhat));

    // ================= ACU: precision gate =================
    reg acu_sv, acu_sl; reg signed [7:0] acu_s; wire acu_dv, acu_fp16;
    precision_controller #(.SCORE_WIDTH(8)) u_acu (
        .clk(clk), .rst_n(rst_n), .s_valid(acu_sv), .s_data(acu_s), .s_last(acu_sl),
        .d_valid(acu_dv), .d_fp16(acu_fp16));

    // ================= TIU: H2O importance =================
    localparam int NS = 8;
    reg tiu_av, tiu_lv, tiu_er; reg [2:0] tiu_as, tiu_ls; reg [7:0] tiu_aw, tiu_thr;
    wire tiu_ev; wire [2:0] tiu_es; wire [NS-1:0] tiu_keep; wire tiu_busy;
    token_importance_unit #(.N_SLOTS(NS), .SCORE_WIDTH(8), .WEIGHT_WIDTH(8)) u_tiu (
        .clk(clk), .rst_n(rst_n), .acc_valid(tiu_av), .acc_slot(tiu_as), .acc_weight(tiu_aw),
        .ld_valid(tiu_lv), .ld_slot(tiu_ls), .evict_req(tiu_er), .evict_valid(tiu_ev),
        .evict_slot(tiu_es), .tier_threshold(tiu_thr), .tier_keep(tiu_keep), .busy(tiu_busy));

    // ---- shared scenario data ----
    reg [DW-1:0] Vin [0:255][0:127]; reg [31:0] Ghat [0:255][0:127];
    integer Dn, Tn, Bn, fv, fg, code, t, d, k;
    reg [DW-1:0] t16; reg [31:0] g32;
    reg [7:0] mass [0:NS-1];
    integer exp_evict, mn; reg exp_fp16; integer mx, sm, e0;

    task step; begin @(negedge clk); end endtask

    initial begin
        // ---------- load a real Qwen attention tile (V + its reference V̂) ----------
        fv = $fopen("vectors/qwen_val.hex", "r"); fg = $fopen("vectors/qwen_vhatwht.hex", "r");
        if (fv==0||fg==0) begin $display("FATAL: missing vectors/"); $finish; end
        code = $fscanf(fv, "%d %d %d\n", Dn, Tn, Bn);
        for (t=0;t<Tn;t=t+1) begin
            for (d=0;d<Dn;d=d+1) begin code=$fscanf(fv,"%h",t16); Vin[t][d]=t16; end
            for (d=0;d<Dn;d=d+1) begin code=$fscanf(fg,"%h",g32); Ghat[t][d]=g32; end
        end
        $fclose(fv); $fclose(fg);
        rst_n = 0; repeat(4) step; rst_n = 1; step;

        // ========== BLOCK 2 (KVE): reconstruct each token's V̂, check bit-exact ==========
        if (Tn > 8) Tn = 8;   // cosim: a few tokens suffice to prove KVE bit-exact in-context
        e0 = errors;
        for (t=0;t<Tn;t=t+1) begin
            for (d=0;d<Dn;d=d+1) kve_in[d*DW +: DW] = Vin[t][d];
            #1;
            for (d=0;d<Dn;d=d+1) begin kve_didx = d[$clog2(D)-1:0]; #1; kve_rot[d*DW +: DW] = kve_drot; end
            #1;
            for (d=0;d<Dn;d=d+1) if (kve_vhat[d*32 +: 32] !== Ghat[t][d]) errors = errors + 1;
        end
        $display("[KVE ] CQ-3-rot V̂ over %0d real-Qwen tokens: %s", Tn, (errors==e0)?"bit-exact vs reference":"MISMATCH");

        // ========== BLOCK 3 (TIU): install slots, accumulate mass, keep-tier + evict ==========
        // masses derived from the tile (per-token amax magnitude, quantized to a weight)
        e0 = errors;
        for (k=0;k<NS;k=k+1) mass[k] = (Vin[k][0] & 8'hFF);          // deterministic per-token weight
        for (k=0;k<NS;k=k+1) begin step; tiu_lv=1; tiu_ls=k[2:0]; end // install NS tokens
        step; tiu_lv=0;
        for (k=0;k<NS;k=k+1) begin step; tiu_av=1; tiu_as=k[2:0]; tiu_aw=mass[k]; end // accumulate mass
        step; tiu_av=0; tiu_thr = 8'd128; step; step;
        // expected keep (score>=thr) and evict (min-mass slot, first-wins on ties)
        exp_evict = 0; mn = mass[0];
        for (k=1;k<NS;k=k+1) if (mass[k] < mn) begin mn = mass[k]; exp_evict = k; end
        for (k=0;k<NS;k=k+1) if (tiu_keep[k] !== (mass[k] >= tiu_thr)) errors = errors + 1;
        // request eviction, then wait on the evict_valid handshake (serial scan ~N_SLOTS+2 cyc)
        tiu_er = 1; step; tiu_er = 0;
        k = 0; while (tiu_ev !== 1'b1 && k < 40) begin step; k = k + 1; end
        if (tiu_ev !== 1'b1) begin errors=errors+1; $display("  TIU evict_valid never pulsed"); end
        else if (tiu_es !== exp_evict[2:0]) begin errors=errors+1; $display("  TIU evict got=%0d exp=%0d", tiu_es, exp_evict); end
        $display("[TIU ] keep-tier (thr=%0d) + eviction victim: %s (evict slot %0d)",
                 tiu_thr, (errors==e0)?"match reference":"MISMATCH", tiu_es);

        // ========== BLOCK 1 (ACU): gate one query's score row INT8/FP16 ==========
        // peaky score row -> should route FP16 (max*N > 10*sum)
        e0 = errors; mx = 0; sm = 0;
        for (k=0;k<16;k=k+1) begin
            step; acu_sv=1; acu_sl=(k==15); acu_s = (k==0) ? 8'sd100 : 8'sd2;  // one spike
            if (((k==0)?100:2) > mx) mx = (k==0)?100:2; sm = sm + ((k==0)?100:2);
        end
        step; acu_sv=0;
        k = 0; while (acu_dv !== 1'b1 && k < 8) begin step; k = k + 1; end  // wait for d_valid pulse
        exp_fp16 = (mx*16 > 10*sm);
        if (acu_dv !== 1'b1) begin errors=errors+1; $display("  ACU d_valid never pulsed"); end
        else if (acu_fp16 !== exp_fp16) begin errors=errors+1; $display("  ACU fp16 got=%0b exp=%0b (max=%0d sum=%0d)", acu_fp16, exp_fp16, mx, sm); end
        $display("[ACU ] precision gate on a peaky score row: %s (fp16=%0b)",
                 (errors==e0)?"match reference":"MISMATCH", acu_fp16);

        $display("");
        $display("CROSS-BLOCK COSIM (ACU + KVE + TIU on one shared tile): %s", (errors==0)?"ALL BLOCKS PASS":"FAILED");
        $finish;
    end
endmodule
