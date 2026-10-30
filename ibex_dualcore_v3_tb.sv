// ============================================================
// ibex_dualcore_tb_v3.sv   — B4 INTEGRATION TEST
//
// 2 core Ibex THẬT chạy chương trình nhỏ, data đi qua hệ thống
// cache-coherent (MESI + crossbar). Kiểm tra dữ liệu shared
// đồng bộ đúng ở tầng top.
//
// Chương trình mỗi core: GHI 1 lần -> ĐỌC chéo 1 lần -> spin NOP
// (để hệ quiesce, tránh ping-pong vô hạn khi sample kết quả).
//
//   Core 0: SHARED[0] (0x0002_0000) <- 0xDEAD0000 ; doc SHARED[1] -> x3
//   Core 1: SHARED[1] (0x0002_0004) <- 0xCAFE0000 ; doc SHARED[0] -> x3
//
// SHARED[0] & SHARED[1] cung 1 cache line (word0/word1 cua line 0)
// -> ep ping-pong MESI: GETM/RECALL/FWD qua crossbar.
//
// Kiem tra cuoi: doc line 0 trong bank crossbar
//   u_dut.u_coh.u_xbar.bank_mem_q[0][0]  (128-bit)
//     word0 = SHARED[0] ; word1 = SHARED[1]
// ============================================================

