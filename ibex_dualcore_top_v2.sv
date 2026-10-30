// ibex_dualcore_top_v2.sv
//
// Dual-Core Ibex Top-Level v2 — dùng Shared Bus
//
// Thay ibex_shared_mem_top bằng ibex_shared_bus_top:
//   - N-master arbiter (có thể mở rộng)
//   - Address decoder
//   - Bus performance monitor
//
// Memory Map:
//   0x0000_0000 – 0x0000_3FFF  Core 0 Private IMEM (16 KiB)
//   0x0001_0000 – 0x0001_3FFF  Core 1 Private IMEM (16 KiB)
//   0x0002_0000 – 0x0002_FFFF  Shared Data SRAM    (64 KiB)

`include "prim_assert.sv"

module ibex_dualcore_top_v2 import ibex_pkg::*; #(
  parameter int unsigned IMem0SizeBytes = 16384,
  parameter int unsigned IMem1SizeBytes = 16384,
  parameter int unsigned DMSizeBytes    = 65536,
  parameter logic [31:0] Core0BootAddr = 32'h0000_0000,
  parameter logic [31:0] Core1BootAddr = 32'h0001_0000,
  parameter logic [31:0] SharedBase    = 32'h0002_0000,
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
  output logic        core1_core_sleep_o,


  // Bus Performance Monitor Outputs
  output logic [31:0] mon_total_cycles_o,
  output logic [31:0] mon_total_txn_o,
  output logic [31:0] mon_write_txn_o,
  output logic [31:0] mon_read_txn_o,
  output logic [31:0] mon_contention_cycles_o,
  output logic [31:0] mon_stall_cycles_o,
  output logic [31:0] mon_bus_active_cycles_o,
  output logic [1:0][31:0] mon_master_txn_o
);

  localparam int unsigned IMem0Depth = IMem0SizeBytes / 4;
  localparam int unsigned IMem1Depth = IMem1SizeBytes / 4;


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

  // Core 0 — ibex_top
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

  // Core 1 — ibex_top
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

  // Core 0 Private IMEM
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

  // Core 1 Private IMEM
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

  // Shared Bus — N-Master + Addr Decoder + Monitor + SRAM
  ibex_shared_bus_top #(
    .N_MASTERS (2),
    .MEM_SIZE  (DMSizeBytes),
    .SRAM_BASE (SharedBase)
  ) u_shared_bus (
    .clk_i                   (clk_i),
    .rst_ni                  (rst_ni),

    // Pack 2 core vào array (index 0 = core0, index 1 = core1)
    .core_data_req_i         ({core1_data_req,   core0_data_req}),
    .core_data_gnt_o         ({core1_data_gnt,   core0_data_gnt}),
    .core_data_addr_i        ({core1_data_addr,  core0_data_addr}),
    .core_data_we_i          ({core1_data_we,    core0_data_we}),
    .core_data_be_i          ({core1_data_be,    core0_data_be}),
    .core_data_wdata_i       ({core1_data_wdata, core0_data_wdata}),
    .core_data_rvalid_o      ({core1_data_rvalid,core0_data_rvalid}),
    .core_data_rdata_o       ({core1_data_rdata, core0_data_rdata}),

    // Monitor outputs
    .mon_total_cycles_o      (mon_total_cycles_o),
    .mon_total_txn_o         (mon_total_txn_o),
    .mon_write_txn_o         (mon_write_txn_o),
    .mon_read_txn_o          (mon_read_txn_o),
    .mon_contention_cycles_o (mon_contention_cycles_o),
    .mon_stall_cycles_o      (mon_stall_cycles_o),
    .mon_bus_active_cycles_o (mon_bus_active_cycles_o),
    .mon_master_txn_o        (mon_master_txn_o)
  );

  // Tie off unused
  logic unused_sig;
  assign unused_sig = ^{unused_core0_scramble_req, unused_core1_scramble_req,
                        unused_core0_data_wdata_intg, unused_core1_data_wdata_intg};

  `ASSERT_INIT(Core0BootAddrAligned, (Core0BootAddr[1:0] == 2'b00))
  `ASSERT_INIT(Core1BootAddrAligned, (Core1BootAddr[1:0] == 2'b00))

endmodule
