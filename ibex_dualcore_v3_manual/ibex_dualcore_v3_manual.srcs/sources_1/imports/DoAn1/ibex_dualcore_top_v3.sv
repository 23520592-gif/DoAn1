// ============================================================
// ibex_dualcore_top_v3.sv
//
// Dual-Core Ibex Top-Level v3 - B4 INTEGRATION
//
// Thay data path Shared-Bus (v2) bằng hệ thống cache-coherent:
//   ibex_coh_subsystem = 2 x L1-D cache (MESI) + permission-only
//   directory + M x S cache-bank crossbar (Hướng B, 2 mạng tách rời).
//
// Hai core Ibex thật vẫn giữ nguyên; chỉ kênh DATA của mỗi core
// được đấu vào L1-D cache tương ứng. Kênh INSTR (private IMEM)
// không đổi.
//
// Memory Map (DATA đi qua coherent subsystem):
//   0x0000_0000 - 0x0000_3FFF  Core 0 Private IMEM (16 KiB)
//   0x0001_0000 - 0x0001_3FFF  Core 1 Private IMEM (16 KiB)
//   Shared data  : nằm trong backing-store của crossbar banks
//                  (MemLines * LineBytes = 256 * 16 = 4 KiB, line-interleaved addr[4])
//
// Lưu ý: directory/cache index theo địa chỉ thô (raw addr). Vùng
// shared dùng trong chương trình test alias vào không gian
// MemLines*LineBytes của bank - đủ cho kịch bản demo coherence.
// ============================================================

