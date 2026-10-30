// ============================================================
// ibex_coherence_pkg.sv   (rev 2)
//
// Định nghĩa chung cho hệ thống cache-coherent dual-core
// (Directory-based MESI + Crossbar) — Đồ án 1
//
// Mọi module trong subsystem (L1-D cache, directory controller,
// crossbar) import package này để dùng chung enum trạng thái và
// loại message, tránh "magic number" rải rác và lệch encoding
// giữa các module.
//
// Giao thức coherence có ĐÚNG 3 nhánh message — phải đủ cả 3 thì
// mỗi giao dịch mới "đóng" được, không treo directory ở transient:
//   (1) coh_req_e : L1-D  → Directory   (khởi xướng giao dịch)
//   (2) coh_msg_e : Directory → L1-D    (lệnh / cấp data)
//   (3) coh_rsp_e : L1-D  → Directory   (đóng giao dịch: ack / flush)
// ============================================================

package ibex_coherence_pkg;

  // ----------------------------------------------------------
  // Tham số hệ thống
  // ----------------------------------------------------------
  parameter int unsigned NumCores  = 2;
  parameter int unsigned NumBanks  = 2;
  parameter int unsigned AddrW     = 32;
  parameter int unsigned DataW     = 32;
  parameter int unsigned LineBytes = 16;                       // 1 cache line
  parameter int unsigned WordBytes = DataW / 8;                // = 4
  parameter int unsigned LineWords = LineBytes / WordBytes;    // = 4

  // ----------------------------------------------------------
  // Trạng thái MESI tại L1-D (lưu cho mỗi cache line)
  // ----------------------------------------------------------
  typedef enum logic [1:0] {
    MESI_I = 2'b00,  // Invalid  — line không hợp lệ
    MESI_S = 2'b01,  // Shared   — clean, có thể nhiều core cùng giữ
    MESI_E = 2'b10,  // Exclusive— clean, CHỈ 1 core giữ (cho phép E→M silent)
    MESI_M = 2'b11   // Modified — dirty, CHỈ 1 core giữ
  } mesi_state_e;

  // ----------------------------------------------------------
  // Trạng thái Directory (lưu cho mỗi memory line)
  //
  // Directory KHÔNG phân biệt E với M — cả hai đều là "đúng 1
  // owner độc quyền". Owner tự biết clean(E)/dirty(M) để quyết
  // có flush data khi bị recall hay không → directory đơn giản hơn.
  // ----------------------------------------------------------
  typedef enum logic [1:0] {
    DIR_U  = 2'b00,  // Uncached — không core nào giữ, mem là bản mới nhất
    DIR_S  = 2'b01,  // Shared   — ≥1 sharer, clean
    DIR_EM = 2'b10   // Excl/Mod — đúng 1 owner độc quyền
  } dir_state_e;

  // ----------------------------------------------------------
  // (1) Request: L1-D → Directory  (khởi xướng giao dịch)
  // ----------------------------------------------------------
  typedef enum logic [1:0] {
    REQ_GETS = 2'b00,  // read miss              (I       → S hoặc E)
    REQ_GETM = 2'b01,  // write miss / upgrade   (I hoặc S → M)
    REQ_PUTM = 2'b10   // writeback dirty evict  (M       → I), KÈM data line
  } coh_req_e;

  // ----------------------------------------------------------
  // (2) Command / Data: Directory → L1-D
  // ----------------------------------------------------------
  typedef enum logic [2:0] {
    MSG_DATA_S   = 3'b000, // cấp data, line về S
    MSG_DATA_E   = 3'b001, // cấp data, line về E (requestor là sharer duy nhất)
    MSG_DATA_M   = 3'b010, // cấp data + quyền ghi, line về M
    MSG_INV      = 3'b011, // invalidate line ở sharer  → chờ RSP_INV_ACK
    MSG_FWD_GETS = 3'b100, // owner hạ M/E → S, flush    → chờ RSP_DATA
    MSG_RECALL   = 3'b101, // owner hạ về I,    flush    → chờ RSP_DATA
    MSG_PUT_ACK  = 3'b110  // xác nhận writeback hoàn tất
  } coh_msg_e;

  // ----------------------------------------------------------
  // (3) Response: L1-D → Directory  (đóng giao dịch)
  //
  // BẮT BUỘC phải có nhánh này. Directory ở transient state sẽ
  // chờ đúng response tương ứng trước khi cấp quyền cho requestor;
  // thiếu nó → directory treo (deadlock) ngay test ping-pong.
  // ----------------------------------------------------------
  typedef enum logic [0:0] {
    RSP_INV_ACK = 1'b0,  // sharer đã invalidate xong (KHÔNG kèm data)
    RSP_DATA    = 1'b1   // owner flush data về directory (đáp FWD_GETS/RECALL)
  } coh_rsp_e;

  // ----------------------------------------------------------
  // Sharer vector cho NumCores core
  // bit i = 1  ⇔  core i đang giữ line.
  // Khi DIR_EM: vector này có đúng 1 bit set = owner.
  // ----------------------------------------------------------
  typedef logic [NumCores-1:0] sharer_vec_t;

  // ----------------------------------------------------------
  // Trích chỉ số word trong line từ địa chỉ byte
  //   word_index = addr[LineOffW-1 : ByteOffW]  → addr[3:2]
  // ----------------------------------------------------------
  parameter int unsigned ByteOffW = $clog2(WordBytes);  // = 2 (byte trong word)
  parameter int unsigned LineOffW = $clog2(LineBytes);  // = 4 (byte trong line)
  parameter int unsigned WordSelW = $clog2(LineWords);  // = 2 (word trong line)

  function automatic logic [WordSelW-1:0] word_index(input logic [AddrW-1:0] addr);
    return addr[LineOffW-1 : ByteOffW];
  endfunction

  // line-aligned address (xóa các bit offset trong line) — tiện so tag/directory
  function automatic logic [AddrW-1:0] line_addr(input logic [AddrW-1:0] addr);
    return {addr[AddrW-1 : LineOffW], {LineOffW{1'b0}}};
  endfunction

endpackage