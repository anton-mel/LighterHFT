import hft_pkg::*;

// Replays a captured NASDAQ ITCH byte stream (filtered to a handful of tickers) through
// hft_top and logs every OUCH order it decides to place. Not self-checking against a
// reference -- this is a real-data smoke test, not a correctness test.
module hft_replay_tb;

  localparam string REPLAY_FILE = "filtered_4stocks.bin";
  localparam int    MAX_BYTES   = 200_000;  // raise for a longer replay once this is confirmed working

  logic clk = 0;
  logic rst;
  logic [7:0] itch_data;
  logic itch_valid;
  logic [7:0] ouch_data;
  logic ouch_valid, ouch_ready;

  hft_top #(.SAMPLE_PERIOD(20000), .CAPITAL(1_000_000_00)) dut (
      .clk(clk), .rst(rst), .itch_data(itch_data), .itch_valid(itch_valid),
      .ouch_data(ouch_data), .ouch_valid(ouch_valid), .ouch_ready(ouch_ready)
  );

  always #5 clk = ~clk;

  byte replay_buf [0:MAX_BYTES-1];
  int  file_bytes;
  int  order_count;
  int  byte_in_order;

  initial begin
    integer fd, n;
    fd = $fopen(REPLAY_FILE, "rb");
    if (fd == 0) begin
      $display("could not open %s", REPLAY_FILE);
      $finish;
    end
    n = $fread(replay_buf, fd);
    $fclose(fd);
    file_bytes = n;
    $display("loaded %0d bytes from %s", file_bytes, REPLAY_FILE);
  end

  logic prev_all_valid, prev_cov_done, prev_solver_done;
  int   evt_count;

  always_ff @(posedge clk) begin
    if (dut.book_evt.valid) evt_count <= evt_count + 1;
    prev_all_valid   <= dut.all_valid;
    prev_cov_done    <= dut.cov_done;
    prev_solver_done <= dut.solver_done;
    if (dut.all_valid && !prev_all_valid)
      $display("[t=%0t] all_valid went high (best_valid=%p)", $time, dut.best_valid);
    if (dut.cov_done && !prev_cov_done)
      $display("[t=%0t] cov_done (primed=%0d, overflow=%0d)", $time, dut.primed, dut.cov_overflow);
    if (dut.solver_done && !prev_solver_done)
      $display("[t=%0t] solver_done, weights=%p", $time, dut.weights);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      byte_in_order <= 0;
      order_count   <= 0;
    end else if (ouch_valid && ouch_ready) begin
      if (byte_in_order == 2) begin
        order_count <= order_count + 1;
        $display("[t=%0t] order #%0d starting", $time, order_count + 1);
      end
      byte_in_order <= (byte_in_order == dut.order_gen.TOTAL_BYTES - 1) ? 0 : byte_in_order + 1;
    end
  end

  initial begin
    rst = 1; itch_data = 0; itch_valid = 0; ouch_ready = 1'b1;
    repeat (3) @(posedge clk);
    rst = 0;
    @(posedge clk);

    wait (file_bytes > 0);

    for (int i = 0; i < file_bytes; i++) begin
      @(posedge clk);
      itch_data  = replay_buf[i];
      itch_valid = 1;
    end
    @(posedge clk);
    itch_valid = 0;

    repeat (20000) @(posedge clk);

    $display("REPLAY DONE: fed %0d bytes, saw %0d book events, %0d orders", file_bytes, evt_count, order_count);
    $finish;
  end

endmodule