`include "prim_assert.sv"

module ibex_dualcore_top_v3 import ibex_pkg::*; #(
  parameter int unsigned IMem0SizeBytes = 16384,
  parameter int unsigned IMem1SizeBytes = 16384,
  parameter int unsigned DMSizeBytes    = 65536,  // giữ tương thích cổng; subsystem dùng MemLines
  parameter logic [31:0] Core0BootAddr = 32'h0000_0000,
  parameter logic [31:0] Core1BootAddr = 32'h0001_0000,
  parameter logic [31:0] SharedBase    = 32'h0002_0000,
  // Cấu hình coherent subsystem
  parameter int unsigned CacheLines    = 16,
  parameter int unsigned MemLines      = 256,
  // Cấu hình core
  parameter bit          RV32E            = 1'b0,
  parameter rv32m_e      RV32M            = RV32MFast,
  parameter rv32b_e      RV32B            = RV32BNone,
  parameter regfile_e    RegFile          = RegFileFF,
  parameter bit          BranchTargetALU  = 1'b0,
  parameter bit          WritebackStage   = 1'b0,
  parameter int unsigned DmHaltAddr       = 32'h1A11_0800,
  parameter int unsigned DmExceptionAddr  = 32'h1A11_0808
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Core 0 Interrupts
  input  logic        core0_irq_software_i,
  input  logic        core0_irq_timer_i,
  input  logic        core0_irq_external_i,
  input  logic [14:0] core0_irq_fast_i,
  input  logic        core0_irq_nm_i,

  // Core 1 Interrupts
  input  logic        core1_irq_software_i,
  input  logic        core1_irq_timer_i,
  input  logic        core1_irq_external_i,
  input  logic [14:0] core1_irq_fast_i,
  input  logic        core1_irq_nm_i,

  // Core 0 Debug
  input  logic        core0_debug_req_i,
  output crash_dump_t core0_crash_dump_o,
  output logic        core0_double_fault_seen_o,

  // Core 1 Debug
  input  logic        core1_debug_req_i,
  output crash_dump_t core1_crash_dump_o,
  output logic        core1_double_fault_seen_o,

  // Core 0 Control
  input  ibex_mubi_t  core0_fetch_enable_i,
  output logic        core0_alert_minor_o,
  output logic        core0_alert_major_internal_o,
  output logic        core0_alert_major_bus_o,
  output logic        core0_core_sleep_o,

  // Core 1 Control
  input  ibex_mubi_t  core1_fetch_enable_i,
  output logic        core1_alert_minor_o,
  output logic        core1_alert_major_internal_o,
  output logic        core1_alert_major_bus_o,
  output logic        core1_core_sleep_o
);

  localparam int unsigned IMem0Depth = IMem0SizeBytes / 4;
  localparam int unsigned IMem1Depth = IMem1SizeBytes / 4;
  localparam int unsigned NumCores   = 2;

  // Core 0 OBI Wires
  logic        core0_instr_req, core0_instr_gnt;
  logic        core0_instr_rvalid;
  logic [31:0] core0_instr_addr, core0_instr_rdata;

  logic        core0_data_req, core0_data_gnt;
  logic        core0_data_rvalid;
  logic        core0_data_we;
  logic  [3:0] core0_data_be;
  logic [31:0] core0_data_addr, core0_data_wdata, core0_data_rdata;

  // Core 1 OBI Wires
  logic        core1_instr_req, core1_instr_gnt;
  logic        core1_instr_rvalid;
  logic [31:0] core1_instr_addr, core1_instr_rdata;

  logic        core1_data_req, core1_data_gnt;
  logic        core1_data_rvalid;
  logic        core1_data_we;
  logic  [3:0] core1_data_be;
  logic [31:0] core1_data_addr, core1_data_wdata, core1_data_rdata;

  // Unused outputs
  logic        unused_core0_scramble_req, unused_core1_scramble_req;
  logic  [6:0] unused_core0_data_wdata_intg, unused_core1_data_wdata_intg;

  prim_ram_1p_pkg::ram_1p_cfg_t ram_cfg_tie;
  assign ram_cfg_tie = '0;

  // Core 0 - ibex_top
  ibex_top #(
    .RV32E           (RV32E),
    .RV32M           (RV32M),
    .RV32B           (RV32B),
    .RegFile         (RegFile),
    .BranchTargetALU (BranchTargetALU),
    .WritebackStage  (WritebackStage),
    .DmHaltAddr      (DmHaltAddr),
    .DmExceptionAddr (DmExceptionAddr)
  ) u_core0 (
    .clk_i                  (clk_i),
    .rst_ni                 (rst_ni),
    .test_en_i              (1'b0),
    .ram_cfg_i              (ram_cfg_tie),
    .hart_id_i              (32'h0),
    .boot_addr_i            (Core0BootAddr),
    .instr_req_o            (core0_instr_req),
    .instr_gnt_i            (core0_instr_gnt),
    .instr_rvalid_i         (core0_instr_rvalid),
    .instr_addr_o           (core0_instr_addr),
    .instr_rdata_i          (core0_instr_rdata),
    .instr_rdata_intg_i     (7'h0),
    .instr_err_i            (1'b0),
    .data_req_o             (core0_data_req),
    .data_gnt_i             (core0_data_gnt),
    .data_rvalid_i          (core0_data_rvalid),
    .data_we_o              (core0_data_we),
    .data_be_o              (core0_data_be),
    .data_addr_o            (core0_data_addr),
    .data_wdata_o           (core0_data_wdata),
    .data_wdata_intg_o      (unused_core0_data_wdata_intg),
    .data_rdata_i           (core0_data_rdata),
    .data_rdata_intg_i      (7'h0),
    .data_err_i             (1'b0),
    .irq_software_i         (core0_irq_software_i),
    .irq_timer_i            (core0_irq_timer_i),
    .irq_external_i         (core0_irq_external_i),
    .irq_fast_i             (core0_irq_fast_i),
    .irq_nm_i               (core0_irq_nm_i),
    .scramble_key_valid_i   (1'b0),
    .scramble_key_i         ('0),
    .scramble_nonce_i       ('0),
    .scramble_req_o         (unused_core0_scramble_req),
    .debug_req_i            (core0_debug_req_i),
    .crash_dump_o           (core0_crash_dump_o),
    .double_fault_seen_o    (core0_double_fault_seen_o),
    .fetch_enable_i         (core0_fetch_enable_i),
    .alert_minor_o          (core0_alert_minor_o),
    .alert_major_internal_o (core0_alert_major_internal_o),
    .alert_major_bus_o      (core0_alert_major_bus_o),
    .core_sleep_o           (core0_core_sleep_o),
    .scan_rst_ni            (1'b1)
  );

  // Core 1 - ibex_top
  ibex_top #(
    .RV32E           (RV32E),
    .RV32M           (RV32M),
    .RV32B           (RV32B),
    .RegFile         (RegFile),
    .BranchTargetALU (BranchTargetALU),
    .WritebackStage  (WritebackStage),
    .DmHaltAddr      (DmHaltAddr),
    .DmExceptionAddr (DmExceptionAddr)
  ) u_core1 (
    .clk_i                  (clk_i),
    .rst_ni                 (rst_ni),
    .test_en_i              (1'b0),
    .ram_cfg_i              (ram_cfg_tie),
    .hart_id_i              (32'h1),
    .boot_addr_i            (Core1BootAddr),
    .instr_req_o            (core1_instr_req),
    .instr_gnt_i            (core1_instr_gnt),
    .instr_rvalid_i         (core1_instr_rvalid),
    .instr_addr_o           (core1_instr_addr),
    .instr_rdata_i          (core1_instr_rdata),
    .instr_rdata_intg_i     (7'h0),
    .instr_err_i            (1'b0),
    .data_req_o             (core1_data_req),
    .data_gnt_i             (core1_data_gnt),
    .data_rvalid_i          (core1_data_rvalid),
    .data_we_o              (core1_data_we),
    .data_be_o              (core1_data_be),
    .data_addr_o            (core1_data_addr),
    .data_wdata_o           (core1_data_wdata),
    .data_wdata_intg_o      (unused_core1_data_wdata_intg),
    .data_rdata_i           (core1_data_rdata),
    .data_rdata_intg_i      (7'h0),
    .data_err_i             (1'b0),
    .irq_software_i         (core1_irq_software_i),
    .irq_timer_i            (core1_irq_timer_i),
    .irq_external_i         (core1_irq_external_i),
    .irq_fast_i             (core1_irq_fast_i),
    .irq_nm_i               (core1_irq_nm_i),
    .scramble_key_valid_i   (1'b0),
    .scramble_key_i         ('0),
    .scramble_nonce_i       ('0),
    .scramble_req_o         (unused_core1_scramble_req),
    .debug_req_i            (core1_debug_req_i),
    .crash_dump_o           (core1_crash_dump_o),
    .double_fault_seen_o    (core1_double_fault_seen_o),
    .fetch_enable_i         (core1_fetch_enable_i),
    .alert_minor_o          (core1_alert_minor_o),
    .alert_major_internal_o (core1_alert_major_internal_o),
    .alert_major_bus_o      (core1_alert_major_bus_o),
    .core_sleep_o           (core1_core_sleep_o),
    .scan_rst_ni            (1'b1)
  );

  // ----------------------------------------------------------
  // Core 0 Private IMEM (instr path không đổi)
  // ----------------------------------------------------------
  logic [31:0] imem0 [0:IMem0Depth-1];
  assign core0_instr_gnt = core0_instr_req;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      core0_instr_rvalid <= 1'b0;
      core0_instr_rdata  <= 32'h0;
    end else begin
      core0_instr_rvalid <= core0_instr_req;
      if (core0_instr_req)
        core0_instr_rdata <= imem0[core0_instr_addr[$clog2(IMem0Depth)+1:2]];
    end
  end

  // ----------------------------------------------------------
  // Core 1 Private IMEM
  // ----------------------------------------------------------
  logic [31:0] imem1 [0:IMem1Depth-1];
  assign core1_instr_gnt = core1_instr_req;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      core1_instr_rvalid <= 1'b0;
      core1_instr_rdata  <= 32'h0;
    end else begin
      core1_instr_rvalid <= core1_instr_req;
      if (core1_instr_req)
        core1_instr_rdata <= imem1[core1_instr_addr[$clog2(IMem1Depth)+1:2]];
    end
  end

  // ----------------------------------------------------------
  // DATA path: 2 core OBI -> coherent subsystem (unpacked per core)
  // index 0 = core0, index 1 = core1
  // ----------------------------------------------------------
  logic [NumCores-1:0] d_req, d_gnt, d_we, d_rvalid;
  logic [31:0]         d_addr  [NumCores];
  logic [3:0]          d_be    [NumCores];
  logic [31:0]         d_wdata [NumCores];
  logic [31:0]         d_rdata [NumCores];

  assign d_req[0]   = core0_data_req;
  assign d_req[1]   = core1_data_req;
  assign d_we[0]    = core0_data_we;
  assign d_we[1]    = core1_data_we;
  assign d_addr[0]  = core0_data_addr;
  assign d_addr[1]  = core1_data_addr;
  assign d_be[0]    = core0_data_be;
  assign d_be[1]    = core1_data_be;
  assign d_wdata[0] = core0_data_wdata;
  assign d_wdata[1] = core1_data_wdata;

  assign core0_data_gnt    = d_gnt[0];
  assign core1_data_gnt    = d_gnt[1];
  assign core0_data_rvalid = d_rvalid[0];
  assign core1_data_rvalid = d_rvalid[1];
  assign core0_data_rdata  = d_rdata[0];
  assign core1_data_rdata  = d_rdata[1];

  ibex_coh_subsystem #(
    .CacheLines (CacheLines),
    .MemLines   (MemLines)
  ) u_coh (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .core_req_i    (d_req),
    .core_gnt_o    (d_gnt),
    .core_addr_i   (d_addr),
    .core_we_i     (d_we),
    .core_be_i     (d_be),
    .core_wdata_i  (d_wdata),
    .core_rvalid_o (d_rvalid),
    .core_rdata_o  (d_rdata)
  );

  // Tie off unused
  logic unused_sig;
  assign unused_sig = ^{unused_core0_scramble_req, unused_core1_scramble_req,
                        unused_core0_data_wdata_intg, unused_core1_data_wdata_intg,
                        SharedBase, DMSizeBytes[0]};

  `ASSERT_INIT(Core0BootAddrAligned, (Core0BootAddr[1:0] == 2'b00))
  `ASSERT_INIT(Core1BootAddrAligned, (Core1BootAddr[1:0] == 2'b00))

endmodule