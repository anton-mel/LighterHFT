import hft_pkg::*;

// Full pipeline: ITCH feed -> per-stock order book -> periodic covariance/min-variance
// solve -> position sizing against target weights -> OUCH order stream.
module hft_top #(
    parameter int SAMPLE_PERIOD  = 100_000,       // cycles between covariance samples
    parameter int CAPITAL        = 1_000_000_00   // notional capital, same price scale as feed
) (
    input  logic       clk,
    input  logic       rst,
    input  logic [7:0] itch_data,
    input  logic       itch_valid,
    output logic [7:0] ouch_data,
    output logic       ouch_valid,
    input  logic       ouch_ready
);

  order_event_t book_evt;
  logic [PRICE_LVL_W-1:0] best_price_idx [0:NUM_STOCKS-1];
  logic [PRICE_W-1:0]     sample_price   [0:NUM_STOCKS-1];
  logic                   best_valid     [0:NUM_STOCKS-1];

  itch_parser parser (
      .clk(clk), .rst(rst), .data(itch_data), .data_valid(itch_valid),
      .evt(book_evt), .evt_valid()
  );

  order_book_top books (
      .clk(clk), .rst(rst), .evt(book_evt),
      .best_price_idx(best_price_idx), .best_price(sample_price), .best_valid(best_valid)
  );

  logic all_valid;
  always_comb begin
    all_valid = 1'b1;
    for (int i = 0; i < NUM_STOCKS; i++) all_valid &= best_valid[i];
  end

  logic [31:0] sample_counter;
  logic        cov_start;

  always_ff @(posedge clk) begin
    if (rst) begin
      sample_counter <= 32'd0;
      cov_start      <= 1'b0;
    end else begin
      cov_start <= 1'b0;
      if (sample_counter == SAMPLE_PERIOD - 1) begin
        sample_counter <= 32'd0;
        if (all_valid) cov_start <= 1'b1;
      end else begin
        sample_counter <= sample_counter + 32'd1;
      end
    end
  end

  fx_t cov_matrix [0:NUM_STOCKS-1][0:NUM_STOCKS-1];
  logic cov_done, cov_overflow;
  fx_t mean_unused [0:NUM_STOCKS-1];

  covariance_engine cov_eng (
      .clk(clk), .rst(rst), .price(sample_price), .start(cov_start),
      .done(cov_done), .overflow(cov_overflow), .mean(mean_unused), .cov(cov_matrix)
  );

  // covariance_engine's very first done pulse is just priming its running-mean state with
  // the baseline price, not real covariance data yet -- don't solve on it.
  logic primed;
  always_ff @(posedge clk) begin
    if (rst) primed <= 1'b0;
    else if (cov_done) primed <= 1'b1;
  end

  fx_t weights [0:NUM_STOCKS-1];
  logic solver_done;

  qr_solver solver (
      .clk(clk), .rst(rst), .cov(cov_matrix), .start(cov_done && primed),
      .done(solver_done), .weights(weights)
  );

  logic [PRICE_W+31:0]      target_shares [0:NUM_STOCKS-1];
  logic [PRICE_W+31:0]      prev_shares   [0:NUM_STOCKS-1];
  logic                     sizing_valid;
  int                       size_idx;

  typedef enum logic [1:0] {Z_IDLE, Z_SIZE, Z_ISSUE} size_state_e;
  size_state_e size_state;

  logic                  order_start;
  logic [STOCK_IDX_W-1:0] order_stock;
  logic                  order_side;
  logic [SHARES_W-1:0]   order_shares;
  logic [PRICE_W-1:0]    order_price;
  logic [ORDER_ID_W-1:0] order_token_ctr;
  logic                  gen_busy;

  always_ff @(posedge clk) begin
    if (rst) begin
      size_state      <= Z_IDLE;
      order_start     <= 1'b0;
      order_token_ctr <= '0;
      for (int i = 0; i < NUM_STOCKS; i++) prev_shares[i] <= '0;
    end else begin
      order_start <= 1'b0;

      case (size_state)
        Z_IDLE: if (solver_done) begin
          size_idx   <= 0;
          size_state <= Z_SIZE;
        end

        Z_SIZE: begin
          automatic logic signed [FX_W+63:0] notional;
          automatic logic signed [FX_W+63:0] shares_signed;
          notional      = $signed(weights[size_idx]) * $signed(64'(CAPITAL));
          shares_signed = notional / $signed({1'b0, sample_price[size_idx], {FX_FRAC{1'b0}}});
          target_shares[size_idx] <= shares_signed[PRICE_W+31:0];
          size_state <= Z_ISSUE;
        end

        Z_ISSUE: begin
          automatic logic signed [PRICE_W+32:0] delta;
          delta = $signed({1'b0, target_shares[size_idx]}) - $signed({1'b0, prev_shares[size_idx]});
          if (delta != 0 && !gen_busy) begin
            order_stock     <= STOCK_IDX_W'(size_idx);
            order_side      <= (delta < 0);
            order_shares    <= SHARES_W'((delta < 0) ? -delta : delta);
            order_price     <= sample_price[size_idx];
            order_token_ctr <= order_token_ctr + 1;
            order_start     <= 1'b1;
            prev_shares[size_idx] <= target_shares[size_idx];
          end

          if (size_idx == NUM_STOCKS-1) size_state <= Z_IDLE;
          else begin
            size_idx   <= size_idx + 1;
            size_state <= Z_SIZE;
          end
        end

        default: size_state <= Z_IDLE;
      endcase
    end
  end

  ouch_order_gen order_gen (
      .clk(clk), .rst(rst),
      .stock_idx(order_stock), .buy_sell(order_side),
      .shares(order_shares), .price(order_price), .order_token(order_token_ctr),
      .start(order_start), .busy(gen_busy),
      .ready(ouch_ready), .data(ouch_data), .data_valid(ouch_valid)
  );

endmodule
