# financial_engine — Red Team Audit Findings

Scope: Zig HFT/multi-tenant trading engine (15.9k LOC). Focus: integer overflow, float-for-money, race conditions, idempotency / double-spend, currency, audit, injection. Build mode: `ReleaseFast` for production binaries (build.zig:51,71,371) — integer overflow is silent wrap.

Severity legend: **CRIT**(immediate exploit) · **HIGH**(loss-of-funds path) · **MED**(reliability/integrity) · **LOW**(hygiene).

---

## C1. Decimal.mul / Decimal.div multiply before overflow check — i128 silent wrap in ReleaseFast — **CRIT**
- File: `src/decimal.zig:103`, `src/decimal.zig:110`
- ```zig
  pub fn mul(self: Self, other: Self) !Self {
      const result = @divTrunc(self.value * other.value, scale_factor);  // overflow happens here, before any check
  }
  pub fn div(self: Self, other: Self) !Self {
      const scaled = self.value * scale_factor;  // 1e9 multiplier — wraps for any value > ~1.7e29
  }
  ```
- ReleaseFast → `*` is undefined behaviour on overflow; LLVM lowers to `mul` instruction → silent two's-complement wrap. Two operands of ~$10B can wrap to a small negative, then `@divTrunc` gives an apparently small positive result.
- **Exploit sketch**: open a position with `quantity` and `price` whose scaled product crosses i128 (≈ ±1.7×10³⁸). `position_value = quantity.mul(price)` returns near-zero → `canOpenPosition` (risk_manager.zig:125) and Praetorian's exposure check (`praetorian_guard.zig:181-185`) approve a position that should bust the buying-power cap. Free leverage. Same primitive bypasses `RunawayProtection.checkOrder` (runaway_protection.zig:81).
- Fix: use `@mulWithOverflow` / `std.math.mul` and return `error.Overflow` first; same for `div`'s pre-multiply.

## C2. Decimal.fromFloat + f64-as-money pervasive — float for currency is the ground covenant violation — **CRIT**
- File: `src/decimal.zig:20-22` (`@intFromFloat(f * scale_factor)` — UB for NaN/Inf/out-of-range; no clamp), and used throughout:
  - `praetorian_guard.zig:14-25` — every risk limit is `f64`
  - `praetorian_guard.zig:181-185, 250` — `order_value`, `allocated_capital`, drawdown all `f64`
  - `multi_tenant_engine.zig:152-165` — `Quote.bid/ask`, `Order.price` are `f64`; spreads/midprices computed with `+` `-` `/` on floats (`executeSPYHunter:272`, `executeMomentumScanner:298`, `executeMeanReversion:320-325`)
  - `risk_manager.zig:250` — `Decimal.fromFloat(0.1)` for the **margin-ratio constant** (10% margin) — 0.1 is non-representable in binary float; rounds to 0.10000000000000000555...
  - `runaway_protection.zig:82, 117, 185-189` — every limit comparison done via `.toFloat()`; sub-cent loss accumulates differently than the limit
  - `signal_broadcast.zig:78-80` — `current_price`, `target_price`, `stop_loss` are `f64` **on the wire** (extern struct sent over ZMQ)
  - `trade_ipc.zig:13-15, 25-26` — `OrderSignal` JSON-serialised `quantity`, `price` as `f64`
  - `coinbase_executor.zig:165-168, coinbase_fix_client.zig:122-126, 436-437` — fills returned as `f64`
  - `c_api.zig:25` — `confidence` is `f32` (acceptable) but JSON shows price flow uses `f64` post-decode in many adjacent paths
- **Exploit sketch**: send `quantity = 0.1 + 0.2 = 0.30000000000000004` shares 1000 times; cumulative drift produces ~4e-13 share dust per op. At HFT rates dust accumulates into free fractional shares on the venue. Worse: `Praetorian.validateOrder` compares `order_value > allocated_capital` in f64 — float-equal-edge orders ($10000.00 limit, order with `100 * 100.0` = exactly representable, vs `100 * 100.01` not) admit/reject inconsistently across runs.
- Fix: ban `f64` from any monetary code path; require `Decimal` end-to-end including over the wire (i128 already in `c_api.zig::CMarketTick`).

