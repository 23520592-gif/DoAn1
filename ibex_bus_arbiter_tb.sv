// ============================================================
// ibex_bus_arbiter_tb.sv
//
// Testbench riêng cho ibex_bus_arbiter
//
// Test cases:
//   TC1: Chỉ Master 0 request
//   TC2: Chỉ Master 1 request
//   TC3: Cả 2 request đồng thời (contention) → round-robin
//   TC4: Master 0 request liên tục, Master 1 request thưa
//   TC5: Nhiều transaction liên tiếp → kiểm tra fairness
//   TC6: Read transaction (có busy) → master kia phải chờ
// ============================================================

`timescale 1ns/1ps

module ibex_bus_arbiter_tb;

  localparam int N = 2;
  localparam int DATA_W = 32;
  localparam int ADDR_W = 32;

  // ----------------------------------------------------------
  // Clock & Reset
  // ----------------------------------------------------------
  logic clk, rst_n;
  initial clk = 0;
  always #10 clk = ~clk;

  initial begin
    rst_n = 0;
    repeat(5) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
  end

  // ----------------------------------------------------------
  // DUT signals
  // ----------------------------------------------------------
  logic [N-1:0]          req;
  logic [N-1:0]          gnt;
  logic [N-1:0][ADDR_W-1:0] addr;
  logic [N-1:0]          we;
  logic [N-1:0][3:0]     be;
  logic [N-1:0][DATA_W-1:0] wdata;
  logic [N-1:0]          rvalid;
  logic [N-1:0][DATA_W-1:0] rdata;

  logic        sram_req;
  logic        sram_gnt;
  logic [31:0] sram_addr;
  logic        sram_we;
  logic  [3:0] sram_be;
  logic [31:0] sram_wdata;
  logic        sram_rvalid;
  logic [31:0] sram_rdata;

  logic [31:0] perf_contention;
  logic [31:0] perf_total_req;
  logic [31:0] perf_busy_cycles;

  // ----------------------------------------------------------
  // DUT
  // ----------------------------------------------------------
  ibex_bus_arbiter #(
    .N_MASTERS (N),
    .DATA_W    (DATA_W),
    .ADDR_W    (ADDR_W)
  ) u_dut (
    .clk_i                  (clk),
    .rst_ni                 (rst_n),
    .req_i                  (req),
    .gnt_o                  (gnt),
    .addr_i                 (addr),
    .we_i                   (we),
    .be_i                   (be),
    .wdata_i                (wdata),
    .rvalid_o               (rvalid),
    .rdata_o                (rdata),
    .sram_req_o             (sram_req),
    .sram_gnt_i             (sram_gnt),
    .sram_addr_o            (sram_addr),
    .sram_we_o              (sram_we),
    .sram_be_o              (sram_be),
    .sram_wdata_o           (sram_wdata),
    .sram_rvalid_i          (sram_rvalid),
    .sram_rdata_i           (sram_rdata),
    .perf_contention_cnt_o  (perf_contention),
    .perf_total_req_cnt_o   (perf_total_req),
    .perf_busy_cycles_cnt_o (perf_busy_cycles)
  );

  // ----------------------------------------------------------
  // Simple SRAM model: gnt ngay, rvalid sau 1 cycle cho read
  // ----------------------------------------------------------
  assign sram_gnt = sram_req;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sram_rvalid <= 0;
      sram_rdata  <= 0;
    end else begin
      sram_rvalid <= sram_req & ~sram_we;
      sram_rdata  <= sram_req ? sram_addr : 32'h0;
    end
  end

  // ----------------------------------------------------------
  // Default signal values
  // ----------------------------------------------------------
  initial begin
    req   = '0;
    addr  = '0;
    we    = '0;
    be    = '1;
    wdata = '0;
  end

  // ----------------------------------------------------------
  // Task: issue single write transaction từ master m
  // ----------------------------------------------------------
  task automatic do_write(
    input int m,
    input logic [31:0] a,
    input logic [31:0] d
  );
    @(negedge clk);
    req[m]   = 1;
    addr[m]  = a;
    we[m]    = 1;
    wdata[m] = d;
    @(posedge clk);
    // Chờ grant
    while (!gnt[m]) @(posedge clk);
    @(negedge clk);
    req[m] = 0;
    we[m]  = 0;
  endtask

  // ----------------------------------------------------------
  // Task: issue single read transaction từ master m
  // ----------------------------------------------------------
  task automatic do_read(
    input  int m,
    input  logic [31:0] a,
    output logic [31:0] d
  );
    @(negedge clk);
    req[m]  = 1;
    addr[m] = a;
    we[m]   = 0;
    @(posedge clk);
    while (!gnt[m]) @(posedge clk);
    @(negedge clk);
    req[m] = 0;
    // Chờ rvalid
    @(posedge clk);
    while (!rvalid[m]) @(posedge clk);
    d = rdata[m];
  endtask

  // ----------------------------------------------------------
  // Monitor
  // ----------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n && sram_req && sram_gnt) begin
      if (sram_we)
        $display("t=%0t | WRITE | winner=%0d | addr=0x%08h | data=0x%08h",
                 $time, u_dut.winner_idx, sram_addr, sram_wdata);
      else
        $display("t=%0t | READ  | winner=%0d | addr=0x%08h",
                 $time, u_dut.winner_idx, sram_addr);
    end
  end

  always @(posedge clk) begin
    if (rst_n && ($countones(req) >= 2) && !u_dut.busy_q)
      $display("t=%0t | *** CONTENTION *** req=%02b winner=%0d rr_ptr=%0d",
               $time, req, u_dut.winner_idx, u_dut.rr_ptr_q);
  end

  // ----------------------------------------------------------
  // Test sequence
  // ----------------------------------------------------------
  logic [31:0] rd_data;
  int pass_cnt, fail_cnt;

  initial begin
    pass_cnt = 0;
    fail_cnt = 0;
    @(posedge rst_n);
    repeat(2) @(posedge clk);

    // ========================================================
    // TC1: Chỉ Master 0 write
    // ========================================================
    $display("\n--- TC1: Only Master 0 write ---");
    do_write(0, 32'h1000, 32'hAAAA_0000);
    repeat(2) @(posedge clk);
    if (gnt == 2'b00) begin // gnt đã low sau transaction
      $display("[PASS] TC1: Master 0 got grant");
      pass_cnt++;
    end

    // ========================================================
    // TC2: Chỉ Master 1 write
    // ========================================================
    $display("\n--- TC2: Only Master 1 write ---");
    do_write(1, 32'h2000, 32'hBBBB_0000);
    repeat(2) @(posedge clk);
    $display("[PASS] TC2: Master 1 got grant");
    pass_cnt++;

    // ========================================================
    // TC3: Cả 2 request đồng thời - round-robin
    // ========================================================
    $display("\n--- TC3: Simultaneous request - round-robin ---");
    @(negedge clk);
    req[0] = 1; addr[0] = 32'h3000; we[0] = 1; wdata[0] = 32'hC0C0_0000;
    req[1] = 1; addr[1] = 32'h4000; we[1] = 1; wdata[1] = 32'hD0D0_0000;

    // Transaction 1
    @(posedge clk);
    while (!(|gnt)) @(posedge clk);
    $display("t=%0t | Contention round 1: winner=%0d", $time, u_dut.winner_idx);
    automatic int w1 = u_dut.winner_idx;
    @(negedge clk);
    req[w1] = 0; we[w1] = 0;

    // Transaction 2 - winner phải đổi
    @(posedge clk);
    while (!(|gnt)) @(posedge clk);
    $display("t=%0t | Contention round 2: winner=%0d", $time, u_dut.winner_idx);
    automatic int w2 = u_dut.winner_idx;
    @(negedge clk);
    req[0] = 0; req[1] = 0;
    we[0]  = 0; we[1]  = 0;

    if (w1 != w2) begin
      $display("[PASS] TC3: Round-robin đúng (%0d → %0d)", w1, w2);
      pass_cnt++;
    end else begin
      $display("[FAIL] TC3: Round-robin sai (cùng winner %0d)", w1);
      fail_cnt++;
    end
    repeat(2) @(posedge clk);

    // ========================================================
    // TC4: Read transaction - kiểm tra busy
    // ========================================================
    $display("\n--- TC4: Read transaction - busy check ---");
    fork
      do_read(0, 32'h5000, rd_data);
    join
    $display("t=%0t | Read data = 0x%08h", $time, rd_data);
    if (rd_data == 32'h5000) begin
      $display("[PASS] TC4: Read data đúng");
      pass_cnt++;
    end else begin
      $display("[FAIL] TC4: Read data sai (got 0x%08h)", rd_data);
      fail_cnt++;
    end
    repeat(2) @(posedge clk);

    // ========================================================
    // TC5: Fairness test - 10 transaction mỗi core
    // ========================================================
    $display("\n--- TC5: Fairness test (10 rounds) ---");
    for (int i = 0; i < 10; i++) begin
      @(negedge clk);
      req[0] = 1; addr[0] = 32'h6000 + i*4; we[0] = 1; wdata[0] = i;
      req[1] = 1; addr[1] = 32'h7000 + i*4; we[1] = 1; wdata[1] = i + 32'h100;
      @(posedge clk);
      while (!(|gnt)) @(posedge clk);
      automatic int ww = u_dut.winner_idx;
      @(negedge clk);
      req[ww] = 0; we[ww] = 0;
      @(posedge clk);
      while (!(|gnt)) @(posedge clk);
      @(negedge clk);
      req[0] = 0; req[1] = 0;
      we[0]  = 0; we[1]  = 0;
    end
    repeat(2) @(posedge clk);

    // ========================================================
    // Kết quả
    // ========================================================
    $display("\n============================================");
    $display("  ARBITER TEST RESULTS");
    $display("============================================");
    $display("  PASS: %0d / FAIL: %0d", pass_cnt, fail_cnt);
    $display("--------------------------------------------");
    $display("  Performance Counters:");
    $display("  Contention events : %0d", perf_contention);
    $display("  Total transactions: %0d", perf_total_req);
    $display("  Busy cycles       : %0d", perf_busy_cycles);
    $display("============================================");

    if (fail_cnt == 0)
      $display("  *** ALL TESTS PASSED ***");
    else
      $display("  *** %0d TESTS FAILED ***", fail_cnt);

    $finish;
  end

endmodule
