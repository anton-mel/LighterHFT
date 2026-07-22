import hft_pkg::*;

// Minimum-variance portfolio weights: w = K^-1*1 / (1^T K^-1 1), via Givens-rotation QR
// (K = QR, so K^-1*1 = R^-1 Q^T 1) and upper-triangular back-substitution. Folded FSM:
// one (pivot, target) row rotation at a time, N cycles of back-substitution, then normalize.
// Internal math runs at wfx_t precision (matching covariance_engine's output) -- Q2.14
// alone underflows for the small covariance values real return data produces; only the
// final weights are rescaled down to fx_t, since that's what position sizing consumes.
module qr_solver (
    input  logic clk,
    input  logic rst,
    input  wfx_t cov [0:NUM_STOCKS-1][0:NUM_STOCKS-1],
    input  logic start,
    output logic done,
    output fx_t  weights [0:NUM_STOCKS-1]
);

  localparam wfx_t WONE_FX = wfx_t'(64'(1) <<< WFX_FRAC);

  wfx_t r [0:NUM_STOCKS-1][0:NUM_STOCKS-1];
  wfx_t qtv [0:NUM_STOCKS-1];
  wfx_t v   [0:NUM_STOCKS-1];

  function automatic wfx_t wfx_mul(input wfx_t a, input wfx_t b);
    logic signed [2*WFX_W-1:0] wide;
    wide = ($signed(a) * $signed(b)) >>> WFX_FRAC;
    return wide[WFX_W-1:0];
  endfunction

  // Non-restoring integer sqrt of a 96-bit input (48 bit-pairs -> 48-bit root); callers
  // pre-scale the input by 2^WFX_FRAC via concatenation so the result lands back in wfx_t
  // fixed-point scale.
  function automatic logic [47:0] isqrt96(input logic [95:0] x);
    logic [95:0] rem;
    logic [47:0] root;
    rem  = '0;
    root = '0;
    for (int i = 47; i >= 0; i--) begin
      rem  = {rem[93:0], x[2*i+1 -: 2]};
      root = root << 1;
      if (rem >= {root, 2'b01}) begin
        rem  = rem - {root, 2'b01};
        root = root | 48'b1;
      end
    end
    return root;
  endfunction

  typedef enum logic [2:0] {S_IDLE, S_INIT, S_ROTATE, S_BACKSUB, S_NORMALIZE, S_DONE} state_e;
  state_e state;
  int pivot, target, bsub_i;
  logic signed [WFX_W+3:0] sum_v;
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
            qtv[i] <= WONE_FX;
            for (int j = 0; j < NUM_STOCKS; j++) r[i][j] <= cov[i][j];
          end
          pivot  <= 0;
          target <= 1;
          state  <= S_ROTATE;
        end

        S_ROTATE: begin
          automatic wfx_t         a, b, c, s, hyp;
          automatic logic [63:0]  sq_total;
          a = r[pivot][pivot];
          b = r[target][pivot];
          if (b == 0) begin
            c = WONE_FX;
            s = '0;
          end else begin
            sq_total = {16'b0, wfx_mul(a, a)} + {16'b0, wfx_mul(b, b)};
            hyp      = wfx_t'(isqrt96({sq_total, {WFX_FRAC{1'b0}}}));
            c = (hyp == 0) ? WONE_FX : wfx_t'($signed({a, {WFX_FRAC{1'b0}}}) / $signed(hyp));
            s = (hyp == 0) ? wfx_t'(0) : wfx_t'($signed({b, {WFX_FRAC{1'b0}}}) / $signed(hyp));
          end

          for (int j = 0; j < NUM_STOCKS; j++) begin
            r[pivot][j]  <= wfx_mul(c, r[pivot][j])  + wfx_mul(s, r[target][j]);
            r[target][j] <= wfx_mul(c, r[target][j]) - wfx_mul(s, r[pivot][j]);
          end
          qtv[pivot]  <= wfx_mul(c, qtv[pivot])  + wfx_mul(s, qtv[target]);
          qtv[target] <= wfx_mul(c, qtv[target]) - wfx_mul(s, qtv[pivot]);

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
          automatic logic signed [WFX_W+3:0] acc;
          acc = {{4{qtv[bsub_i][WFX_W-1]}}, qtv[bsub_i]};
          for (int k = bsub_i+1; k < NUM_STOCKS; k++) acc = acc - wfx_mul(r[bsub_i][k], v[k]);
          // a zero pivot means an under-determined (e.g. all-zero) covariance input; park
          // that row's weight at zero rather than divide by zero.
          v[bsub_i] <= (r[bsub_i][bsub_i] == 0) ? wfx_t'(0) :
                       wfx_t'($signed({acc, {WFX_FRAC{1'b0}}}) / $signed(r[bsub_i][bsub_i]));

          if (bsub_i == 0) begin
            norm_pass <= 1'b0;
            state     <= S_NORMALIZE;
          end else begin
            bsub_i <= bsub_i - 1;
          end
        end

        S_NORMALIZE: begin
          if (!norm_pass) begin
            automatic logic signed [WFX_W+3:0] total;
            total = 0;
            for (int i = 0; i < NUM_STOCKS; i++) total = total + $signed(v[i]);
            sum_v     <= total;
            norm_pass <= 1'b1;
          end else begin
            for (int i = 0; i < NUM_STOCKS; i++) begin
              automatic wfx_t weight_wide;
              weight_wide = (sum_v == 0) ? wfx_t'(0) :
                            wfx_t'($signed({v[i], {WFX_FRAC{1'b0}}}) / $signed(sum_v));
              weights[i]  <= fx_t'(weight_wide >>> (WFX_FRAC - FX_FRAC));
            end
            done  <= 1'b1;
            state <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