## C3. JSON injection in Alpaca order placement — symbol/client_order_id concatenated unescaped — **CRIT**
- File: `src/alpaca_trading_api.zig:220-258`
- ```zig
  try json_body.appendSlice(self.allocator, "\"symbol\":\"");
  try json_body.appendSlice(self.allocator, order.symbol);   // <- no escaping
  try json_body.appendSlice(self.allocator, "\",\"qty\":");
  ...
  try json_body.appendSlice(self.allocator, "\",\"client_order_id\":\"");
  try json_body.appendSlice(self.allocator, client_id);      // <- no escaping; if caller-provided
  ```
- Symbol & caller-supplied client_order_id come from upstream tenants/strategies (`multi_tenant_engine.zig:386-403` builds `client_order_id` from `tenant_id` which originates in `service_config.tenants[]`).
- **Exploit sketch**: tenant configures `tenant_id = `\``A","qty":99999,"side":"sell","type":"market","time_in_force":"day","x":"`\`` → resulting JSON: `{"symbol":"AAPL", ... ,"client_order_id":"A","qty":99999,"side":"sell",...}`. Alpaca takes the **last** value for repeated keys in JSON; the malicious tenant just inflated qty and flipped side. Auth still succeeds because API key is the platform's, not the tenant's.
- Fix: use `std.json.Stringify` / proper escape, or whitelist `[A-Z0-9._-]{1,32}` for symbol and `[A-Za-z0-9_-]{1,128}` for client_order_id.

## C4. FIX field injection — SOH/`=` not stripped from values — **CRIT**
- File: `src/fix_protocol.zig:95-103` (and v5 mirrors at `fix_protocol_v5.zig:355-461`)
- ```zig
  pub fn addField(self: *Self, tag: Tag, value: []const u8) !void {
      try self.buffer.appendSlice(self.allocator, value);  // raw
      try self.buffer.append(self.allocator, 0x01);         // SOH delimiter
  }
  ```
- A `value` containing `0x01` ends the field early; remaining bytes become a new field. `client_order_id`, `symbol`, even error reasons echoed back can carry adversarial bytes (and `client_order_id` flows from tenant config).
- **Exploit sketch**: `client_order_id = "A\x0138=999999999\x01"` → broker now sees an injected `38=` (OrderQty) inside the message. Combined with C5 (raw scaled price) you can replace the entire order.
- Fix: reject any value containing 0x01, 0x02, or `=`; call from `Session.createNewOrder` with whitelisted symbols.

## C5. FIX qty/price serialised as raw scaled i128 — orders for 10⁹× requested — **CRIT** (functional, but exploitable)
- File: `src/fix_protocol.zig:233`, `src/fix_protocol.zig:247`
- ```zig
  const qty_str = try std.fmt.allocPrint(self.allocator, "{d}", .{quantity.value});  // .value is scaled by 1e9
  ```
- `quantity = Decimal.fromInt(100)` → `quantity.value = 100_000_000_000` → FIX field `38=100000000000`. If the broker doesn't reject, you've placed an order for 100 billion shares.
- Also memory leak: `placeOrder` (alpaca_trading_api.zig:224) allocates `try std.fmt.allocPrint` for `qty` and never frees it — leaks per call.
- Fix: emit `quantity` formatted via `Decimal.format`, not `.value`.

## C6. Idempotency broken — retry generates a new client_order_id — **CRIT** (double-execution)
- File: `src/alpaca_trading_api.zig:204-213`
- ```zig
  const order_num = self.last_order_id.fetchAdd(1, .monotonic);  // increments on EVERY attempt
  break :blk try std.fmt.allocPrint(..., "HFT_{d}_{d}", .{ ts_sec, order_num });
  ```
- The "client_order_id" is the broker's idempotency key. Generating a fresh one per attempt means a network-retry of the same logical order is a brand-new order to Alpaca → **the broker fills both**.
- Same pattern in multi_tenant_engine.zig:386-389 (`{tenant_id}_{ts}_{rand_u32}`): two requests in the same wall-clock second can collide on the random u32 (birthday at ~65k orders/sec), and any retry escapes idempotency.
- Fix: derive client_order_id deterministically from `(strategy, symbol, signal_id)` and reuse across retries; never regenerate.

