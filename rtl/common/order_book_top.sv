import hft_pkg::*;

module order_book_top (
    input  logic                   clk,
    input  logic                   rst,
    input  order_event_t           evt,
    output logic [PRICE_LVL_W-1:0] best_price_idx [0:NUM_STOCKS-1],
    output logic                   best_valid     [0:NUM_STOCKS-1]
);

  genvar i;
  generate
    for (i = 0; i < NUM_STOCKS; i++) begin : g_book
      order_event_t evt_masked;
      assign evt_masked       = evt;
      assign evt_masked.valid = evt.valid && (evt.stock_idx == i);

      order_book book (
          .clk(clk), .rst(rst),
          .evt(evt_masked),
          .best_price_idx(best_price_idx[i]),
          .best_valid(best_valid[i])
      );
    end
  endgenerate

endmodule
