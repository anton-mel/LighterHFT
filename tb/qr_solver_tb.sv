import hft_pkg::*;

module qr_solver_tb;

  logic clk = 0;
  logic rst;
  wfx_t cov [0:NUM_STOCKS-1][0:NUM_STOCKS-1];
  logic start, done;
  fx_t weights [0:NUM_STOCKS-1];

  int errors = 0;

  qr_solver dut (
      .clk(clk), .rst(rst), .cov(cov), .start(start), .done(done), .weights(weights)
  );

  always #5 clk = ~clk;

  initial begin
    #200000;
    $display("TIMEOUT");
    $finish;
  end

  task automatic check(input string name, input logic cond);
    if (!cond) begin
      errors++;
      $display("FAIL: %s", name);
    end else begin
      $display("PASS: %s", name);
    end
  endtask

  initial begin
    rst = 1; start = 0;
    for (int i = 0; i < NUM_STOCKS; i++)
      for (int j = 0; j < NUM_STOCKS; j++) cov[i][j] = '0;
    repeat (3) @(posedge clk);
    rst = 0;
    @(posedge clk);

    // diagonal covariance (no correlation): min-variance weights should be
    // proportional to 1/variance -- 1.0, 0.8, 1.2, 0.6 -> weights below
    cov[0][0] = 64'sd4294967296;  // 1.0
    cov[1][1] = 64'sd3435973836;  // 0.8
    cov[2][2] = 64'sd5153960755;  // 1.2
    cov[3][3] = 64'sd2576980377;  // 0.6

    start <= 1'b1;
    @(posedge clk);
    start <= 1'b0;
    @(posedge clk iff done);

    check("weight0", weights[0] == 16'sd3449);
    check("weight1", weights[1] == 16'sd4311);
    check("weight2", weights[2] == 16'sd2874);
    check("weight3", weights[3] == 16'sd5748);

    // now exercise the Givens-rotation path with real off-diagonal correlation
    cov[0][1] = 64'sd1048576000; cov[1][0] = 64'sd1048576000;
    start <= 1'b1;
    @(posedge clk);
    start <= 1'b0;
    @(posedge clk iff done);

    begin
      automatic logic signed [19:0] wsum;
      wsum = 0;
      for (int i = 0; i < NUM_STOCKS; i++) wsum = wsum + $signed(weights[i]);
      check("correlated_weights_sum_to_one",
            (wsum > 16'sd16384 - 16'sd50) && (wsum < 16'sd16384 + 16'sd50));
    end

    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("%0d TEST(S) FAILED", errors);
    $finish;
  end

endmodule
