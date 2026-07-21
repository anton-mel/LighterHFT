import hft_pkg::*;

// Binary-tree best-price reducer (Figure 4 style): each cycle, level l+1 feeds level l,
// preferring the higher-index (higher-price) child when both are populated. Root = best bid.
module price_ladder (
    input  logic                      clk,
    input  logic                      rst,
    input  logic [PRICE_LVL_W-1:0]    idx,
    input  logic signed [SHARES_W:0]  delta,
    input  logic                      valid,
    output logic [PRICE_LVL_W-1:0]    best_idx,
    output logic                      best_valid
);

  logic [SHARES_W-1:0] qty [0:PRICE_LEVELS-1];

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < PRICE_LEVELS; i++) qty[i] <= '0;
    end else if (valid) begin
      logic signed [SHARES_W:0] sum;
      sum = $signed({1'b0, qty[idx]}) + delta;
      qty[idx] <= (sum < 0) ? '0 : sum[SHARES_W-1:0];
    end
  end

  logic                   node_valid [0:PRICE_LVL_W][0:PRICE_LEVELS-1];
  logic [PRICE_LVL_W-1:0] node_idx   [0:PRICE_LVL_W][0:PRICE_LEVELS-1];

  genvar lvl, pos;
  generate
    for (pos = 0; pos < PRICE_LEVELS; pos++) begin : g_leaf
      always_ff @(posedge clk) begin
        node_valid[PRICE_LVL_W][pos] <= (qty[pos] != 0);
        node_idx[PRICE_LVL_W][pos]   <= PRICE_LVL_W'(pos);
      end
    end
    for (lvl = PRICE_LVL_W - 1; lvl >= 0; lvl--) begin : g_level
      localparam int NODES = 1 << lvl;
      for (pos = 0; pos < NODES; pos++) begin : g_node
        always_ff @(posedge clk) begin
          if (node_valid[lvl+1][2*pos+1]) begin
            node_valid[lvl][pos] <= 1'b1;
            node_idx[lvl][pos]   <= node_idx[lvl+1][2*pos+1];
          end else if (node_valid[lvl+1][2*pos]) begin
            node_valid[lvl][pos] <= 1'b1;
            node_idx[lvl][pos]   <= node_idx[lvl+1][2*pos];
          end else begin
            node_valid[lvl][pos] <= 1'b0;
          end
        end
      end
    end
  endgenerate

  assign best_idx   = node_idx[0][0];
  assign best_valid = node_valid[0][0];

endmodule