## C7. HFTSystem double-execution — every signal hits broker AND local book — **CRIT**
- File: `src/hft_system.zig:267-305`
- ```zig
  if (self.executor) |exec| {
      _ = exec.sendOrder(order) catch ...;   // Alpaca/Coinbase
      self.metrics.orders_sent += 1;
  }
  ...
  const order = switch (signal.action) {
      .buy => try book.addOrder(.buy, .limit, signal.target_price, signal.quantity, ...),  // local book ALSO submits
  ```
- Every accepted signal both routes to the executor and inserts into the in-process matching engine. If both venues fill, the position doubles. The local book also matches against orders that never existed at the broker, creating a phantom inventory used by `strategy.position` (line 311-313) — strategy thinks it filled, executor disagrees → desync.
- Also: executor errors are swallowed (`catch |err| { std.debug.print(...); }`), then the function still proceeds to mutate local state.
- Fix: pick one path per signal; pass `executor` xor local-book mode at HFTSystem.init.

## C8. trade_ipc returns dangling slices — `parsed.deinit()` runs in defer before return — **CRIT** (UAF)
- File: `src/trade_ipc.zig:171-189`
- ```zig
  const parsed = json.parseFromSlice(OrderResponse, self.allocator, json_data, ...);
  defer parsed.deinit();             // frees backing allocations on function exit
  const response = parsed.value;     // contains pointers into freed memory
  return response;                   // <- caller receives dangling []const u8 slices
  ```
- Any access to `response.order_id`, `response.status`, `response.@"error"` post-return reads freed heap.
- Fix: dupe each field into a stable buffer, or return the `Parsed` envelope to the caller.

## C9. Predictable UUID fallback + ignored read return — **CRIT** (uninitialised memory leaks as ClOrdID)
- File: `src/coinbase_executor.zig:35-50`
- ```zig
  const fd = std.posix.openatZ(..., "/dev/urandom", ...) catch {
      const seed: u64 = @bitCast(ts.sec *% 1000000000 +% ts.nsec);
      for (0..16) |i| { uuid_bytes[i] = @truncate((seed *% (i+1)) >> ((i%8)*8)); }  // deterministic from clock
      return formatUUID(buf, uuid_bytes);
  };
  defer _ = std.c.close(fd);
  _ = std.c.read(fd, &uuid_bytes, 16);   // return value DISCARDED; partial read leaves uninit bytes
  ```
- Two bugs in one function:
  1. Fallback UUIDv4 is fully predictable (seed from `clock_gettime(REALTIME)` which an external observer can guess to ms). An attacker can pre-compute upcoming ClOrdIDs and front-run cancels.
  2. `read()` may return < 16 (EINTR, signal). Remaining `uuid_bytes` are **stack-uninitialised** in Zig (`var uuid_bytes: [16]u8 = undefined`). UB; can leak prior-call data on the wire.
- Fix: `std.crypto.random.bytes(&uuid_bytes)` (CSPRNG, infallible). Drop the fallback.

## C10. Praetorian Guard exposure ratchet — only goes up, never down — **CRIT** (DoS by trading)
- File: `src/praetorian_guard.zig:277-281`
- ```zig
  if (side == .buy) {
      profile_entry.current_positions += 1;
      profile_entry.current_exposure_usd += order_value;
  }
  ```
- No corresponding decrement on sell, on close, on broker rejection, or on cancel. Every approved buy permanently consumes capacity. After N orders, all subsequent buys fail with `"Would exceed total exposure limit"` and the tenant is bricked with no manual reset path.
- Compounded by C11 (drawdown protection is dead code).
- Fix: subscribe to fill/close events from the executor; decrement on counter-trades and on rejection. Reconcile against `getPositions()` periodically.

## C11. Praetorian drawdown protection is dead code — **CRIT** (advertised guard does not exist)
- File: `src/praetorian_guard.zig:262-272`
- ```zig
  if (profile_entry.starting_equity > 0) {            // never set anywhere
      const drawdown = ((max_equity - current_equity) / max_equity) * 100.0;
      if (drawdown > limits.max_drawdown_percent) { ... reject ... }
  }
  ```
