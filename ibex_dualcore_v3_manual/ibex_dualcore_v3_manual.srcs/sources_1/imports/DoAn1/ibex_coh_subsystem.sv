// ============================================================
// ibex_coh_subsystem.sv
//
// NumCores L1-D caches + permission-only directory + M x S
// cache-bank crossbar. Coherence control and line data are split:
//   cache <-> directory : GETS/GETM/PUTM/INV/FWD/ACK permission
//   cache <-> banks     : 128-bit line fill/writeback through xbar
// ============================================================

module ibex_coh_subsystem import ibex_coherence_pkg::*; #(
  parameter int unsigned CacheLines = 16,
  parameter int unsigned MemLines   = 256
) (
  input  logic                       clk_i,
  input  logic                       rst_ni,

  input  logic [NumCores-1:0]        core_req_i,
  output logic [NumCores-1:0]        core_gnt_o,
  input  logic [31:0]                core_addr_i  [NumCores],
  input  logic [NumCores-1:0]        core_we_i,
  input  logic [3:0]                 core_be_i    [NumCores],
  input  logic [31:0]                core_wdata_i [NumCores],
  output logic [NumCores-1:0]        core_rvalid_o,
  output logic [31:0]                core_rdata_o [NumCores]
);

  localparam int unsigned LineW = LineWords * DataW;

  // ---- permission network: cache <-> directory ----
  logic [NumCores-1:0] req_valid;
  coh_req_e            req_type  [NumCores];
  logic [AddrW-1:0]    req_addr  [NumCores];
  logic [NumCores-1:0] req_gnt;

  logic [NumCores-1:0] resp_valid;
  coh_msg_e            resp_msg  [NumCores];

  logic [NumCores-1:0] snoop_valid;
  coh_msg_e            snoop_cmd [NumCores];
  logic [AddrW-1:0]    snoop_addr[NumCores];

  logic [NumCores-1:0] snoop_rsp_valid;
  coh_rsp_e            snoop_rsp_type [NumCores];

  // ---- data network: cache <-> bank crossbar ----
  logic [NumCores-1:0] data_req_valid;
  logic [NumCores-1:0] data_req_we;
  logic [AddrW-1:0]    data_req_addr  [NumCores];
  logic [LineW-1:0]    data_req_wdata [NumCores];
  logic [NumCores-1:0] data_req_gnt;
  logic [NumCores-1:0] data_rsp_valid;
  logic [LineW-1:0]    data_rsp_rdata [NumCores];

  for (genvar g = 0; g < NumCores; g++) begin : g_cache
    ibex_l1_dcache #(.CacheLines(CacheLines)) u_l1 (
      .clk_i, .rst_ni,
      .core_req_i    (core_req_i[g]),
      .core_gnt_o    (core_gnt_o[g]),
      .core_addr_i   (core_addr_i[g]),
      .core_we_i     (core_we_i[g]),
      .core_be_i     (core_be_i[g]),
      .core_wdata_i  (core_wdata_i[g]),
      .core_rvalid_o (core_rvalid_o[g]),
      .core_rdata_o  (core_rdata_o[g]),

      .req_valid_o   (req_valid[g]),
      .req_type_o    (req_type[g]),
      .req_addr_o    (req_addr[g]),
      .req_gnt_i     (req_gnt[g]),
      .resp_valid_i  (resp_valid[g]),
      .resp_msg_i    (resp_msg[g]),

      .snoop_valid_i (snoop_valid[g]),
      .snoop_cmd_i   (snoop_cmd[g]),
      .snoop_addr_i  (snoop_addr[g]),
      .snoop_rsp_valid_o (snoop_rsp_valid[g]),
      .snoop_rsp_type_o  (snoop_rsp_type[g]),

      .data_req_valid_o (data_req_valid[g]),
      .data_req_we_o    (data_req_we[g]),
      .data_req_addr_o  (data_req_addr[g]),
      .data_req_wdata_o (data_req_wdata[g]),
      .data_req_gnt_i   (data_req_gnt[g]),
      .data_rsp_valid_i (data_rsp_valid[g]),
      .data_rsp_rdata_i (data_rsp_rdata[g])
    );
  end

  ibex_directory_controller #(.MemLines(MemLines)) u_dir (
    .clk_i, .rst_ni,
    .req_valid_i   (req_valid),
    .req_type_i    (req_type),
    .req_addr_i    (req_addr),
    .req_gnt_o     (req_gnt),
    .resp_valid_o  (resp_valid),
    .resp_msg_o    (resp_msg),
    .snoop_valid_o (snoop_valid),
    .snoop_cmd_o   (snoop_cmd),
    .snoop_addr_o  (snoop_addr),
    .snoop_rsp_valid_i (snoop_rsp_valid),
    .snoop_rsp_type_i  (snoop_rsp_type)
  );

  ibex_cache_bank_crossbar #(.MemLines(MemLines)) u_xbar (
    .clk_i, .rst_ni,
    .m_req_valid_i (data_req_valid),
    .m_req_we_i    (data_req_we),
    .m_req_addr_i  (data_req_addr),
    .m_req_wdata_i (data_req_wdata),
    .m_req_gnt_o   (data_req_gnt),
    .m_rsp_valid_o (data_rsp_valid),
    .m_rsp_rdata_o (data_rsp_rdata)
  );

endmodule
