import hft_pkg::*;

// Owns running mean/moment/covariance state for NUM_STOCKS series, in Q2.14 fixed point.
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
    output fx_t                cov  [0:NUM_STOCKS-1][0:NUM_STOCKS-1]
);

  localparam fx_t ONE_FX = fx_t'(1 << FX_FRAC);
  localparam logic signed [2*FX_W-1:0] FX_MAX = (1 <<< (FX_W-1)) - 1;
  localparam logic signed [2*FX_W-1:0] FX_MIN = -(1 <<< (FX_W-1));

  logic [PRICE_W-1:0] last_price [0:NUM_STOCKS-1];
  fx_t                moment     [0:NUM_STOCKS-1][0:NUM_STOCKS-1];
  logic [31:0]        count;
  logic                first_sample;

  fx_t returns  [0:NUM_STOCKS-1];
  fx_t new_mean [0:NUM_STOCKS-1];

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
        mean[i] <= '0;
        for (int j = 0; j < NUM_STOCKS; j++) moment[i][j] <= '0;
      end
    end else begin
      done <= 1'b0;

      case (state)
        S_IDLE: if (start) begin
          overflow <= 1'b0;
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
          automatic logic signed [PRICE_W+FX_FRAC:0] ratio;
          ratio = ($signed({1'b0, price[idx_i]}) <<< FX_FRAC) / $signed({1'b0, last_price[idx_i]});
          returns[idx_i] <= fx_t'(ratio) - ONE_FX;
          if (idx_i == NUM_STOCKS-1) begin
            idx_i <= 0;
            state <= S_MEAN;
          end else begin
            idx_i <= idx_i + 1;
          end
        end

        S_MEAN: begin
          automatic logic signed [FX_W+32:0] num;
          num = ($signed(mean[idx_i]) * $signed({1'b0, count})) + $signed(returns[idx_i]);
          new_mean[idx_i] <= fx_t'(num / $signed({1'b0, count + 32'd1}));
          if (idx_i == NUM_STOCKS-1) begin
            idx_i <= 0;
            idx_j <= 0;
            state <= S_MOMENT;
          end else begin
            idx_i <= idx_i + 1;
          end
        end

        S_MOMENT: begin
          automatic logic signed [2*FX_W-1:0] prod_wide;
          automatic fx_t                      prod;
          automatic logic signed [FX_W+32:0]  num;
          prod_wide = ($signed(returns[idx_i]) * $signed(returns[idx_j])) >>> FX_FRAC;
          if (prod_wide > FX_MAX) begin
            overflow <= 1'b1;
            prod = fx_t'(FX_MAX);
          end else if (prod_wide < FX_MIN) begin
            overflow <= 1'b1;
            prod = fx_t'(FX_MIN);
          end else begin
            prod = prod_wide[FX_W-1:0];
          end
          num = ($signed(moment[idx_i][idx_j]) * $signed({1'b0, count})) + $signed(prod);
          moment[idx_i][idx_j] <= fx_t'(num / $signed({1'b0, count + 32'd1}));
          if (idx_j == NUM_STOCKS-1) begin
            idx_j <= 0;
            if (idx_i == NUM_STOCKS-1) begin
              idx_i <= 0;
              idx_j <= 0;
              mean  <= new_mean;
              state <= S_COV;
            end else begin
              idx_i <= idx_i + 1;
            end
          end else begin
            idx_j <= idx_j + 1;
          end
        end

        S_COV: begin
          automatic logic signed [2*FX_W-1:0] prod_wide;
          automatic fx_t                      prod;
          prod_wide = ($signed(mean[idx_i]) * $signed(mean[idx_j])) >>> FX_FRAC;
          if (prod_wide > FX_MAX) begin
            overflow <= 1'b1;
            prod = fx_t'(FX_MAX);
          end else if (prod_wide < FX_MIN) begin
            overflow <= 1'b1;
            prod = fx_t'(FX_MIN);
          end else begin
            prod = prod_wide[FX_W-1:0];
          end
          cov[idx_i][idx_j] <= moment[idx_i][idx_j] - prod;
          if (idx_j == NUM_STOCKS-1) begin
            idx_j <= 0;
            if (idx_i == NUM_STOCKS-1) state <= S_COMMIT;
            else idx_i <= idx_i + 1;
          end else begin
            idx_j <= idx_j + 1;
          end
        end

        S_COMMIT: begin
          for (int i = 0; i < NUM_STOCKS; i++) last_price[i] <= price[i];
          count <= count + 32'd1;
          done  <= 1'b1;
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
