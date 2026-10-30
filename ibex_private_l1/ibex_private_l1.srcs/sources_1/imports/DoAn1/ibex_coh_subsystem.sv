// ============================================================
// ibex_coh_subsystem.sv
//
// Gom NumCores L1-D cache + 1 directory thành 1 khối coherent.
// Phía trên: NumCores cổng OBI (nối thẳng data port của Ibex).
// Phía trong: cache[i] ↔ directory qua 4 kênh của giao thức.
//
// Đây là khối để verify Bước 2 (1 bank nội bộ trong directory).
// Bước 3 sẽ chèn crossbar giữa cache và directory + chia bank.
// ============================================================

module ibex_coh_subsystem import ibex_coherence_pkg::*; #(
  parameter int unsigned CacheLines = 16,
  parameter int unsigned MemLines   = 256
) (
  input  logic                       clk_i,
  input  logic                       rst_ni,

  // OBI slave cho từng core (nối data port Ibex)
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

  // ---- kênh cache ↔ directory ----
  logic [NumCores-1:0]     req_valid;
  coh_req_e                req_type  [NumCores];
  logic [AddrW-1:0]        req_addr  [NumCores];
  logic [LineW-1:0]        req_data  [NumCores];
  logic [NumCores-1:0]     req_gnt;

  logic [NumCores-1:0]     resp_valid;
  coh_msg_e                resp_msg  [NumCores];
  logic [LineW-1:0]        resp_data [NumCores];

  logic [NumCores-1:0]     snoop_valid;
  coh_msg_e                snoop_cmd [NumCores];
  logic [AddrW-1:0]        snoop_addr[NumCores];

  logic [NumCores-1:0]     snoop_rsp_valid;
  coh_rsp_e                snoop_rsp_type [NumCores];
  logic [LineW-1:0]        snoop_rsp_data [NumCores];

  // ---- caches ----
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
      .req_data_o    (req_data[g]),
      .req_gnt_i     (req_gnt[g]),
      .resp_valid_i  (resp_valid[g]),
      .resp_msg_i    (resp_msg[g]),
      .resp_data_i   (resp_data[g]),
      .snoop_valid_i (snoop_valid[g]),
      .snoop_cmd_i   (snoop_cmd[g]),
      .snoop_addr_i  (snoop_addr[g]),
      .snoop_rsp_valid_o (snoop_rsp_valid[g]),
      .snoop_rsp_type_o  (snoop_rsp_type[g]),
      .snoop_rsp_data_o  (snoop_rsp_data[g])
    );
  end

  // ---- directory ----
  ibex_directory_controller #(.MemLines(MemLines)) u_dir (
    .clk_i, .rst_ni,
    .req_valid_i   (req_valid),
    .req_type_i    (req_type),
    .req_addr_i    (req_addr),
    .req_data_i    (req_data),
    .req_gnt_o     (req_gnt),
    .resp_valid_o  (resp_valid),
    .resp_msg_o    (resp_msg),
    .resp_data_o   (resp_data),
    .snoop_valid_o (snoop_valid),
    .snoop_cmd_o   (snoop_cmd),
    .snoop_addr_o  (snoop_addr),
    .snoop_rsp_valid_i (snoop_rsp_valid),
    .snoop_rsp_type_i  (snoop_rsp_type),
    .snoop_rsp_data_i  (snoop_rsp_data)
  );

endmodule