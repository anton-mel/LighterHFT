import hft_pkg::*;

module ouch_order_gen_tb;

  logic clk = 0;
  logic rst;
  logic [STOCK_IDX_W-1:0] stock_idx;
  logic buy_sell;
  logic [SHARES_W-1:0] shares;
  logic [PRICE_W-1:0] price;
  logic [ORDER_ID_W-1:0] order_token;
  logic start, busy, ready;
  logic [7:0] data;
  logic data_valid;

  int errors = 0;
  byte captured[$];

  ouch_order_gen dut (
      .clk(clk), .rst(rst), .stock_idx(stock_idx), .buy_sell(buy_sell),
      .shares(shares), .price(price), .order_token(order_token), .start(start),
      .busy(busy), .ready(ready), .data(data), .data_valid(data_valid)
  );

  always #5 clk = ~clk;

  initial begin
    #100000;
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

  always_ff @(posedge clk) begin
    if (data_valid && ready) captured.push_back(data);
  end

  initial begin
    rst = 1; start = 0; ready = 1'b1;
    stock_idx = 2; buy_sell = 1'b1; shares = 32'd250;
    price = 32'd55500; order_token = 64'h1122334455667788;
    repeat (3) @(posedge clk);
    rst = 0;
    @(posedge clk);

    start <= 1'b1;
    @(posedge clk);
    start <= 1'b0;
    @(posedge clk iff !busy);
    repeat (3) @(posedge clk);

    check("total_bytes", captured.size() == 45);
    check("len_hi", captured[0] == 8'h00);
    check("len_lo", captured[1] == 8'd43);
    check("type",   captured[2] == "O");
    check("token0", captured[3]  == 8'h11);
    check("token7", captured[10] == 8'h88);
    check("side",   captured[11] == "S");
    check("shares3",captured[15] == 8'd250);
    check("stock",  captured[23] == 8'd2);
    check("price3", {captured[24], captured[25], captured[26], captured[27]} == 32'd55500);

    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("%0d TEST(S) FAILED", errors);
    $finish;
  end

endmodule
