// ============================================================
// ibex_l1_cache.sv
//
// Blocking L1-D cache with MESI permission from directory and
// line data transferred directly through cache-bank crossbar.
// Directory messages carry permission only; fill/writeback data
// uses the data_req_* channel below.
// ============================================================

module ibex_l1_dcache import ibex_coherence_pkg::*; #(
  parameter int unsigned CacheLines = 16
) (
  input  logic                       clk_i,
  input  logic                       rst_ni,

  // ---------------- CORE side: OBI-like slave ----------------
  input  logic                       core_req_i,
  output logic                       core_gnt_o,
  input  logic [31:0]                core_addr_i,
  input  logic                       core_we_i,
  input  logic [3:0]                 core_be_i,
  input  logic [31:0]                core_wdata_i,
  output logic                       core_rvalid_o,
  output logic [31:0]                core_rdata_o,

  // ---------- Permission channel: cache -> directory ----------
  output logic                       req_valid_o,
  output coh_req_e                   req_type_o,
  output logic [AddrW-1:0]           req_addr_o,
  input  logic                       req_gnt_i,

  // ---------- Permission response: directory -> cache ----------
  input  logic                       resp_valid_i,
  input  coh_msg_e                   resp_msg_i,

  // ---------- Snoop command: directory -> cache ----------
  input  logic                       snoop_valid_i,
  input  coh_msg_e                   snoop_cmd_i,
  input  logic [AddrW-1:0]           snoop_addr_i,
  output logic                       snoop_rsp_valid_o,
  output coh_rsp_e                   snoop_rsp_type_o,

  // ---------- Data channel: cache -> crossbar/banks ----------
  output logic                       data_req_valid_o,
  output logic                       data_req_we_o,
  output logic [AddrW-1:0]           data_req_addr_o,
  output logic [LineWords*DataW-1:0] data_req_wdata_o,
  input  logic                       data_req_gnt_i,
  input  logic                       data_rsp_valid_i,
  input  logic [LineWords*DataW-1:0] data_rsp_rdata_i
);

  localparam int unsigned LineW  = LineWords * DataW;
  localparam int unsigned IndexW = $clog2(CacheLines);
  localparam int unsigned TagW   = AddrW - IndexW - LineOffW;

  function automatic logic [IndexW-1:0] idx_of(input logic [AddrW-1:0] a);
    return a[LineOffW +: IndexW];
  endfunction

  function automatic logic [TagW-1:0] tag_of(input logic [AddrW-1:0] a);
    return a[AddrW-1 -: TagW];
  endfunction

  function automatic logic [31:0] merge_be(input logic [31:0] old_w,
                                           input logic [31:0] new_w,
                                           input logic [3:0]  be);
    logic [31:0] r;
    for (int b = 0; b < 4; b++) begin
      r[b*8 +: 8] = be[b] ? new_w[b*8 +: 8] : old_w[b*8 +: 8];
    end
    return r;
  endfunction

  mesi_state_e      state_q [CacheLines];
  logic [TagW-1:0]  tag_q   [CacheLines];
  logic [LineW-1:0] data_q  [CacheLines];

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_WB_DATA,
    ST_WB_DATA_WAIT,
    ST_WB_REQ,
    ST_WB_WAIT,
    ST_REQ,
    ST_WAIT_PERM,
    ST_FILL_DATA,
    ST_FILL_WAIT,
    ST_SNOOP,
    ST_SNOOP_WB,
    ST_SNOOP_WB_WAIT
  } state_e;

  state_e st_q, st_d;
  state_e ret_q, ret_d;

  logic [AddrW-1:0] req_addr_q;
  logic             req_we_q;
  logic [3:0]       req_be_q;
  logic [31:0]      req_wdata_q;
  coh_req_e         pend_req_q;
  coh_msg_e         fill_msg_q;

  logic [AddrW-1:0] victim_addr_q;
  logic [LineW-1:0] victim_data_q;

  logic [AddrW-1:0] snp_addr_q;
  coh_msg_e         snp_cmd_q;

  logic             rvalid_q;
  logic [31:0]      rdata_q;

  logic [IndexW-1:0] c_idx;
  logic [TagW-1:0]   c_tag;
  logic              c_hit;
  mesi_state_e       c_state;
  logic [1:0]        c_word;
  logic [LineW-1:0]  c_line;

  assign c_idx   = idx_of(core_addr_i);
  assign c_tag   = tag_of(core_addr_i);
  assign c_state = state_q[c_idx];
  assign c_hit   = (c_state != MESI_I) && (tag_q[c_idx] == c_tag);
  assign c_word  = word_index(core_addr_i);
  assign c_line  = data_q[c_idx];

  logic c_read_hit;
  logic c_write_hit_perm;
  logic c_write_hit_up;
  logic victim_dirty;

  assign c_read_hit       = c_hit && core_req_i && !core_we_i;
  assign c_write_hit_perm = c_hit && core_we_i && ((c_state == MESI_M) || (c_state == MESI_E));
  assign c_write_hit_up   = c_hit && core_we_i && (c_state == MESI_S);
  assign victim_dirty     = (state_q[c_idx] == MESI_M);

  logic [IndexW-1:0] s_idx;
  logic              s_present;
  assign s_idx     = idx_of(snp_addr_q);
  assign s_present = (state_q[s_idx] != MESI_I) && (tag_q[s_idx] == tag_of(snp_addr_q));

  logic snoop_can_take;
  assign snoop_can_take = snoop_valid_i &&
                          (st_q == ST_IDLE || st_q == ST_REQ || st_q == ST_WB_REQ);

  always_comb begin
    st_d  = st_q;
    ret_d = ret_q;

    unique case (st_q)
      ST_IDLE: begin
        if (snoop_valid_i) begin
          ret_d = ST_IDLE;
          st_d  = ST_SNOOP;
        end else if (core_req_i) begin
          if (c_read_hit || c_write_hit_perm) begin
            st_d = ST_IDLE;
          end else if (c_write_hit_up) begin
            st_d = ST_REQ;
          end else begin
            st_d = victim_dirty ? ST_WB_DATA : ST_REQ;
          end
        end
      end

      ST_WB_DATA: begin
        if (data_req_gnt_i) st_d = ST_WB_DATA_WAIT;
      end

      ST_WB_DATA_WAIT: begin
        if (data_rsp_valid_i) st_d = ST_WB_REQ;
      end

      ST_WB_REQ: begin
        if (snoop_can_take) begin
          ret_d = ST_WB_REQ;
          st_d  = ST_SNOOP;
        end else if (req_gnt_i) begin
          st_d = ST_WB_WAIT;
        end
      end

      ST_WB_WAIT: begin
        if (resp_valid_i && resp_msg_i == MSG_PUT_ACK) st_d = ST_REQ;
      end

      ST_REQ: begin
        if (snoop_can_take) begin
          ret_d = ST_REQ;
          st_d  = ST_SNOOP;
        end else if (req_gnt_i) begin
          st_d = ST_WAIT_PERM;
        end
      end

      ST_WAIT_PERM: begin
        if (resp_valid_i) st_d = ST_FILL_DATA;
      end

      ST_FILL_DATA: begin
        if (data_req_gnt_i) st_d = ST_FILL_WAIT;
      end

      ST_FILL_WAIT: begin
        if (data_rsp_valid_i) st_d = ST_IDLE;
      end

      ST_SNOOP: begin
        if (s_present && (snp_cmd_q == MSG_FWD_GETS || snp_cmd_q == MSG_RECALL)) begin
          st_d = ST_SNOOP_WB;
        end else begin
          st_d = ret_q;
        end
      end

      ST_SNOOP_WB: begin
        if (data_req_gnt_i) st_d = ST_SNOOP_WB_WAIT;
      end

      ST_SNOOP_WB_WAIT: begin
        if (data_rsp_valid_i) st_d = ret_q;
      end

      default: st_d = ST_IDLE;
    endcase
  end

  integer i;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q          <= ST_IDLE;
      ret_q         <= ST_IDLE;
      req_addr_q    <= '0;
      req_we_q      <= 1'b0;
      req_be_q      <= '0;
      req_wdata_q   <= '0;
      pend_req_q    <= REQ_GETS;
      fill_msg_q    <= MSG_DATA_S;
      victim_addr_q <= '0;
      victim_data_q <= '0;
      snp_addr_q    <= '0;
      snp_cmd_q     <= MSG_INV;
      rvalid_q      <= 1'b0;
      rdata_q       <= '0;
      for (i = 0; i < CacheLines; i++) begin
        state_q[i] <= MESI_I;
        tag_q[i]   <= '0;
        data_q[i]  <= '0;
      end
    end else begin
      st_q     <= st_d;
      ret_q    <= ret_d;
      rvalid_q <= 1'b0;

      if (st_q == ST_IDLE && !snoop_valid_i && core_req_i) begin
        req_addr_q  <= core_addr_i;
        req_we_q    <= core_we_i;
        req_be_q    <= core_be_i;
        req_wdata_q <= core_wdata_i;
        pend_req_q  <= core_we_i ? REQ_GETM : REQ_GETS;

        if (!(c_read_hit || c_write_hit_perm || c_write_hit_up) && victim_dirty) begin
          victim_addr_q <= {tag_q[c_idx], c_idx, {LineOffW{1'b0}}};
          victim_data_q <= data_q[c_idx];
          state_q[c_idx] <= MESI_I;
        end

        if (c_read_hit) begin
          rdata_q  <= c_line[c_word*DataW +: DataW];
          rvalid_q <= 1'b1;
        end else if (c_write_hit_perm) begin
          data_q[c_idx][c_word*DataW +: DataW] <=
              merge_be(c_line[c_word*DataW +: DataW], core_wdata_i, core_be_i);
          if (c_state == MESI_E) state_q[c_idx] <= MESI_M;
          rvalid_q <= 1'b1;
        end
      end

      if (st_q == ST_FILL_WAIT && data_rsp_valid_i) begin
        data_q[idx_of(req_addr_q)] <= data_rsp_rdata_i;
        tag_q [idx_of(req_addr_q)] <= tag_of(req_addr_q);

        unique case (fill_msg_q)
          MSG_DATA_S: state_q[idx_of(req_addr_q)] <= MESI_S;
          MSG_DATA_E: state_q[idx_of(req_addr_q)] <= MESI_E;
          MSG_DATA_M: state_q[idx_of(req_addr_q)] <= MESI_M;
          default:    state_q[idx_of(req_addr_q)] <= MESI_S;
        endcase

        if (req_we_q) begin
          data_q[idx_of(req_addr_q)][word_index(req_addr_q)*DataW +: DataW] <=
              merge_be(data_rsp_rdata_i[word_index(req_addr_q)*DataW +: DataW],
                       req_wdata_q, req_be_q);
          state_q[idx_of(req_addr_q)] <= MESI_M;
          rdata_q <= req_wdata_q;
        end else begin
          rdata_q <= data_rsp_rdata_i[word_index(req_addr_q)*DataW +: DataW];
        end
        rvalid_q <= 1'b1;
      end

      if (st_q == ST_WAIT_PERM && resp_valid_i) begin
        fill_msg_q <= resp_msg_i;
      end

      if (st_q == ST_SNOOP) begin
        if (s_present) begin
          unique case (snp_cmd_q)
            MSG_INV:      state_q[s_idx] <= MESI_I;
            MSG_FWD_GETS: state_q[s_idx] <= MESI_S;
            MSG_RECALL:   state_q[s_idx] <= MESI_I;
            default: ;
          endcase
        end
      end

      if (snoop_valid_i &&
          (st_q == ST_IDLE || st_q == ST_REQ || st_q == ST_WB_REQ)) begin
        snp_addr_q <= snoop_addr_i;
        snp_cmd_q  <= snoop_cmd_i;
      end
    end
  end

  assign core_gnt_o    = core_req_i && (st_q == ST_IDLE) && !snoop_valid_i;
  assign core_rvalid_o = rvalid_q;
  assign core_rdata_o  = rdata_q;

  always_comb begin
    req_valid_o = 1'b0;
    req_type_o  = REQ_GETS;
    req_addr_o  = line_addr(req_addr_q);

    unique case (st_q)
      ST_WB_REQ: begin
        req_valid_o = 1'b1;
        req_type_o  = REQ_PUTM;
        req_addr_o  = line_addr(victim_addr_q);
      end
      ST_REQ: begin
        req_valid_o = 1'b1;
        req_type_o  = pend_req_q;
      end
      default: ;
    endcase
  end

  always_comb begin
    data_req_valid_o = 1'b0;
    data_req_we_o    = 1'b0;
    data_req_addr_o  = line_addr(req_addr_q);
    data_req_wdata_o = '0;

    unique case (st_q)
      ST_WB_DATA: begin
        data_req_valid_o = 1'b1;
        data_req_we_o    = 1'b1;
        data_req_addr_o  = line_addr(victim_addr_q);
        data_req_wdata_o = victim_data_q;
      end
      ST_FILL_DATA: begin
        data_req_valid_o = 1'b1;
        data_req_we_o    = 1'b0;
        data_req_addr_o  = line_addr(req_addr_q);
      end
      ST_SNOOP_WB: begin
        data_req_valid_o = 1'b1;
        data_req_we_o    = 1'b1;
        data_req_addr_o  = line_addr(snp_addr_q);
        data_req_wdata_o = data_q[s_idx];
      end
      default: ;
    endcase
  end

  assign snoop_rsp_valid_o = (st_q == ST_SNOOP &&
                              (!s_present || snp_cmd_q == MSG_INV)) ||
                             (st_q == ST_SNOOP_WB_WAIT && data_rsp_valid_i);
  assign snoop_rsp_type_o  = (snp_cmd_q == MSG_INV) ? RSP_INV_ACK : RSP_DATA;

endmodule
