// ============================================================
// ibex_cache_bank_crossbar.sv
//
// 2 cache masters x 2 memory banks line crossbar.
// - One round-robin arbiter per bank.
// - Cache requests are line-granular read/write transactions.
// - A grant accepts one request; read/write completion returns on rvalid
//   one cycle later. For writes, rdata is don't-care.
// ============================================================

module ibex_cache_bank_crossbar import ibex_coherence_pkg::*; #(
  parameter int unsigned MemLines = 256
) (
  input  logic                       clk_i,
  input  logic                       rst_ni,

  input  logic [NumCores-1:0]        m_req_valid_i,
  input  logic [NumCores-1:0]        m_req_we_i,
  input  logic [AddrW-1:0]           m_req_addr_i  [NumCores],
  input  logic [LineWords*DataW-1:0] m_req_wdata_i [NumCores],
  output logic [NumCores-1:0]        m_req_gnt_o,
  output logic [NumCores-1:0]        m_rsp_valid_o,
  output logic [LineWords*DataW-1:0] m_rsp_rdata_o [NumCores]
);

  localparam int unsigned LineW     = LineWords * DataW;
  localparam int unsigned BankSelW  = (NumBanks <= 1) ? 1 : $clog2(NumBanks);
  localparam int unsigned TotalLiW  = $clog2(MemLines);
  localparam int unsigned BankLines = MemLines / NumBanks;
  localparam int unsigned BankLiW   = $clog2(BankLines);

  logic [LineW-1:0] bank_mem_q [NumBanks][BankLines];

  function automatic logic [TotalLiW-1:0] line_index(input logic [AddrW-1:0] a);
    return a[LineOffW +: TotalLiW];
  endfunction

  function automatic logic [BankSelW-1:0] bank_of(input logic [AddrW-1:0] a);
    logic [TotalLiW-1:0] li;
    li = line_index(a);
    if (NumBanks == 1) return '0;
    else return li[BankSelW-1:0];
  endfunction

  function automatic logic [BankLiW-1:0] row_of(input logic [AddrW-1:0] a);
    logic [TotalLiW-1:0] li;
    li = line_index(a);
    if (NumBanks == 1) return li[BankLiW-1:0];
    else return li[BankSelW +: BankLiW];
  endfunction

  logic [$clog2(NumCores)-1:0] rr_q [NumBanks];

  logic [NumBanks-1:0]                  bank_win_valid;
  logic [$clog2(NumCores)-1:0]          bank_win_id [NumBanks];
  logic [BankSelW-1:0]                  m_bank     [NumCores];

  for (genvar m = 0; m < NumCores; m++) begin : g_decode
    assign m_bank[m] = bank_of(m_req_addr_i[m]);
  end

  always_comb begin
    m_req_gnt_o = '0;
    for (int b = 0; b < NumBanks; b++) begin
      bank_win_valid[b] = 1'b0;
      bank_win_id[b]    = '0;
      for (int k = 0; k < NumCores; k++) begin
        automatic int unsigned ix = (int'(rr_q[b]) + k) % NumCores;
        if (m_req_valid_i[ix] && (m_bank[ix] == b[BankSelW-1:0]) && !bank_win_valid[b]) begin
          bank_win_valid[b] = 1'b1;
          bank_win_id[b]    = ix[$clog2(NumCores)-1:0];
        end
      end
      if (bank_win_valid[b]) m_req_gnt_o[bank_win_id[b]] = 1'b1;
    end
  end

  integer bi;
  integer ri;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (bi = 0; bi < NumBanks; bi++) begin
        rr_q[bi] <= '0;
        for (ri = 0; ri < BankLines; ri++) bank_mem_q[bi][ri] <= '0;
      end
      m_rsp_valid_o <= '0;
      for (int m = 0; m < NumCores; m++) m_rsp_rdata_o[m] <= '0;
    end else begin
      m_rsp_valid_o <= '0;

      for (int b = 0; b < NumBanks; b++) begin
        if (bank_win_valid[b]) begin
          automatic int unsigned win;
          automatic logic [BankLiW-1:0] row;
          win = int'(bank_win_id[b]);
          row = row_of(m_req_addr_i[win]);

          rr_q[b] <= (win == NumCores-1) ? '0 : ($clog2(NumCores))'(win + 1);
          m_rsp_valid_o[win] <= 1'b1;

          if (m_req_we_i[win]) begin
            bank_mem_q[b][row] <= m_req_wdata_i[win];
            m_rsp_rdata_o[win] <= '0;
          end else begin
            m_rsp_rdata_o[win] <= bank_mem_q[b][row];
          end
        end
      end
    end
  end

endmodule
