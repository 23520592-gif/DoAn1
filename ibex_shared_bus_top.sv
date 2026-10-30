// ============================================================
// ibex_shared_bus_top.sv
//
// Shared Bus Top-Level
//
// Tích hợp toàn bộ Shared Bus subsystem:
//   - ibex_bus_arbiter   : N-master round-robin arbiter
//   - ibex_addr_decoder  : địa chỉ → slave routing
//   - ibex_bus_monitor   : performance monitoring
//   - ibex_shared_sram   : shared data memory
//
// Thay thế ibex_shared_mem_top trong thiết kế dual-core.
//
// Kiến trúc:
//
//   Core 0 ──┐
//   Core 1 ──┤──► ibex_bus_arbiter ──► ibex_addr_decoder ──► ibex_shared_sram
//   Core N ──┘         │                      │
//                ibex_bus_monitor ◄────────────┘
//
// Parameters:
//   N_MASTERS    : số master kết nối vào bus (mặc định 2)
//   MEM_SIZE     : kích thước Shared SRAM (bytes)
//   SRAM_BASE    : địa chỉ base của SRAM trong memory map
// ============================================================

`include "prim_assert.sv"

module ibex_shared_bus_top #(
  parameter int unsigned N_MASTERS = 2,
  parameter int unsigned MEM_SIZE  = 65536,        // 64 KiB
  parameter logic [31:0] SRAM_BASE = 32'h0002_0000
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,

  // ----------------------------------------------------------
  // OBI Data Ports — từ N Masters
  // Interface dạng array để dễ connect N core
  // ----------------------------------------------------------
  input  logic [N_MASTERS-1:0]          core_data_req_i,
  output logic [N_MASTERS-1:0]          core_data_gnt_o,
  input  logic [N_MASTERS-1:0][31:0]    core_data_addr_i,
  input  logic [N_MASTERS-1:0]          core_data_we_i,
  input  logic [N_MASTERS-1:0][3:0]     core_data_be_i,
  input  logic [N_MASTERS-1:0][31:0]    core_data_wdata_i,
  output logic [N_MASTERS-1:0]          core_data_rvalid_o,
  output logic [N_MASTERS-1:0][31:0]    core_data_rdata_o,

  // ----------------------------------------------------------
  // Performance Monitor Outputs (để testbench đọc)
  // ----------------------------------------------------------
  output logic [31:0]                   mon_total_cycles_o,
  output logic [31:0]                   mon_total_txn_o,
  output logic [31:0]                   mon_write_txn_o,
  output logic [31:0]                   mon_read_txn_o,
  output logic [31:0]                   mon_contention_cycles_o,
  output logic [31:0]                   mon_stall_cycles_o,
  output logic [31:0]                   mon_bus_active_cycles_o,
  output logic [N_MASTERS-1:0][31:0]    mon_master_txn_o
);

  // ----------------------------------------------------------
  // Internal Wires: Arbiter → SRAM
  // ----------------------------------------------------------
  logic        arb_sram_req;
  logic        arb_sram_gnt;
  logic [31:0] arb_sram_addr;
  logic        arb_sram_we;
  logic  [3:0] arb_sram_be;
  logic [31:0] arb_sram_wdata;
  logic        arb_sram_rvalid;
  logic [31:0] arb_sram_rdata;

  // ----------------------------------------------------------
  // Internal Wires: Address Decoder
  // ----------------------------------------------------------
  logic [0:0]  slave_sel;      // 1 slave trong Đồ án 1
  logic        decode_err;

  // ----------------------------------------------------------
  // Internal Wires: Arbiter Performance Outputs
  // ----------------------------------------------------------
  logic [31:0] arb_contention_cnt;
  logic [31:0] arb_total_req_cnt;
  logic [31:0] arb_busy_cycles_cnt;
  logic        arb_busy;       // expose busy state cho monitor
  logic        arb_winner_we;  // write/read của winner (cho monitor)

  // ----------------------------------------------------------
  // ibex_bus_arbiter: N-Master Round-Robin
  // ----------------------------------------------------------
  ibex_bus_arbiter #(
    .N_MASTERS (N_MASTERS),
    .DATA_W    (32),
    .ADDR_W    (32)
  ) u_arbiter (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),

    .req_i                (core_data_req_i),
    .gnt_o                (core_data_gnt_o),
    .addr_i               (core_data_addr_i),
    .we_i                 (core_data_we_i),
    .be_i                 (core_data_be_i),
    .wdata_i              (core_data_wdata_i),
    .rvalid_o             (core_data_rvalid_o),
    .rdata_o              (core_data_rdata_o),

    .sram_req_o           (arb_sram_req),
    .sram_gnt_i           (arb_sram_gnt),
    .sram_addr_o          (arb_sram_addr),
    .sram_we_o            (arb_sram_we),
    .sram_be_o            (arb_sram_be),
    .sram_wdata_o         (arb_sram_wdata),
    .sram_rvalid_i        (arb_sram_rvalid),
    .sram_rdata_i         (arb_sram_rdata),

    .perf_contention_cnt_o  (arb_contention_cnt),
    .perf_total_req_cnt_o   (arb_total_req_cnt),
    .perf_busy_cycles_cnt_o (arb_busy_cycles_cnt)
  );

  // ----------------------------------------------------------
  // ibex_addr_decoder: Route địa chỉ đến đúng slave
  // ----------------------------------------------------------
  ibex_addr_decoder #(
    .N_SLAVES  (1),
    .SRAM_BASE (SRAM_BASE),
    .SRAM_SIZE (MEM_SIZE)
  ) u_addr_decoder (
    .addr_i       (arb_sram_addr),
    .req_i        (arb_sram_req),
    .slave_sel_o  (slave_sel),
    .decode_err_o (decode_err)
  );

  // ----------------------------------------------------------
  // ibex_shared_sram: Shared Data Memory
  // Chỉ nhận request khi addr decoder chọn slave 0
  // ----------------------------------------------------------
  ibex_shared_sram #(
    .MemSizeBytes (MEM_SIZE)
  ) u_shared_sram (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .req_i    (arb_sram_req & slave_sel[0]),
    .gnt_o    (arb_sram_gnt),
    .addr_i   (arb_sram_addr),
    .we_i     (arb_sram_we),
    .be_i     (arb_sram_be),
    .wdata_i  (arb_sram_wdata),
    .rvalid_o (arb_sram_rvalid),
    .rdata_o  (arb_sram_rdata)
  );

  // Nếu decode error thì gnt vẫn phải trả về để không deadlock
  // (trả gnt nhưng rvalid sẽ không lên, core sẽ nhận err)
  // Trong thiết kế đơn giản: gnt từ SRAM đã đủ

  // ----------------------------------------------------------
  // ibex_bus_monitor: Performance Monitor
  // ----------------------------------------------------------

  // Expose busy từ arbiter thông qua hierarchical ref hoặc port
  // Ở đây dùng signal internal từ arbiter output làm proxy
  // busy = arb_busy_cycles đang tăng khi busy_q=1
  // Đơn giản hơn: tái tạo busy từ rvalid pending
  logic busy_proxy;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) busy_proxy <= 1'b0;
    else if (arb_sram_req && arb_sram_gnt && !arb_sram_we)
      busy_proxy <= 1'b1;
    else if (arb_sram_rvalid)
      busy_proxy <= 1'b0;
  end

  ibex_bus_monitor #(
    .N_MASTERS (N_MASTERS)
  ) u_bus_monitor (
    .clk_i                  (clk_i),
    .rst_ni                 (rst_ni),

    .req_i                  (core_data_req_i),
    .gnt_i                  (core_data_gnt_o),
    .sram_req_i             (arb_sram_req),
    .sram_gnt_i             (arb_sram_gnt),
    .sram_we_i              (arb_sram_we),
    .sram_rvalid_i          (arb_sram_rvalid),
    .busy_i                 (busy_proxy),
    .addr_i                 (arb_sram_addr),
    .decode_err_i           (decode_err),

    .mon_total_cycles_o     (mon_total_cycles_o),
    .mon_total_txn_o        (mon_total_txn_o),
    .mon_write_txn_o        (mon_write_txn_o),
    .mon_read_txn_o         (mon_read_txn_o),
    .mon_contention_cycles_o(mon_contention_cycles_o),
    .mon_stall_cycles_o     (mon_stall_cycles_o),
    .mon_bus_active_cycles_o(mon_bus_active_cycles_o),
    .mon_master_txn_o       (mon_master_txn_o),
    .mon_decode_err_o       ()
  );

  // ----------------------------------------------------------
  // Assertions
  // ----------------------------------------------------------

  // Decode error không được xảy ra trong normal operation
  `ASSERT(SharedBusNoDecodeErr,
      !decode_err,
      "Address decode error: core đang access địa chỉ ngoài SRAM range")

endmodule
