import hft_pkg::*;

// Replays a real 5-minute NASDAQ market-open window through hft_top and tracks a simple
// backtest P&L: each order is assumed filled immediately at its quoted price (no slippage/
// partial fills modeled), and any residual position is marked to the last observed price.
module pnl_backtest_tb;

  localparam string REPLAY_FILE = "opening_vol.bin";
  localparam int    MAX_BYTES   = 3_000_000;
  localparam longint CAPITAL_USD = 100_000;

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

  byte replay_buf [0:MAX_BYTES-1];
  int  file_bytes;

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

  longint cash   [0:NUM_STOCKS-1];
  longint shares [0:NUM_STOCKS-1];
  int     fills  [0:NUM_STOCKS-1];
  logic   prev_order_start;
  logic   prev_cov_done, prev_solver_done;

  always_ff @(posedge clk) begin
    prev_cov_done    <= dut.cov_done;
    prev_solver_done <= dut.solver_done;
    if (dut.cov_done && !prev_cov_done)
      $display("[t=%0t] cov_done overflow=%0d price=%p cov=%p",
                $time, dut.cov_overflow, dut.sample_price, dut.cov_matrix);
    if (dut.solver_done && !prev_solver_done)
      $display("[t=%0t] solver_done weights=%p", $time, dut.weights);
  end

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

    begin
      automatic longint total_pnl_raw = 0;
      $display("=== BACKTEST RESULT: %0s, notional capital $%0d ===", REPLAY_FILE, CAPITAL_USD);
      for (int i = 0; i < NUM_STOCKS; i++) begin
        automatic longint mtm      = shares[i] * longint'(dut.sample_price[i]);
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
