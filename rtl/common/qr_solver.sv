import hft_pkg::*;

// Minimum-variance portfolio weights: w = K^-1*1 / (1^T K^-1 1), via Givens-rotation QR
// (K = QR, so K^-1*1 = R^-1 Q^T 1) and upper-triangular back-substitution. Folded FSM:
// one (pivot, target) row rotation at a time, N cycles of back-substitution, then normalize.
module qr_solver (
    input  logic clk,
    input  logic rst,
    input  fx_t  cov [0:NUM_STOCKS-1][0:NUM_STOCKS-1],
    input  logic start,
    output logic done,
    output fx_t  weights [0:NUM_STOCKS-1]
);

  localparam fx_t ONE_FX = fx_t'(1 << FX_FRAC);

  fx_t r [0:NUM_STOCKS-1][0:NUM_STOCKS-1];
  fx_t qtv [0:NUM_STOCKS-1];
  fx_t v   [0:NUM_STOCKS-1];

  function automatic fx_t fx_mul(input fx_t a, input fx_t b);
    logic signed [2*FX_W-1:0] wide;
    wide = ($signed(a) * $signed(b)) >>> FX_FRAC;
    return wide[FX_W-1:0];
  endfunction

  // 16-bit non-restoring integer sqrt of a 32-bit input; callers pre-scale the input by
  // 2^FX_FRAC via concatenation so the result lands back in Q2.14 fixed-point scale.
  function automatic logic [15:0] isqrt32(input logic [31:0] x);
    logic [31:0] rem;
    logic [15:0] root;
    rem  = '0;
    root = '0;
    for (int i = 15; i >= 0; i--) begin
      rem  = {rem[29:0], x[2*i+1 -: 2]};
      root = root << 1;
      if (rem >= {root, 2'b01}) begin
        rem  = rem - {root, 2'b01};
        root = root | 16'b1;
      end
    end
    return root;
  endfunction

  typedef enum logic [2:0] {S_IDLE, S_INIT, S_ROTATE, S_BACKSUB, S_NORMALIZE, S_DONE} state_e;
  state_e state;
  int pivot, target, bsub_i;
  logic signed [FX_W+3:0] sum_v;
  logic norm_pass;

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= S_IDLE;
      done  <= 1'b0;
    end else begin
      done <= 1'b0;

      case (state)
        S_IDLE: if (start) state <= S_INIT;

        S_INIT: begin
          for (int i = 0; i < NUM_STOCKS; i++) begin
            qtv[i] <= ONE_FX;
            for (int j = 0; j < NUM_STOCKS; j++) r[i][j] <= cov[i][j];
          end
          pivot  <= 0;
          target <= 1;
          state  <= S_ROTATE;
        end

        S_ROTATE: begin
          automatic fx_t         a, b, c, s, hyp;
          automatic logic [17:0] sq_total;
          a = r[pivot][pivot];
          b = r[target][pivot];
          if (b == 0) begin
            c = ONE_FX;
            s = '0;
          end else begin
            sq_total = {2'b00, fx_mul(a, a)} + {2'b00, fx_mul(b, b)};
            hyp      = fx_t'(isqrt32({sq_total, {FX_FRAC{1'b0}}}));
            c = (hyp == 0) ? ONE_FX : fx_t'($signed({a, {FX_FRAC{1'b0}}}) / $signed(hyp));
            s = (hyp == 0) ? fx_t'(0) : fx_t'($signed({b, {FX_FRAC{1'b0}}}) / $signed(hyp));
          end

          for (int j = 0; j < NUM_STOCKS; j++) begin
            r[pivot][j]  <= fx_mul(c, r[pivot][j])  + fx_mul(s, r[target][j]);
            r[target][j] <= fx_mul(c, r[target][j]) - fx_mul(s, r[pivot][j]);
          end
          qtv[pivot]  <= fx_mul(c, qtv[pivot])  + fx_mul(s, qtv[target]);
          qtv[target] <= fx_mul(c, qtv[target]) - fx_mul(s, qtv[pivot]);

          if (target == NUM_STOCKS-1) begin
            if (pivot == NUM_STOCKS-2) begin
              bsub_i <= NUM_STOCKS-1;
              state  <= S_BACKSUB;
            end else begin
              pivot  <= pivot + 1;
              target <= pivot + 2;
            end
          end else begin
            target <= target + 1;
          end
        end

        S_BACKSUB: begin
          automatic logic signed [FX_W+3:0] acc;
          acc = {{4{qtv[bsub_i][FX_W-1]}}, qtv[bsub_i]};
          for (int k = bsub_i+1; k < NUM_STOCKS; k++) acc = acc - fx_mul(r[bsub_i][k], v[k]);
          // a zero pivot means an under-determined (e.g. all-zero) covariance input; park
          // that row's weight at zero rather than divide by zero.
          v[bsub_i] <= (r[bsub_i][bsub_i] == 0) ? fx_t'(0) :
                       fx_t'($signed({acc, {FX_FRAC{1'b0}}}) / $signed(r[bsub_i][bsub_i]));

          if (bsub_i == 0) begin
            norm_pass <= 1'b0;
            state     <= S_NORMALIZE;
          end else begin
            bsub_i <= bsub_i - 1;
          end
        end

        S_NORMALIZE: begin
          if (!norm_pass) begin
            automatic logic signed [FX_W+3:0] total;
            total = 0;
            for (int i = 0; i < NUM_STOCKS; i++) total = total + $signed(v[i]);
            sum_v     <= total;
            norm_pass <= 1'b1;
          end else begin
            for (int i = 0; i < NUM_STOCKS; i++)
              weights[i] <= (sum_v == 0) ? fx_t'(0) :
                            fx_t'($signed({v[i], {FX_FRAC{1'b0}}}) / $signed(sum_v));
            done  <= 1'b1;
            state <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
