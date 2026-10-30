module prim_buf #(parameter int Width = 1) (
  input  logic [Width-1:0] in_i,
  output logic [Width-1:0] out_o
);
  assign out_o = in_i;
endmodule
