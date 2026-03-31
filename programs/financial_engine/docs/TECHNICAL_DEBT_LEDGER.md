TECHNICAL_DEBT_LEDGER.md
A Comprehensive Audit of the Zig Financial Engine

Objective: To identify, categorize, and prioritize all known technical debt within the codebase. This document will serve as the roadmap for hardening the system for production deployment.
🔴 CRITICAL DEBT (High Risk / Must Fix)

These issues represent a direct threat to the core functionality and integrity of the trading system.

1. The Mocked Zig Trading API

    Location: src/alpaca_trading_api.zig

    Issue: The Zig-native Alpaca REST client still contains mocked, hardcoded responses for placing orders and getting account info.

    Risk: Catastrophic Failure. If the Go trade_executor fails to start, the Zig engine might fall back to using this mocked API without crashing. It would appear to be trading, processing signals and logging "orders," but no real orders would ever be sent to the market. This is a silent, mission-critical failure mode.

    Solution: The mocked functions must be ripped out and replaced with a full implementation of the Alpaca REST API in Zig, leveraging the now-proven zig-http-concurrent client. This will eventually make the Go bridge obsolete.

2. Disconnected Order Execution Pipeline

    Location: src/hft_system.zig (processSignal function)

    Issue: The logic to generate a trading signal is fully implemented, but the final step—sending that signal over the ZeroMQ bridge to the Go trade_executor—is the final piece of the integration.

    Risk: The system is currently "monitor-only." It can see the market and make decisions, but it cannot act on them. It is a brain without a mouth.

    Solution: Implement the final integration step within processSignal. When a buy or sell signal is generated, serialize it into a JSON message and send it to the OrderSender (ZeroMQ client) module.

🟡 MAJOR DEBT (Medium Risk / Should Fix)

These issues impact the system's configurability, safety, and core business logic.

1. Missing Risk Management & Position Tracking

    Location: System-wide.

    Issue: The core logic for tracking current positions, calculating real-time P&L, and enforcing risk rules (e.g., "max daily loss," "max position size") is not yet implemented.

    Risk: Without this, the engine is a "dumb" execution bot. It could place a thousand consecutive losing trades without ever stopping. It cannot make intelligent decisions based on its current market exposure. Running without this is financial suicide.

    Solution: Build dedicated modules for PositionManager and RiskManager. The PositionManager will subscribe to fill confirmations from the trade executor. The RiskManager will check every new signal against a set of configurable rules before allowing an order to be sent.

2. Hardcoded Strategy Parameters

    Location: src/hft_system.zig and strategy-specific files.

    Issue: Key strategy parameters (e.g., moving average lengths, RSI periods, entry/exit thresholds) are likely hardcoded as "demo values."

    Risk: The system is not configurable or optimizable. To test a new parameter, you have to recompile the entire engine.

    Solution: Move all strategy parameters into a dedicated configuration file (strategy.json or similar) that is loaded at startup.

🔵 MINOR DEBT (Low Risk / Nice to Fix)

These issues relate to code quality, maintainability, and operational elegance.

1. The "Magic Sleep" in WebSocket Auth

    Location: src/hft_alpaca_real.zig

    Issue: We are using a hardcoded std.Thread.sleep(2 * std.time.ns_per_s) to wait for WebSocket authentication to complete.

    Risk: It's a brittle "hack." If Alpaca's auth response is slow due to network latency, the system could fail by trying to subscribe before it's authenticated. It also adds an unnecessary 2-second delay to every startup.

    Solution: Re-architect the connection logic into a proper state machine. The system should wait in a CONNECTING state, move to AUTHENTICATING after sending credentials, and only proceed to SUBSCRIBING after receiving a successful authentication message from the WebSocket callback.

2. Disorganized Root Directory

    Location: Project root.

    Issue: The project contains a mix of Go source, Zig source, C files, and compiled binaries in the root directory.

    Risk: Unprofessional and confusing. It makes the project harder to navigate, build, and maintain.

    Solution: A full project cleanup. Create a bin/ directory for compiled executables, a pkg/ or libs/ for third-party code, and ensure all source code lives within the src/ and go-bridge/ directories.

This ledger is your new roadmap. It transforms the vague feeling of "things that are left to do" into a concrete, prioritized, and actionable engineering plan. The path to a truly production-grade, battle-ready system is now clear.
