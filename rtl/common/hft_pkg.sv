package hft_pkg;

  parameter int NUM_STOCKS      = 4;
  parameter int STOCK_IDX_W     = $clog2(NUM_STOCKS);

  parameter int STOCK_LOCATE_W  = 16;
  parameter int TRACKING_NUM_W  = 16;
  parameter int TIMESTAMP_W     = 48;
  parameter int ORDER_ID_W      = 64;
  parameter int SHARES_W        = 32;
  parameter int PRICE_W         = 32;

  parameter int ORDERTAB_ADDR_W = 18;
  parameter int ORDERTAB_DEPTH  = 1 << ORDERTAB_ADDR_W;

  parameter int PRICE_LVL_W     = 8;
  parameter int PRICE_LEVELS    = 1 << PRICE_LVL_W;
  // PRICE_TICK * PRICE_LEVELS bounds the total price range trackable relative to each
  // stock's reference (set once, at its first order of the day) -- too narrow and every
  // real stock saturates the ladder within minutes (verified against real NASDAQ data:
  // 100 = $0.01/tick, $2.55 total range, saturated almost immediately). A real system
  // would periodically rebase the reference instead of fixing it for the whole session;
  // this is the cheaper fix for now.
  parameter int PRICE_TICK      = 5000;

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