- `starting_equity`, `current_equity`, `max_equity` (declared at `praetorian_guard.zig:39-41`) are initialised to `0.0` and **never written** anywhere in the codebase (`grep starting_equity src/` returns only the declaration and the dead check). The drawdown limit advertised in `RiskLimits.max_drawdown_percent` is never enforced.
- Fix: wire `updateAccountState` to populate equity fields and update on each closed trade.

## C12. Negative-quantity bypass in RiskManager / Praetorian — no sign check — **CRIT**
- File: `src/risk_manager.zig:103-138`, `src/praetorian_guard.zig:158-292`
- `canOpenPosition` checks `quantity.greaterThan(self.limits.max_position_size)`. A negative `quantity` trivially passes this. Then `position_value = quantity.mul(price)` is negative; `total_exposure.add(neg)` *reduces* tracked exposure → opening "negative" positions effectively *creates margin*. Same path in Praetorian (`order_value = price * quantity` with `quantity:u32` is positive, but Decimal arithmetic in `risk_manager.zig` accepts the i128 sign).
- **Exploit sketch**: call `risk_manager.openPosition("AAPL", .long, Decimal.fromInt(-1000), price)` → margin freed, exposure decreases. Subsequent legitimate buys now have extra headroom.
- Fix: assert `quantity.greaterThan(Decimal.zero())` at top of `canOpenPosition`, `openPosition`, `validateOrder`. (Praetorian uses `u32 quantity` which is at least non-negative — but no min; `0` passes minimum-order check via `0 * 200.0 < 100 = below_minimum_order` rejection — ok — but **selling** with `quantity=0` flows through with no exposure check at all, no-op approved.)

## C13. RiskManager use-after-free in updatePrice — closePosition removes while caller holds pointer — **CRIT**
- File: `src/risk_manager.zig:198-227`
- ```zig
  if (self.positions.getPtr(symbol)) |position| {       // pointer into hashmap
      position.current_price = price;
      ...
      if (should_close) { _ = self.closePosition(symbol, price) catch {}; }  // hashmap.remove invalidates `position`
      // execution continues with `position.take_profit` access on dead memory
      if (position.take_profit) |tp| { ... }
  }
  ```
- `closePosition` does `self.positions.remove(symbol)` (line 192). After the SL block triggers a close, the next-line `position.take_profit` access reads a freed entry (or worse, an entry that's been overwritten by a later put on the same slot).
- Fix: take a value-copy of the Position before the SL/TP branches, or `return` after `closePosition`.

## C14. RiskManager symbol-key UAF — borrowed slice used as hashmap key — **HIGH**
- File: `src/risk_manager.zig:159` (`try self.positions.put(symbol, position)`), and the `Position.symbol` field also points to the same caller-owned memory.
- Caller's `symbol` slice is not duped before being used as the StringHashMap key. The HFT path passes a stack-array view (`hft_system.zig:243` from `MarketTick.symbol = "AAPL"` literals — those happen to be safe because they're rodata) but FFI callers (`c_api.zig:83` slices a caller-controlled `[*c]const u8`) re-use the buffer. After the FFI call returns, the slice is dangling but the hashmap still keys on it.
- Fix: `try self.allocator.dupe(u8, symbol)` and own the lifetime; free on remove.

## C15. /tmp ZMQ IPC path is world-writable — order interception — **CRIT**
- File: `src/trade_ipc.zig:55, 71` — `ipc:///tmp/hft_orders.ipc`, `ipc:///tmp/hft_responses.ipc`
- Predictable, world-writable path. An attacker with any local-user shell can `zmq_bind(PULL, "ipc:///tmp/hft_orders.ipc")` **before** the legitimate Trade Executor process starts, capturing every signal (incl. action/symbol/qty/price) and impersonating fills back via the responses socket.
- Fix: `ipc://$XDG_RUNTIME_DIR/quantum_synapse/orders.<uid>.ipc` with `0700` parent dir; or unix socket with credential check; or TCP+CurveZMQ with pinned keys.

