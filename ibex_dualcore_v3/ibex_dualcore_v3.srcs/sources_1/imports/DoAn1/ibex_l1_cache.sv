// ============================================================
// ibex_l1_dcache.sv
//
// L1 Data Cache — directory-based MESI, BLOCKING (1 outstanding).
// Đồ án 1 — dual-core Ibex + crossbar + MESI.
//
//   - Phía CORE : OBI slave (req/gnt/addr/we/be/wdata/rvalid/rdata),
//                 trùng giao thức với ibex_shared_sram.
//   - Phía DIR  : master phát request (GetS/GetM/PutM) + nhận
//                 command/data (MSG_*), và một kênh snoop riêng để
//                 directory hạ trạng thái line (INV/FWD_GETS/RECALL).
//
//   Tổ chức: direct-mapped, write-back, write-allocate.
//   Line = LineBytes (16B = 4 word) lấy từ ibex_coherence_pkg.
//
//   Đơn giản hóa có chủ ý (sẽ tinh chỉnh khi ghép directory):
//     * Eviction line clean (S/E) là SILENT — không báo directory.
//       Directory có thể còn coi ta là sharer; khi nhận INV cho line
//       không còn → ta vẫn trả RSP_INV_ACK (no-op), nên vẫn đúng.
//       Eviction line dirty (M) BẮT BUỘC PutM.
//     * Snoop được phục vụ ở IDLE và ở 2 state "đang chờ directory
//       NHẬN request của mình" (REQ/WB_REQ) — đủ để phá deadlock khi
//       core khác cần ta flush trước khi request của ta được nhận.
//       Khi đã vào WAIT (directory đang phục vụ ta) thì directory
//       serialize nên không snoop ta nữa.
// ============================================================

