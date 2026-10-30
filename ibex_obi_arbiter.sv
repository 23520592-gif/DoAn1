// Copyright lowRISC contributors.
// Copyright 2018 ETH Zurich and University of Bologna, see also CREDITS.md.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

/**
 * OBI Bus Arbiter for Dual-Core Shared Memory
 *
 * Arbitrates between two OBI masters (Core 0 and Core 1) to access a single
 * shared SRAM. Uses a round-robin policy to ensure fairness: when both cores
 * request simultaneously, priority alternates each transaction.
 *
 * OBI Protocol:
 *   - Address phase : master asserts req_i; slave asserts gnt_o in same cycle
 *   - Response phase: slave asserts rvalid_o one cycle after a read gnt
 *   - Write has no rvalid response (we_i = 1)
 */
module ibex_obi_arbiter (
  input  logic        clk_i,
  input  logic        rst_ni,

  // -------------------------------------------------------------------------
  // OBI Slave Port – Core 0 (Master 0)
  // -------------------------------------------------------------------------
  input  logic        core0_req_i,
  output logic        core0_gnt_o,
  input  logic [31:0] core0_addr_i,
  input  logic        core0_we_i,
  input  logic [3:0]  core0_be_i,
  input  logic [31:0] core0_wdata_i,
  output logic        core0_rvalid_o,
  output logic [31:0] core0_rdata_o,

  // -------------------------------------------------------------------------
  // OBI Slave Port – Core 1 (Master 1)
  // -------------------------------------------------------------------------
  input  logic        core1_req_i,
  output logic        core1_gnt_o,
  input  logic [31:0] core1_addr_i,
  input  logic        core1_we_i,
  input  logic [3:0]  core1_be_i,
  input  logic [31:0] core1_wdata_i,
  output logic        core1_rvalid_o,
  output logic [31:0] core1_rdata_o,

  // -------------------------------------------------------------------------
  // OBI Master Port – To Shared SRAM (Slave)
  // -------------------------------------------------------------------------
  output logic        sram_req_o,
  input  logic        sram_gnt_i,
  output logic [31:0] sram_addr_o,
  output logic        sram_we_o,
  output logic [3:0]  sram_be_o,
  output logic [31:0] sram_wdata_o,
  input  logic        sram_rvalid_i,
  input  logic [31:0] sram_rdata_i
);

  /////////////////////////////////////////////////////////////////////////////
  // Arbitration Logic
  /////////////////////////////////////////////////////////////////////////////

  // Indicates whether the arbiter is currently busy serving a transaction
  // (address phase has been granted but response has not yet returned for read)
  logic        busy_q;

  // Tracks which core won the most recent grant (0 = Core 0, 1 = Core 1)
  // Used for round-robin: next conflict gives priority to the other core
  logic        last_winner_q;

  // Combinational winner selection
  logic        winner;

  always_comb begin
    if (core0_req_i && core1_req_i) begin
      // Both request at same time: grant to whichever core did NOT win last
      winner = ~last_winner_q;
    end else if (core0_req_i) begin
      winner = 1'b0;
    end else begin
      winner = 1'b1;
    end
  end

  // A new address-phase transaction can only start when the arbiter is idle
  logic any_req;
  assign any_req = core0_req_i | core1_req_i;

  // Issue request to SRAM only when not currently busy
  assign sram_req_o = any_req & ~busy_q;

  /////////////////////////////////////////////////////////////////////////////
  // Sequential State
  /////////////////////////////////////////////////////////////////////////////

  // winner_q: remembers which core is being served during the response phase
  logic winner_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q        <= 1'b0;
      last_winner_q <= 1'b0;
      winner_q      <= 1'b0;
    end else begin
      // Latch winner when address phase starts
      if (sram_req_o & sram_gnt_i) begin
        winner_q      <= winner;
        last_winner_q <= winner;
        // Become busy only for reads (writes have no rvalid response)
        busy_q        <= ~(winner ? core1_we_i : core0_we_i);
      end

      // Clear busy when SRAM response arrives
      if (busy_q & sram_rvalid_i) begin
        busy_q <= 1'b0;
      end
    end
  end

  /////////////////////////////////////////////////////////////////////////////
  // Grant Generation
  /////////////////////////////////////////////////////////////////////////////

  assign core0_gnt_o = sram_req_o & sram_gnt_i & (winner == 1'b0);
  assign core1_gnt_o = sram_req_o & sram_gnt_i & (winner == 1'b1);

  /////////////////////////////////////////////////////////////////////////////
  // Address Phase Mux – forward winning core to SRAM
  /////////////////////////////////////////////////////////////////////////////

  assign sram_addr_o  = winner ? core1_addr_i  : core0_addr_i;
  assign sram_we_o    = winner ? core1_we_i    : core0_we_i;
  assign sram_be_o    = winner ? core1_be_i    : core0_be_i;
  assign sram_wdata_o = winner ? core1_wdata_i : core0_wdata_i;

  /////////////////////////////////////////////////////////////////////////////
  // Response Phase – route SRAM rvalid/rdata back to correct core
  /////////////////////////////////////////////////////////////////////////////

  assign core0_rvalid_o = sram_rvalid_i & (winner_q == 1'b0);
  assign core1_rvalid_o = sram_rvalid_i & (winner_q == 1'b1);

  // Both cores receive the same rdata bus; only the correct core's rvalid
  // is asserted, so the other core will ignore this data
  assign core0_rdata_o  = sram_rdata_i;
  assign core1_rdata_o  = sram_rdata_i;

  /////////////////////////////////////////////////////////////////////////////
  // Assertions
  /////////////////////////////////////////////////////////////////////////////

  // Both grants must never be asserted simultaneously
  `ASSERT(ObiArbiterMutualExclusion,
      !(core0_gnt_o && core1_gnt_o))

  // rvalid must not appear without a prior granted read
  `ASSERT(ObiArbiterRvalidKnown,
      sram_rvalid_i |-> busy_q || $past(busy_q))

endmodule
