import hft_pkg::*;

// Owns running mean/moment/covariance state for NUM_STOCKS series, in wfx_t precision --
// real per-sample returns are small, and covariance squares them, which underflows Q2.14's
// resolution before it can accumulate into a usable variance estimate (verified against
// real NASDAQ data: a 0.03% per-sample return survives Q2.14, but its square does not).
// cov is output at wfx_t precision (qr_solver consumes it directly); mean is unused
// downstream today and stays Q2.14 for now.
// Folded (sequential, single shared datapath) design: correctness and clarity over peak
// throughput, since VMK180 has ample headroom and one price update is not latency-critical
// relative to book/order-path timing.
module covariance_engine (
    input  logic               clk,
    input  logic               rst,
    input  logic [PRICE_W-1:0] price [0:NUM_STOCKS-1],
    input  logic               start,
    output logic                done,
    output logic                overflow,
    output fx_t                mean [0:NUM_STOCKS-1],
    output wfx_t               cov  [0:NUM_STOCKS-1][0:NUM_STOCKS-1]
);

  localparam wfx_t WONE_FX = wfx_t'(64'(1) <<< WFX_FRAC);
  localparam logic signed [2*WFX_W-1:0] WFX_MAX = (1 <<< (WFX_W-1)) - 1;
  localparam logic signed [2*WFX_W-1:0] WFX_MIN = -(1 <<< (WFX_W-1));

  logic [PRICE_W-1:0] last_price [0:NUM_STOCKS-1];
  // price is a live, continuously-updating port -- S_RETURNS and S_COMMIT read it ~40 cycles
  // apart within the same sample, so a price update landing in between would be compared
  // against itself (silently swallowed) unless both stages read one consistent snapshot.
  logic [PRICE_W-1:0] price_snap  [0:NUM_STOCKS-1];
  wfx_t               wmean      [0:NUM_STOCKS-1];
  wfx_t               wmoment    [0:NUM_STOCKS-1][0:NUM_STOCKS-1];
  logic [31:0]        count;
  logic                first_sample;

  wfx_t returns   [0:NUM_STOCKS-1];
  wfx_t new_wmean [0:NUM_STOCKS-1];

  typedef enum logic [2:0] {S_IDLE, S_RETURNS, S_MEAN, S_MOMENT, S_COV, S_COMMIT} state_e;
  state_e state;
  int idx_i, idx_j;

  always_ff @(posedge clk) begin
    if (rst) begin
      state        <= S_IDLE;
      count        <= 32'd0;
      first_sample <= 1'b1;
      done         <= 1'b0;
      overflow     <= 1'b0;
      for (int i = 0; i < NUM_STOCKS; i++) begin
        wmean[i] <= '0;
        for (int j = 0; j < NUM_STOCKS; j++) wmoment[i][j] <= '0;
      end
    end else begin
      done <= 1'b0;

      case (state)
        S_IDLE: if (start) begin
          overflow <= 1'b0;
          for (int i = 0; i < NUM_STOCKS; i++) price_snap[i] <= price[i];
          if (first_sample) begin
            for (int i = 0; i < NUM_STOCKS; i++) last_price[i] <= price[i];
            first_sample <= 1'b0;
            done  <= 1'b1;
          end else begin
            idx_i <= 0;
            state <= S_RETURNS;
          end
        end

        S_RETURNS: begin
          automatic logic signed [PRICE_W+WFX_FRAC:0] ratio;
          // stock has no price yet (never quoted this round or before) -- no baseline to
          // compare against, so contribute zero return/covariance until it shows up.
          if (last_price[idx_i] == 0) begin
            returns[idx_i] <= '0;
          end else begin
            ratio = $signed({1'b0, price_snap[idx_i], {WFX_FRAC{1'b0}}}) / $signed({1'b0, last_price[idx_i]});
            returns[idx_i] <= wfx_t'(ratio) - WONE_FX;
          end
          if (idx_i == NUM_STOCKS-1) begin
            idx_i <= 0;
            state <= S_MEAN;
          end else begin
            idx_i <= idx_i + 1;
          end
        end

        S_MEAN: begin
          automatic logic signed [WFX_W+32:0] num;
          num = ($signed(wmean[idx_i]) * $signed({1'b0, count})) + $signed(returns[idx_i]);
          new_wmean[idx_i] <= wfx_t'(num / $signed({1'b0, count + 32'd1}));
          if (idx_i == NUM_STOCKS-1) begin
            idx_i <= 0;
            idx_j <= 0;
            state <= S_MOMENT;
          end else begin
            idx_i <= idx_i + 1;
          end
        end

        S_MOMENT: begin
          automatic logic signed [2*WFX_W-1:0] prod_wide;
          automatic wfx_t                      prod;
          automatic logic signed [WFX_W+32:0]  num;
          prod_wide = ($signed(returns[idx_i]) * $signed(returns[idx_j])) >>> WFX_FRAC;
          if (prod_wide > WFX_MAX) begin
            overflow <= 1'b1;
            prod = wfx_t'(WFX_MAX);
          end else if (prod_wide < WFX_MIN) begin
            overflow <= 1'b1;
            prod = wfx_t'(WFX_MIN);
          end else begin
            prod = prod_wide[WFX_W-1:0];
          end
          num = ($signed(wmoment[idx_i][idx_j]) * $signed({1'b0, count})) + $signed(prod);
          wmoment[idx_i][idx_j] <= wfx_t'(num / $signed({1'b0, count + 32'd1}));
          if (idx_j == NUM_STOCKS-1) begin
            idx_j <= 0;
            if (idx_i == NUM_STOCKS-1) begin
              idx_i <= 0;
              idx_j <= 0;
              wmean <= new_wmean;
              state <= S_COV;
            end else begin
              idx_i <= idx_i + 1;
            end
          end else begin
            idx_j <= idx_j + 1;
          end
        end

        S_COV: begin
          automatic logic signed [2*WFX_W-1:0] prod_wide;
          automatic wfx_t                      prod;
          automatic wfx_t                      wcov;
          prod_wide = ($signed(wmean[idx_i]) * $signed(wmean[idx_j])) >>> WFX_FRAC;
          if (prod_wide > WFX_MAX) begin
            overflow <= 1'b1;
            prod = wfx_t'(WFX_MAX);
          end else if (prod_wide < WFX_MIN) begin
            overflow <= 1'b1;
            prod = wfx_t'(WFX_MIN);
          end else begin
            prod = prod_wide[WFX_W-1:0];
          end
          wcov = wmoment[idx_i][idx_j] - prod;
          cov[idx_i][idx_j] <= wcov;
          if (idx_j == NUM_STOCKS-1) begin
            idx_j <= 0;
            if (idx_i == NUM_STOCKS-1) state <= S_COMMIT;
            else idx_i <= idx_i + 1;
          end else begin
            idx_j <= idx_j + 1;
          end
        end

        S_COMMIT: begin
          for (int i = 0; i < NUM_STOCKS; i++) last_price[i] <= price_snap[i];
          for (int i = 0; i < NUM_STOCKS; i++) mean[i] <= fx_t'(wmean[i] >>> (WFX_FRAC - FX_FRAC));
          count <= count + 32'd1;
          done  <= 1'b1;
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
