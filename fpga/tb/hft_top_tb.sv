import hft_pkg::*;

module hft_top_tb;

  logic clk = 0;
  logic rst;
  logic [7:0] itch_data;
  logic itch_valid;
  logic [7:0] ouch_data;
  logic ouch_valid, ouch_ready;

  int errors = 0;
  byte captured[$];

  hft_top #(.SAMPLE_PERIOD(50), .CAPITAL(1_000_000_00)) dut (
      .clk(clk), .rst(rst), .itch_data(itch_data), .itch_valid(itch_valid),
      .ouch_data(ouch_data), .ouch_valid(ouch_valid), .ouch_ready(ouch_ready)
  );

  always #5 clk = ~clk;

  initial begin
    #500000;
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

  byte queue[$];

  task automatic push_add(input logic [15:0] locate, input logic [63:0] oid,
                           input logic [31:0] shares, input logic [31:0] price);
    queue.push_back(8'd0); queue.push_back(8'd36); queue.push_back("A");
    queue.push_back(locate[15:8]); queue.push_back(locate[7:0]);
    queue.push_back(8'h00); queue.push_back(8'h00);
    for (int i = 0; i < 6; i++) queue.push_back(8'h00);
    for (int i = 0; i < 8; i++) queue.push_back(oid[63-8*i -: 8]);
    queue.push_back("B");
    for (int i = 0; i < 4; i++) queue.push_back(shares[31-8*i -: 8]);
    for (int i = 0; i < 8; i++) queue.push_back("X");
    for (int i = 0; i < 4; i++) queue.push_back(price[31-8*i -: 8]);
  endtask

  always_ff @(posedge clk) begin
    if (ouch_valid && ouch_ready) captured.push_back(ouch_data);
  end

  initial begin
    rst = 1; itch_data = 0; itch_valid = 0; ouch_ready = 1'b1;
    repeat (3) @(posedge clk);
    rst = 0;
    @(posedge clk);

    push_add(TARGET_LOCATES[0], 64'd1, 32'd100, 32'd10000);
    push_add(TARGET_LOCATES[1], 64'd2, 32'd100, 32'd20000);
    push_add(TARGET_LOCATES[2], 64'd3, 32'd100, 32'd30000);
    push_add(TARGET_LOCATES[3], 64'd4, 32'd100, 32'd40000);
    push_add(TARGET_LOCATES[0], 64'd5, 32'd100, 32'd15000);  // moves stock 0's best price up

    foreach (queue[i]) begin
      @(posedge clk);
      itch_data  = queue[i];
      itch_valid = 1;
    end
    @(posedge clk);
    itch_valid = 0;

    wait (captured.size() >= 3);
    repeat (5) @(posedge clk);

    check("order_type_present", captured[2] == "O");

    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("%0d TEST(S) FAILED", errors);
    $finish;
  end

endmodule
