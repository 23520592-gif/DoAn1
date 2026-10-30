// ============================================================
// ibex_addr_decoder_tb.sv
//
// Testbench riêng cho ibex_addr_decoder
//
// Test cases:
//   TC1: Địa chỉ đúng trong SRAM range → slave_sel[0]=1
//   TC2: Địa chỉ đầu SRAM (boundary low)
//   TC3: Địa chỉ cuối SRAM (boundary high)
//   TC4: Địa chỉ ngoài range → decode_err=1
//   TC5: req=0 → không decode
//   TC6: Nhiều địa chỉ ngẫu nhiên trong range
// ============================================================

`timescale 1ns/1ps

module ibex_addr_decoder_tb;

  localparam logic [31:0] SRAM_BASE = 32'h0002_0000;
  localparam int unsigned SRAM_SIZE = 65536; // 64 KiB

  // ----------------------------------------------------------
  // DUT signals
  // ----------------------------------------------------------
  logic [31:0] addr;
  logic        req;
  logic [0:0]  slave_sel;
  logic        decode_err;

  // ----------------------------------------------------------
  // DUT
  // ----------------------------------------------------------
  ibex_addr_decoder #(
    .N_SLAVES  (1),
    .SRAM_BASE (SRAM_BASE),
    .SRAM_SIZE (SRAM_SIZE)
  ) u_dut (
    .addr_i       (addr),
    .req_i        (req),
    .slave_sel_o  (slave_sel),
    .decode_err_o (decode_err)
  );

  // ----------------------------------------------------------
  // Task: kiểm tra decode
  // ----------------------------------------------------------
  int pass_cnt, fail_cnt;

  task automatic check(
    input string   tc_name,
    input logic [31:0] a,
    input logic    r,
    input logic    exp_sel,
    input logic    exp_err
  );
    addr = a;
    req  = r;
    #1; // combinational, đợi settle
    if (slave_sel[0] === exp_sel && decode_err === exp_err) begin
      $display("[PASS] %s | addr=0x%08h req=%0b | sel=%0b err=%0b",
               tc_name, a, r, slave_sel[0], decode_err);
      pass_cnt++;
    end else begin
      $display("[FAIL] %s | addr=0x%08h req=%0b | got sel=%0b err=%0b | exp sel=%0b err=%0b",
               tc_name, a, r, slave_sel[0], decode_err, exp_sel, exp_err);
      fail_cnt++;
    end
  endtask

  // ----------------------------------------------------------
  // Test sequence
  // ----------------------------------------------------------
  initial begin
    pass_cnt = 0;
    fail_cnt = 0;
    addr = '0;
    req  = '0;
    #5;

    $display("============================================");
    $display("  Address Decoder Test");
    $display("  SRAM: 0x%08h - 0x%08h",
             SRAM_BASE, SRAM_BASE + SRAM_SIZE - 1);
    $display("============================================");

    // TC1: Địa chỉ giữa SRAM range
    check("TC1 mid-range  ", 32'h0002_1000, 1, 1, 0);

    // TC2: Boundary thấp (đúng địa chỉ base)
    check("TC2 bound-low  ", SRAM_BASE, 1, 1, 0);

    // TC3: Boundary cao (byte cuối cùng)
    check("TC3 bound-high ", SRAM_BASE + SRAM_SIZE - 4, 1, 1, 0);

    // TC4a: Ngoài range - dưới base
    check("TC4a below-base", 32'h0001_FFFC, 1, 0, 1);

    // TC4b: Ngoài range - trên top
    check("TC4b above-top ", SRAM_BASE + SRAM_SIZE, 1, 0, 1);

    // TC4c: Hoàn toàn ngoài
    check("TC4c far-out   ", 32'hFFFF_FFFF, 1, 0, 1);

    // TC5: req=0 → không decode gì cả
    check("TC5 req=0      ", SRAM_BASE, 0, 0, 0);

    // TC6: Nhiều địa chỉ ngẫu nhiên trong range
    for (int i = 0; i < 8; i++) begin
      automatic logic [31:0] rand_offset = $urandom_range(0, SRAM_SIZE/4 - 1) * 4;
      check($sformatf("TC6 random[%0d] ", i),
            SRAM_BASE + rand_offset, 1, 1, 0);
    end

    $display("============================================");
    $display("  PASS: %0d / FAIL: %0d", pass_cnt, fail_cnt);
    if (fail_cnt == 0)
      $display("  *** ALL TESTS PASSED ***");
    else
      $display("  *** %0d TESTS FAILED ***", fail_cnt);
    $display("============================================");
    $finish;
  end

endmodule