## C16. Signal broadcast unauthenticated, unencrypted — competitive intel theft — **HIGH**
- File: `src/signal_broadcast.zig:147-170` (`zmq_bind(PUB, ...)`); `runServer` defaults endpoint to `tcp://127.0.0.1:5555`.
- ZMQ PUB/SUB has no authentication. Any process that can reach the bind address sees every signal (`SignalAction`, symbol, target_price, stop_loss). No `ZMQ_CURVE_*` configuration; no replay-token; no signing.
- Fix: enable CurveZMQ (`ZMQ_CURVE_SERVER=1`, server_secret_key, allow-list of subscriber public keys), or wrap in TLS. Sign each `TradingSignal` with an Ed25519 over `(signal_id, sequence, timestamp_ns, symbol, action, prices)`.

## C17. Praetorian Guard memory leak — duped tenant_ids never freed — **MED**
- File: `src/praetorian_guard.zig:99-103` and 112-119
- `registerTenant` does `const id_copy = try self.allocator.dupe(u8, tenant_id);` and uses it as the StringHashMap key. `deinit` calls only `tenant_profiles.deinit()` — the duped keys leak. Same for `capital_allocations`. Long-lived process accumulates per-tenant churn.
- Fix: iterate keys and free before deinit.

## C18. ArrayList pointer invalidation — TenantEngine holds dangling `&algorithms.items[..]` — **CRIT**
- File: `src/multi_tenant_engine.zig:564-571`
- ```zig
  const engine = try TenantEngine.init(
      self.allocator,
      &self.algorithms.items[self.algorithms.items.len - 1],  // pointer into ArrayList
      ...
  );
  try self.tenants.append(self.allocator, engine);
  ```
- Subsequent `addTenant` calls may grow the `algorithms` ArrayList; growth reallocates the items buffer; **all previously stored `&algorithms.items[i]` pointers in already-spawned TenantEngines become dangling**. Each engine's `executionLoop` then reads a freed pointer to drive its strategy. UAF with attacker-influenced data (config tenants count).
- Same pattern with `praetorian_guard` optional → `&self.praetorian_guard` (line 568) is a pointer into the orchestrator's optional payload; safe only if orchestrator never moves.
- Fix: heap-allocate `TenantAlgorithm` (`allocator.create`) and store pointers in a fixed slot, or pre-`ensureTotalCapacity` to a hard cap and never exceed.

## C19. c_api buffer overread — caller-controlled `symbol_len` — **HIGH**
- File: `src/c_api.zig:83`
- `const symbol_slice = tick.symbol_ptr[0..tick.symbol_len];` — no upper bound on `tick.symbol_len`. C consumer passes any `u32`; downstream code does `std.StringHashMap.get(symbol_slice)` → reads up to 4 GB of process memory looking for a hash collision.
- Compounded by `g_hft_system` being global mutable without locking → multi-thread FFI races.
- Fix: `if (tick.symbol_len == 0 or tick.symbol_len > 32) return -EINVAL;` first.

## C20. OrderBook has zero locking despite concurrent intent — **HIGH**
- File: `src/order_book_v2.zig:201-378`
- `processOrder` mutates bids/asks ArrayLists, swaps, removes, while `cancelOrder` (line 381) walks the same lists. No mutex. The HFT engine drives `processSignal` from per-tenant threads (`multi_tenant_engine.zig:228+`) and FFI from arbitrary callers (`c_api.zig:79`). Concurrent push/pop on the unsynchronised `std.ArrayList` corrupts internal `len`, `capacity`, `items` triplets.
- `cancelOrder` also leaks: it sets `order.status = .cancelled` but **never removes the entry from `self.orders` map nor frees the `*Order`** (line 407). Long-running engines accumulate cancelled orders indefinitely.
- Fix: a per-symbol RwLock; remove cancelled orders from the map and `destroy(order)`.