module ibex_l1_dcache import ibex_coherence_pkg::*; #(
  parameter int unsigned CacheLines = 16
) (
  input  logic                       clk_i,
  input  logic                       rst_ni,

  // ---------------- Phía CORE : OBI slave ----------------
  input  logic                       core_req_i,
  output logic                       core_gnt_o,
  input  logic [31:0]                core_addr_i,
  input  logic                       core_we_i,
  input  logic [3:0]                 core_be_i,
  input  logic [31:0]                core_wdata_i,
  output logic                       core_rvalid_o,
  output logic [31:0]                core_rdata_o,

  // ---------- Phía DIR : uplink request (master) ----------
  output logic                       req_valid_o,
  output coh_req_e                   req_type_o,
  output logic [AddrW-1:0]           req_addr_o,    // line-aligned
  output logic [LineWords*DataW-1:0] req_data_o,    // chỉ dùng cho PUTM
  input  logic                       req_gnt_i,

  // ---------- Phía DIR : downlink cho request của ta ----------
  input  logic                       resp_valid_i,
  input  coh_msg_e                   resp_msg_i,    // DATA_S/E/M | PUT_ACK
  input  logic [LineWords*DataW-1:0] resp_data_i,

  // ---------- Phía DIR : snoop (directory khởi xướng) ----------
  input  logic                       snoop_valid_i,
  input  coh_msg_e                   snoop_cmd_i,   // INV | FWD_GETS | RECALL
  input  logic [AddrW-1:0]           snoop_addr_i,
  output logic                       snoop_rsp_valid_o,
  output coh_rsp_e                   snoop_rsp_type_o,
  output logic [LineWords*DataW-1:0] snoop_rsp_data_o
);

  // ----------------------------------------------------------
  // Local params & address breakdown
  //   addr = | tag | index | line-offset |
  // ----------------------------------------------------------
  localparam int unsigned LineW  = LineWords * DataW;          // 128
  localparam int unsigned IndexW = $clog2(CacheLines);         // 4
  localparam int unsigned TagW   = AddrW - IndexW - LineOffW;  // 24

  function automatic logic [IndexW-1:0] idx_of (input logic [AddrW-1:0] a);
    return a[LineOffW +: IndexW];
  endfunction
  function automatic logic [TagW-1:0] tag_of (input logic [AddrW-1:0] a);
    return a[AddrW-1 -: TagW];
  endfunction

  // ----------------------------------------------------------
  // Storage
  // ----------------------------------------------------------
  mesi_state_e          state_q [CacheLines];
  logic [TagW-1:0]      tag_q   [CacheLines];
  logic [LineW-1:0]     data_q  [CacheLines];

  // ----------------------------------------------------------
  // FSM
  // ----------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE,
    ST_WB_REQ,    // phát PUTM victim, chờ gnt
    ST_WB_WAIT,   // chờ PUT_ACK
    ST_REQ,       // phát GetS/GetM, chờ gnt
    ST_WAIT,      // chờ DATA_S/E/M
    ST_SNOOP      // phục vụ snoop 1 cycle
  } state_e;

  state_e st_q, st_d;
  state_e ret_q, ret_d;          // state quay lại sau snoop

  // Latched core request (OBI: phải chốt vì addr/wdata không giữ sau gnt)
  logic [AddrW-1:0] req_addr_q;
  logic             req_we_q;
  logic [3:0]       req_be_q;
  logic [31:0]      req_wdata_q;
  coh_req_e         pend_req_q;          // GetS hay GetM cho refill

  // Latched snoop
  logic [AddrW-1:0] snp_addr_q;
  coh_msg_e         snp_cmd_q;

  // Output regs phía core
  logic             rvalid_q;
  logic [31:0]      rdata_q;

  // ----------------------------------------------------------
  // Combinational lookup cho request hiện trên cổng core (IDLE)
  // ----------------------------------------------------------
  logic [IndexW-1:0] c_idx;
  logic [TagW-1:0]   c_tag;
  logic              c_hit;
  mesi_state_e       c_state;
  logic [1:0]        c_word;          // word-offset trong line
  logic [LineW-1:0]  c_line;

  assign c_idx   = idx_of(core_addr_i);
  assign c_tag   = tag_of(core_addr_i);
  assign c_state = state_q[c_idx];
  assign c_hit   = (c_state != MESI_I) && (tag_q[c_idx] == c_tag);
  assign c_word  = word_index(core_addr_i);
  assign c_line  = data_q[c_idx];

  logic c_read_hit, c_write_hit_perm, c_write_hit_up;
  assign c_read_hit       = c_hit && (core_req_i && !core_we_i);
  assign c_write_hit_perm = c_hit && core_we_i && (c_state == MESI_M || c_state == MESI_E);
  assign c_write_hit_up   = c_hit && core_we_i && (c_state == MESI_S);

  // Victim cần writeback? (miss vào slot đang giữ line dirty/exclusive khác tag)
  logic        victim_dirty;
  assign victim_dirty = (state_q[c_idx] == MESI_M) || (state_q[c_idx] == MESI_E);

  // Snoop lookup
  logic [IndexW-1:0] s_idx;
  logic              s_present;
  assign s_idx     = idx_of(snp_addr_q);
  assign s_present = (state_q[s_idx] != MESI_I) && (tag_q[s_idx] == tag_of(snp_addr_q));

  // Có snoop đang chờ và ta ở state cho phép phục vụ?
  logic snoop_can_take;
  assign snoop_can_take = snoop_valid_i &&
                          (st_q == ST_IDLE || st_q == ST_REQ || st_q == ST_WB_REQ);

  // word-write áp byte-enable
  function automatic logic [31:0] merge_be (input logic [31:0] old_w,
                                            input logic [31:0] new_w,
                                            input logic [3:0]  be);
    logic [31:0] r;
    for (int b = 0; b < 4; b++)
      r[b*8 +: 8] = be[b] ? new_w[b*8 +: 8] : old_w[b*8 +: 8];
    return r;
  endfunction

  // ==========================================================
  // Next-state (comb)
  // ==========================================================
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
            st_d = ST_IDLE;                     // hit 1 cycle (rvalid ở cycle sau)
          end else if (c_write_hit_up) begin
            st_d = ST_REQ;                      // upgrade S->M
          end else begin                        // miss
            st_d = victim_dirty ? ST_WB_REQ : ST_REQ;
          end
        end
      end

      ST_WB_REQ: begin
        if (snoop_can_take) begin ret_d = ST_WB_REQ; st_d = ST_SNOOP; end
        else if (req_gnt_i)  st_d = ST_WB_WAIT;
      end

      ST_WB_WAIT: begin
        if (resp_valid_i && resp_msg_i == MSG_PUT_ACK) st_d = ST_REQ;
      end

      ST_REQ: begin
        if (snoop_can_take) begin ret_d = ST_REQ; st_d = ST_SNOOP; end
        else if (req_gnt_i)  st_d = ST_WAIT;
      end

      ST_WAIT: begin
        if (resp_valid_i) st_d = ST_IDLE;       // DATA_S/E/M → hoàn tất
      end

      ST_SNOOP: begin
        st_d = ret_q;                           // 1 cycle rồi quay lại
      end

      default: st_d = ST_IDLE;
    endcase
  end

  // ==========================================================
  // Datapath + state update (seq)
  // ==========================================================
  integer i;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q        <= ST_IDLE;
      ret_q       <= ST_IDLE;
      req_addr_q  <= '0;
      req_we_q    <= 1'b0;
      req_be_q    <= '0;
      req_wdata_q <= '0;
      pend_req_q  <= REQ_GETS;
      snp_addr_q  <= '0;
      snp_cmd_q   <= MSG_INV;
      rvalid_q    <= 1'b0;
      rdata_q     <= 32'h0;
      for (i = 0; i < CacheLines; i++) begin
        state_q[i] <= MESI_I;
        tag_q[i]   <= '0;
        data_q[i]  <= '0;
      end
    end else begin
      st_q     <= st_d;
      ret_q    <= ret_d;
      rvalid_q <= 1'b0;                          // mặc định 1-cycle pulse

      // ---------------- IDLE : hit & chốt request ----------------
      if (st_q == ST_IDLE && !snoop_valid_i && core_req_i) begin
        // chốt request (dùng cho miss/upgrade)
        req_addr_q  <= core_addr_i;
        req_we_q    <= core_we_i;
        req_be_q    <= core_be_i;
        req_wdata_q <= core_wdata_i;
        pend_req_q  <= core_we_i ? REQ_GETM : REQ_GETS;

        if (c_read_hit) begin
          rdata_q  <= c_line[c_word*DataW +: DataW];
          rvalid_q <= 1'b1;
        end else if (c_write_hit_perm) begin
          data_q[c_idx][c_word*DataW +: DataW] <=
              merge_be(c_line[c_word*DataW +: DataW], core_wdata_i, core_be_i);
          if (c_state == MESI_E) state_q[c_idx] <= MESI_M;   // E→M silent
          rvalid_q <= 1'b1;
        end
        // c_write_hit_up / miss : không rvalid ở đây, đi qua FSM
      end

      // ---------------- WAIT : nhận data/quyền từ directory ----------------
      if (st_q == ST_WAIT && resp_valid_i) begin
        // refill line (GetS/GetM-miss mang data; upgrade mang lại mem-line ≡ ta)
        data_q[idx_of(req_addr_q)] <= resp_data_i;
        tag_q [idx_of(req_addr_q)] <= tag_of(req_addr_q);

        unique case (resp_msg_i)
          MSG_DATA_S: state_q[idx_of(req_addr_q)] <= MESI_S;
          MSG_DATA_E: state_q[idx_of(req_addr_q)] <= MESI_E;
          MSG_DATA_M: state_q[idx_of(req_addr_q)] <= MESI_M;
          default:    state_q[idx_of(req_addr_q)] <= MESI_S;
        endcase

        // nếu là store: áp wdata vào đúng word + ép M
        if (req_we_q) begin
          data_q[idx_of(req_addr_q)][word_index(req_addr_q)*DataW +: DataW] <=
              merge_be(resp_data_i[word_index(req_addr_q)*DataW +: DataW],
                       req_wdata_q, req_be_q);
          state_q[idx_of(req_addr_q)] <= MESI_M;
          rdata_q  <= req_wdata_q;            // store: rdata không dùng
        end else begin
          rdata_q  <= resp_data_i[word_index(req_addr_q)*DataW +: DataW];
        end
        rvalid_q <= 1'b1;
      end

      // ---------------- SNOOP : hạ trạng thái + phát response ----------------
      if (st_q == ST_SNOOP) begin
        if (s_present) begin
          unique case (snp_cmd_q)
            MSG_INV:      state_q[s_idx] <= MESI_I;
            MSG_FWD_GETS: state_q[s_idx] <= MESI_S;   // owner xuống S
            MSG_RECALL:   state_q[s_idx] <= MESI_I;   // owner xuống I
            default: ;
          endcase
        end
      end

      // chốt snoop khi bắt đầu phục vụ
      if (snoop_valid_i &&
          (st_q == ST_IDLE || st_q == ST_REQ || st_q == ST_WB_REQ)) begin
        snp_addr_q <= snoop_addr_i;
        snp_cmd_q  <= snoop_cmd_i;
      end
    end
  end

  // ==========================================================
  // Outputs (comb)
  // ==========================================================
  // Core OBI
  assign core_gnt_o    = core_req_i && (st_q == ST_IDLE) && !snoop_valid_i;
  assign core_rvalid_o = rvalid_q;
  assign core_rdata_o  = rdata_q;

  // Uplink request
  always_comb begin
    req_valid_o = 1'b0;
    req_type_o  = REQ_GETS;
    req_addr_o  = line_addr(req_addr_q);
    req_data_o  = data_q[idx_of(req_addr_q)];   // victim line cho PUTM
    unique case (st_q)
      ST_WB_REQ: begin
        req_valid_o = 1'b1;
        req_type_o  = REQ_PUTM;
        // địa chỉ victim = tag victim + index hiện tại
        req_addr_o  = {tag_q[idx_of(req_addr_q)], idx_of(req_addr_q), {LineOffW{1'b0}}};
      end
      ST_REQ: begin
        req_valid_o = 1'b1;
        req_type_o  = pend_req_q;
      end
      default: ;
    endcase
  end

  // Snoop response
  assign snoop_rsp_valid_o = (st_q == ST_SNOOP);
  assign snoop_rsp_type_o  = (snp_cmd_q == MSG_INV) ? RSP_INV_ACK : RSP_DATA;
  assign snoop_rsp_data_o  = data_q[s_idx];

endmodule
