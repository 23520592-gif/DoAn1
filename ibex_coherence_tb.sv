`timescale 1ns/1ps

module ibex_coherence_tb;

  logic clk;
  logic rst_n;

  // Tao Clock an toan bat dau tu 0, dao lien tuc moi 5ns (Chu ky 10ns)
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  localparam int NumCores = 2;
  
  // Tin hieu giao tiep OBI noi voi Subsystem
  logic [NumCores-1:0] core_req;
  logic [NumCores-1:0] core_gnt;
  logic [31:0]         core_addr  [NumCores];
  logic [NumCores-1:0] core_we;
  logic [3:0]          core_be    [NumCores];
  logic [31:0]         core_wdata [NumCores];
  logic [NumCores-1:0] core_rvalid;
  logic [31:0]         core_rdata [NumCores];

  // Khoi tao khoi subsystem DUT
  ibex_coh_subsystem #(
    .CacheLines(16),
    .MemLines(256)
  ) dut (
    .clk_i        (clk),
    .rst_ni       (rst_n),
    .core_req_i   (core_req),
    .core_gnt_o   (core_gnt),
    .core_addr_i  (core_addr),
    .core_we_i    (core_we),
    .core_be_i    (core_be),
    .core_wdata_i (core_wdata),
    .core_rvalid_o(core_rvalid),
    .core_rdata_o (core_rdata)
  );

  // ---------- Cac Task Mo Phong Giao Thuc OBI ----------
  task automatic obi_read(input int core_id, input logic [31:0] addr, output logic [31:0] rdata);
    @(posedge clk);
    core_req[core_id]  <= 1'b1;
    core_addr[core_id] <= addr;
    core_we[core_id]   <= 1'b0;
    core_be[core_id]   <= 4'b1111;
    
    wait(core_gnt[core_id] == 1'b1);
    @(posedge clk);
    core_req[core_id] <= 1'b0;
    
    wait(core_rvalid[core_id] == 1'b1);
    rdata = core_rdata[core_id];
    @(posedge clk);
  endtask

  task automatic obi_write(input int core_id, input logic [31:0] addr, input logic [31:0] wdata, input logic [3:0] be);
    @(posedge clk);
    core_req[core_id]   <= 1'b1;
    core_addr[core_id]  <= addr;
    core_we[core_id]    <= 1'b1;
    core_be[core_id]    <= be;
    core_wdata[core_id] <= wdata;
    
    wait(core_gnt[core_id] == 1'b1);
    @(posedge clk);
    core_req[core_id] <= 1'b0;
    
    wait(core_rvalid[core_id] == 1'b1);
    @(posedge clk);
  endtask

  // ---------- Kich Ban Kiem Tra Coherence ----------
  initial begin
    logic [31:0] rdata;
    
    // Khoi tao cac tin hieu ban dau ve muc logic 0 an toan de khu X lan truyen
    rst_n    = 1'b0;
    core_req = '0;
    core_we  = '0;
    for (int i = 0; i < NumCores; i++) begin
      core_addr[i]  = 32'h0;
      core_be[i]    = 4'h0;
      core_wdata[i] = 32'h0;
    end
    
    // Doi 2 chu ky clock chinh quy thay the cho cu phap ##2 loi cu
    repeat(2) @(posedge clk); 
    rst_n = 1'b1;
    @(posedge clk);
    
    $display("\n=======================================================");
    $display("=== BAT DAU TEST KICH BAN COHERENCE ===");
    $display("=======================================================\n");

    // 1. Core 0 doc miss (I -> E)
    $display("[TIME %0t] 1. Core 0 doc addr 0x000 (Du kien: Miss, DIR cap Exclusive)", $time);
    obi_read(0, 32'h000, rdata);
    
    // 2. Core 1 doc miss (Core 0 ha E->S, DIR cap Shared)
    $display("\n[TIME %0t] 2. Core 1 doc addr 0x000 (Du kien: Core 0 bi snoop ha E->S)", $time);
    obi_read(1, 32'h000, rdata);

    // 3. Core 0 ghi du lieu (S -> M, Core 1 bi snoop lam mat hieu luc - Invalidate)
    $display("\n[TIME %0t] 3. Core 0 ghi addr 0x000 du lieu 0x12345678", $time);
    obi_write(0, 32'h000, 32'h12345678, 4'b1111);

    // 4. Core 1 doc lai dia chi cu (Gay miss -> kich snoop FWD du lieu moi tu Core 0)
    $display("\n[TIME %0t] 4. Core 1 doc lai addr 0x000 de kiem tra du lieu moi", $time);
    obi_read(1, 32'h000, rdata);
    if (rdata !== 32'h12345678) $error("LOI: Core 1 doc sai data!");
    else $display("    -> PASSED: Du lieu dong bo chinh xac: %h", rdata);

    $display("\n=======================================================");
    $display("=== MO PHONG COHERENCE HOAN TAT THANH CONG! ===");
    $display("=======================================================\n");
    $finish;
  end

endmodule