## C21. Decimal.fromString — integer-part overflow, no length cap — **MED**
- File: `src/decimal.zig:33-34`
- `try std.fmt.parseInt(i64, integer_part, 10)` accepts up to ±9.2×10¹⁸. Then `value = int_val * scale_factor` — scale is 1e9 → for `int_val > ~1.7e20` (impossible in i64) ok, but `int_val = 9.2e18 * 1e9 = 9.2e27` ≤ i128.max (~1.7e38), fine. **However** sign-handling (line 46-50) subtracts `dec_value * multiplier` after `int_val * scale_factor`; if `int_val == i64.min` (`-9223372036854775808`), `int_val * scale_factor` does NOT overflow i128, but the subsequent `value -= dec_value * multiplier` can cross i128.min. ReleaseFast → silent wrap to a large positive amount.
- Also: `dec_value = parseInt(i64, dec, 10)` accepts a leading `-` in the decimal-part substring, allowing `"5.-1"` to parse as `5 - (-1)*1e8 = 5.10000000`. Effectively bypasses parsers that pre-validate the string.
- Fix: bound `integer_part.len ≤ 18`, validate decimal_part is `[0-9]+`, use checked arithmetic.

## C22. Decimal.add overflow check uses wrong threshold — silently allows large sums — **HIGH**
- File: `src/decimal.zig:81-87`
- ```zig
  if (self.value > 0 and other.value > max_safe_value - self.value) { return error.Overflow; }
  ```
- `max_safe_value = std.math.maxInt(i128) / scale_factor` ≈ 1.7e29, **not** `maxInt(i128)`. Two Decimals just below `max_safe_value` can sum to nearly 3.4e29 without triggering overflow — no actual i128 wrap, but the post-condition (representing 9-decimal-place values) is broken: future `mul` on the result then explodes.
- Fix: compare against `std.math.maxInt(i128) - other.value` directly, or use `@addWithOverflow`.

## C23. round() can overflow on near-max values — **MED**
- File: `src/decimal.zig:121-137`
- `self.value - remainder + divisor` does no overflow check. Rounding up a value within `divisor` of `i128.max` wraps in ReleaseFast.
- Fix: branch on sign and use `@addWithOverflow`.

## C24. trade_ipc receive buffer overflow — `buffer[result] = 0` when result > len — **HIGH**
- File: `src/trade_ipc.zig:154-167`
- ```zig
  const result = c.zmq_recv(self.recv_socket, &buffer, buffer.len - 1, ZMQ_DONTWAIT);
  // zmq_recv returns the actual message size, which may be GREATER than buffer.len-1 (truncation)
  buffer[@intCast(result)] = 0;   // OOB write if result >= 1024
  ```
- ZMQ docs: "If the message is larger than the supplied buffer, the message is truncated and zmq_recv returns the original message size." Adversary controlling the response endpoint (cf. C15) can send a 4 GB response → `result = 4_000_000_000` → write 4 GB past stack/heap buffer → instant memory corruption.
- Fix: `const n = @min(result, buffer.len - 1); buffer[n] = 0;`

## C25. Praetorian: unsynchronised reads of account state during validation — **HIGH**
- File: `src/praetorian_guard.zig:249-250`
- `validateOrder` reads `self.total_buying_power` and `self.capital_allocations.get(...)` while holding only `profile_entry.mutex`. A concurrent `updateAccountState` (line 128) takes `account_mutex` and writes `total_buying_power` — torn read in `validateOrder`. Also `incrementRejection` (line 294-302) mutates `self.rejection_reasons` and `self.total_orders_rejected` from arbitrary threads with no lock.
- Fix: take `account_mutex` for the read; convert counters to `std.atomic.Value(u64)`.

## C26. Praetorian market-order value estimate is a magic constant — **HIGH** (size-cap bypass for pricey assets)
- File: `src/praetorian_guard.zig:181-185`
- ```zig
  const order_value = if (price) |p| p * @as(f64, @floatFromInt(quantity))
                      else @as(f64, @floatFromInt(quantity)) * 200.0;  // !!!
  ```
- Market orders always estimate at $200/share. For $4000 shares (BRK.A), a `qty=10` market order is estimated as $2,000 → passes `max_order_value_usd = 25,000`. Real fill is $40,000. Exposure cap blown by 16×.
- Fix: pass last-trade price from the order book; reject market orders for symbols without a recent quote.

## C27. multi_tenant capital allocation > 100% — recomputed but not redistributed — **MED**
- File: `src/multi_tenant_engine.zig:597-600`
- `capital_percent = 100.0 / tenants.items.len` — but registerTenant uses *current* tenant count for *only the new tenant*. Tenant 1 keeps its 100%, tenant 2 gets 50%, tenant 3 gets 33% → total allocation = 100 + 50 + 33 = 183%.
- Fix: re-register every tenant after addTenant, or pre-declare allocations from config.

