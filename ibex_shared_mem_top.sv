// Copyright lowRISC contributors.
// Copyright 2018 ETH Zurich and University of Bologna, see also CREDITS.md.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

/**
 * Shared Memory Subsystem – Top Level
 *
 * Integrates an OBI arbiter (ibex_obi_arbiter) and a shared SRAM
 * (ibex_shared_sram) to form the data-side shared memory interconnect for a
 * dual-core Ibex system.
 *
 * Address Mapping (example – adjust to your system memory map):
 *   0x0000_0000 – 0x0000_FFFF  Shared SRAM (64 KiB)
 *
 * Both cores connect their data OBI port here.  Instruction OBI ports are
 * connected separately to private instruction memories (not in this module).
 *
 * Parameters:
 *   MemSizeBytes – shared SRAM size in bytes, passed through to ibex_shared_sram
 */
module ibex_shared_mem_top #(
  parameter int unsigned MemSizeBytes = 65536  // 64 KiB default
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // -------------------------------------------------------------------------
  // OBI Data Port – Core 0
  // -------------------------------------------------------------------------
  input  logic        core0_data_req_i,
  output logic        core0_data_gnt_o,
  input  logic [31:0] core0_data_addr_i,
  input  logic        core0_data_we_i,
  input  logic [3:0]  core0_data_be_i,
  input  logic [31:0] core0_data_wdata_i,
  output logic        core0_data_rvalid_o,
  output logic [31:0] core0_data_rdata_o,

  // -------------------------------------------------------------------------
  // OBI Data Port – Core 1
  // -------------------------------------------------------------------------
  input  logic        core1_data_req_i,
  output logic        core1_data_gnt_o,
  input  logic [31:0] core1_data_addr_i,
  input  logic        core1_data_we_i,
  input  logic [3:0]  core1_data_be_i,
  input  logic [31:0] core1_data_wdata_i,
  output logic        core1_data_rvalid_o,
  output logic [31:0] core1_data_rdata_o
);

  /////////////////////////////////////////////////////////////////////////////
  // Internal Wires – Arbiter to SRAM (OBI)
  /////////////////////////////////////////////////////////////////////////////

  logic        arb_sram_req;
  logic        arb_sram_gnt;
  logic [31:0] arb_sram_addr;
  logic        arb_sram_we;
  logic [3:0]  arb_sram_be;
  logic [31:0] arb_sram_wdata;
  logic        arb_sram_rvalid;
  logic [31:0] arb_sram_rdata;

  /////////////////////////////////////////////////////////////////////////////
  // OBI Arbiter Instance
  /////////////////////////////////////////////////////////////////////////////

  ibex_obi_arbiter u_obi_arbiter (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),

    // Core 0 slave port
    .core0_req_i    (core0_data_req_i),
    .core0_gnt_o    (core0_data_gnt_o),
    .core0_addr_i   (core0_data_addr_i),
    .core0_we_i     (core0_data_we_i),
    .core0_be_i     (core0_data_be_i),
    .core0_wdata_i  (core0_data_wdata_i),
    .core0_rvalid_o (core0_data_rvalid_o),
    .core0_rdata_o  (core0_data_rdata_o),

    // Core 1 slave port
    .core1_req_i    (core1_data_req_i),
    .core1_gnt_o    (core1_data_gnt_o),
    .core1_addr_i   (core1_data_addr_i),
    .core1_we_i     (core1_data_we_i),
    .core1_be_i     (core1_data_be_i),
    .core1_wdata_i  (core1_data_wdata_i),
    .core1_rvalid_o (core1_data_rvalid_o),
    .core1_rdata_o  (core1_data_rdata_o),

    // SRAM master port
    .sram_req_o     (arb_sram_req),
    .sram_gnt_i     (arb_sram_gnt),
    .sram_addr_o    (arb_sram_addr),
    .sram_we_o      (arb_sram_we),
    .sram_be_o      (arb_sram_be),
    .sram_wdata_o   (arb_sram_wdata),
    .sram_rvalid_i  (arb_sram_rvalid),
    .sram_rdata_i   (arb_sram_rdata)
  );

  /////////////////////////////////////////////////////////////////////////////
  // Shared SRAM Instance
  /////////////////////////////////////////////////////////////////////////////

  ibex_shared_sram #(
    .MemSizeBytes (MemSizeBytes)
  ) u_shared_sram (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),

    .req_i    (arb_sram_req),
    .gnt_o    (arb_sram_gnt),
    .addr_i   (arb_sram_addr),
    .we_i     (arb_sram_we),
    .be_i     (arb_sram_be),
    .wdata_i  (arb_sram_wdata),
    .rvalid_o (arb_sram_rvalid),
    .rdata_o  (arb_sram_rdata)
  );

  /////////////////////////////////////////////////////////////////////////////
  // Assertions
  /////////////////////////////////////////////////////////////////////////////

  // Core 0 must never see a grant without an active request
  `ASSERT(Core0GntImpliesReq,
      core0_data_gnt_o |-> core0_data_req_i)

  // Core 1 must never see a grant without an active request
  `ASSERT(Core1GntImpliesReq,
      core1_data_gnt_o |-> core1_data_req_i)

endmodule
