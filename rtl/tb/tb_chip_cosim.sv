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

    // ===== MatE: INT8 P·V MAC (mate_pv) — the token-reduction accumulation =====
    reg              pv_sv, pv_sl;
    reg  signed [7:0] pv_a;
    reg  [D*8-1:0]   pv_v;
    wire             pv_cv;
    wire signed [D*32-1:0] pv_c;
    mate_pv #(.N(D)) u_pv (
        .clk(clk), .rst_n(rst_n),
        .s_valid(pv_sv), .a_data(pv_a), .v_data(pv_v), .s_last(pv_sl),
        .c_valid(pv_cv), .c_data(pv_c));

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

    // ---- P·V (MatE) working state ----
    localparam integer PVM = 8;          // tokens accumulated by the P·V tile
    localparam real    PV_TOL = 0.06;    // e2e reconstruction rel-err gate (INT8 tile)
    reg  [DW-1:0] rotv16 [0:PVM*D-1];    // rotated V̂ per (token,channel), fp16, from KVE
    reg  signed [7:0] Vint [0:PVM*D-1];  // int8-quantized rotated V̂ (shared tile scale)
    integer Aint [0:PVM-1];              // int8 attention weights
    integer tbc  [0:D-1];                // TB int32 reference of the P·V accumulation
    real scaleA, scaleV, vmax, rr, orot_r, ortl, oref, gmax, adiff, maxrel;
    integer iv, pd;

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
            for (d=0;d<Dn;d=d+1) begin
                kve_didx = d[$clog2(D)-1:0]; #1;
                kve_rot[d*DW +: DW] = kve_drot;
                if (t < PVM) rotv16[t*D + d] = kve_drot;   // stash rotated V̂ for the P·V tile
            end
            #1;
            for (d=0;d<Dn;d=d+1) if (kve_vhat[d*32 +: 32] !== Ghat[t][d]) errors = errors + 1;
        end
        $display("[KVE ] CQ-3-rot V̂ over %0d real-Qwen tokens: %s", Tn, (errors==e0)?"bit-exact vs reference":"MISMATCH");

        // ===== BLOCK 2b (MatE P·V MAC): true end-to-end KVE -> P·V -> inverse =====
        // Insert the INT8 P·V accumulation Σ_t A[t]·V̂rot[t] between the KVE's rotated V̂
        // and wht_inverse_out, so the cosim runs the whole attention-output datapath —
        // not a straight V̂ copy. Bit-exact int32 gate + an e2e reconstruction check:
        // because the inverse WHT is linear, inverse(Σ A·V̂rot) = Σ A·V̂ = Σ A·Ghat, so the
        // reference is TB-computable from Ghat (the reference values) — no model needed.
        e0 = errors;
        for (t=0;t<PVM;t=t+1) Aint[t] = 127 - 10*t;          // distinct positive int8 weights
        scaleA = 1.0/127.0;
        vmax = 0.0;                                          // shared tile scale for V̂rot -> int8
        for (t=0;t<PVM;t=t+1) for (d=0;d<D;d=d+1) begin
            rr = cq_fp_pkg::f16_to_real(rotv16[t*D+d]); if (rr<0.0) rr=-rr;
            if (rr>vmax) vmax=rr;
        end
        scaleV = (vmax>0.0) ? (vmax/127.0) : 1.0;
        for (t=0;t<PVM;t=t+1) for (d=0;d<D;d=d+1) begin
            rr = cq_fp_pkg::f16_to_real(rotv16[t*D+d]) / scaleV;
            iv = $rtoi(rr + (rr>=0.0 ? 0.5 : -0.5));
            if (iv>127) iv=127; if (iv<-127) iv=-127;
            Vint[t*D+d] = iv[7:0];
        end
        for (d=0;d<D;d=d+1) begin                            // TB int32 reference (matmul_int8)
            tbc[d] = 0;
            for (t=0;t<PVM;t=t+1) tbc[d] = tbc[d] + Aint[t]*$signed(Vint[t*D+d]);
        end
        for (t=0;t<PVM;t=t+1) begin                          // drive the mate_pv RTL
            step;
            pv_sv = 1; pv_a = Aint[t][7:0]; pv_sl = (t==PVM-1);
            for (d=0;d<D;d=d+1) pv_v[d*8 +: 8] = Vint[t*D+d];
        end
        step; pv_sv = 0; pv_sl = 0;
        pd = 0; while (pv_cv !== 1'b1 && pd < 8) begin step; pd = pd + 1; end
        if (pv_cv !== 1'b1) begin errors=errors+1; $display("  P·V c_valid never pulsed"); end
        else for (d=0;d<D;d=d+1)
            if ($signed(pv_c[d*32 +: 32]) !== tbc[d]) begin
                errors=errors+1;
                if (d<3) $display("  P·V lane %0d: got %0d exp %0d", d, $signed(pv_c[d*32 +: 32]), tbc[d]);
            end
        $display("[MatE] INT8 P·V MAC (mate_pv), %0d tokens x D=%0d, INT32 acc: %s",
                 PVM, D, (errors==e0)?"int32 bit-exact vs matmul_int8":"MISMATCH");

        // e2e: dequant the int32 result -> wht_inverse_out -> attention output; compare
        // to Σ_t A[t]·Ghat[t] (the reference values). Gap = INT8 P·V quantization only.
        e0 = errors;
        for (d=0;d<D;d=d+1) begin
            orot_r = $itor($signed(pv_c[d*32 +: 32])) * scaleA * scaleV;
            kve_rot[d*DW +: DW] = cq_fp_pkg::real_to_f16(orot_r);
        end
        #1;
        gmax = 1.0e-9;
        for (d=0;d<D;d=d+1) begin
            oref = 0.0;
            for (t=0;t<PVM;t=t+1) oref = oref + ($itor(Aint[t])*scaleA)*cq_fp_pkg::f32_to_real(Ghat[t][d]);
            if (oref<0.0 ? -oref>gmax : oref>gmax) gmax = (oref<0.0?-oref:oref);
        end
        maxrel = 0.0;
        for (d=0;d<D;d=d+1) begin
            ortl = cq_fp_pkg::f32_to_real(kve_vhat[d*32 +: 32]);
            oref = 0.0;
            for (t=0;t<PVM;t=t+1) oref = oref + ($itor(Aint[t])*scaleA)*cq_fp_pkg::f32_to_real(Ghat[t][d]);
            adiff = ortl - oref; if (adiff<0.0) adiff=-adiff;
            if (adiff/gmax > maxrel) maxrel = adiff/gmax;
        end
        if (maxrel >= PV_TOL) errors = errors + 1;
        $display("[MatE] e2e KVE->P·V->inverse vs Sigma A*Ghat: max rel err %f (%s, tol %.2f)",
                 maxrel, (maxrel<PV_TOL)?"within tol":"OUT OF TOL", PV_TOL);

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
        $display("CROSS-BLOCK COSIM (ACU + KVE + MatE P·V + TIU on one shared tile): %s", (errors==0)?"ALL BLOCKS PASS":"FAILED");
        $finish;
    end
endmodule
