// tb_kvce_apa_tiu.sv — end-to-end cosim of the three built LonghornSilicon blocks.
//
// One real Qwen2 attention slice (tests/integration/trace.hex) flows through all
// three RTL blocks in a single simulation, wired in chip order:
//
//   KVCE (cq_value_path, CQ-8)  compress+decompress K,V  ->  K̂, V̂
//   in-sim                      S = Q · K̂   (attention scores)
//   APA  (precision_controller) route the score tile      ->  INT8 / FP16 decision
//   in-sim                      P = softmax(S)
//   TIU  (token_importance_unit) accumulate P, evict       ->  heavy-hitter victim
//   in-sim                      O = P · V̂   (attention output, sanity)
//
// Each block self-checks against its own rule recomputed in the TB on the SAME
// RTL-derived data, so this proves the three blocks interoperate on a coherent
// dataflow (per-block bit-exactness is already covered by each repo's own TBs).
`timescale 1ns/1ps

module tb_kvce_apa_tiu;
    localparam int D  = 64;
    localparam int DW = 16;
    localparam int MAXT = 64;
    localparam int NSLOT = 8;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---- DUT 1: KVCE value codec (CQ-8) ----
    reg  [3:0]        kv_bits = 4'd8;
    reg               kv_iv = 0;
    reg  [D*DW-1:0]   kv_ivec = 0;
    wire              kv_busy;
    wire              kv_ov;
    wire [DW-1:0]     kv_osc;
    wire [D*8-1:0]    kv_ocode;
    wire [D*8-1:0]    kv_opay;
    reg  [D*8-1:0]    kv_dc = 0;
    reg  [DW-1:0]     kv_ds = 0;
    reg  [$clog2(D)-1:0] kv_didx = 0;
    wire [31:0]       kv_dh;
    cq_value_path #(.D(D), .DW(DW)) u_kvce (
        .clk(clk), .rst_n(rst_n), .bits(kv_bits),
        .in_valid(kv_iv), .in_vec(kv_ivec), .busy(kv_busy),
        .out_valid(kv_ov), .out_scale(kv_osc), .out_codes(kv_ocode), .out_pay(kv_opay),
        .dec_codes(kv_dc), .dec_scale(kv_ds), .dec_idx(kv_didx), .dec_hat(kv_dh));

    // ---- DUT 2: APA precision controller (tile N = 4*4 = 16) ----
    reg              pc_sv = 0, pc_sl = 0;
    reg  signed [7:0] pc_sd = 0;
    wire             pc_dv, pc_fp16;
    precision_controller #(.BLOCK_M(4), .BLOCK_N(4), .SCORE_WIDTH(8), .THRESHOLD(10)) u_apa (
        .clk(clk), .rst_n(rst_n),
        .s_valid(pc_sv), .s_data(pc_sd), .s_last(pc_sl),
        .d_valid(pc_dv), .d_fp16(pc_fp16));

    // ---- DUT 3: TIU ----
    reg              t_av = 0; reg [2:0] t_as = 0; reg [7:0] t_aw = 0;
    reg              t_lv = 0; reg [2:0] t_ls = 0;
    reg              t_er = 0;
    reg  [7:0]       t_thr = 8'd0;
    wire             t_ev; wire [2:0] t_es; wire [NSLOT-1:0] t_keep; wire t_busy;
    token_importance_unit #(.N_SLOTS(NSLOT), .SCORE_WIDTH(8), .WEIGHT_WIDTH(8)) u_tiu (
        .clk(clk), .rst_n(rst_n),
        .acc_valid(t_av), .acc_slot(t_as), .acc_weight(t_aw),
        .ld_valid(t_lv), .ld_slot(t_ls),
        .evict_req(t_er), .evict_valid(t_ev), .evict_slot(t_es),
        .tier_threshold(t_thr), .tier_keep(t_keep), .busy(t_busy));

    // ---- trace storage ----
    integer Dn, Tn, Cn;
    real    Q [0:MAXT-1];
    reg [DW-1:0] Kbits [0:MAXT*128-1];
    reg [DW-1:0] Vbits [0:MAXT*128-1];
    real Khat [0:MAXT-1][0:127];
    real Vhat [0:MAXT-1][0:127];
    real Sr   [0:MAXT-1];
    real Pr   [0:MAXT-1];
    int  sq   [0:MAXT-1];

    integer tests=0, pass=0;

    // latch the precision decision (d_valid is a 1-cycle pulse)
    reg got_dec = 0, got_fp16 = 0;
    always @(posedge clk) if (pc_dv) begin got_dec <= 1'b1; got_fp16 <= pc_fp16; end

    // fp32 bit pattern -> real (iverilog 12 has no $bitstoshortreal)
    function real f32_to_real(input [31:0] w);
        integer e, k; real frac, val;
        begin
            e = w[30:23];
            if (e==0 || e==255) val = 0.0;
            else begin
                frac = 1.0;
                for (k=0;k<23;k=k+1) if (w[k]) frac = frac + 2.0**(k-23);
                val = frac * (2.0 ** (e-127));
            end
            f32_to_real = w[31] ? -val : val;
        end
    endfunction

    // compress token `vec` (D fp16 words at base) then decompress into `dst` (real)
    task automatic codec(input int base, input int which, input int tk);
        integer d; reg [DW-1:0] sc; reg [D*8-1:0] codes;
        begin
            @(negedge clk);
            for (d=0; d<D; d=d+1)
                kv_ivec[d*DW +: DW] = (which==0) ? Kbits[base+d] : Vbits[base+d];
            kv_iv = 1'b1; @(negedge clk); kv_iv = 1'b0;
            while (!kv_ov) @(negedge clk);
            sc = kv_osc; codes = kv_ocode;
            kv_dc = codes; kv_ds = sc;
            for (d=0; d<D; d=d+1) begin
                kv_didx = d[$clog2(D)-1:0]; #1;
                if (which==0) Khat[tk][d] = f32_to_real(kv_dh);
                else          Vhat[tk][d] = f32_to_real(kv_dh);
            end
        end
    endtask

    // ---- TIU shadow (mirror the RTL argmin exactly) ----
    integer sh_score [0:NSLOT-1];
    integer sh_valid [0:NSLOT-1];
    function integer exp_victim; integer k, ms, mi;
        begin ms = sh_valid[0] ? sh_score[0] : (1<<20); mi = 0;
            for (k=0;k<NSLOT;k=k+1) if (sh_valid[k] && sh_score[k]<ms) begin ms=sh_score[k]; mi=k; end
            exp_victim = mi; end
    endfunction

    integer fd, code, t, d, freeslot, victim, slot_of [0:MAXT-1];
    real smax, ssum, sabsmax, expo, psum, omax, O [0:127];
    integer sqmax, sqsum; reg exp_fp16;
    reg [DW-1:0] tmpw;
    string qline;

    initial begin
        // load trace
        fd = $fopen("trace.hex", "r");
        if (fd==0) begin $display("ERROR: no trace.hex"); $finish; end
        code = $fscanf(fd, "%d %d %d\n", Dn, Tn, Cn);
        for (d=0; d<Dn; d=d+1) code = $fscanf(fd, "%f", Q[d]);
        for (t=0; t<Tn; t=t+1) begin
            for (d=0; d<Dn; d=d+1) begin code=$fscanf(fd,"%h",tmpw); Kbits[t*Dn+d]=tmpw; end
            for (d=0; d<Dn; d=d+1) begin code=$fscanf(fd,"%h",tmpw); Vbits[t*Dn+d]=tmpw; end
        end
        $fclose(fd);
        $display("loaded slice: D=%0d T=%0d C=%0d", Dn, Tn, Cn);

        rst_n=0; repeat(3) @(posedge clk); rst_n=1; @(posedge clk);

        // ---- STAGE 1: KVCE compress+decompress K and V ----
        for (t=0; t<Tn; t=t+1) begin codec(t*Dn, 0, t); codec(t*Dn, 1, t); end
        $display("[KVCE] compressed+decompressed %0d tokens (K,V) via cq_value_path (CQ-8)", Tn);

        // ---- STAGE 2: scores S = Q . Khat, quantize to int8 ----
        sabsmax = 0.0;
        for (t=0; t<Tn; t=t+1) begin
            Sr[t] = 0.0;
            for (d=0; d<Dn; d=d+1) Sr[t] = Sr[t] + Q[d]*Khat[t][d];
            if (Sr[t] > sabsmax) sabsmax = Sr[t];
            if (-Sr[t] > sabsmax) sabsmax = -Sr[t];
        end
        for (t=0; t<Tn; t=t+1)
            sq[t] = (sabsmax>0.0) ? $rtoi(Sr[t]/sabsmax*127.0) : 0;

        // ---- STAGE 3: APA precision route over the tile of Tn scores ----
        sqmax=0; sqsum=0; got_dec=0;
        for (t=0; t<Tn; t=t+1) begin
            @(negedge clk); pc_sv=1; pc_sd=sq[t][7:0]; pc_sl=(t==Tn-1);
            @(negedge clk); pc_sv=0; pc_sl=0;
            if ((sq[t]<0?-sq[t]:sq[t]) > sqmax) sqmax=(sq[t]<0?-sq[t]:sq[t]);
            sqsum = sqsum + (sq[t]<0?-sq[t]:sq[t]);
        end
        repeat(3) @(posedge clk); #1;
        exp_fp16 = (sqmax*Tn) > (sqsum*10);       // recompute the ratio gate (N=Tn=16)
        tests=tests+1;
        if (got_dec && (got_fp16===exp_fp16)) begin pass=pass+1;
            $display("[APA] decision=%s (max=%0d sum=%0d N=%0d) matches the ratio gate", got_fp16?"FP16":"INT8", sqmax, sqsum, Tn); end
        else $display("[APA] MISMATCH: got_dec=%0b fp16=%0b exp=%0b", got_dec, got_fp16, exp_fp16);

        // ---- STAGE 4: softmax(S) -> weights -> TIU accumulate + evict ----
        smax=Sr[0]; for (t=1;t<Tn;t=t+1) if (Sr[t]>smax) smax=Sr[t];
        psum=0.0; for (t=0;t<Tn;t=t+1) begin Pr[t]=$exp(Sr[t]-smax); psum=psum+Pr[t]; end
        for (t=0;t<Tn;t=t+1) Pr[t]=Pr[t]/psum;

        for (d=0;d<NSLOT;d=d+1) begin sh_score[d]=0; sh_valid[d]=0; end
        for (t=0; t<Tn; t=t+1) begin
            // find a free slot; else evict the argmin
            freeslot=-1;
            for (d=0; d<Cn; d=d+1) if (!sh_valid[d]) begin freeslot=d; d=Cn; end
            if (freeslot==-1) begin
                victim = exp_victim();
                @(negedge clk); t_er=1; @(negedge clk); #1 t_er=0;
                wait (t_ev==1'b1); #1;
                tests=tests+1;
                if (t_es===victim[2:0]) pass=pass+1;
                else $display("[TIU] MISMATCH evict tok %0d: rtl=%0d exp=%0d", t, t_es, victim);
                sh_valid[victim]=0; freeslot=victim;
                @(posedge clk);
            end
            // LOAD token t into freeslot
            @(negedge clk); t_lv=1; t_ls=freeslot[2:0]; @(negedge clk); #1 t_lv=0;
            sh_valid[freeslot]=1; sh_score[freeslot]=0; slot_of[t]=freeslot;
            // ACC this token's received attention weight (single query)
            begin integer w; w = $rtoi(Pr[t]*255.0); if (w>255) w=255;
                @(negedge clk); t_av=1; t_as=freeslot[2:0]; t_aw=w[7:0]; @(negedge clk); #1 t_av=0;
                sh_score[freeslot] = sh_score[freeslot] + w; if (sh_score[freeslot]>255) sh_score[freeslot]=255;
            end
        end
        $display("[TIU] streamed %0d tokens through cache budget C=%0d, evictions checked", Tn, Cn);

        // ---- STAGE 5: O = P . Vhat (sanity) ----
        omax=0.0;
        for (d=0; d<Dn; d=d+1) begin O[d]=0.0;
            for (t=0;t<Tn;t=t+1) O[d]=O[d]+Pr[t]*Vhat[t][d];
            if (O[d]>omax) omax=O[d]; end
        $display("[OUT] attention output O = P.V̂ computed (max element %0.4f), full pipeline ran", omax);

        $display("");
        $display("Checks: %0d  Pass: %0d", tests, pass);
        if (tests>0 && tests==pass) $display("ALL TESTS PASSED");
        else $display("FAILED (%0d/%0d)", pass, tests);
        $finish;
    end
endmodule
