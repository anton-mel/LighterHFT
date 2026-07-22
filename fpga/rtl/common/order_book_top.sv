import hft_pkg::*;

module order_book_top (
    input  logic                   clk,
    input  logic                   rst,
    input  order_event_t           evt,
    output logic [PRICE_LVL_W-1:0] best_price_idx [0:NUM_STOCKS-1],
    output logic [PRICE_W-1:0]     best_price     [0:NUM_STOCKS-1],
    output logic                   best_valid     [0:NUM_STOCKS-1]
);

  genvar i;
  generate
    for (i = 0; i < NUM_STOCKS; i++) begin : g_book
      order_book #(.STOCK_ID(i)) book (
          .clk(clk), .rst(rst),
          .evt(evt),
          .best_price_idx(best_price_idx[i]),
          .best_price(best_price[i]),
          .best_valid(best_valid[i])
      );
    end
  endgenerate

endmodule
