import struct
import sys
import json
import numpy as np

IN_PATH = sys.argv[1] if len(sys.argv) > 1 else "filtered_4stocks.bin"
OUT_PATH = sys.argv[2] if len(sys.argv) > 2 else "lifetime_series.json"

TARGET_LOCATES = [14, 381, 3420, 5217]
NAMES = ["AAPL", "AMZN", "GOOGL", "MSFT"]
LOC_TO_IDX = {loc: i for i, loc in enumerate(TARGET_LOCATES)}
NUM_STOCKS = 4
CAPITAL = 100_000.0
REBAL_NS = 1_000_000_000  # rebalance cadence: every 1 real second of trading time

# per-stock live order book: order_id -> (price_raw, shares, is_sell)
books = [dict() for _ in range(NUM_STOCKS)]
# per-stock resting bid volume by price (raw ITCH price units, 1/10000 dollar)
bid_qty = [dict() for _ in range(NUM_STOCKS)]
best_bid = [None] * NUM_STOCKS  # raw price units


def add_bid_qty(s, price, qty):
    bid_qty[s][price] = bid_qty[s].get(price, 0) + qty
    if bid_qty[s][price] <= 0:
        del bid_qty[s][price]
        if best_bid[s] == price:
            best_bid[s] = max(bid_qty[s]) if bid_qty[s] else None
    elif best_bid[s] is None or price > best_bid[s]:
        best_bid[s] = price


def remove_order(s, order_id, shares_removed):
    entry = books[s].get(order_id)
    if entry is None:
        return
    price, shares, is_sell = entry
    removed = min(shares_removed, shares)
    remaining = shares - removed
    if not is_sell:
        add_bid_qty(s, price, -removed)
    if remaining <= 0:
        del books[s][order_id]
    else:
        books[s][order_id] = (price, remaining, is_sell)


# portfolio state
cash = [0.0] * NUM_STOCKS
shares_held = [0.0] * NUM_STOCKS
last_price = [0.0] * NUM_STOCKS  # dollars
target_shares = [0.0] * NUM_STOCKS
fills = []
pnl_series = []

# covariance/min-variance running state (population mean/moment, matches covariance_engine.sv)
wmean = np.zeros(NUM_STOCKS)
wmoment = np.zeros((NUM_STOCKS, NUM_STOCKS))
sample_count = 0
last_sample_price = [0.0] * NUM_STOCKS
first_sample_done = False


def maybe_rebalance(ts_ns):
    global sample_count, first_sample_done
    prices = np.array(last_price)
    if not np.any(prices > 0):
        return
    if not first_sample_done:
        for i in range(NUM_STOCKS):
            last_sample_price[i] = prices[i]
        first_sample_done = True
        return

    returns = np.zeros(NUM_STOCKS)
    for i in range(NUM_STOCKS):
        if last_sample_price[i] > 0 and prices[i] > 0:
            returns[i] = prices[i] / last_sample_price[i] - 1.0
        last_sample_price[i] = prices[i] if prices[i] > 0 else last_sample_price[i]

    n = sample_count
    new_mean = (wmean * n + returns) / (n + 1)
    outer = np.outer(returns, returns)
    wmoment[:] = (wmoment * n + outer) / (n + 1)
    wmean[:] = new_mean
    sample_count += 1

    cov = wmoment - np.outer(wmean, wmean)
    cov += np.eye(NUM_STOCKS) * 1e-12  # tiny regularization, avoids singular matrix on early samples

    try:
        inv = np.linalg.inv(cov)
    except np.linalg.LinAlgError:
        return
    ones = np.ones(NUM_STOCKS)
    raw_w = inv @ ones
    denom = ones @ raw_w
    if denom == 0:
        return
    weights = raw_w / denom

    for i in range(NUM_STOCKS):
        if prices[i] <= 0:
            continue
        notional = weights[i] * CAPITAL
        # truncate toward zero like the RTL's integer division -- whole shares only, so a
        # sub-share weight wobble doesn't spuriously trigger a fill
        new_target = float(int(notional / prices[i]))
        delta = new_target - target_shares[i]
        target_shares[i] = new_target
        if delta == 0:
            continue
        px = prices[i]
        side = "SELL" if delta < 0 else "BUY"
        sh = abs(delta)
        if delta < 0:
            cash[i] += px * sh
        else:
            cash[i] -= px * sh
        shares_held[i] += delta
        total = sum(cash[s] + shares_held[s] * last_price[s] for s in range(NUM_STOCKS))
        fills.append({"t": ts_ns, "stock": NAMES[i], "side": side,
                      "shares": round(sh, 2), "price": round(px, 4), "pnl": round(total, 2)})
        pnl_series.append({"t": ts_ns, "pnl": round(total, 2)})


