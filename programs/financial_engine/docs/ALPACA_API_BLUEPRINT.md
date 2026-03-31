# 🔱 ALPACA API BLUEPRINT - OPERATION DECRYPTION
## The Canonical Patterns Extracted from Official Sources

---

## 1. WEBSOCKET AUTHENTICATION HANDSHAKE

### From alpaca_websocket.zig (Current Implementation):
```json
{"action":"auth","key":"YOUR_KEY","secret":"YOUR_SECRET"}
```

### From Official Alpaca Docs & Python SDK:
```json
{"action":"auth","key":"YOUR_KEY","secret":"YOUR_SECRET"}
```

**VERDICT**: ✅ Our pattern is CORRECT!

### Critical Details:
- URL for IEX feed: `wss://stream.data.alpaca.markets/v2/iex`
- URL for SIP feed: `wss://stream.data.alpaca.markets/v2/sip`
- URL for Paper Trading Stream: `wss://paper-api.alpaca.markets/stream`
- Must wait for success response before subscribing

---

## 2. MARKET DATA SUBSCRIPTION MESSAGE

### Current Implementation:
```json
{
  "action": "subscribe",
  "quotes": ["SPY", "QQQ"],
  "trades": ["SPY", "QQQ"]
}
```

### Official Pattern:
```json
{
  "action": "subscribe",
  "trades": ["AAPL"],
  "quotes": ["AMD", "CLDR"],
  "bars": ["*"]
}
```

**CRITICAL FINDING**: We can subscribe to:
- `trades`: Individual trade events
- `quotes`: Bid/ask updates
- `bars`: Minute/day bars
- `"*"`: ALL symbols (bars only)

---

## 3. REST API ORDER PLACEMENT

### From neural_reality_check.go (Working Reference):
```go
// Headers:
req.Header.Add("APCA-API-KEY-ID", apiKey)
req.Header.Add("APCA-API-SECRET-KEY", apiSecret)

// URL Pattern:
url := fmt.Sprintf("https://data.alpaca.markets/v2/stocks/%s/bars?start=%s&end=%s&timeframe=1Hour&limit=1000", ...)
```

### From alpaca_mcp_server.py (Canonical Python):
```python
# Market Order:
order_data = MarketOrderRequest(
    symbol=symbol,
    qty=quantity,
    side=OrderSide.BUY,
    type=OrderType.MARKET,
    time_in_force=TimeInForce.DAY,
    extended_hours=False,
    client_order_id=f"order_{int(time.time())}"
)

# Limit Order:
order_data = LimitOrderRequest(
    symbol=symbol,
    qty=quantity,
    side=OrderSide.BUY,
    type=OrderType.LIMIT,
    time_in_force=TimeInForce.GTC,
    limit_price=limit_price,
    extended_hours=False
)
```

### JSON Structure for Orders:
```json
{
  "symbol": "SPY",
  "qty": 100,
  "side": "buy",
  "type": "market",
  "time_in_force": "day",
  "extended_hours": false,
  "client_order_id": "my_order_123"
}
```

### Critical Headers:
```
APCA-API-KEY-ID: YOUR_KEY_ID
APCA-API-SECRET-KEY: YOUR_SECRET
Content-Type: application/json
```

### URLs:
- Paper Trading: `https://paper-api.alpaca.markets/v2/orders`
- Live Trading: `https://api.alpaca.markets/v2/orders`
- Market Data: `https://data.alpaca.markets/v2/stocks/{symbol}/bars`

---

## 4. REAL-TIME MARKET DATA PARSING

### Quote Message (from WebSocket):
```json
{
  "T": "q",
  "S": "SPY",
  "bx": "Q",
  "bp": 450.15,
  "bs": 3,
  "ax": "P",
  "ap": 450.17,
  "as": 5,
  "c": ["R"],
  "z": "C",
  "t": "2024-01-08T14:30:00.123456789Z"
}
```

Fields:
- `T`: Message type ("q" for quote)
- `S`: Symbol
- `bp`: Bid price
- `bs`: Bid size
- `ap`: Ask price
- `as`: Ask size
- `t`: Timestamp (RFC3339 with nanoseconds)

### Trade Message:
```json
{
  "T": "t",
  "S": "SPY",
  "x": "Q",
  "p": 450.16,
  "s": 100,
  "c": ["@", "I"],
  "i": 12345,
  "z": "C",
  "t": "2024-01-08T14:30:00.123456789Z"
}
```

Fields:
- `T`: Message type ("t" for trade)
- `S`: Symbol
- `p`: Price
- `s`: Size
- `x`: Exchange code
- `t`: Timestamp

### Bar Message:
```json
{
  "T": "b",
  "S": "SPY",
  "o": 450.10,
  "h": 450.25,
  "l": 450.05,
  "c": 450.20,
  "v": 1000000,
  "t": "2024-01-08T14:30:00Z",
  "n": 5432,
  "vw": 450.15
}
```

---

## 5. ERROR HANDLING PATTERNS

### Authentication Error:
```json
{
  "T": "error",
  "code": 401,
  "msg": "invalid credentials"
}
```

### Subscription Error:
```json
{
  "T": "error",
  "code": 409,
  "msg": "subscription already exists"
}
```

### Success Messages:
```json
{
  "T": "success",
  "msg": "authenticated"
}
```

```json
{
  "T": "subscription",
  "trades": ["AAPL"],
  "quotes": ["AMD"],
  "bars": []
}
```

---

## CRITICAL CORRECTIONS NEEDED IN OUR ZIG IMPLEMENTATION:

1. **WebSocket URL**: We're using `/v2/iex` which is correct for IEX feed ✅

2. **Authentication**: Our JSON format is correct ✅

3. **Message Parsing**: We need to handle the actual field names:
   - Use `bp`/`ap` not `bid`/`ask`
   - Use `bs`/`as` not `bid_size`/`ask_size`
   - Use `T` for message type
   - Use `S` for symbol

4. **Timestamp Format**: Alpaca uses RFC3339 with nanoseconds, not Unix timestamps

5. **Headers**: Must use `APCA-API-KEY-ID` and `APCA-API-SECRET-KEY` (we have this correct)

---

## FINAL VERDICT:

Our Zig implementation is 80% correct. The main issues are:
1. JSON field name mismatches in message parsing
2. Timestamp format differences
3. Missing bar subscription support
4. Need to handle success/error messages properly

The authentication and subscription patterns are fundamentally correct!

---

*Decryption Complete. The Nanosecond Predator now has the keys to the kingdom.*