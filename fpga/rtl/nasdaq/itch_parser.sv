import hft_pkg::*;

// Frame contract: [len_hi][len_lo] big-endian byte count of (type+payload), then [type][payload...]
// S_EMIT decodes the just-finished message and, in the same cycle, accepts the next message's
// first byte if present -- so back-to-back messages need no dead cycle, including the cycle
// an Order Replace's decomposed synthesized Add is emitted (data_valid has no ready/backpressure
// signal to spend a cycle on, so byte consumption can never pause).
module itch_parser (
    input  logic         clk,
    input  logic         rst,
    input  logic [7:0]   data,
    input  logic         data_valid,
    output order_event_t evt,
    output logic         evt_valid
);

  localparam int PAYLOAD_MAX = 35;
  localparam int OFF_ORDER_ID  = 10;
  localparam int LEN_ORDER_ID  = 8;
  localparam int OFF_BUYSELL_A = 18;
  localparam int OFF_SHARES_A  = 19;
  localparam int OFF_PRICE_A   = 31;
  localparam int OFF_SHARES_EC = 18;
  localparam int OFF_NEW_ID_U  = 18;
  localparam int OFF_SHARES_U  = 26;
  localparam int OFF_PRICE_U   = 30;
  localparam int LEN_QTY       = 4;

  typedef enum logic [2:0] {S_LEN0, S_LEN1, S_TYPE, S_PAYLOAD, S_EMIT} state_e;
  state_e state;

  logic [15:0] msg_len, remaining;
  logic [7:0]  msg_type;
  logic [7:0]  payload [0:PAYLOAD_MAX-1];
  int          byte_idx;

  logic         replace_pending;
  order_event_t replace_add;

  function automatic logic [63:0] be_bytes(input logic [7:0] arr [0:PAYLOAD_MAX-1],
                                            input int start, input int len);
    logic [63:0] acc;
    acc = '0;
    for (int i = 0; i < len; i++) acc = (acc << 8) | arr[start+i];
    return acc;
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      state           <= S_LEN0;
      evt_valid       <= 1'b0;
      replace_pending <= 1'b0;
    end else begin
      evt_valid <= 1'b0;
      // evt.valid must default-clear too -- it's only ever set inside specific S_EMIT case
      // branches below, so without this it holds its previous value for the ~20-40 cycles it
      // takes to shift in the next message, and order_book (which gates on evt.valid, not the
      // separate evt_valid port) reprocesses the same stale event once per cycle until then.
      evt.valid <= 1'b0;

      // Emitting the decomposed Replace's synthesized Add must not pause byte-stream
      // consumption below -- the feed has no backpressure/ready signal, so a dropped cycle
      // here permanently desyncs every message boundary for the rest of the stream (verified
      // against real NASDAQ data: garbage/repeating decodes after the first 'U' message).
      if (replace_pending) begin
        evt             <= replace_add;
        evt_valid       <= 1'b1;
        replace_pending <= 1'b0;
      end

      // State machine keeps consuming data every cycle regardless of replace_pending above --
      // safe to coexist, since replace_pending only fires while state is S_LEN0/S_LEN1 (never
      // S_EMIT, as a "U" message's own S_EMIT cycle already advances state away from S_EMIT),
      // so the two blocks never drive evt/evt_valid in the same cycle.
      case (state)
        S_LEN0: if (data_valid) begin
          msg_len[15:8] <= data;
          state         <= S_LEN1;
        end

        S_LEN1: if (data_valid) begin
          msg_len[7:0] <= data;
          remaining    <= {msg_len[15:8], data};
          state        <= S_TYPE;
        end

        S_TYPE: if (data_valid) begin
          msg_type  <= data;
          remaining <= remaining - 16'd1;
          byte_idx  <= 0;
          state     <= S_PAYLOAD;
        end

        S_PAYLOAD: if (data_valid) begin
          if (byte_idx < PAYLOAD_MAX) payload[byte_idx] <= data;
          byte_idx  <= byte_idx + 1;
          remaining <= remaining - 16'd1;
          if (remaining == 16'd1) state <= S_EMIT;
        end

        S_EMIT: begin
          automatic logic [ORDER_ID_W-1:0] oid;
          automatic stock_match_t          m;
          oid = ORDER_ID_W'(be_bytes(payload, OFF_ORDER_ID, LEN_ORDER_ID));
          m   = locate_to_idx({payload[0], payload[1]});

          if (data_valid) begin
            msg_len[15:8] <= data;
            state         <= S_LEN1;
          end else begin
            state <= S_LEN0;
          end

          unique case (msg_type)
            "A", "F": begin
              evt.valid     <= m.valid;
              evt.op        <= OP_ADD;
              evt.stock_idx <= m.idx;
              evt.order_id  <= oid;
              evt.buy_sell  <= (payload[OFF_BUYSELL_A] == "S");
              evt.shares    <= SHARES_W'(be_bytes(payload, OFF_SHARES_A, LEN_QTY));
              evt.price     <= PRICE_W'(be_bytes(payload, OFF_PRICE_A, LEN_QTY));
              evt_valid     <= m.valid;
            end
            "E", "C": begin
              evt.valid     <= m.valid;
              evt.op        <= OP_EXECUTE;
              evt.stock_idx <= m.idx;
              evt.order_id  <= oid;
              evt.shares    <= SHARES_W'(be_bytes(payload, OFF_SHARES_EC, LEN_QTY));
              evt_valid     <= m.valid;
            end
            "X": begin
              evt.valid     <= m.valid;
              evt.op        <= OP_CANCEL;
              evt.stock_idx <= m.idx;
              evt.order_id  <= oid;
              evt.shares    <= SHARES_W'(be_bytes(payload, OFF_SHARES_EC, LEN_QTY));
              evt_valid     <= m.valid;
            end
            "D": begin
              evt.valid     <= m.valid;
              evt.op        <= OP_DELETE;
              evt.stock_idx <= m.idx;
              evt.order_id  <= oid;
              evt_valid     <= m.valid;
            end
            "U": begin
              // decompose replace into delete(old) this cycle, add(new) next cycle
              evt.valid     <= m.valid;
              evt.op        <= OP_DELETE;
              evt.stock_idx <= m.idx;
              evt.order_id  <= oid;
              evt_valid     <= m.valid;

              replace_add.valid     <= m.valid;
              replace_add.op        <= OP_ADD;
              replace_add.stock_idx <= m.idx;
              replace_add.order_id  <= ORDER_ID_W'(be_bytes(payload, OFF_NEW_ID_U, LEN_ORDER_ID));
              replace_add.shares    <= SHARES_W'(be_bytes(payload, OFF_SHARES_U, LEN_QTY));
              replace_add.price     <= PRICE_W'(be_bytes(payload, OFF_PRICE_U, LEN_QTY));
              replace_pending       <= m.valid;
            end
            default: ;
          endcase
        end
      endcase
    end
  end

endmodule
