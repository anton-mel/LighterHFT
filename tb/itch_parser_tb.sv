import hft_pkg::*;

module itch_parser_tb;

  logic clk = 0;
  logic rst;
  logic [7:0] data;
  logic data_valid;
  order_event_t evt;
  logic evt_valid;

  int errors = 0;

  itch_parser dut (
      .clk(clk), .rst(rst), .data(data), .data_valid(data_valid),
      .evt(evt), .evt_valid(evt_valid)
  );

  always #5 clk = ~clk;

  byte queue[$];

  // Add Order (type 'A'), locate=5, oid=0xAABBCCDD11223344, buy, shares=100, price=123400
  initial begin
    queue = '{
      8'd0, 8'd36, "A",
      8'h00, 8'h05,             // stock locate
      8'h00, 8'h00,             // tracking number
      8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, // timestamp
      8'hAA, 8'hBB, 8'hCC, 8'hDD, 8'h11, 8'h22, 8'h33, 8'h44, // order ref number
      "B",                      // buy/sell
      8'h00, 8'h00, 8'h00, 8'd100, // shares
      "X", "X", "X", "X", "X", "X", "X", "X",  // stock ticker (unused)
      8'h00, 8'h01, 8'hE2, 8'h48, // price = 123400

      8'd0, 8'd19, "D",
      8'h00, 8'h05,
      8'h00, 8'h00,
      8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
      8'hAA, 8'hBB, 8'hCC, 8'hDD, 8'h11, 8'h22, 8'h33, 8'h44,

      8'd0, 8'd23, "X",
      8'h00, 8'h09,
      8'h00, 8'h00,
      8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
      8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h42,
      8'h00, 8'h00, 8'h00, 8'd25
    };
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
    rst = 1; data = 0; data_valid = 0;
    repeat (3) @(posedge clk);
    rst = 0;

    fork
      begin
        foreach (queue[i]) begin
          @(posedge clk);
          data       = queue[i];
          data_valid = 1;
        end
        @(posedge clk);
        data_valid = 0;
      end
    join_none

    @(posedge clk iff evt_valid);
    check("add.op",        evt.op == OP_ADD);
    check("add.stock_idx", evt.stock_idx == locate_to_idx(16'd5));
    check("add.order_id",  evt.order_id == 64'hAABBCCDD11223344);
    check("add.buy_sell",  evt.buy_sell == 1'b0);
    check("add.shares",    evt.shares == 32'd100);
    check("add.price",     evt.price == 32'd123400);

    @(posedge clk iff evt_valid);
    check("delete.op",       evt.op == OP_DELETE);
    check("delete.order_id", evt.order_id == 64'hAABBCCDD11223344);

    @(posedge clk iff evt_valid);
    check("cancel.op",       evt.op == OP_CANCEL);
    check("cancel.order_id", evt.order_id == 64'h0000000000000042);
    check("cancel.shares",   evt.shares == 32'd25);

    repeat (10) @(posedge clk);
    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("%0d TEST(S) FAILED", errors);
    $finish;
  end

endmodule
