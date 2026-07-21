import hft_pkg::*;

// Per-stock order book: direct-mapped order table (indexed by low bits of order_id) +
// price_ladder for O(log PRICE_LEVELS) best-price tracking. Two-stage pipeline: stage 1
// registers the request and reads the table; stage 2 acts on the read result.
module order_book (
    input  logic                    clk,
    input  logic                    rst,
    input  order_event_t            evt,
    output logic [PRICE_LVL_W-1:0]  best_price_idx,
    output logic                    best_valid
);

  typedef struct packed {
    logic                   occupied;
    logic [PRICE_LVL_W-1:0] price_idx;
    logic [SHARES_W-1:0]    shares;
  } slot_t;

  slot_t table_mem [0:ORDERTAB_DEPTH-1];

  function automatic logic [PRICE_LVL_W-1:0] price_to_idx(input logic [PRICE_W-1:0] price);
    logic [PRICE_W-1:0] capped;
    capped = (price > PRICE_W'(PRICE_TICK * (PRICE_LEVELS - 1))) ?
             PRICE_W'(PRICE_TICK * (PRICE_LEVELS - 1)) : price;
    return PRICE_LVL_W'(capped / PRICE_TICK);
  endfunction

  logic [ORDERTAB_ADDR_W-1:0] rd_addr;
  slot_t                      rd_slot;
  order_event_t               evt_q;
  logic                       valid_q;

  assign rd_addr = evt.order_id[ORDERTAB_ADDR_W-1:0];

  always_ff @(posedge clk) begin
    evt_q   <= evt;
    valid_q <= evt.valid;
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
    ladder_valid <= 1'b0;
    if (valid_q) begin
      automatic logic [ORDERTAB_ADDR_W-1:0] wr_addr;
      wr_addr = evt_q.order_id[ORDERTAB_ADDR_W-1:0];

      unique case (evt_q.op)
        OP_ADD: begin
          automatic logic [PRICE_LVL_W-1:0] pidx;
          pidx = price_to_idx(evt_q.price);
          table_mem[wr_addr] <= '{occupied: 1'b1, price_idx: pidx, shares: evt_q.shares};
          ladder_idx   <= pidx;
          ladder_delta <= $signed({1'b0, evt_q.shares});
          ladder_valid <= 1'b1;
        end

        OP_CANCEL, OP_EXECUTE: begin
          automatic logic [SHARES_W-1:0] removed, remaining;
          removed   = (evt_q.shares > rd_slot.shares) ? rd_slot.shares : evt_q.shares;
          remaining = rd_slot.shares - removed;
          table_mem[wr_addr].shares   <= remaining;
          table_mem[wr_addr].occupied <= (remaining != 0);
          ladder_idx   <= rd_slot.price_idx;
          ladder_delta <= -$signed({1'b0, removed});
          ladder_valid <= rd_slot.occupied;
        end

        OP_DELETE: begin
          table_mem[wr_addr].occupied <= 1'b0;
          ladder_idx   <= rd_slot.price_idx;
          ladder_delta <= -$signed({1'b0, rd_slot.shares});
          ladder_valid <= rd_slot.occupied;
        end

        default: ;
      endcase
    end
  end

endmodule
