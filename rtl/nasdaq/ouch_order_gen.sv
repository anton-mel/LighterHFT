import hft_pkg::*;

// Serializes a target trade into an OUCH-like Enter Order byte stream. Same
// [len_hi][len_lo][type][payload...] frame contract as itch_parser's input, for symmetry.
// Order token is ORDER_ID_W (8 bytes) wide, matching order_id elsewhere, not OUCH's real
// 14-byte ASCII token. Administrative fields we don't vary (time-in-force, firm, capacity,
// ...) are fixed constants -- this is a simplified Enter Order, not a certified OUCH 4.2 encoder.
module ouch_order_gen (
    input  logic                  clk,
    input  logic                  rst,
    input  logic [STOCK_IDX_W-1:0] stock_idx,
    input  logic                  buy_sell,
    input  logic [SHARES_W-1:0]   shares,
    input  logic [PRICE_W-1:0]    price,
    input  logic [ORDER_ID_W-1:0] order_token,
    input  logic                  start,
    output logic                  busy,
    input  logic                  ready,
    output logic [7:0]            data,
    output logic                  data_valid
);

  localparam int TOKEN_BYTES  = ORDER_ID_W / 8;
  localparam int PAYLOAD_LEN  = 42;
  localparam int MSG_LEN      = PAYLOAD_LEN + 1;  // type+payload, matches the length field
  localparam int TOTAL_BYTES  = 2 + MSG_LEN;      // + the two length-prefix bytes themselves

  logic [7:0] buf_mem [0:PAYLOAD_LEN-1];
  int         idx;

  typedef enum logic [1:0] {S_IDLE, S_BUILD, S_SEND} state_e;
  state_e state;

  always_ff @(posedge clk) begin
    if (rst) begin
      state      <= S_IDLE;
      busy       <= 1'b0;
      data_valid <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          data_valid <= 1'b0;
          if (start) begin
            busy  <= 1'b1;
            state <= S_BUILD;
          end
        end

        S_BUILD: begin
          for (int i = 0; i < TOKEN_BYTES; i++)
            buf_mem[i] <= order_token[8*(TOKEN_BYTES-1-i) +: 8];
          buf_mem[8] <= buy_sell ? "S" : "B";
          for (int i = 0; i < 4; i++)  buf_mem[9+i] <= shares[8*(3-i) +: 8];
          for (int i = 0; i < 7; i++)  buf_mem[13+i] <= 8'h00; // stock ticker (unused)
          buf_mem[20] <= 8'(stock_idx);
          for (int i = 0; i < 4; i++)  buf_mem[21+i] <= price[8*(3-i) +: 8];
          for (int i = 0; i < 4; i++)  buf_mem[25+i] <= 8'h00; // time in force
          buf_mem[29] <= "L"; buf_mem[30] <= "G"; buf_mem[31] <= "H"; buf_mem[32] <= "T"; // firm
          buf_mem[33] <= "Y"; // display
          buf_mem[34] <= "P"; // capacity
          buf_mem[35] <= "N"; // intermarket sweep
          for (int i = 0; i < 4; i++)  buf_mem[36+i] <= 8'h00; // min quantity
          buf_mem[40] <= "N"; // cross type
          buf_mem[41] <= "R"; // customer type
          idx        <= 1;
          data       <= 8'(MSG_LEN >> 8);
          data_valid <= 1'b1;
          state      <= S_SEND;
        end

        S_SEND: if (ready) begin
          if (idx == TOTAL_BYTES) begin
            data_valid <= 1'b0;
            busy       <= 1'b0;
            state      <= S_IDLE;
          end else begin
            unique case (idx)
              1:       data <= 8'(MSG_LEN);
              2:       data <= "O";
              default: data <= buf_mem[idx-3];
            endcase
            idx <= idx + 1;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
