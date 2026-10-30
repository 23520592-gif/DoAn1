// ============================================================
// ibex_addr_decoder.sv
//
// Address Decoder cho Shared Bus
//
// Decode địa chỉ từ winning master và route đến đúng slave.
// Trong Đồ án 1 chỉ có 1 slave (Shared SRAM), nhưng module
// được thiết kế để dễ mở rộng thêm slave sau này.
//
// Memory Map (mặc định):
//   0x0002_0000 – 0x0002_FFFF  Shared SRAM (64 KiB)
//   (các vùng khác → error response)
//
// Parameters:
//   N_SLAVES    : số slave (mặc định 1)
//   SRAM_BASE   : địa chỉ base của Shared SRAM
//   SRAM_SIZE   : kích thước Shared SRAM (bytes)
// ============================================================

`include "prim_assert.sv"

module ibex_addr_decoder #(
  parameter int unsigned N_SLAVES  = 1,
  parameter logic [31:0] SRAM_BASE = 32'h0002_0000,
  parameter int unsigned SRAM_SIZE = 65536           // 64 KiB
) (
  // ----------------------------------------------------------
  // Address từ Bus Arbiter
  // ----------------------------------------------------------
  input  logic [31:0] addr_i,
  input  logic        req_i,

  // ----------------------------------------------------------
  // Slave Select Output
  // ----------------------------------------------------------
  output logic [N_SLAVES-1:0] slave_sel_o,  // one-hot slave select
  output logic                decode_err_o  // địa chỉ không hợp lệ
);

  // ----------------------------------------------------------
  // Address Range Check
  // ----------------------------------------------------------
  logic sram_sel;

  assign sram_sel = req_i &&
                    (addr_i >= SRAM_BASE) &&
                    (addr_i < (SRAM_BASE + SRAM_SIZE));

  // ----------------------------------------------------------
  // Slave Select (one-hot)
  // Slave 0: Shared SRAM
  // Slave 1+: có thể thêm sau (Peripheral, ROM...)
  // ----------------------------------------------------------
  always_comb begin
    slave_sel_o  = '0;
    decode_err_o = 1'b0;

    if (req_i) begin
      if (sram_sel) begin
        slave_sel_o[0] = 1'b1;
      end else begin
        // Địa chỉ không map đến slave nào
        decode_err_o = 1'b1;
      end
    end
  end

  // ----------------------------------------------------------
  // Assertions
  // ----------------------------------------------------------

  // Chỉ được chọn đúng 1 slave tại một thời điểm
  `ASSERT(AddrDecOneHot,
      req_i && !decode_err_o |-> $countones(slave_sel_o) == 1)

  // Không được vừa select slave vừa báo lỗi
  `ASSERT(AddrDecNoErrAndSel,
      !(decode_err_o && |slave_sel_o))

endmodule