def main():
    count = 0
    next_rebal = None
    with open(IN_PATH, "rb") as f:
        data = f.read()
    n = len(data)
    offset = 0
    while offset + 2 <= n:
        msg_len = struct.unpack(">H", data[offset:offset + 2])[0]
        start = offset + 2
        if start + msg_len > n:
            break
        p = data[start:start + msg_len]
        offset = start + msg_len
        count += 1

        mtype = p[0:1]
        if mtype not in (b"A", b"F", b"E", b"C", b"X", b"D", b"U"):
            continue
        locate = struct.unpack(">H", p[1:3])[0]
        if locate not in LOC_TO_IDX:
            continue
        s = LOC_TO_IDX[locate]
        ts = int.from_bytes(p[5:11], "big")

        if next_rebal is None:
            next_rebal = ts + REBAL_NS

        if mtype in (b"A", b"F"):
            oid = int.from_bytes(p[11:19], "big")
            is_sell = p[19:20] == b"S"
            shares = struct.unpack(">I", p[20:24])[0]
            price_raw = struct.unpack(">I", p[32:36])[0]
            books[s][oid] = (price_raw, shares, is_sell)
            if not is_sell:
                add_bid_qty(s, price_raw, shares)
        elif mtype in (b"E", b"C"):
            oid = int.from_bytes(p[11:19], "big")
            shares = struct.unpack(">I", p[19:23])[0]
            remove_order(s, oid, shares)
        elif mtype == b"X":
            oid = int.from_bytes(p[11:19], "big")
            shares = struct.unpack(">I", p[19:23])[0]
            remove_order(s, oid, shares)
        elif mtype == b"D":
            oid = int.from_bytes(p[11:19], "big")
            entry = books[s].get(oid)
            if entry:
                remove_order(s, oid, entry[1])
        elif mtype == b"U":
            oid = int.from_bytes(p[11:19], "big")
            entry = books[s].get(oid)
            if entry:
                remove_order(s, oid, entry[1])
            new_oid = int.from_bytes(p[19:27], "big")
            new_shares = struct.unpack(">I", p[27:31])[0]
            new_price = struct.unpack(">I", p[31:35])[0]
            books[s][new_oid] = (new_price, new_shares, False)
            add_bid_qty(s, new_price, new_shares)

        if best_bid[s] is not None:
            last_price[s] = best_bid[s] / 10000.0

        if ts >= next_rebal:
            maybe_rebalance(ts)
            next_rebal = ts + REBAL_NS

    final_prices = [p if p > 0 else 0 for p in last_price]
    final_total = sum(cash[i] + shares_held[i] * final_prices[i] for i in range(NUM_STOCKS))

    result = {
        "total_messages": count,
        "fills": fills,
        "pnl_series": pnl_series,
        "final": {
            "total_pnl": round(final_total, 2),
            "per_stock": [
                {"stock": NAMES[i], "shares": round(shares_held[i], 2),
                 "last_price": round(final_prices[i], 4),
                 "pnl": round(cash[i] + shares_held[i] * final_prices[i], 2)}
                for i in range(NUM_STOCKS)
            ],
        },
    }
    with open(OUT_PATH, "w") as f:
        json.dump(result, f)
    print(f"messages={count} fills={len(fills)} final_pnl={result['final']['total_pnl']}")
    for row in result["final"]["per_stock"]:
        print(row)


if __name__ == "__main__":
    main()
