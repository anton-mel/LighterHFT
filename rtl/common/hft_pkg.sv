package hft_pkg;

  parameter int NUM_STOCKS      = 4;
  parameter int STOCK_IDX_W     = $clog2(NUM_STOCKS);

  parameter int STOCK_LOCATE_W  = 16;
  parameter int TRACKING_NUM_W  = 16;
  parameter int TIMESTAMP_W     = 48;
  parameter int ORDER_ID_W      = 64;
  parameter int SHARES_W        = 32;
  parameter int PRICE_W         = 32;

  parameter int ORDERTAB_ADDR_W = 12;
  parameter int ORDERTAB_DEPTH  = 1 << ORDERTAB_ADDR_W;

  parameter int PRICE_LVL_W     = 8;
  parameter int PRICE_LEVELS    = 1 << PRICE_LVL_W;
  parameter int PRICE_TICK      = 100;

  parameter int FX_W            = 16;
  parameter int FX_FRAC         = 14;
  typedef logic signed [FX_W-1:0] fx_t;

  parameter int CORDIC_ITERS    = 14;

  typedef enum logic [1:0] {
    OP_ADD     = 2'd0,
    OP_CANCEL  = 2'd1,
    OP_EXECUTE = 2'd2,
    OP_DELETE  = 2'd3
  } book_op_e;

  typedef struct packed {
    logic                        valid;
    book_op_e                    op;
    logic [STOCK_IDX_W-1:0]      stock_idx;
    logic [ORDER_ID_W-1:0]       order_id;
    logic [PRICE_W-1:0]          price;
    logic [SHARES_W-1:0]         shares;
    logic                        buy_sell;
  } order_event_t;

  function automatic logic [STOCK_IDX_W-1:0] locate_to_idx(input logic [STOCK_LOCATE_W-1:0] locate);
    return STOCK_IDX_W'(locate % NUM_STOCKS);
  endfunction

endpackage