`timescale 1ns/1ps

module ibex_dualcore_v3_tb;

  localparam int unsigned IMEM0_SIZE  = 16384;
  localparam int unsigned IMEM1_SIZE  = 16384;
  localparam int unsigned DMEM_SIZE   = 65536;
  localparam logic [31:0] CORE0_BOOT  = 32'h0000_0000;
  localparam logic [31:0] CORE1_BOOT  = 32'h0001_0000;
  localparam logic [31:0] SHARED_BASE = 32'h0002_0000;
  localparam logic [3:0]  MUBI4_TRUE  = 4'b0101;

  // Clock & Reset
  logic clk;
  logic rst_n;
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Core stimulus tie-offs
  logic        core0_irq_software = 1'b0, core0_irq_timer = 1'b0, core0_irq_external = 1'b0, core0_irq_nm = 1'b0;
  logic [14:0] core0_irq_fast = '0;
  logic        core1_irq_software = 1'b0, core1_irq_timer = 1'b0, core1_irq_external = 1'b0, core1_irq_nm = 1'b0;
  logic [14:0] core1_irq_fast = '0;
  logic        core0_debug_req = 1'b0, core1_debug_req = 1'b0;
  logic [3:0]  core0_fetch_enable, core1_fetch_enable;

  // Core outputs (observed)
  ibex_pkg::crash_dump_t core0_crash_dump, core1_crash_dump;
  logic core0_double_fault, core1_double_fault;
  logic core0_alert_minor, core0_alert_major_internal, core0_alert_major_bus, core0_core_sleep;
  logic core1_alert_minor, core1_alert_major_internal, core1_alert_major_bus, core1_core_sleep;

  // DUT
  ibex_dualcore_top_v3 #(
    .IMem0SizeBytes (IMEM0_SIZE),
    .IMem1SizeBytes (IMEM1_SIZE),
    .DMSizeBytes    (DMEM_SIZE),
    .Core0BootAddr  (CORE0_BOOT),
    .Core1BootAddr  (CORE1_BOOT),
    .RegFile        (ibex_pkg::RegFileFF)
  ) u_dut (
    .clk_i                        (clk),
    .rst_ni                       (rst_n),
    .core0_irq_software_i         (core0_irq_software),
    .core0_irq_timer_i            (core0_irq_timer),
    .core0_irq_external_i         (core0_irq_external),
    .core0_irq_fast_i             (core0_irq_fast),
    .core0_irq_nm_i               (core0_irq_nm),
    .core1_irq_software_i         (core1_irq_software),
    .core1_irq_timer_i            (core1_irq_timer),
    .core1_irq_external_i         (core1_irq_external),
    .core1_irq_fast_i             (core1_irq_fast),
    .core1_irq_nm_i               (core1_irq_nm),
    .core0_debug_req_i            (core0_debug_req),
    .core0_crash_dump_o           (core0_crash_dump),
    .core0_double_fault_seen_o    (core0_double_fault),
    .core1_debug_req_i            (core1_debug_req),
    .core1_crash_dump_o           (core1_crash_dump),
    .core1_double_fault_seen_o    (core1_double_fault),
    .core0_fetch_enable_i         (core0_fetch_enable),
    .core0_alert_minor_o          (core0_alert_minor),
    .core0_alert_major_internal_o (core0_alert_major_internal),
    .core0_alert_major_bus_o      (core0_alert_major_bus),
    .core0_core_sleep_o           (core0_core_sleep),
    .core1_fetch_enable_i         (core1_fetch_enable),
    .core1_alert_minor_o          (core1_alert_minor),
    .core1_alert_major_internal_o (core1_alert_major_internal),
    .core1_alert_major_bus_o      (core1_alert_major_bus),
    .core1_core_sleep_o           (core1_core_sleep)
  );

  // Reset + fetch enable
  initial begin
    rst_n = 1'b0;
    core0_fetch_enable = 4'b0000;
    core1_fetch_enable = 4'b0000;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    core0_fetch_enable = MUBI4_TRUE;
    core1_fetch_enable = MUBI4_TRUE;
  end

  // Load programs
  initial begin
    @(posedge rst_n);
    @(posedge clk);

    for (int i = 0; i < IMEM0_SIZE/4; i++) u_dut.imem0[i] = 32'h00000013;
    for (int i = 0; i < IMEM1_SIZE/4; i++) u_dut.imem1[i] = 32'h00000013;

    // ---- Core 0 @ imem0[32] (PC=0x80) ----
    u_dut.imem0[32] = 32'h000200B7; // lui  x1,0x20      x1=0x0002_0000
    u_dut.imem0[33] = 32'hDEAD0137; // lui  x2,0xDEAD0   x2=0xDEAD0000
    u_dut.imem0[34] = 32'h0020A023; // sw   x2,0(x1)
    u_dut.imem0[35] = 32'h0040A183; // lw   x3,4(x1)     x3<-SHARED[1]
    u_dut.imem0[36] = 32'h0000006F; // jal  x0,0         spin (self loop)

    // ---- Core 1 @ imem1[32] (PC=0x1_0080) ----
    u_dut.imem1[32] = 32'h000200B7; // lui  x1,0x20
    u_dut.imem1[33] = 32'hCAFE0137; // lui  x2,0xCAFE0
    u_dut.imem1[34] = 32'h0020A223; // sw   x2,4(x1)
    u_dut.imem1[35] = 32'h0000A183; // lw   x3,0(x1)     x3<-SHARED[0]
    u_dut.imem1[36] = 32'h0000006F; // jal  x0,0         spin

    $display("============================================");
    $display("  B4: Dual-Core Ibex + Coherent Subsystem");
    $display("============================================");
  end

  int unsigned trc;
  always @(posedge clk) if (rst_n && trc < 60) begin
    if (u_dut.u_coh.core_req_i[0] && u_dut.u_coh.core_gnt_o[0]) begin
      $display("t=%0t C0 ACCEPT we=%b addr=%08h wdata=%08h", $time,
               u_dut.u_coh.core_we_i[0], u_dut.u_coh.core_addr_i[0], u_dut.u_coh.core_wdata_i[0]);
      trc <= trc + 1;
    end
    if (u_dut.u_coh.core_req_i[1] && u_dut.u_coh.core_gnt_o[1]) begin
      $display("t=%0t C1 ACCEPT we=%b addr=%08h wdata=%08h", $time,
               u_dut.u_coh.core_we_i[1], u_dut.u_coh.core_addr_i[1], u_dut.u_coh.core_wdata_i[1]);
      trc <= trc + 1;
    end
    if (u_dut.u_coh.core_rvalid_o[0]) begin
      $display("t=%0t C0 RVALID rdata=%08h", $time, u_dut.u_coh.core_rdata_o[0]); trc <= trc + 1;
    end
    if (u_dut.u_coh.core_rvalid_o[1]) begin
      $display("t=%0t C1 RVALID rdata=%08h", $time, u_dut.u_coh.core_rdata_o[1]); trc <= trc + 1;
    end
  end

  // Đếm hoạt động data + instr để chẩn đoán
  int unsigned n_core0_dreq, n_core1_dreq, n_core0_we, n_core1_we;
  always @(posedge clk) if (rst_n) begin
    if (u_dut.u_coh.core_req_i[0] && u_dut.u_coh.core_gnt_o[0]) begin
      n_core0_dreq <= n_core0_dreq + 1;
      if (u_dut.u_coh.core_we_i[0]) n_core0_we <= n_core0_we + 1;
    end
    if (u_dut.u_coh.core_req_i[1] && u_dut.u_coh.core_gnt_o[1]) begin
      n_core1_dreq <= n_core1_dreq + 1;
      if (u_dut.u_coh.core_we_i[1]) n_core1_we <= n_core1_we + 1;
    end
  end

  // Final check
  logic [127:0] bank_line;
  logic [31:0]  sh0, sh1;
  initial begin
    #50_000; // 50 us du de quiesce

    $display("  DIAG: core0 data-accept=%0d (we=%0d) | core1 data-accept=%0d (we=%0d)",
             n_core0_dreq, n_core0_we, n_core1_dreq, n_core1_we);
    $display("  DIAG: core0 instr_req seen=%b  core1 instr_req seen=%b",
             u_dut.core0_instr_req, u_dut.core1_instr_req);
    $display("  DIAG: cache0 line0 state=%0d data=%032h",
             u_dut.u_coh.g_cache[0].u_l1.state_q[0], u_dut.u_coh.g_cache[0].u_l1.data_q[0]);
    $display("  DIAG: cache1 line0 state=%0d data=%032h",
             u_dut.u_coh.g_cache[1].u_l1.state_q[0], u_dut.u_coh.g_cache[1].u_l1.data_q[0]);

    bank_line = u_dut.u_coh.u_xbar.bank_mem_q[0][0];
    sh0 = bank_line[31:0];
    sh1 = bank_line[63:32];

    $display("--------------------------------------------");
    $display("  Bank line0 (crossbar backing store):");
    $display("    SHARED[0] = 0x%08h  (Core0 ghi 0xDEAD0000)", sh0);
    $display("    SHARED[1] = 0x%08h  (Core1 ghi 0xCAFE0000)", sh1);
    $display("--------------------------------------------");

    if (sh0 === 32'hDEAD0000) $display("  [PASS] SHARED[0] = 0xDEAD0000");
    else                       $display("  [FAIL] SHARED[0] expected 0xDEAD0000, got 0x%08h", sh0);

    if (sh1 === 32'hCAFE0000) $display("  [PASS] SHARED[1] = 0xCAFE0000");
    else                       $display("  [FAIL] SHARED[1] expected 0xCAFE0000, got 0x%08h", sh1);

    $display("============================================");
    $finish;
  end

endmodule