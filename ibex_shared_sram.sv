// Copyright lowRISC contributors.
// Copyright 2018 ETH Zurich and University of Bologna, see also CREDITS.md.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

/**
 * Shared SRAM – OBI-Compliant Single-Port Memory
 *
 * A byte-enable, single-port SRAM that follows the OBI handshake protocol:
 *   - Grant (gnt_o) is asserted combinationally in the same cycle as req_i
 *   - For both reads and writes, rvalid_o is asserted one cycle after the
 *     granted request (Ibex LSU waits for rvalid to retire stores too)
 *
 * On Xilinx FPGAs (Vivado), the mem array synthesises to Block RAM (BRAM)
 * in Simple Dual-Port or True Dual-Port mode depending on tool heuristics.
 * Byte-enable write is supported through individual byte slice assignments.
 *
 * Parameters:
 *   MemSizeBytes – total memory size in bytes (must be a multiple of 4)
 */
module ibex_shared_sram #(
  parameter int unsigned MemSizeBytes = 65536  // 64 KiB default
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // -------------------------------------------------------------------------
  // OBI Slave Interface
  // -------------------------------------------------------------------------
  input  logic        req_i,
  output logic        gnt_o,
  input  logic [31:0] addr_i,      // byte-addressed
  input  logic        we_i,
  input  logic [3:0]  be_i,        // byte enable (1 bit per byte lane)
  input  logic [31:0] wdata_i,
  output logic        rvalid_o,
  output logic [31:0] rdata_o
);

  /////////////////////////////////////////////////////////////////////////////
  // Local Parameters
  /////////////////////////////////////////////////////////////////////////////

  localparam int unsigned MemDepth = MemSizeBytes / 4;  // number of 32-bit words

  /////////////////////////////////////////////////////////////////////////////
  // Memory Array
  //
  // Declared as a flat logic array so Vivado infers BRAM automatically.
  // Initial values are undefined (X) which is correct for FPGA block RAM.
  /////////////////////////////////////////////////////////////////////////////

  logic [31:0] mem [0:MemDepth-1];

  /////////////////////////////////////////////////////////////////////////////
  // OBI Grant
  //
  // Grant is given combinationally: the SRAM accepts every request in the
  // same cycle it is presented (no back-pressure, single-cycle address phase).
  /////////////////////////////////////////////////////////////////////////////

  assign gnt_o = req_i;

  /////////////////////////////////////////////////////////////////////////////
  // Word Address
  /////////////////////////////////////////////////////////////////////////////

  // Ibex always issues naturally aligned word/halfword/byte accesses.
  // Drop the two LSBs to convert byte address to word index.
  logic [$clog2(MemDepth)-1:0] word_addr;
  assign word_addr = addr_i[$clog2(MemDepth)+1:2];

  /////////////////////////////////////////////////////////////////////////////
  // Write Path (synchronous, byte-enable)
  /////////////////////////////////////////////////////////////////////////////

  always_ff @(posedge clk_i) begin
    if (req_i && we_i) begin
      if (be_i[0]) mem[word_addr][ 7: 0] <= wdata_i[ 7: 0];
      if (be_i[1]) mem[word_addr][15: 8] <= wdata_i[15: 8];
      if (be_i[2]) mem[word_addr][23:16] <= wdata_i[23:16];
      if (be_i[3]) mem[word_addr][31:24] <= wdata_i[31:24];
    end
  end

  /////////////////////////////////////////////////////////////////////////////
  // Read Path (synchronous, 1-cycle latency)
  //
  // rvalid_o is registered so it arrives exactly one cycle after the granted
  // request, satisfying the OBI response-phase requirement.
  // Both reads and writes produce a response (Ibex requires rvalid to complete
  // a store as well as a load).
  /////////////////////////////////////////////////////////////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_o <= 1'b0;
      rdata_o  <= 32'h0;
    end else begin
      rvalid_o <= req_i;          // response cho CẢ write lẫn read (Ibex LSU cần)
      rdata_o  <= mem[word_addr];
    end
  end

  /////////////////////////////////////////////////////////////////////////////
  // Assertions
  /////////////////////////////////////////////////////////////////////////////

  // Address must be within the allocated memory range
  `ASSERT(SharedSramAddrInRange,
      req_i |-> (word_addr < MemDepth))

endmodule