## C28. multi_tenant random pre-trade sleep — modulo bias + 0–99 ms HFT latency — **MED**
- File: `src/multi_tenant_engine.zig:374-375` — `const delay = std.crypto.random.int(u32) % 100;`
- Modulo bias is negligible at 100, but a 0–99 ms sleep before placing every order is catastrophic for an "HFT" engine. Also makes timing non-deterministic, which compounds C25 races.
- Fix: remove the sleep, rely on broker rate-limit responses.

## C29. multi_tenant marketDataDistributor cannot be stopped — **MED**
- File: `src/multi_tenant_engine.zig:679-726`
- `while (true)` with no `should_stop` check; the orchestrator's `deinit` joins tenant threads but the distributor thread spins forever after shutdown, accessing `self.tenants` whose backing arena may have been destroyed.
- Fix: an atomic stop flag and a join in `deinit`.

## C30. Currency type does not exist — USD subtracted from BTC silently — **HIGH** (correctness)
- No `Currency` enum, no `Money(Currency, Decimal)` newtype. `Decimal` arithmetic happily subtracts a EUR-denominated value from a USD one. The strategies and risk engine treat all numbers as fungible. A multi-asset tenant routing both `SPY` and `BTC-USD` via Coinbase mixes prices in the same `position_value` aggregate.
- Fix: introduce `Money { ccy: Currency, amount: Decimal }` with arithmetic that errors on mismatch.

## C31. No audit log — every trade printed to stdout — **CRIT** (compliance + integrity)
- `grep -rn "audit\|hash_chain\|append.only\|journal" src/` returns nothing. Trades, signals, and order responses are emitted via `std.debug.print` only; lost on stdout rotation, no append-only journal, no hash-chained record, no signed log. An attacker with stdin/stdout redirect (or just buffering) can rewrite/erase activity history. Required for any regulated trading.
- Fix: append-only log file with `O_APPEND` writes of CBOR-encoded events, each containing `prev_hash + sha256(payload)` (Merkle chain). Sign daily root with offline key.

## C32. Dust accounting — divTrunc systematically rounds toward zero — **MED**
- `Decimal.mul` (line 103) and `Decimal.div` (line 111) use `@divTrunc`. For sells the truncation reduces what the seller receives; for fees that are computed as `principal.mul(rate)` the truncation reduces the fee. Across millions of trades the dust accumulates somewhere — but **nowhere in the codebase is the rounding remainder accounted for**, which means it silently disappears (or, in net, is kept by whichever party benefits from `@divTrunc` rounding direction).
- For fees (none implemented yet — but when they are): truncation rounds the fee *toward zero* (i.e. against the house when fee is positive), but for a *seller's gross proceeds* truncation rounds against the seller. Direction-dependent. Banker's rounding or an explicit `RoundingMode` enum is required.
- Fix: track a per-account dust-residual ledger; add `Decimal.divRem` returning quotient and remainder.

## C33. `catch unreachable` on bufPrint of unbounded data — **MED**
- File: `src/fix_protocol_v5.zig:355-461` (10+ sites), `src/multi_tenant_engine.zig:494,497`
- `bufPrint(&buf, "{d}", .{value}) catch unreachable` is sound only if `buf` is statically large enough for *every* `value`. For i128 (up to 40 chars) into a smaller `buf` (some of these are 16/24 bytes), an oversized value triggers an unreachable panic — a remote-controlled DoS if `value` ever flows from network input. Even where buffers are sized, `catch unreachable` removes the safety net for future refactors.
- Fix: return the error or use `bufPrintZ` with proven-large buffers and `assert`.

