// ============================================================
// ibex_directory_controller.sv
//
// Directory-based MESI coherence controller — Đồ án 1.
//
//   - Giữ SỔ CÁI cho mỗi memory line: {dir_state_e, sharer_vec_t}.
//   - TUẦN TỰ HÓA: round-robin chọn 1 core/lần, xử lý trọn vẹn rồi
//     mới nhận request kế (điểm ordering của hệ MESI).
//   - Sinh đúng các MSG_* / snoop mà ibex_l1_dcache đang chờ.
//
//   BACKING MEMORY: tạm để NỘI BỘ dạng line-array (1 "bank" duy
//   nhất) để verify coherence ở Bước 2. Sang Bước 3 sẽ thay bằng
//   truy cập SRAM/bank thật qua crossbar — chỉ phải đổi khối mem,
//   phần sổ cái + FSM giữ nguyên.
//
//   Directory KHÔNG phân biệt E/M: cả hai là DIR_EM (1 owner).
//   Owner tự gửi data khi bị FWD_GETS/RECALL nên directory luôn
//   ghi lại mem từ flush (kể cả owner đang E clean — vô hại).
// ============================================================

module ibex_directory_controller import ibex_coherence_pkg::*; #(
  parameter int unsigned MemLines = 256
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  // ---------- request : cache → dir ----------
  input  logic        [NumCores-1:0]   req_valid_i,
  input  coh_req_e                     req_type_i  [NumCores],
  input  logic [AddrW-1:0]             req_addr_i  [NumCores],
  input  logic [LineWords*DataW-1:0]   req_data_i  [NumCores],
  output logic        [NumCores-1:0]   req_gnt_o,

  // ---------- response : dir → cache (cho request của core) ----------
  output logic        [NumCores-1:0]   resp_valid_o,
  output coh_msg_e                     resp_msg_o  [NumCores],
  output logic [LineWords*DataW-1:0]   resp_data_o [NumCores],

  // ---------- snoop : dir → cache ----------
  output logic        [NumCores-1:0]   snoop_valid_o,
  output coh_msg_e                     snoop_cmd_o [NumCores],
  output logic [AddrW-1:0]             snoop_addr_o[NumCores],

  // ---------- snoop response : cache → dir ----------
  input  logic        [NumCores-1:0]   snoop_rsp_valid_i,
  input  coh_rsp_e                     snoop_rsp_type_i [NumCores],
  input  logic [LineWords*DataW-1:0]   snoop_rsp_data_i [NumCores]
);

  localparam int unsigned LineW = LineWords * DataW;
  localparam int unsigned LiW   = $clog2(MemLines);   // bit chọn line trong mem

  function automatic logic [LiW-1:0] line_of (input logic [AddrW-1:0] a);
    return a[LineOffW +: LiW];
  endfunction

  // ----------------------------------------------------------
  // Sổ cái + backing memory (1 bank nội bộ — tạm cho Bước 2)
  // ----------------------------------------------------------
  dir_state_e   dstate_q  [MemLines];
  sharer_vec_t  sharers_q [MemLines];
  logic [LineW-1:0] mem_q [MemLines];

  // ----------------------------------------------------------
  // FSM
  // ----------------------------------------------------------
  typedef enum logic [2:0] {
    D_IDLE,
    D_FWD,      // GetS tới line đang EM: bắt owner flush → S
    D_RECALL,   // GetM tới line đang EM: bắt owner flush → I
    D_INV,      // GetM tới line đang S : invalidate các sharer khác
    D_RESP      // phát kết quả cho requestor
  } dstate_e;

  dstate_e st_q, st_d;

  // round-robin pointer
  logic [$clog2(NumCores)-1:0] rr_q, rr_d;

  // thanh ghi giao dịch đang xử lý
  logic [$clog2(NumCores)-1:0] cur_core_q;
  coh_req_e                    cur_type_q;
  logic [AddrW-1:0]            cur_addr_q;
  logic [LiW-1:0]              cur_li_q;
  sharer_vec_t                 inv_pend_q;   // sharer còn phải INV
  coh_msg_e                    resp_msg_q;
  logic [LineW-1:0]            resp_data_q;
  logic [$clog2(NumCores)-1:0] owner_q;      // owner khi EM

  // mask của core hiện tại
  function automatic sharer_vec_t core_mask (input logic [$clog2(NumCores)-1:0] c);
    sharer_vec_t m;
    m = '0; m[c] = 1'b1;
    return m;
  endfunction

  // owner id từ sharer one-hot (EM)
  function automatic logic [$clog2(NumCores)-1:0] onehot_id (input sharer_vec_t v);
    logic [$clog2(NumCores)-1:0] id;
    id = '0;
    for (int k = 0; k < NumCores; k++) if (v[k]) id = k[$clog2(NumCores)-1:0];
    return id;
  endfunction

  // ----------------------------------------------------------
  // Arbitration (round-robin) — chỉ ở D_IDLE
  // ----------------------------------------------------------
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

  // tiện đọc thông tin sharer của line đang xử lý
  sharer_vec_t cur_sharers;
  dir_state_e  cur_dstate;
  assign cur_sharers = sharers_q[cur_li_q];
  assign cur_dstate  = dstate_q [cur_li_q];

  // sharer khác requestor (cần INV khi GetM trên S)
  sharer_vec_t others_at_decode;
  assign others_at_decode = sharers_q[line_of(req_addr_i[win_id])] &
                            ~core_mask(win_id);

  // ==========================================================
  // Next-state
  // ==========================================================
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
                default: st_d = D_RESP;        // U → E, S → S
              endcase
            end
            REQ_GETM: begin
              unique case (dstate_q[line_of(req_addr_i[win_id])])
                DIR_EM:  st_d = D_RECALL;
                DIR_S:   st_d = (others_at_decode != '0) ? D_INV : D_RESP;
                default: st_d = D_RESP;        // U → M
              endcase
            end
            default: st_d = D_RESP;
          endcase
        end
      end

      D_FWD:    if (snoop_rsp_valid_i[owner_q]) st_d = D_RESP;
      D_RECALL: if (snoop_rsp_valid_i[owner_q]) st_d = D_RESP;
      D_INV:    if (inv_pend_q == '0)           st_d = D_RESP;

      D_RESP:   st_d = D_IDLE;
      default:  st_d = D_IDLE;
    endcase
  end

  // ==========================================================
  // Sequential
  // ==========================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q  <= D_IDLE;
      rr_q  <= '0;
      dstate_q  <= '{default: DIR_U};
      sharers_q <= '{default: '0};
      mem_q      <= '{default: '0};
      cur_core_q <= '0;
      cur_type_q <= REQ_GETS;
      cur_addr_q <= '0;
      cur_li_q   <= '0;
      inv_pend_q <= '0;
      resp_msg_q <= MSG_DATA_S;
      resp_data_q <= '0;
      owner_q    <= '0;
    end else begin
      st_q <= st_d;
      rr_q <= rr_d;

      // -------- D_IDLE : latch + giải quyết nhánh "nhanh" --------
      if (st_q == D_IDLE && win_val) begin
        cur_core_q <= win_id;
        cur_type_q <= req_type_i[win_id];
        cur_addr_q <= req_addr_i[win_id];
        cur_li_q   <= line_of(req_addr_i[win_id]);
        owner_q    <= onehot_id(sharers_q[line_of(req_addr_i[win_id])]);

        unique case (req_type_i[win_id])
          // ---- writeback ----
          REQ_PUTM: begin
            mem_q   [line_of(req_addr_i[win_id])] <= req_data_i[win_id];
            sharers_q[line_of(req_addr_i[win_id])] <= '0;
            dstate_q [line_of(req_addr_i[win_id])] <= DIR_U;
            resp_msg_q  <= MSG_PUT_ACK;
          end
          // ---- read miss ----
          REQ_GETS: begin
            unique case (dstate_q[line_of(req_addr_i[win_id])])
              DIR_U: begin                       // sharer duy nhất → E
                sharers_q[line_of(req_addr_i[win_id])] <= core_mask(win_id);
                dstate_q [line_of(req_addr_i[win_id])] <= DIR_EM;
                resp_msg_q  <= MSG_DATA_E;
                resp_data_q <= mem_q[line_of(req_addr_i[win_id])];
              end
              DIR_S: begin                       // thêm sharer → S
                sharers_q[line_of(req_addr_i[win_id])] <=
                    sharers_q[line_of(req_addr_i[win_id])] | core_mask(win_id);
                resp_msg_q  <= MSG_DATA_S;
                resp_data_q <= mem_q[line_of(req_addr_i[win_id])];
              end
              default: ;                          // EM → xử lý ở D_FWD
            endcase
          end
          // ---- write miss / upgrade ----
          REQ_GETM: begin
            unique case (dstate_q[line_of(req_addr_i[win_id])])
              DIR_U: begin
                sharers_q[line_of(req_addr_i[win_id])] <= core_mask(win_id);
                dstate_q [line_of(req_addr_i[win_id])] <= DIR_EM;
                resp_msg_q  <= MSG_DATA_M;
                resp_data_q <= mem_q[line_of(req_addr_i[win_id])];
              end
              DIR_S: begin
                if (others_at_decode == '0) begin // chỉ mình là sharer → cấp M ngay
                  sharers_q[line_of(req_addr_i[win_id])] <= core_mask(win_id);
                  dstate_q [line_of(req_addr_i[win_id])] <= DIR_EM;
                  resp_msg_q  <= MSG_DATA_M;
                  resp_data_q <= mem_q[line_of(req_addr_i[win_id])];
                end else begin
                  inv_pend_q  <= others_at_decode; // còn sharer khác → INV
                end
              end
              default: ;                          // EM → xử lý ở D_RECALL
            endcase
          end
          default: ;
        endcase
      end

      // -------- D_FWD : owner flush, hạ xuống S --------
      if (st_q == D_FWD && snoop_rsp_valid_i[owner_q]) begin
        if (snoop_rsp_type_i[owner_q] == RSP_DATA)
          mem_q[cur_li_q] <= snoop_rsp_data_i[owner_q];
        sharers_q[cur_li_q] <= sharers_q[cur_li_q] | core_mask(cur_core_q);
        dstate_q [cur_li_q] <= DIR_S;
        resp_msg_q  <= MSG_DATA_S;
        resp_data_q <= (snoop_rsp_type_i[owner_q] == RSP_DATA)
                       ? snoop_rsp_data_i[owner_q] : mem_q[cur_li_q];
      end

      // -------- D_RECALL : owner flush, hạ xuống I --------
      if (st_q == D_RECALL && snoop_rsp_valid_i[owner_q]) begin
        if (snoop_rsp_type_i[owner_q] == RSP_DATA)
          mem_q[cur_li_q] <= snoop_rsp_data_i[owner_q];
        sharers_q[cur_li_q] <= core_mask(cur_core_q);
        dstate_q [cur_li_q] <= DIR_EM;
        resp_msg_q  <= MSG_DATA_M;
        resp_data_q <= (snoop_rsp_type_i[owner_q] == RSP_DATA)
                       ? snoop_rsp_data_i[owner_q] : mem_q[cur_li_q];
      end

      // -------- D_INV : gom Inv-Ack từ các sharer khác --------
      if (st_q == D_INV) begin
        for (int c = 0; c < NumCores; c++) begin
          if (inv_pend_q[c] && snoop_rsp_valid_i[c] &&
              snoop_rsp_type_i[c] == RSP_INV_ACK)
            inv_pend_q[c] <= 1'b0;
        end
        // khi sạch → cấp M (cập nhật ở cùng cycle chuyển D_RESP)
        if (inv_pend_q == '0) begin
          sharers_q[cur_li_q] <= core_mask(cur_core_q);
          dstate_q [cur_li_q] <= DIR_EM;
          resp_msg_q  <= MSG_DATA_M;
          resp_data_q <= mem_q[cur_li_q];
        end
      end
    end
  end

  // ==========================================================
  // Outputs (comb)
  // ==========================================================
  always_comb begin
    // defaults
    req_gnt_o     = '0;
    resp_valid_o  = '0;
    snoop_valid_o = '0;
    for (int c = 0; c < NumCores; c++) begin
      resp_msg_o[c]  = MSG_DATA_S;
      resp_data_o[c] = '0;
      snoop_cmd_o[c] = MSG_INV;
      snoop_addr_o[c]= '0;
    end

    // grant: cùng cycle chọn winner ở D_IDLE
    if (st_q == D_IDLE && win_val) req_gnt_o[win_id] = 1'b1;

    // snoop trong các state chờ
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
      for (int c = 0; c < NumCores; c++) if (inv_pend_q[c]) begin
        snoop_valid_o[c] = 1'b1;
        snoop_cmd_o  [c] = MSG_INV;
        snoop_addr_o [c] = cur_addr_q;
      end
    end

    // response cho requestor
    if (st_q == D_RESP) begin
      resp_valid_o[cur_core_q] = 1'b1;
      resp_msg_o  [cur_core_q] = resp_msg_q;
      resp_data_o [cur_core_q] = resp_data_q;
    end
  end

endmodule
