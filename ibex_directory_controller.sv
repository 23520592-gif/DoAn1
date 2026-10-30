// ============================================================
// ibex_directory_controller.sv
//
// Directory-based MESI permission controller.
// This block intentionally carries no line data. Caches flush/fill
// line data directly through ibex_cache_bank_crossbar; directory only
// serializes permission ownership and snoop acknowledgements.
// ============================================================

module ibex_directory_controller import ibex_coherence_pkg::*; #(
  parameter int unsigned MemLines = 256
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  // ---------- request: cache -> dir ----------
  input  logic        [NumCores-1:0]   req_valid_i,
  input  coh_req_e                     req_type_i  [NumCores],
  input  logic [AddrW-1:0]             req_addr_i  [NumCores],
  output logic        [NumCores-1:0]   req_gnt_o,

  // ---------- response: dir -> cache ----------
  output logic        [NumCores-1:0]   resp_valid_o,
  output coh_msg_e                     resp_msg_o  [NumCores],

  // ---------- snoop: dir -> cache ----------
  output logic        [NumCores-1:0]   snoop_valid_o,
  output coh_msg_e                     snoop_cmd_o [NumCores],
  output logic [AddrW-1:0]             snoop_addr_o[NumCores],

  // ---------- snoop response: cache -> dir ----------
  input  logic        [NumCores-1:0]   snoop_rsp_valid_i,
  input  coh_rsp_e                     snoop_rsp_type_i [NumCores]
);

  localparam int unsigned LiW = $clog2(MemLines);

  function automatic logic [LiW-1:0] line_of(input logic [AddrW-1:0] a);
    return a[LineOffW +: LiW];
  endfunction

  dir_state_e  dstate_q  [MemLines];
  sharer_vec_t sharers_q [MemLines];

  typedef enum logic [2:0] {
    D_IDLE,
    D_FWD,
    D_RECALL,
    D_INV,
    D_RESP
  } dstate_e;

  dstate_e st_q, st_d;

  logic [$clog2(NumCores)-1:0] rr_q, rr_d;
  logic [$clog2(NumCores)-1:0] cur_core_q;
  coh_req_e                    cur_type_q;
  logic [AddrW-1:0]            cur_addr_q;
  logic [LiW-1:0]              cur_li_q;
  sharer_vec_t                 inv_pend_q;
  coh_msg_e                    resp_msg_q;
  logic [$clog2(NumCores)-1:0] owner_q;

  function automatic sharer_vec_t core_mask(input logic [$clog2(NumCores)-1:0] c);
    sharer_vec_t m;
    m = '0;
    m[c] = 1'b1;
    return m;
  endfunction

  function automatic logic [$clog2(NumCores)-1:0] onehot_id(input sharer_vec_t v);
    logic [$clog2(NumCores)-1:0] id;
    id = '0;
    for (int k = 0; k < NumCores; k++) begin
      if (v[k]) id = k[$clog2(NumCores)-1:0];
    end
    return id;
  endfunction

  logic                        win_val;
  logic [$clog2(NumCores)-1:0] win_id;

  always_comb begin
    win_val = 1'b0;
    win_id  = '0;
    for (int k = 0; k < NumCores; k++) begin
      automatic int unsigned ix = (int'(rr_q) + k) % NumCores;
      if (req_valid_i[ix] && !win_val) begin
        win_val = 1'b1;
        win_id  = ix[$clog2(NumCores)-1:0];
      end
    end
  end

  sharer_vec_t others_at_decode;
  assign others_at_decode = sharers_q[line_of(req_addr_i[win_id])] & ~core_mask(win_id);

  always_comb begin
    st_d = st_q;
    rr_d = rr_q;

    unique case (st_q)
      D_IDLE: begin
        if (win_val) begin
          rr_d = (int'(win_id) == NumCores-1) ? '0 : ($clog2(NumCores))'(win_id + 1'b1);
          unique case (req_type_i[win_id])
            REQ_PUTM: st_d = D_RESP;
            REQ_GETS: begin
              unique case (dstate_q[line_of(req_addr_i[win_id])])
                DIR_EM:  st_d = D_FWD;
                default: st_d = D_RESP;
              endcase
            end
            REQ_GETM: begin
              unique case (dstate_q[line_of(req_addr_i[win_id])])
                DIR_EM:  st_d = D_RECALL;
                DIR_S:   st_d = (others_at_decode != '0) ? D_INV : D_RESP;
                default: st_d = D_RESP;
              endcase
            end
            default: st_d = D_RESP;
          endcase
        end
      end

      D_FWD: begin
        if (snoop_rsp_valid_i[owner_q] && snoop_rsp_type_i[owner_q] == RSP_DATA) st_d = D_RESP;
      end

      D_RECALL: begin
        if (snoop_rsp_valid_i[owner_q] && snoop_rsp_type_i[owner_q] == RSP_DATA) st_d = D_RESP;
      end

      D_INV: begin
        if (inv_pend_q == '0) st_d = D_RESP;
      end

      D_RESP:  st_d = D_IDLE;
      default: st_d = D_IDLE;
    endcase
  end

  integer mi;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q <= D_IDLE;
      rr_q <= '0;
      for (mi = 0; mi < MemLines; mi++) begin
        dstate_q[mi]  <= DIR_U;
        sharers_q[mi] <= '0;
      end
      cur_core_q <= '0;
      cur_type_q <= REQ_GETS;
      cur_addr_q <= '0;
      cur_li_q   <= '0;
      inv_pend_q <= '0;
      resp_msg_q <= MSG_DATA_S;
      owner_q    <= '0;
    end else begin
      st_q <= st_d;
      rr_q <= rr_d;

      if (st_q == D_IDLE && win_val) begin
        cur_core_q <= win_id;
        cur_type_q <= req_type_i[win_id];
        cur_addr_q <= req_addr_i[win_id];
        cur_li_q   <= line_of(req_addr_i[win_id]);
        owner_q    <= onehot_id(sharers_q[line_of(req_addr_i[win_id])]);

        unique case (req_type_i[win_id])
          REQ_PUTM: begin
            if (sharers_q[line_of(req_addr_i[win_id])] == core_mask(win_id)) begin
              sharers_q[line_of(req_addr_i[win_id])] <= '0;
              dstate_q [line_of(req_addr_i[win_id])] <= DIR_U;
            end
            resp_msg_q <= MSG_PUT_ACK;
          end

          REQ_GETS: begin
            unique case (dstate_q[line_of(req_addr_i[win_id])])
              DIR_U: begin
                sharers_q[line_of(req_addr_i[win_id])] <= core_mask(win_id);
                dstate_q [line_of(req_addr_i[win_id])] <= DIR_EM;
                resp_msg_q <= MSG_DATA_E;
              end
              DIR_S: begin
                sharers_q[line_of(req_addr_i[win_id])] <=
                    sharers_q[line_of(req_addr_i[win_id])] | core_mask(win_id);
                resp_msg_q <= MSG_DATA_S;
              end
              default: ;
            endcase
          end

          REQ_GETM: begin
            unique case (dstate_q[line_of(req_addr_i[win_id])])
              DIR_U: begin
                sharers_q[line_of(req_addr_i[win_id])] <= core_mask(win_id);
                dstate_q [line_of(req_addr_i[win_id])] <= DIR_EM;
                resp_msg_q <= MSG_DATA_M;
              end
              DIR_S: begin
                if (others_at_decode == '0) begin
                  sharers_q[line_of(req_addr_i[win_id])] <= core_mask(win_id);
                  dstate_q [line_of(req_addr_i[win_id])] <= DIR_EM;
                  resp_msg_q <= MSG_DATA_M;
                end else begin
                  inv_pend_q <= others_at_decode;
                end
              end
              default: ;
            endcase
          end
          default: ;
        endcase
      end

      if (st_q == D_FWD && snoop_rsp_valid_i[owner_q] &&
          snoop_rsp_type_i[owner_q] == RSP_DATA) begin
        sharers_q[cur_li_q] <= sharers_q[cur_li_q] | core_mask(cur_core_q);
        dstate_q [cur_li_q] <= DIR_S;
        resp_msg_q <= MSG_DATA_S;
      end

      if (st_q == D_RECALL && snoop_rsp_valid_i[owner_q] &&
          snoop_rsp_type_i[owner_q] == RSP_DATA) begin
        sharers_q[cur_li_q] <= core_mask(cur_core_q);
        dstate_q [cur_li_q] <= DIR_EM;
        resp_msg_q <= MSG_DATA_M;
      end

      if (st_q == D_INV) begin
        for (int c = 0; c < NumCores; c++) begin
          if (inv_pend_q[c] && snoop_rsp_valid_i[c] &&
              snoop_rsp_type_i[c] == RSP_INV_ACK) begin
            inv_pend_q[c] <= 1'b0;
          end
        end
        if (inv_pend_q == '0) begin
          sharers_q[cur_li_q] <= core_mask(cur_core_q);
          dstate_q [cur_li_q] <= DIR_EM;
          resp_msg_q <= MSG_DATA_M;
        end
      end
    end
  end

  always_comb begin
    req_gnt_o     = '0;
    resp_valid_o  = '0;
    snoop_valid_o = '0;

    for (int c = 0; c < NumCores; c++) begin
      resp_msg_o[c]   = MSG_DATA_S;
      snoop_cmd_o[c]  = MSG_INV;
      snoop_addr_o[c] = '0;
    end

    if (st_q == D_IDLE && win_val) req_gnt_o[win_id] = 1'b1;

    if (st_q == D_FWD) begin
      snoop_valid_o[owner_q] = 1'b1;
      snoop_cmd_o  [owner_q] = MSG_FWD_GETS;
      snoop_addr_o [owner_q] = cur_addr_q;
    end

    if (st_q == D_RECALL) begin
      snoop_valid_o[owner_q] = 1'b1;
      snoop_cmd_o  [owner_q] = MSG_RECALL;
      snoop_addr_o [owner_q] = cur_addr_q;
    end

    if (st_q == D_INV) begin
      for (int c = 0; c < NumCores; c++) begin
        if (inv_pend_q[c]) begin
          snoop_valid_o[c] = 1'b1;
          snoop_cmd_o[c]   = MSG_INV;
          snoop_addr_o[c]  = cur_addr_q;
        end
      end
    end

    if (st_q == D_RESP) begin
      resp_valid_o[cur_core_q] = 1'b1;
      resp_msg_o  [cur_core_q] = resp_msg_q;
    end
  end

endmodule
