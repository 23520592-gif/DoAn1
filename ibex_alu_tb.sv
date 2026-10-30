// ============================================================
// Testbench test ALU của Ibex CPU
// Chạy các lệnh RISC-V thực tế để test từng phép tính ALU
// Quan sát: operand_a, operand_b, result, PC, instr
// ============================================================

`timescale 1ns/1ps

module ibex_top_tb;

  // ----------------------------------------------------------
  // Clock & Reset
  // ----------------------------------------------------------
  logic clk;
  logic rst_n;

  initial clk = 0;
  always #10 clk = ~clk;

  initial begin
    rst_n = 0;
    #100;
    rst_n = 1;
  end

  // ----------------------------------------------------------
  // Instruction Memory
  // Chứa chương trình RISC-V test ALU
  //
  // Thanh ghi sử dụng:
  //   x1 = 10  (0x0000000A)
  //   x2 = 20  (0x00000014)
  //   x3 = kết quả phép tính
  //
  // Danh sách lệnh:
  //   addi x1, x0, 10      → x1 = 10
  //   addi x2, x0, 20      → x2 = 20
  //   add  x3, x1, x2      → x3 = 30  (ADD)
  //   sub  x3, x2, x1      → x3 = 10  (SUB)
  //   and  x3, x1, x2      → x3 = 0   (AND: 01010 & 10100)
  //   or   x3, x1, x2      → x3 = 30  (OR:  01010 | 10100)
  //   xor  x3, x1, x2      → x3 = 30  (XOR: 01010 ^ 10100)
  //   sll  x3, x1, x2      → x3 = x1 << (x2&0x1F) = 10<<20
  //   srl  x3, x2, x1      → x3 = x2 >> (x1&0x1F) = 20>>10
  //   slt  x3, x1, x2      → x3 = 1   (10 < 20)
  //   sltu x3, x2, x1      → x3 = 0   (20 >= 10 unsigned)
  //   lui  x3, 0xABCDE     → x3 = 0xABCDE000
  //   addi x3, x3, 0x123   → x3 = 0xABCDE123 (test immediate)
  //   jal  x0, 0           → nhảy về 0 (loop)
  // ----------------------------------------------------------

  logic [31:0] instr_mem [0:255];

  initial begin
    // Khởi tạo tất cả = NOP
    for (int i = 0; i < 256; i++)
      instr_mem[i] = 32'h00000013;

    // ---- Test Program ----
    // addi x1, x0, 10   → x1 = 10
    // Đặt program bắt đầu từ 0x80 (index 32)
instr_mem[32] = 32'h00A00093; // addi x1, x0, 10
instr_mem[33] = 32'h01400113; // addi x2, x0, 20
instr_mem[34] = 32'h002081B3; // add  x3, x1, x2
instr_mem[35] = 32'h401101B3; // sub  x3, x2, x1
instr_mem[36] = 32'h0020F1B3; // and  x3, x1, x2
instr_mem[37] = 32'h0020E1B3; // or   x3, x1, x2
instr_mem[38] = 32'h0020C1B3; // xor  x3, x1, x2
instr_mem[39] = 32'h002091B3; // sll  x3, x1, x2
instr_mem[40] = 32'h001151B3; // srl  x3, x2, x1
instr_mem[41] = 32'h0020A1B3; // slt  x3, x1, x2
instr_mem[42] = 32'h001131B3; // sltu x3, x2, x1
instr_mem[43] = 32'hABCDE1B7; // lui  x3, 0xABCDE
instr_mem[44] = 32'h12318193; // addi x3, x3, 0x123
instr_mem[45] = 32'h00000013; // nop
instr_mem[46] = 32'h00000013; // nop
instr_mem[47] = 32'hFC1FF06F; // jal x0, -60 (loop về 32)
  end

  // ----------------------------------------------------------
  // Signals
  // ----------------------------------------------------------
  logic        instr_req;
  logic        instr_gnt;
  logic        instr_rvalid;
  logic [31:0] instr_addr;
  logic [31:0] instr_rdata;
  logic  [6:0] instr_rdata_intg;
  logic        instr_err;

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

  logic        irq_software, irq_timer, irq_external;
  logic [14:0] irq_fast;
  logic        irq_nm, debug_req;
  logic        fetch_enable;
  logic        alert_minor, alert_major_internal, alert_major_bus;
  logic        core_sleep;
  logic        scan_rst_n;

  // ----------------------------------------------------------
  // Instruction Memory Model
  // ----------------------------------------------------------
  assign instr_gnt        = instr_req;
  assign instr_err        = 1'b0;
  assign instr_rdata_intg = 7'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      instr_rvalid <= 0;
      instr_rdata  <= 32'h00000013;
    end else begin
      instr_rvalid <= instr_req;
      if (instr_req)
        instr_rdata <= instr_mem[instr_addr[9:2]];
    end
  end

  // ----------------------------------------------------------
  // Data Memory Model
  // ----------------------------------------------------------
  logic [31:0] data_mem [0:255];

  assign data_gnt        = data_req;
  assign data_err        = 1'b0;
  assign data_rdata_intg = 7'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_rvalid <= 0;
      data_rdata  <= 32'h0;
    end else begin
      data_rvalid <= data_req;
      if (data_req) begin
        if (data_we) begin
          if (data_be[0]) data_mem[data_addr[9:2]][ 7: 0] <= data_wdata[ 7: 0];
          if (data_be[1]) data_mem[data_addr[9:2]][15: 8] <= data_wdata[15: 8];
          if (data_be[2]) data_mem[data_addr[9:2]][23:16] <= data_wdata[23:16];
          if (data_be[3]) data_mem[data_addr[9:2]][31:24] <= data_wdata[31:24];
        end else
          data_rdata <= data_mem[data_addr[9:2]];
      end
    end
  end

  // ----------------------------------------------------------
  // Static assignments
  // ----------------------------------------------------------
  assign irq_software  = 1'b0;
  assign irq_timer     = 1'b0;
  assign irq_external  = 1'b0;
  assign irq_fast      = 15'b0;
  assign irq_nm        = 1'b0;
  assign debug_req     = 1'b0;
  assign fetch_enable  = 1'b1;
  assign scan_rst_n    = 1'b1;
  assign data_wdata_intg = 7'b0;

  // ----------------------------------------------------------
  // DUT: ibex_top
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
    .instr_req_o            (instr_req),
    .instr_gnt_i            (instr_gnt),
    .instr_rvalid_i         (instr_rvalid),
    .instr_addr_o           (instr_addr),
    .instr_rdata_i          (instr_rdata),
    .instr_rdata_intg_i     (instr_rdata_intg),
    .instr_err_i            (instr_err),
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
    .irq_software_i         (irq_software),
    .irq_timer_i            (irq_timer),
    .irq_external_i         (irq_external),
    .irq_fast_i             (irq_fast),
    .irq_nm_i               (irq_nm),
    .debug_req_i            (debug_req),
    .crash_dump_o           (),
    .alert_minor_o          (alert_minor),
    .alert_major_internal_o (alert_major_internal),
    .alert_major_bus_o      (alert_major_bus),
    .fetch_enable_i         (fetch_enable),
    .core_sleep_o           (core_sleep)
  );

  // ----------------------------------------------------------
  // Monitor: in kết quả ALU ra console
  // ----------------------------------------------------------
  // Lấy signals nội bộ qua hierarchical reference
  wire [31:0] alu_op_a  = ibex_top_tb.u_ibex_top.u_ibex_core.ex_block_i.alu_i.operand_a_i;
  wire [31:0] alu_op_b  = ibex_top_tb.u_ibex_top.u_ibex_core.ex_block_i.alu_i.operand_b_i;
  wire [31:0] alu_result = ibex_top_tb.u_ibex_top.u_ibex_core.ex_block_i.alu_i.result_o;
  wire [31:0] pc_id     = ibex_top_tb.u_ibex_top.u_ibex_core.if_stage_i.pc_id_o;

  // In kết quả mỗi khi instr_valid và có thay đổi result
  logic [31:0] prev_result;
  logic [31:0] prev_pc;

  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (alu_result !== prev_result || pc_id !== prev_pc) begin
        $display("t=%0t | PC=0x%08h | A=0x%08h | B=0x%08h | Result=0x%08h",
                 $time, pc_id, alu_op_a, alu_op_b, alu_result);
        prev_result <= alu_result;
        prev_pc     <= pc_id;
      end
    end
  end

  // ----------------------------------------------------------
  // Simulation control
  // ----------------------------------------------------------
  initial begin
    $display("========================================");
    $display("  Ibex ALU Test Simulation");
    $display("========================================");
    $display("  Operations: ADD, SUB, AND, OR, XOR");
    $display("              SLL, SRL, SLT, SLTU, LUI");
    $display("  x1=10, x2=20");
    $display("========================================");

    #20000; // Chạy 20us — đủ để thấy 1 vòng loop
    $display("========================================");
    $display("  Simulation complete at %0t", $time);
    $display("========================================");
    $finish;
  end

endmodule
