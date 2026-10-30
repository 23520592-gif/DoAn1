// ============================================================
// ibex_shared_bus_tb.sv
//
// Testbench: Dual-Core Ibex với Shared Bus
//
// Kịch bản test:
//   1. Core 0 ghi 0xDEAD0000 vào SHARED[0x0002_0000]
//   2. Core 1 ghi 0xCAFE0000 vào SHARED[0x0002_0004]
//   3. Cả 2 core đọc lại giá trị của nhau (verify shared)
//   4. In Performance Report từ Bus Monitor
//
// Performance Report bao gồm:
//   - Tổng số transaction
//   - Số lần contention
//   - Bus utilization (%)
//   - Stall cycles
//   - Per-core transaction count
// ============================================================

`timescale 1ns/1ps

module ibex_shared_bus_tb;

  // ----------------------------------------------------------
  // Parameters
  // ----------------------------------------------------------
  localparam int unsigned IMEM0_SIZE  = 16384;
  localparam int unsigned IMEM1_SIZE  = 16384;
  localparam int unsigned DMEM_SIZE   = 65536;
  localparam logic [31:0] CORE0_BOOT  = 32'h0000_0000;
  localparam logic [31:0] CORE1_BOOT  = 32'h0001_0000;
  localparam logic [31:0] SHARED_BASE = 32'h0002_0000;
  localparam logic [3:0]  MUBI4_TRUE  = 4'b0101;

  // Thời gian chạy simulation
  localparam int unsigned SIM_TIME_NS = 500_000; // 500us

  // ----------------------------------------------------------
  // Clock & Reset
  // ----------------------------------------------------------
  logic clk;
  logic rst_n;

  initial clk = 0;
  always #10 clk = ~clk; // 50 MHz

  // Hiển thị %0t theo đơn vị ns (timescale 1ns/1ps), 0 chữ số thập phân
  initial $timeformat(-9, 0, " ns", 0);

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

  // Performance monitor outputs
  logic [31:0] mon_total_cycles;
  logic [31:0] mon_total_txn;
  logic [31:0] mon_write_txn;
  logic [31:0] mon_read_txn;
  logic [31:0] mon_contention_cycles;
  logic [31:0] mon_stall_cycles;
  logic [31:0] mon_bus_active_cycles;
  logic [1:0][31:0] mon_master_txn;

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
  // DUT: ibex_dualcore_top_v2
  // ----------------------------------------------------------
  ibex_dualcore_top_v2 #(
    .IMem0SizeBytes (IMEM0_SIZE),
    .IMem1SizeBytes (IMEM1_SIZE),
    .DMSizeBytes    (DMEM_SIZE),
    .Core0BootAddr  (CORE0_BOOT),
    .Core1BootAddr  (CORE1_BOOT),
    .SharedBase     (SHARED_BASE),
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
    .core1_core_sleep_o           (core1_core_sleep),
    .mon_total_cycles_o           (mon_total_cycles),
    .mon_total_txn_o              (mon_total_txn),
    .mon_write_txn_o              (mon_write_txn),
    .mon_read_txn_o               (mon_read_txn),
    .mon_contention_cycles_o      (mon_contention_cycles),
    .mon_stall_cycles_o           (mon_stall_cycles),
    .mon_bus_active_cycles_o      (mon_bus_active_cycles),
    .mon_master_txn_o             (mon_master_txn)
  );

  // ----------------------------------------------------------
  // Load Programs vào IMEM
  // ----------------------------------------------------------
  initial begin
    @(posedge rst_n);
    @(posedge clk);

    // NOP toàn bộ IMEM
    for (int i = 0; i < IMEM0_SIZE/4; i++) u_dut.imem0[i] = 32'h00000013;
    for (int i = 0; i < IMEM1_SIZE/4; i++) u_dut.imem1[i] = 32'h00000013;

    // ---- Core 0 @ imem0[32] (PC = 0x0000_0080) ----
    // lui  x1, 0x20         → x1 = 0x0002_0000
    u_dut.imem0[32] = 32'h000200B7;
    // lui  x2, 0xDEAD0      → x2 = 0xDEAD0000
    u_dut.imem0[33] = 32'hDEAD0137;
    // sw   x2, 0(x1)        → SHARED[0] = 0xDEAD0000
    u_dut.imem0[34] = 32'h0020A023;
    // lw   x3, 4(x1)        → x3 = SHARED[4] (Core1 wrote)
    u_dut.imem0[35] = 32'h0040A183;
    // addi x4, x0, 0xAA     → x4 = 0xAA (sentinel Core0 đã xong)
    u_dut.imem0[36] = 32'h0AA00213;
    // sw   x4, 8(x1)        → SHARED[8] = 0xAA (flag Core0 done)
    u_dut.imem0[37] = 32'h0040A423;
    // nop
    u_dut.imem0[38] = 32'h00000013;
    // jal  x0, -16          → loop về lw (imem0[35])
    u_dut.imem0[39] = 32'hFF1FF06F;

    // ---- Core 1 @ imem1[32] (PC = 0x0001_0080) ----
    // lui  x1, 0x20         → x1 = 0x0002_0000
    u_dut.imem1[32] = 32'h000200B7;
    // lui  x2, 0xCAFE0      → x2 = 0xCAFE0000
    u_dut.imem1[33] = 32'hCAFE0137;
    // sw   x2, 4(x1)        → SHARED[4] = 0xCAFE0000
    u_dut.imem1[34] = 32'h0020A223;
    // lw   x3, 0(x1)        → x3 = SHARED[0] (Core0 wrote)
    u_dut.imem1[35] = 32'h0000A183;
    // addi x4, x0, 0xBB     → x4 = 0xBB (sentinel Core1 đã xong)
    u_dut.imem1[36] = 32'h0BB00213;
    // sw   x4, 12(x1)       → SHARED[12] = 0xBB (flag Core1 done)
    u_dut.imem1[37] = 32'h0040A623;
    // nop
    u_dut.imem1[38] = 32'h00000013;
    // jal  x0, -16          → loop về lw (imem1[35])
    u_dut.imem1[39] = 32'hFF1FF06F;

    $display("=================================================");
    $display("  Dual-Core Ibex SHARED BUS Simulation");
    $display("=================================================");
    $display("  N_MASTERS = 2 (expandable)");
    $display("  Arbiter   = Round-Robin");
    $display("  Monitor   = Bus Performance Counter");
    $display("-------------------------------------------------");
    $display("  Core 0: WRITE 0xDEAD0000 -> SHARED[0x%08h]",
             SHARED_BASE);
    $display("  Core 0: READ  SHARED[0x%08h]", SHARED_BASE + 4);
    $display("  Core 1: WRITE 0xCAFE0000 -> SHARED[0x%08h]",
             SHARED_BASE + 4);
    $display("  Core 1: READ  SHARED[0x%08h]", SHARED_BASE);
    $display("=================================================");
  end

  // ----------------------------------------------------------
  // Hierarchical references — Bus Arbiter signals
  // ----------------------------------------------------------
  wire [1:0]  arb_req    = u_dut.u_shared_bus.u_arbiter.req_i;
  wire [1:0]  arb_gnt    = u_dut.u_shared_bus.u_arbiter.gnt_o;
  wire        arb_sreq   = u_dut.u_shared_bus.u_arbiter.sram_req_o;
  wire        arb_swe    = u_dut.u_shared_bus.u_arbiter.sram_we_o;
  wire [31:0] arb_saddr  = u_dut.u_shared_bus.u_arbiter.sram_addr_o;
  wire [31:0] arb_swdat  = u_dut.u_shared_bus.u_arbiter.sram_wdata_o;
  wire        arb_busy   = u_dut.u_shared_bus.u_arbiter.busy_q;
  wire        arb_rvalid = u_dut.u_shared_bus.u_arbiter.sram_rvalid_i;
  wire [$clog2(2)-1:0] arb_winner = u_dut.u_shared_bus.u_arbiter.winner_idx;
  wire [$clog2(2)-1:0] arb_rr_ptr = u_dut.u_shared_bus.u_arbiter.rr_ptr_q;

  // ----------------------------------------------------------
  // Monitor: log mọi SRAM transaction
  // ----------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n && arb_sreq) begin
      if (arb_swe)
        $display("t=%0t | WRITE | Core%0d | 0x%08h <- 0x%08h | rr_ptr=%0d",
                 $realtime, arb_winner, arb_saddr, arb_swdat, arb_rr_ptr);
      else
        $display("t=%0t | READ  | Core%0d | 0x%08h           | rr_ptr=%0d",
                 $realtime, arb_winner, arb_saddr, arb_rr_ptr);
    end
  end

  // Monitor: contention
  always @(posedge clk) begin
    if (rst_n && ($countones(arb_req) >= 2) && !arb_busy)
      $display("t=%0t | *** CONTENTION *** req=%02b -> Winner=Core%0d | rr_ptr=%0d",
               $realtime, arb_req, arb_winner, arb_rr_ptr);
  end

  // Monitor: pass/fail
  always @(posedge clk) begin
    if (rst_n) begin
      if (arb_gnt[0] && arb_swe && arb_saddr == SHARED_BASE)
        $display("t=%0t | [PASS] Core0 wrote 0x%08h -> SHARED[0]",
                 $realtime, arb_swdat);
      if (arb_gnt[1] && arb_swe && arb_saddr == SHARED_BASE + 4)
        $display("t=%0t | [PASS] Core1 wrote 0x%08h -> SHARED[1]",
                 $realtime, arb_swdat);
    end
  end

  // ----------------------------------------------------------
  // Kết thúc simulation — in Performance Report
  // ----------------------------------------------------------
  initial begin
    #(SIM_TIME_NS);

    // Kiểm tra SRAM contents
    $display("");
    $display("=================================================");
    $display("  SHARED SRAM Contents:");
    $display("  [0x0002_0000] = 0x%08h  (Core0 wrote)",
             u_dut.u_shared_bus.u_shared_sram.mem[0]);
    $display("  [0x0002_0004] = 0x%08h  (Core1 wrote)",
             u_dut.u_shared_bus.u_shared_sram.mem[1]);
    $display("  [0x0002_0008] = 0x%08h  (Core0 done flag)",
             u_dut.u_shared_bus.u_shared_sram.mem[2]);
    $display("  [0x0002_000C] = 0x%08h  (Core1 done flag)",
             u_dut.u_shared_bus.u_shared_sram.mem[3]);
    $display("-------------------------------------------------");

    // Pass/Fail
    if (u_dut.u_shared_bus.u_shared_sram.mem[0] == 32'hDEAD0000)
      $display("  [PASS] SHARED[0] = 0xDEAD0000 (Core0) OK");
    else
      $display("  [FAIL] SHARED[0] = 0x%08h expected 0xDEAD0000",
               u_dut.u_shared_bus.u_shared_sram.mem[0]);

    if (u_dut.u_shared_bus.u_shared_sram.mem[1] == 32'hCAFE0000)
      $display("  [PASS] SHARED[1] = 0xCAFE0000 (Core1) OK");
    else
      $display("  [FAIL] SHARED[1] = 0x%08h expected 0xCAFE0000",
               u_dut.u_shared_bus.u_shared_sram.mem[1]);

    // ----------------------------------------------------------
    // Performance Report từ Bus Monitor
    // ----------------------------------------------------------
    $display("=================================================");
    $display("  BUS PERFORMANCE REPORT");
    $display("=================================================");
    $display("  Total cycles        : %0d", mon_total_cycles);
    $display("  Total transactions  : %0d", mon_total_txn);
    $display("  - Write transactions: %0d", mon_write_txn);
    $display("  - Read  transactions: %0d", mon_read_txn);
    $display("-------------------------------------------------");
    $display("  Contention cycles   : %0d", mon_contention_cycles);
    $display("  Stall cycles        : %0d", mon_stall_cycles);
    $display("  Bus active cycles   : %0d", mon_bus_active_cycles);
    $display("-------------------------------------------------");
    $display("  Bus utilization     : %0d%%",
             mon_total_cycles > 0 ?
             (mon_bus_active_cycles * 100 / mon_total_cycles) : 0);
    $display("  Contention rate     : %0d%%",
             mon_total_cycles > 0 ?
             (mon_contention_cycles * 100 / mon_total_cycles) : 0);
    $display("-------------------------------------------------");
    $display("  Per-Core Transactions:");
    $display("  Core 0 granted      : %0d times", mon_master_txn[0]);
    $display("  Core 1 granted      : %0d times", mon_master_txn[1]);
    $display("  Fairness ratio      : %0d:%0d",
             mon_master_txn[0], mon_master_txn[1]);
    $display("=================================================");
    $finish;
  end

endmodule
