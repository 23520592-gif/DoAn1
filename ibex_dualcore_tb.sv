// ============================================================
// Testbench: ibex_dualcore_top
//
// Kịch bản test:
//   1. Core 0 ghi 0xDEAD0000 vào SHARED[0] = 0x0002_0000
//   2. Core 1 ghi 0xCAFE0000 vào SHARED[1] = 0x0002_0004
//   3. Core 0 đọc lại SHARED[1] (giá trị Core 1 đã ghi)
//   4. Core 1 đọc lại SHARED[0] (giá trị Core 0 đã ghi)
//   5. Quan sát arbitration khi 2 core tranh chấp bus
//
// Memory Map:
//   0x0000_0000 – 0x0000_3FFF  Core 0 Private IMEM (16 KiB)
//   0x0001_0000 – 0x0001_3FFF  Core 1 Private IMEM (16 KiB)
//   0x0002_0000 – 0x0002_FFFF  Shared Data SRAM    (64 KiB)
//
// Ibex boot: PC bắt đầu tại boot_addr + 0x80
//   Core 0: 0x0000_0080 → imem0[32]
//   Core 1: 0x0001_0080 → imem1[32]
// ============================================================

`timescale 1ns/1ps

module ibex_dualcore_tb;

  // ----------------------------------------------------------
  // Parameters
  // ----------------------------------------------------------
  localparam int unsigned IMEM0_SIZE  = 16384;
  localparam int unsigned IMEM1_SIZE  = 16384;
  localparam int unsigned DMEM_SIZE   = 65536;
  localparam logic [31:0] CORE0_BOOT  = 32'h0000_0000;
  localparam logic [31:0] CORE1_BOOT  = 32'h0001_0000;
  localparam logic [31:0] SHARED_BASE = 32'h0002_0000;

  // ibex_mubi_t = logic[3:0], IbexMuBi4True = 4'b0101
  localparam logic [3:0] MUBI4_TRUE = 4'b0101;

  // ----------------------------------------------------------
  // Clock & Reset
  // ----------------------------------------------------------
  logic clk;
  logic rst_n;

  initial clk = 0;
  always #10 clk = ~clk;

  initial begin
    rst_n = 0;
    repeat (10) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
  end

  // ----------------------------------------------------------
  // DUT Signals
  // ----------------------------------------------------------
  logic        core0_irq_software, core0_irq_timer, core0_irq_external;
  logic [14:0] core0_irq_fast;
  logic        core0_irq_nm, core0_debug_req;
  logic [3:0]  core0_fetch_enable;
  logic        core0_alert_minor, core0_alert_major_internal;
  logic        core0_alert_major_bus, core0_core_sleep;
  ibex_pkg::crash_dump_t core0_crash_dump;
  logic        core0_double_fault;

  logic        core1_irq_software, core1_irq_timer, core1_irq_external;
  logic [14:0] core1_irq_fast;
  logic        core1_irq_nm, core1_debug_req;
  logic [3:0]  core1_fetch_enable;
  logic        core1_alert_minor, core1_alert_major_internal;
  logic        core1_alert_major_bus, core1_core_sleep;
  ibex_pkg::crash_dump_t core1_crash_dump;
  logic        core1_double_fault;

  // Tie off
  assign core0_irq_software = 0; assign core1_irq_software = 0;
  assign core0_irq_timer    = 0; assign core1_irq_timer    = 0;
  assign core0_irq_external = 0; assign core1_irq_external = 0;
  assign core0_irq_fast     = 0; assign core1_irq_fast     = 0;
  assign core0_irq_nm       = 0; assign core1_irq_nm       = 0;
  assign core0_debug_req    = 0; assign core1_debug_req    = 0;
  assign core0_fetch_enable = MUBI4_TRUE;
  assign core1_fetch_enable = MUBI4_TRUE;

  // ----------------------------------------------------------
  // DUT
  // ----------------------------------------------------------
  ibex_dualcore_top #(
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

  // ----------------------------------------------------------
  // Load Programs
  // ----------------------------------------------------------
  initial begin
    @(posedge rst_n);
    @(posedge clk);

    // NOP toàn bộ IMEM
    for (int i = 0; i < IMEM0_SIZE/4; i++) u_dut.imem0[i] = 32'h00000013;
    for (int i = 0; i < IMEM1_SIZE/4; i++) u_dut.imem1[i] = 32'h00000013;

    // ---- Core 0 Program @ imem0[32] (PC=0x0000_0080) ----
    // lui  x1, 0x20         → x1 = 0x0002_0000 (SHARED_BASE)
    u_dut.imem0[32] = 32'h000200B7;
    // lui  x2, 0xDEAD0      → x2 = 0xDEAD0000
    u_dut.imem0[33] = 32'hDEAD0137;
    // sw   x2, 0(x1)        → SHARED[0] = 0xDEAD0000
    u_dut.imem0[34] = 32'h00208023;
    // lw   x3, 4(x1)        → x3 = SHARED[1]
    u_dut.imem0[35] = 32'h0040A183;
    // nop
    u_dut.imem0[36] = 32'h00000013;
    // jal  x0, -8           → loop về sw/lw (imem0[34])
    u_dut.imem0[37] = 32'hFF9FF06F;

    // ---- Core 1 Program @ imem1[32] (PC=0x0001_0080) ----
    // lui  x1, 0x20         → x1 = 0x0002_0000 (SHARED_BASE)
    u_dut.imem1[32] = 32'h000200B7;
    // lui  x2, 0xCAFE0      → x2 = 0xCAFE0000
    u_dut.imem1[33] = 32'hCAFE0137;
    // sw   x2, 4(x1)        → SHARED[1] = 0xCAFE0000
    u_dut.imem1[34] = 32'h002082A3;
    // lw   x3, 0(x1)        → x3 = SHARED[0]
    u_dut.imem1[35] = 32'h0000A183;
    // nop
    u_dut.imem1[36] = 32'h00000013;
    // jal  x0, -8           → loop về sw/lw (imem1[34])
    u_dut.imem1[37] = 32'hFF9FF06F;

    $display("============================================");
    $display("  Dual-Core Ibex Shared Memory Simulation");
    $display("============================================");
    $display("  Core 0 boot: 0x%08h", CORE0_BOOT);
    $display("  Core 1 boot: 0x%08h", CORE1_BOOT);
    $display("  Shared base: 0x%08h", SHARED_BASE);
    $display("--------------------------------------------");
    $display("  Core 0 → WRITE 0xDEAD0000 to SHARED[0]");
    $display("  Core 0 → READ  SHARED[1]");
    $display("  Core 1 → WRITE 0xCAFE0000 to SHARED[1]");
    $display("  Core 1 → READ  SHARED[0]");
    $display("============================================");
  end

  // ----------------------------------------------------------
  // Hierarchical references — Arbiter signals
  // ----------------------------------------------------------
  wire        arb_req      = u_dut.u_shared_mem.u_obi_arbiter.sram_req_o;
  wire        arb_we       = u_dut.u_shared_mem.u_obi_arbiter.sram_we_o;
  wire [31:0] arb_addr     = u_dut.u_shared_mem.u_obi_arbiter.sram_addr_o;
  wire [31:0] arb_wdata    = u_dut.u_shared_mem.u_obi_arbiter.sram_wdata_o;
  wire        arb_winner   = u_dut.u_shared_mem.u_obi_arbiter.winner;
  wire        arb_busy     = u_dut.u_shared_mem.u_obi_arbiter.busy_q;
  wire        arb_lastwin  = u_dut.u_shared_mem.u_obi_arbiter.last_winner_q;
  wire        c0_req       = u_dut.u_shared_mem.u_obi_arbiter.core0_req_i;
  wire        c1_req       = u_dut.u_shared_mem.u_obi_arbiter.core1_req_i;
  wire        c0_gnt       = u_dut.u_shared_mem.u_obi_arbiter.core0_gnt_o;
  wire        c1_gnt       = u_dut.u_shared_mem.u_obi_arbiter.core1_gnt_o;

  // ----------------------------------------------------------
  // Monitor: log mọi transaction lên Shared SRAM
  // ----------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n && arb_req) begin
      if (arb_we)
        $display("t=%0t ns | WRITE | Core%0d | 0x%08h ← 0x%08h",
                 $time/1000, arb_winner, arb_addr, arb_wdata);
      else
        $display("t=%0t ns | READ  | Core%0d | 0x%08h",
                 $time/1000, arb_winner, arb_addr);
    end
  end

  // Monitor: contention
  always @(posedge clk) begin
    if (rst_n && c0_req && c1_req && !arb_busy)
      $display("t=%0t ns | *** CONTENTION *** Core0 & Core1 → Winner=Core%0d",
               $time/1000, arb_winner);
  end

  // Monitor: pass/fail per transaction
  always @(posedge clk) begin
    if (rst_n) begin
      if (c0_gnt && arb_we && arb_addr == SHARED_BASE)
        $display("t=%0t ns | [PASS] Core0 wrote 0x%08h → SHARED[0]",
                 $time/1000, arb_wdata);
      if (c1_gnt && arb_we && arb_addr == SHARED_BASE + 4)
        $display("t=%0t ns | [PASS] Core1 wrote 0x%08h → SHARED[1]",
                 $time/1000, arb_wdata);
    end
  end

  // ----------------------------------------------------------
  // Kết thúc simulation và in kết quả
  // ----------------------------------------------------------
  initial begin
    #100_000; // 100 us

    $display("============================================");
    $display("  Shared SRAM Contents @ 100us:");
    $display("  SHARED[0] = 0x%08h  (Core 0 wrote)",
             u_dut.u_shared_mem.u_shared_sram.mem[0]);
    $display("  SHARED[1] = 0x%08h  (Core 1 wrote)",
             u_dut.u_shared_mem.u_shared_sram.mem[1]);
    $display("--------------------------------------------");

    if (u_dut.u_shared_mem.u_shared_sram.mem[0] == 32'hDEAD0000)
      $display("  [PASS] SHARED[0] = 0xDEAD0000 ✓");
    else
      $display("  [FAIL] SHARED[0] expected 0xDEAD0000, got 0x%08h",
               u_dut.u_shared_mem.u_shared_sram.mem[0]);

    if (u_dut.u_shared_mem.u_shared_sram.mem[1] == 32'hCAFE0000)
      $display("  [PASS] SHARED[1] = 0xCAFE0000 ✓");
    else
      $display("  [FAIL] SHARED[1] expected 0xCAFE0000, got 0x%08h",
               u_dut.u_shared_mem.u_shared_sram.mem[1]);

    $display("============================================");
    $finish;
  end

endmodule
