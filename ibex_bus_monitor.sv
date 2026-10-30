// ============================================================
// ibex_bus_monitor.sv
//
// Bus Performance Monitor
//
// Thu thập các thông số hiệu năng của Shared Bus:
//   - Số lần contention (nhiều master cùng request)
//   - Throughput: số transaction hoàn thành
//   - Latency trung bình: từ req đến gnt
//   - Bus utilization: % cycle có transaction
//   - Stall cycles: số cycle master phải chờ do busy
//
// Dùng để so sánh Shared Bus vs Crossbar trong báo cáo.
//
// Parameters:
//   N_MASTERS : phải khớp với ibex_bus_arbiter
// ============================================================

`include "prim_assert.sv"

module ibex_bus_monitor #(
  parameter int unsigned N_MASTERS = 2
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  // ----------------------------------------------------------
  // Bus Signals (observe-only, không drive)
  // ----------------------------------------------------------
  input  logic [N_MASTERS-1:0]    req_i,       // request từ masters
  input  logic [N_MASTERS-1:0]    gnt_i,       // grant đến masters
  input  logic                    sram_req_i,  // request đến SRAM
  input  logic                    sram_gnt_i,  // grant từ SRAM
  input  logic                    sram_we_i,   // write/read
  input  logic                    sram_rvalid_i, // read response valid
  input  logic                    busy_i,      // arbiter đang busy
  input  logic [31:0]             addr_i,      // địa chỉ đang access
  input  logic                    decode_err_i, // address decode error

  // ----------------------------------------------------------
  // Performance Counters Output
  // ----------------------------------------------------------
  // Tổng số cycle chạy
  output logic [31:0]             mon_total_cycles_o,

  // Số transaction hoàn thành (write + read)
  output logic [31:0]             mon_total_txn_o,
  output logic [31:0]             mon_write_txn_o,
  output logic [31:0]             mon_read_txn_o,

  // Contention: số cycle có >=2 master request đồng thời
  output logic [31:0]             mon_contention_cycles_o,

  // Stall: số cycle master bị từ chối vì busy
  output logic [31:0]             mon_stall_cycles_o,

  // Bus utilization: số cycle SRAM đang được dùng
  output logic [31:0]             mon_bus_active_cycles_o,

  // Per-master grant count (mỗi master được phục vụ bao nhiêu lần)
  output logic [N_MASTERS-1:0][31:0] mon_master_txn_o,

  // Address decode errors
  output logic [31:0]             mon_decode_err_o
);

  // ----------------------------------------------------------
  // Counters
  // ----------------------------------------------------------
  logic [31:0] total_cycles_q;
  logic [31:0] total_txn_q;
  logic [31:0] write_txn_q;
  logic [31:0] read_txn_q;
  logic [31:0] contention_cycles_q;
  logic [31:0] stall_cycles_q;
  logic [31:0] bus_active_cycles_q;
  logic [N_MASTERS-1:0][31:0] master_txn_q;
  logic [31:0] decode_err_q;

  // ----------------------------------------------------------
  // Derived signals
  // ----------------------------------------------------------
  logic txn_granted;
  logic contention;
  logic stall;

  // Transaction granted: sram_req và sram_gnt cùng lúc
  assign txn_granted = sram_req_i && sram_gnt_i;

  // Contention: ít nhất 2 master đang request
  assign contention = ($countones(req_i) >= 2) && !busy_i;

  // Stall: có request nhưng bị block vì busy
  assign stall = |req_i && busy_i;

  // ----------------------------------------------------------
  // Sequential Counting
  // ----------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      total_cycles_q      <= '0;
      total_txn_q         <= '0;
      write_txn_q         <= '0;
      read_txn_q          <= '0;
      contention_cycles_q <= '0;
      stall_cycles_q      <= '0;
      bus_active_cycles_q <= '0;
      master_txn_q        <= '{default: '0};
      decode_err_q        <= '0;
    end else begin
      // Tổng số cycle
      total_cycles_q <= total_cycles_q + 1;

      // Transaction counts
      if (txn_granted) begin
        total_txn_q <= total_txn_q + 1;
        if (sram_we_i)
          write_txn_q <= write_txn_q + 1;
        else
          read_txn_q <= read_txn_q + 1;
      end

      // Contention cycles
      if (contention)
        contention_cycles_q <= contention_cycles_q + 1;

      // Stall cycles
      if (stall)
        stall_cycles_q <= stall_cycles_q + 1;

      // Bus active cycles (SRAM đang được request)
      if (sram_req_i || sram_rvalid_i)
        bus_active_cycles_q <= bus_active_cycles_q + 1;

      // Per-master transaction count
      for (int i = 0; i < N_MASTERS; i++) begin
        if (gnt_i[i])
          master_txn_q[i] <= master_txn_q[i] + 1;
      end

      // Decode errors
      if (decode_err_i)
        decode_err_q <= decode_err_q + 1;
    end
  end

  // ----------------------------------------------------------
  // Output assignments
  // ----------------------------------------------------------
  assign mon_total_cycles_o      = total_cycles_q;
  assign mon_total_txn_o         = total_txn_q;
  assign mon_write_txn_o         = write_txn_q;
  assign mon_read_txn_o          = read_txn_q;
  assign mon_contention_cycles_o = contention_cycles_q;
  assign mon_stall_cycles_o      = stall_cycles_q;
  assign mon_bus_active_cycles_o = bus_active_cycles_q;
  assign mon_master_txn_o        = master_txn_q;
  assign mon_decode_err_o        = decode_err_q;

endmodule
