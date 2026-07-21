import hft_pkg::*;

module covariance_engine_tb;

  logic clk = 0;
  logic rst;
  logic [PRICE_W-1:0] price [0:NUM_STOCKS-1];
  logic start, done, overflow;
  fx_t  mean [0:NUM_STOCKS-1];
  wfx_t cov  [0:NUM_STOCKS-1][0:NUM_STOCKS-1];

  int errors = 0;

  covariance_engine dut (
      .clk(clk), .rst(rst), .price(price), .start(start),
      .done(done), .overflow(overflow), .mean(mean), .cov(cov)
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
    repeat (3) @(posedge clk);
    rst = 0;
    @(posedge clk);

    price[0] = 32'd10000; price[1] = 32'd20000; price[2] = 32'd30000; price[3] = 32'd40000;
    start <= 1'b1;
    @(posedge clk);
    start <= 1'b0;
    @(posedge clk iff done);
    check("first_sample_no_overflow", !overflow);

    price[0] = 32'd11000; price[1] = 32'd19000; price[2] = 32'd30000; price[3] = 32'd42000;
    start <= 1'b1;
    @(posedge clk);
    start <= 1'b0;
    @(posedge clk iff done);

    check("mean0", mean[0] == 16'sd1638);
    check("mean1", mean[1] == -16'sd820);
    check("mean2", mean[2] == 16'sd0);
    check("mean3", mean[3] == 16'sd819);

    for (int i = 0; i < NUM_STOCKS; i++)
      for (int j = 0; j < NUM_STOCKS; j++)
        check($sformatf("cov_zero_%0d_%0d", i, j), cov[i][j] == '0);

    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("%0d TEST(S) FAILED", errors);
    $finish;
  end

endmodule
