module prim_clock_gating (
  input  logic clk_i, en_i, test_en_i,
  output logic clk_o
);
  assign clk_o = clk_i & (en_i | test_en_i);
endmodule
