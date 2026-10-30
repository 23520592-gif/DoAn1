// ============================================================
// Testbench đơn giản cho Ibex CPU Core (ibex_top)
// Chỉ dùng để quan sát waveform trên Vivado xsim
// Không cần FuseSoC hay firmware thật
// ============================================================

`timescale 1ns/1ps

module ibex_top_tb;

  // ----------------------------------------------------------
  // Clock & Reset
  // ----------------------------------------------------------
  logic clk;
  logic rst_n;

  // Clock 50MHz (chu kỳ 20ns)
  initial clk = 0;
  always #10 clk = ~clk;

  // Reset: giữ low 100ns rồi release
  initial begin
    rst_n = 0;
    #100;
    rst_n = 1;
  end

  // ----------------------------------------------------------
  // Instruction Memory (ROM đơn giản 1KB)
  // Chứa vòng lặp NOP để CPU fetch liên tục
  // ----------------------------------------------------------
  // NOP = 32'h00000013 (ADDI x0, x0, 0)
  // JAL  = 32'h0000006F (nhảy về địa chỉ 0, tạo vòng lặp vô hạn)
  logic [31:0] instr_mem [0:255];

  initial begin
    // Điền NOP vào toàn bộ memory
    for (int i = 0; i < 256; i++) begin
      instr_mem[i] = 32'h00000013; // NOP
    end
    // Dòng cuối: JAL x0, 0 (nhảy về 0x000)
    instr_mem[10] = 32'hFE1FF06F; // JAL x0, -0x20 (nhảy về đầu)
  end

  // ----------------------------------------------------------
  // Signals kết nối với ibex_top
  // ----------------------------------------------------------

  // Instruction fetch interface
  logic        instr_req;
  logic        instr_gnt;
  logic        instr_rvalid;
  logic [31:0] instr_addr;
  logic [31:0] instr_rdata;
  logic  [6:0] instr_rdata_intg;
  logic        instr_err;

  // Data memory interface
  logic        data_req;
  logic        data_gnt;
  logic        data_rvalid;
  logic        data_we;
  logic  [3:0] data_be;
  logic [31:0] data_addr;
  logic [31:0] data_wdata;
  logic  [6:0] data_wdata_intg;
  logic [31:0] data_rdata;
  logic  [6:0] data_rdata_intg;
  logic        data_err;

  // IRQ
  logic        irq_software;
  logic        irq_timer;
  logic        irq_external;
  logic [14:0] irq_fast;
  logic        irq_nm;

  // Debug
  logic        debug_req;
  logic        fetch_enable;

  // Alert
  logic        alert_minor;
  logic        alert_major_internal;
  logic        alert_major_bus;

  // Core sleep
  logic        core_sleep;

  // Scan
  logic        scan_rst_n;

  // ----------------------------------------------------------
  // Instruction Memory Model
  // Grant ngay lập tức, valid sau 1 cycle
  // ----------------------------------------------------------
  assign instr_gnt    = instr_req;
  assign instr_err    = 1'b0;
  assign instr_rdata_intg = 7'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      instr_rvalid <= 0;
      instr_rdata  <= 32'h00000013; // NOP
    end else begin
      instr_rvalid <= instr_req;
      if (instr_req) begin
        // Đọc từ instruction memory (word-aligned)
        instr_rdata <= instr_mem[instr_addr[9:2]];
      end
    end
  end

  // ----------------------------------------------------------
  // Data Memory Model (đơn giản, 256 words)
  // ----------------------------------------------------------
  logic [31:0] data_mem [0:255];

  assign data_gnt          = data_req;
  assign data_err          = 1'b0;
  assign data_rdata_intg   = 7'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_rvalid <= 0;
      data_rdata  <= 32'h0;
    end else begin
      data_rvalid <= data_req;
      if (data_req) begin
        if (data_we) begin
          // Write
          if (data_be[0]) data_mem[data_addr[9:2]][ 7: 0] <= data_wdata[ 7: 0];
          if (data_be[1]) data_mem[data_addr[9:2]][15: 8] <= data_wdata[15: 8];
          if (data_be[2]) data_mem[data_addr[9:2]][23:16] <= data_wdata[23:16];
          if (data_be[3]) data_mem[data_addr[9:2]][31:24] <= data_wdata[31:24];
        end else begin
          // Read
          data_rdata <= data_mem[data_addr[9:2]];
        end
      end
    end
  end

  // ----------------------------------------------------------
  // Kết nối các tín hiệu còn lại
  // ----------------------------------------------------------
  assign irq_software  = 1'b0;
  assign irq_timer     = 1'b0;
  assign irq_external  = 1'b0;
  assign irq_fast      = 15'b0;
  assign irq_nm        = 1'b0;
  assign debug_req     = 1'b0;
  assign fetch_enable  = 1'b1; // Cho phép CPU fetch ngay
  assign scan_rst_n    = 1'b1;
  assign data_wdata_intg = 7'b0;

  // ----------------------------------------------------------
  // Instantiate ibex_top (DUT)
  // ----------------------------------------------------------
  ibex_top #(
    .PMPEnable        (1'b0),
    .PMPGranularity   (0),
    .PMPNumRegions    (4),
    .MHPMCounterNum   (0),
    .MHPMCounterWidth (40),
    .RV32E            (1'b0),
    .RV32M            (ibex_pkg::RV32MFast),
    .RV32B            (ibex_pkg::RV32BNone),
    .RegFile          (ibex_pkg::RegFileFF),
    .BranchTargetALU  (1'b0),
    .WritebackStage   (1'b0),
    .ICache           (1'b0),
    .ICacheECC        (1'b0),
    .BranchPredictor  (1'b0),
    .DbgTriggerEn     (1'b0),
    .DmHaltAddr       (32'h1A110800),
    .DmExceptionAddr  (32'h1A110808)
  ) u_ibex_top (
    .clk_i                  (clk),
    .rst_ni                 (rst_n),

    .test_en_i              (1'b0),
    .scan_rst_ni            (scan_rst_n),
    .ram_cfg_i              ('0),

    .hart_id_i              (32'b0),
    .boot_addr_i            (32'h00000000),

    // Instruction memory interface
    .instr_req_o            (instr_req),
    .instr_gnt_i            (instr_gnt),
    .instr_rvalid_i         (instr_rvalid),
    .instr_addr_o           (instr_addr),
    .instr_rdata_i          (instr_rdata),
    .instr_rdata_intg_i     (instr_rdata_intg),
    .instr_err_i            (instr_err),

    // Data memory interface
    .data_req_o             (data_req),
    .data_gnt_i             (data_gnt),
    .data_rvalid_i          (data_rvalid),
    .data_we_o              (data_we),
    .data_be_o              (data_be),
    .data_addr_o            (data_addr),
    .data_wdata_o           (data_wdata),
    .data_wdata_intg_o      (data_wdata_intg),
    .data_rdata_i           (data_rdata),
    .data_rdata_intg_i      (data_rdata_intg),
    .data_err_i             (data_err),

    // IRQ
    .irq_software_i         (irq_software),
    .irq_timer_i            (irq_timer),
    .irq_external_i         (irq_external),
    .irq_fast_i             (irq_fast),
    .irq_nm_i               (irq_nm),

    // Debug
    .debug_req_i            (debug_req),

    // Crash dump (không dùng)
    .crash_dump_o           (),

    // Alert
    .alert_minor_o          (alert_minor),
    .alert_major_internal_o (alert_major_internal),
    .alert_major_bus_o      (alert_major_bus),

    // Fetch enable
    .fetch_enable_i         (fetch_enable),
    .core_sleep_o           (core_sleep)
  );

  // ----------------------------------------------------------
  // Simulation control
  // ----------------------------------------------------------
  initial begin
    $display("=== Ibex CPU Simulation Start ===");
    $display("Clock: 50MHz, Reset released at 100ns");
    $display("Program: NOP loop (infinite)");
    
    // Chạy 10000ns rồi dừng
    #10000;
    $display("=== Simulation done at %0t ===", $time);
    $finish;
  end

  // Monitor: in ra mỗi khi CPU fetch instruction
  always @(posedge clk) begin
    if (instr_rvalid && rst_n) begin
      $display("t=%0t | PC=0x%08h | INSTR=0x%08h",
               $time, instr_addr, instr_rdata);
    end
  end

endmodule