## C34. fix_protocol checksum scope wrong + body-length lookup is fragile — **MED**
- File: `src/fix_protocol.zig:128, 152-159`
- `body_start = indexOf(buffer.items, "35=")`; if any prior field's *value* contains the literal string `35=` (e.g. an `OnBehalfOfCompID` set to `"OPEN35=BUY"`), body_length is computed against the wrong offset and the broker drops the message. More importantly, the checksum sums **all bytes including the BodyLength field** but FIX 4.4 specifies the checksum is computed over the message excluding the CheckSum field — that part is right; the bug is the prior body-length offset.
- Also: `getCurrentTimestamp()` returns Unix seconds (`fix_protocol.zig:5-9`) — FIX `SendingTime` (52) requires `YYYYMMDD-HH:MM:SS.sss` UTC. Every message will be rejected.
- Fix: track field offsets explicitly during build; format `SendingTime` correctly.

## C35. RiskManager.openPosition: same-side aggregation skipped, opposite-side bypass — **HIGH**
- File: `src/risk_manager.zig:117-122` and 142-164
- `canOpenPosition` adds the new quantity to the existing position's quantity regardless of side (`existing.quantity.add(quantity)`). For an existing 1000-long, opening a 500-short *does not* check that 500 is itself within `position_limit_per_symbol` from a directional standpoint; nor does `openPosition` *update* the existing position — it overwrites via `try self.positions.put(symbol, position)` (line 159), so opening any new position on an existing symbol silently destroys the prior position's bookkeeping (entry_price, opened_at, stops). Closing the original is no longer possible because `closePosition` reads the new (overwritten) entry_price.
- Fix: explicit `addToPosition` / `flipSide` / `replacePosition` flow; never silently overwrite.

## C36. FIX session sequence numbers are in-memory only — **HIGH** (broker disconnect/reject)
- File: `src/fix_protocol.zig:175, 186-187`
- `outgoing_seq_num` initialised to 1 every `Session.init`. After a process restart the broker still expects the previous `MsgSeqNum + 1`; resetting to 1 forces the broker to send `Reject (MsgSeqNum too low)` and may auto-disconnect / require manual reset. There is no persistence and no `ResetSeqNumFlag (141=Y)` logic on logon.
- Fix: persist seq num to disk per session, restore on init.

## C37. SignalPublisher accepts caller-supplied symbol with no length check on topic — **LOW**
- File: `src/signal_broadcast.zig:200-203`
- `topic_buf: [32]u8` and `bufPrint("SIGNAL:{s}", .{sym})` — `sym` is from `getSymbol()` which caps at 16, so 23 ≤ 32. Safe. Logging here for the auditor: tightly coupled — if `setSymbol` ever raises the cap to 32, the format will overflow `topic_buf`.
- Fix: assert at compile time that `7 + symbol.len ≤ topic_buf.len`.

## C38. PaperTradingExecutor / NullExecutor / FIXEngine never actually transmit — **MED** (false sense of security)
- `fix_protocol.zig:303-310` — `connect()` allocates a logon message and frees it without sending anywhere; `is_connected = true`. Same for `sendOrder` and `maintainConnection`. The FIX engine is a print-only stub, but `LiveTradingSystem` (`live_trading.zig:104-119`) presents itself as wired to a real exchange and prints "✅ System is now LIVE!".
- Risk: an operator believing they have routed an order when in reality nothing went out (or vice-versa).
- Fix: gate the message-only stub behind an explicit `.dry_run` mode and refuse to claim "LIVE".

---

# Top-priority fix order (loss-of-funds first)
1. **C1, C2** — kill float-money + fix Decimal overflow (foundational)
2. **C3, C4, C5** — JSON/FIX injection on outgoing orders
3. **C6, C7** — idempotency + double-execution
4. **C12, C13, C14, C18** — memory-safety in risk path
5. **C15, C16** — auth/encryption on the IPC + signal channels
6. **C10, C11, C26** — make Praetorian actually enforce the limits it claims
7. **C31** — append-only audit log (compliance blocker)

# Build hardening recommendations (config-only, no patches)
- Replace `optimize = .ReleaseFast` (build.zig:51,71,371) with `.ReleaseSafe` for any binary that processes external input. Performance delta on this codebase is dominated by ZMQ + HTTP, not arithmetic — the safety wins are worth it.
- Add a `-Dstrict-money` build option that fails compilation on any `f64` parameter named `price`, `qty`, `quantity`, `amount`, `value` (a small build.zig source-grep step).

— end findings —
