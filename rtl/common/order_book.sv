import hft_pkg::*;

// Per-stock order book: direct-mapped order table (indexed by low bits of order_id) +
// price_ladder for O(log PRICE_LEVELS) best-price tracking. Two-stage pipeline: stage 1
// registers the request and reads the table; stage 2 acts on the read result.
module order_book #(
    parameter int STOCK_ID = 0
) (
    input  logic                    clk,
    input  logic                    rst,
    input  order_event_t            evt,
    output logic [PRICE_LVL_W-1:0]  best_price_idx,
    output logic [PRICE_W-1:0]      best_price,
    output logic                    best_valid
);

  logic evt_valid_here;
  assign evt_valid_here = evt.valid && (evt.stock_idx == STOCK_ID);

  // order_id is 64-bit but the table is only ORDERTAB_DEPTH-deep, so a direct-mapped index
  // (low bits of order_id) collides for real, large order-reference-number volumes -- the
  // tag lets a collision be detected and dropped instead of silently corrupting whichever
  // other order now occupies that slot (verified against real NASDAQ data: millions of
  // orders in a session guarantee frequent collisions against a 4096-entry table).
  typedef struct packed {
    logic                   occupied;
    logic [ORDER_ID_W-1:0]  tag;
    logic [PRICE_LVL_W-1:0] price_idx;
    logic [SHARES_W-1:0]    shares;
  } slot_t;

  slot_t table_mem [0:ORDERTAB_DEPTH-1];

  // Real prices are absolute (e.g. $150.00), but the ladder only has PRICE_LEVELS buckets --
  // so it tracks price *relative to* this stock's first-seen price, not from zero. Matches
  // how real low-latency books stay fine-grained without needing an absolute-price-sized ladder.
  logic [PRICE_W-1:0] price_base;
  logic               price_base_set;

  // best_price_idx's backing registers (price_ladder's node_idx tree) are only written once
  // a node goes valid, so they hold X until this stock's first order -- gate the output so an
  // unquoted stock reads as a clean 0, not X, matching what covariance_engine's zero-price
  // guard expects.
  assign best_price = best_valid ? (price_base + PRICE_W'(best_price_idx) * PRICE_W'(PRICE_TICK)) : '0;

  function automatic logic [PRICE_LVL_W-1:0] price_to_idx(input logic [PRICE_W-1:0] price,
                                                            input logic [PRICE_W-1:0] base);
    logic signed [PRICE_W:0] rel;
    logic [PRICE_W-1:0]      capped;
    rel    = $signed({1'b0, price}) - $signed({1'b0, base});
    capped = (rel < 0) ? '0 :
             (rel > PRICE_W'(PRICE_TICK * (PRICE_LEVELS - 1))) ? PRICE_W'(PRICE_TICK * (PRICE_LEVELS - 1)) :
             rel[PRICE_W-1:0];
    return PRICE_LVL_W'(capped / PRICE_TICK);
  endfunction

  logic [ORDERTAB_ADDR_W-1:0] rd_addr;
  slot_t                      rd_slot;
  order_event_t               evt_q;
  logic                       valid_q;

  assign rd_addr = evt.order_id[ORDERTAB_ADDR_W-1:0];

  always_ff @(posedge clk) begin
    evt_q   <= evt;
    valid_q <= evt_valid_here;
    rd_slot <= table_mem[rd_addr];
  end

  logic                     ladder_valid;
  logic [PRICE_LVL_W-1:0]   ladder_idx;
  logic signed [SHARES_W:0] ladder_delta;

  price_ladder ladder (
      .clk(clk), .rst(rst),
      .idx(ladder_idx), .delta(ladder_delta), .valid(ladder_valid),
      .best_idx(best_price_idx), .best_valid(best_valid)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      price_base     <= '0;
      price_base_set <= 1'b0;
      ladder_valid   <= 1'b0;
    end else begin
      ladder_valid <= 1'b0;
      if (valid_q) begin
        automatic logic [ORDERTAB_ADDR_W-1:0] wr_addr;
        wr_addr = evt_q.order_id[ORDERTAB_ADDR_W-1:0];

        unique case (evt_q.op)
          // bid side only (matches the reference design's stated scope) -- sell-side
          // orders are never added, so a stale deep ask can't get stuck as "best".
          OP_ADD: if (!evt_q.buy_sell) begin
            automatic logic [PRICE_LVL_W-1:0]   pidx;
            automatic logic signed [PRICE_W:0]  rel_to_base;
            rel_to_base = $signed({1'b0, evt_q.price}) - $signed({1'b0, price_base});
            // rebase whenever the reference can no longer reach this price -- real resting
            // orders can be miles from the market (e.g. regulatory "stub quote" backstops
            // far below the touch), so a reference fixed once at the first order of the day
            // gets stuck permanently otherwise (verified against real NASDAQ data).
            if (!price_base_set || rel_to_base > $signed(PRICE_W'(PRICE_TICK * (PRICE_LEVELS - 1)))) begin
              price_base     <= evt_q.price;
              price_base_set <= 1'b1;
              pidx = '0;
            end else begin
              pidx = price_to_idx(evt_q.price, price_base);
            end
            table_mem[wr_addr] <= '{occupied: 1'b1, tag: evt_q.order_id, price_idx: pidx, shares: evt_q.shares};
            ladder_idx   <= pidx;
            ladder_delta <= $signed({1'b0, evt_q.shares});
            ladder_valid <= 1'b1;
          end

          OP_CANCEL, OP_EXECUTE: begin
            automatic logic [SHARES_W-1:0] removed, remaining;
            automatic logic                found;
            found     = rd_slot.occupied && (rd_slot.tag == evt_q.order_id);
            removed   = (evt_q.shares > rd_slot.shares) ? rd_slot.shares : evt_q.shares;
            remaining = rd_slot.shares - removed;
            if (found) begin
              table_mem[wr_addr].shares   <= remaining;
              table_mem[wr_addr].occupied <= (remaining != 0);
            end
            ladder_idx   <= rd_slot.price_idx;
            ladder_delta <= -$signed({1'b0, removed});
            ladder_valid <= found;
          end

          OP_DELETE: begin
            automatic logic found;
            found = rd_slot.occupied && (rd_slot.tag == evt_q.order_id);
            if (found) table_mem[wr_addr].occupied <= 1'b0;
            ladder_idx   <= rd_slot.price_idx;
            ladder_delta <= -$signed({1'b0, rd_slot.shares});
            ladder_valid <= found;
          end

          default: ;
        endcase
      end
    end
  end

endmodule
