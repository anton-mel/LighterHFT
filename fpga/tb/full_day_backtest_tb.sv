import hft_pkg::*;

// Replays a full real NASDAQ ITCH session (not just a short slice) through hft_top and tracks
// backtest P&L, same accounting as pnl_backtest_tb. Streams the file through a small chunk
// buffer instead of loading it into one large fixed array -- xsim becomes unstable at runtime
// with fixed arrays beyond a few million bytes, and a full session is much larger than that.
module full_day_backtest_tb;

  localparam string  REPLAY_FILE  = "filtered_4stocks.bin";
  localparam int     CHUNK_BYTES  = 1_000_000;
  localparam longint CAPITAL_USD  = 100_000;
  localparam longint PROGRESS_EVERY = 5_000_000;

  logic clk = 0;
  logic rst;
  logic [7:0] itch_data;
  logic itch_valid;
  logic [7:0] ouch_data;
  logic ouch_valid, ouch_ready;

  hft_top #(.SAMPLE_PERIOD(20000), .CAPITAL(100_000 * 10000)) dut (
      .clk(clk), .rst(rst), .itch_data(itch_data), .itch_valid(itch_valid),
      .ouch_data(ouch_data), .ouch_valid(ouch_valid), .ouch_ready(ouch_ready)
  );

  always #5 clk = ~clk;

  longint cash   [0:NUM_STOCKS-1];
  longint shares [0:NUM_STOCKS-1];
  int     fills  [0:NUM_STOCKS-1];
  logic   prev_order_start;

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < NUM_STOCKS; i++) begin
        cash[i]   <= 0;
        shares[i] <= 0;
        fills[i]  <= 0;
      end
      prev_order_start <= 1'b0;
    end else begin
      prev_order_start <= dut.order_start;
      if (dut.order_start && !prev_order_start) begin
        automatic int     s   = int'(dut.order_stock);
        automatic longint px  = longint'(dut.order_price);
        automatic longint shq = longint'(dut.order_shares);
        if (dut.order_side) begin  // sell
          cash[s]   <= cash[s] + px * shq;
          shares[s] <= shares[s] - shq;
        end else begin             // buy
          cash[s]   <= cash[s] - px * shq;
          shares[s] <= shares[s] + shq;
        end
        fills[s] <= fills[s] + 1;
        $display("[t=%0t] fill: stock=%0d side=%s shares=%0d price=$%0.4f",
                  $time, s, dut.order_side ? "SELL" : "BUY", shq, real'(px) / 10000.0);
      end
    end
  end

  byte    chunk [0:CHUNK_BYTES-1];
  longint total_bytes;

  initial begin
    integer fd, n;
    longint next_progress;
    rst = 1; itch_data = 0; itch_valid = 0; ouch_ready = 1'b1;
    repeat (3) @(posedge clk);
    rst = 0;
    @(posedge clk);

    fd = $fopen(REPLAY_FILE, "rb");
    if (fd == 0) begin
      $display("could not open %s", REPLAY_FILE);
      $finish;
    end

    total_bytes    = 0;
    next_progress  = PROGRESS_EVERY;
    n = $fread(chunk, fd);
    while (n > 0) begin
      for (int i = 0; i < n; i++) begin
        @(posedge clk);
        itch_data  = chunk[i];
        itch_valid = 1;
      end
      total_bytes += n;
      if (total_bytes >= next_progress) begin
        $display("[t=%0t] progress: %0d bytes fed", $time, total_bytes);
        next_progress += PROGRESS_EVERY;
      end
      n = $fread(chunk, fd);
    end
    $fclose(fd);
    @(posedge clk);
    itch_valid = 0;
    $display("loaded %0d total bytes from %s", total_bytes, REPLAY_FILE);

    repeat (20000) @(posedge clk);

    begin
      automatic longint total_pnl_raw = 0;
      $display("=== BACKTEST RESULT: %0s, notional capital $%0d ===", REPLAY_FILE, CAPITAL_USD);
      for (int i = 0; i < NUM_STOCKS; i++) begin
        automatic longint mtm       = shares[i] * longint'(dut.sample_price[i]);
        automatic longint stock_pnl = cash[i] + mtm;
        total_pnl_raw += stock_pnl;
        $display("stock %0d: fills=%0d final_shares=%0d last_price=$%0.4f pnl=$%0.2f",
                  i, fills[i], shares[i], real'(dut.sample_price[i]) / 10000.0,
                  real'(stock_pnl) / 10000.0);
      end
      $display("TOTAL PNL: $%0.2f on $%0d notional (%0.4f%%)",
                real'(total_pnl_raw) / 10000.0, CAPITAL_USD,
                100.0 * real'(total_pnl_raw) / 10000.0 / real'(CAPITAL_USD));
    end
    $finish;
  end

endmodule
