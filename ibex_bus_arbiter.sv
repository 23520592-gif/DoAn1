// ============================================================
// ibex_bus_arbiter.sv
//
// N-Master OBI Bus Arbiter
//
// Nâng cấp từ ibex_obi_arbiter (2 master cố định) lên N master
// có thể cấu hình qua parameter.
//
// Tính năng:
//   - Round-robin fairness giữa N master
//   - OBI-compliant: gnt cùng cycle với req
//   - busy_q chặn request mới khi đang chờ read response
//   - Performance counters: contention, total cycles, busy cycles
//
// Parameters:
//   N_MASTERS : số lượng master (mặc định 2, có thể mở rộng)
//   DATA_W    : độ rộng data bus (mặc định 32-bit)
//   ADDR_W    : độ rộng address bus (mặc định 32-bit)
// ============================================================

`include "prim_assert.sv"

module ibex_bus_arbiter #(
  parameter int unsigned N_MASTERS = 2,
  parameter int unsigned DATA_W    = 32,
  parameter int unsigned ADDR_W    = 32
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,

  // ----------------------------------------------------------
  // OBI Slave Ports — từ N Masters (packed arrays)
  // ----------------------------------------------------------
  input  logic [N_MASTERS-1:0]          req_i,
  output logic [N_MASTERS-1:0]          gnt_o,
  input  logic [N_MASTERS-1:0][ADDR_W-1:0] addr_i,
  input  logic [N_MASTERS-1:0]          we_i,
  input  logic [N_MASTERS-1:0][3:0]     be_i,
  input  logic [N_MASTERS-1:0][DATA_W-1:0] wdata_i,
  output logic [N_MASTERS-1:0]          rvalid_o,
  output logic [N_MASTERS-1:0][DATA_W-1:0] rdata_o,

  // ----------------------------------------------------------
  // OBI Master Port — đến Shared SRAM (Slave)
  // ----------------------------------------------------------
  output logic                          sram_req_o,
  input  logic                          sram_gnt_i,
  output logic [ADDR_W-1:0]             sram_addr_o,
  output logic                          sram_we_o,
  output logic [3:0]                    sram_be_o,
  output logic [DATA_W-1:0]             sram_wdata_o,
  input  logic                          sram_rvalid_i,
  input  logic [DATA_W-1:0]             sram_rdata_i,

  // ----------------------------------------------------------
  // Performance Counters (cho Bus Monitor / báo cáo)
  // ----------------------------------------------------------
  output logic [31:0]                   perf_contention_cnt_o,
  output logic [31:0]                   perf_total_req_cnt_o,
  output logic [31:0]                   perf_busy_cycles_cnt_o
);

  // ----------------------------------------------------------
  // Kiểm tra parameter hợp lệ
  // ----------------------------------------------------------
  `ASSERT_INIT(NMastersGe2, N_MASTERS >= 2)
  `ASSERT_INIT(NMastersLe16, N_MASTERS <= 16)

  // ----------------------------------------------------------
  // Internal Signals
  // ----------------------------------------------------------

  // Index của winner hiện tại (log2 của N_MASTERS bits)
  localparam int unsigned IDX_W = $clog2(N_MASTERS);

  // Round-robin pointer: trỏ đến master được ưu tiên tiếp theo
  logic [IDX_W-1:0] rr_ptr_q;     // pointer hiện tại (registered)
  logic [IDX_W-1:0] rr_ptr_next;  // pointer kỳ tiếp theo

  // Winner của cycle hiện tại
  logic [IDX_W-1:0] winner_idx;
  logic             any_winner;

  // Arbiter state
  logic             busy_q;        // đang chờ read response
  logic [IDX_W-1:0] winner_q;     // winner đang được serve (response phase)

  // any request
  logic any_req;
  assign any_req = |req_i;

  // ----------------------------------------------------------
  // Round-Robin Arbitration
  //
  // Thuật toán: bắt đầu từ rr_ptr_q, quét vòng tròn
  // tìm master đầu tiên có req=1.
  // Đảm bảo: mỗi master đều được phục vụ theo lượt.
  // ----------------------------------------------------------
  always_comb begin
    winner_idx = '0;
    any_winner = 1'b0;

    // Quét từ rr_ptr_q đến N_MASTERS-1, rồi từ 0 đến rr_ptr_q-1
    for (int i = 0; i < N_MASTERS; i++) begin
      // Tính index theo round-robin không dùng automatic
      if (req_i[(int'(rr_ptr_q) + i) % N_MASTERS] && !any_winner) begin
        winner_idx = IDX_W'((int'(rr_ptr_q) + i) % N_MASTERS);
        any_winner = 1'b1;
      end
    end
  end

  // ----------------------------------------------------------
  // SRAM Request: chỉ issue khi có winner và không busy
  // ----------------------------------------------------------
  assign sram_req_o = any_winner & ~busy_q;

  // ----------------------------------------------------------
  // Address Phase Mux: forward winner đến SRAM
  // ----------------------------------------------------------
  assign sram_addr_o  = addr_i [winner_idx];
  assign sram_we_o    = we_i   [winner_idx];
  assign sram_be_o    = be_i   [winner_idx];
  assign sram_wdata_o = wdata_i[winner_idx];

  // ----------------------------------------------------------
  // Grant Generation
  // ----------------------------------------------------------
  always_comb begin
    gnt_o = '0;
    if (sram_req_o && sram_gnt_i) begin
      gnt_o[winner_idx] = 1'b1;
    end
  end

  // ----------------------------------------------------------
  // Round-Robin Pointer Update
  //
  // Sau mỗi transaction được grant, pointer tiến 1 bước
  // để master tiếp theo được ưu tiên lần sau.
  // ----------------------------------------------------------
  always_comb begin
    rr_ptr_next = rr_ptr_q;
    if (sram_req_o && sram_gnt_i) begin
      // Tiến pointer đến master ngay sau winner
      rr_ptr_next = IDX_W'((int'(winner_idx) + 1) % N_MASTERS);
    end
  end

  // ----------------------------------------------------------
  // Sequential State
  // ----------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q     <= 1'b0;
      winner_q   <= '0;
      rr_ptr_q   <= '0;
    end else begin
      // Cập nhật round-robin pointer
      rr_ptr_q <= rr_ptr_next;

      // Latch winner khi address phase hoàn tất
      if (sram_req_o && sram_gnt_i) begin
        winner_q <= winner_idx;
        // Busy cho CẢ read lẫn write: SRAM phát rvalid 1 cycle sau mọi grant,
        // giữ winner_q ổn định để route response về đúng master.
        busy_q <= 1'b1;
      end

      // Clear busy khi SRAM trả response
      if (busy_q && sram_rvalid_i) begin
        busy_q <= 1'b0;
      end
    end
  end

  // ----------------------------------------------------------
  // Response Phase: route rvalid/rdata về đúng master
  // ----------------------------------------------------------
  always_comb begin
    rvalid_o = '0;
    rdata_o  = '{default: '0};

    if (sram_rvalid_i) begin
      rvalid_o[winner_q]           = 1'b1;
      rdata_o [winner_q]           = sram_rdata_i;
    end
  end

  // ----------------------------------------------------------
  // Performance Counters
  // ----------------------------------------------------------
  logic [31:0] contention_cnt_q;
  logic [31:0] total_req_cnt_q;
  logic [31:0] busy_cycles_cnt_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      contention_cnt_q  <= '0;
      total_req_cnt_q   <= '0;
      busy_cycles_cnt_q <= '0;
    end else begin
      // Contention: có ít nhất 2 master request cùng lúc
      if ($countones(req_i) >= 2 && !busy_q)
        contention_cnt_q <= contention_cnt_q + 1;

      // Total requests granted
      if (sram_req_o && sram_gnt_i)
        total_req_cnt_q <= total_req_cnt_q + 1;

      // Busy cycles: số cycle arbiter bị block
      if (busy_q)
        busy_cycles_cnt_q <= busy_cycles_cnt_q + 1;
    end
  end

  assign perf_contention_cnt_o  = contention_cnt_q;
  assign perf_total_req_cnt_o   = total_req_cnt_q;
  assign perf_busy_cycles_cnt_o = busy_cycles_cnt_q;

  // ----------------------------------------------------------
  // Assertions
  // ----------------------------------------------------------

  // Không bao giờ grant 2 master cùng lúc
  `ASSERT(BusArbMutualExclusion,
      $countones(gnt_o) <= 1)

  // rvalid không được xuất hiện khi không busy
  `ASSERT(BusArbRvalidKnown,
      sram_rvalid_i |-> busy_q || $past(busy_q))

  // Grant phải kèm theo request
  for (genvar i = 0; i < N_MASTERS; i++) begin : g_gnt_check
    `ASSERT(BusArbGntImpliesReq,
        gnt_o[i] |-> req_i[i])
  end

endmodule
