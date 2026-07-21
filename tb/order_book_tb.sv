import hft_pkg::*;

module order_book_tb;

  logic clk = 0;
  logic rst;
  order_event_t evt;
  logic [PRICE_LVL_W-1:0] best_price_idx;
  logic [PRICE_W-1:0]     best_price;
  logic                   best_valid;

  int errors = 0;

  order_book dut (
      .clk(clk), .rst(rst), .evt(evt),
      .best_price_idx(best_price_idx), .best_price(best_price), .best_valid(best_valid)
  );

  always #5 clk = ~clk;

  task automatic send(input book_op_e op, input logic [63:0] oid,
                       input logic [31:0] price, input logic [31:0] shares);
    evt.valid     <= 1'b1;
    evt.stock_idx <= '0;
    evt.buy_sell  <= 1'b0;
    evt.op       <= op;
    evt.order_id <= oid;
    evt.price    <= price;
    evt.shares   <= shares;
    @(posedge clk);
    evt.valid <= 1'b0;
    @(posedge clk);
  endtask

  task automatic check(input string name, input logic cond);
    if (!cond) begin
      errors++;
      $display("FAIL: %s", name);
    end else begin
      $display("PASS: %s", name);
    end
  endtask

  initial begin
    rst = 1; evt.valid = 0;
    repeat (3) @(posedge clk);
    rst = 0;
    @(posedge clk);

    // first add sets this stock's price reference -- its own bucket is always 0
    send(OP_ADD, 64'd1, 32'd50000, 32'd10);   // price_idx 0 (this is the reference price)
    repeat (12) @(posedge clk);
    check("best_after_add1", best_valid && best_price_idx == 8'd0 && best_price == 32'd50000);

    send(OP_ADD, 64'd2, 32'd100000, 32'd20);  // (100000-50000)/500 = price_idx 100, higher
    repeat (12) @(posedge clk);
    check("best_after_add2", best_valid && best_price_idx == 8'd100 && best_price == 32'd100000);

    send(OP_DELETE, 64'd2, 32'd0, 32'd0);
    repeat (12) @(posedge clk);
    check("best_after_delete2", best_valid && best_price_idx == 8'd0);

    send(OP_EXECUTE, 64'd1, 32'd0, 32'd10);
    repeat (12) @(posedge clk);
    check("best_after_full_execute", !best_valid);

    // price far beyond the current reference's reach (e.g. a real trading price arriving
    // after the reference got stuck on a stub-quote-like outlier) should rebase, not saturate
    send(OP_ADD, 64'd3, 32'd2000000, 32'd5);
    repeat (12) @(posedge clk);
    check("best_after_rebase", best_valid && best_price_idx == 8'd0 && best_price == 32'd2000000);

    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("%0d TEST(S) FAILED", errors);
    $finish;
  end

endmodule
