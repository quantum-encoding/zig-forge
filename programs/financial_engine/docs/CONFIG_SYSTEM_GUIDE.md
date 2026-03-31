# 🎮 Mission Control: Configuration-Driven HFT Engine

## 🚀 The Revolution

The HFT engine no longer requires recompilation to change trading parameters. The system is now **data-driven**, not code-driven. All trading strategies, symbols, and risk parameters are loaded from external JSON configuration files at runtime.

## 🔧 Core Architecture

### The ConfigManager
A robust configuration management system that:
- Loads JSON configuration files
- Validates all parameters
- Supports environment variable overrides
- Provides clear error messages

### Command-Line Interface
```bash
# Load European pre-market configuration
./hft_alpaca_real --config config/european_premarket.json

# Load US tech stocks configuration
./hft_alpaca_real --config config/us_tech_regular.json

# Load aggressive scalping configuration
./hft_alpaca_real --config config/aggressive_scalping.json

# Show help
./hft_alpaca_real --help
```

## 📁 Configuration Files

### Structure
Each configuration file controls:

#### 🔑 API Credentials
```json
{
    "paper_trading": true,              // Paper or live trading mode
}
```
Note: API keys are loaded from environment variables for security

#### ⚡ Trading Parameters
```json
{
    "max_order_rate": 10000,           // Max orders per second
    "max_message_rate": 100000,        // Max messages per second
    "latency_threshold_us": 100,       // Latency threshold in microseconds
    "tick_buffer_size": 50000,         // Market data buffer size
    "enable_logging": true,            // Enable detailed logging
    "enable_live_trading": false       // Enable order execution
}
```

#### 📈 Strategy Parameters
```json
{
    "max_position": 5000,              // Maximum position size
    "max_spread": 0.10,                // Maximum bid-ask spread
    "min_edge": 0.02,                  // Minimum profit edge
    "tick_window": 100,                // Analysis window size
    "min_profit_threshold": 0.0015,    // Minimum profit to trigger trade
    "position_sizing_pct": 0.15        // Position sizing percentage
}
```

#### 🛡️ Risk Management
```json
{
    "stop_loss_percentage": 0.015,     // Stop loss threshold
    "max_position_value": 100000,      // Maximum position value in USD
    "max_daily_trades": 200,           // Daily trade limit
    "max_orders_per_minute": 100,      // Rate limiting
    "min_order_size": 1,               // Minimum order size
    "max_order_size": 500,             // Maximum order size
    "enable_short_selling": true,      // Allow short positions
    "use_market_orders": false         // Use market vs limit orders
}
```

#### ⏰ Operational Settings
```json
{
    "enable_pre_market": true,         // Trade in pre-market
    "enable_after_hours": false,       // Trade after hours
    "risk_check_interval_ms": 500,     // Risk check frequency
    "order_timeout_ms": 20000,         // Order timeout
    "run_duration_seconds": 23400,     // Run duration (null for indefinite)
    "startup_mode": "monitor_only"     // "monitor_only", "live_trading", or "simulation"
}
```

#### 📊 Trading Symbols
```json
{
    "symbols": [
        "AAPL",
        "MSFT",
        "GOOGL",
        "AMZN",
        "NVDA"
    ]
}
```

## 🎯 Pre-Built Configurations

### 1. European Pre-Market (`config/european_premarket.json`)
- **Focus**: European stocks in pre-market hours
- **Symbols**: ASML, SAP, SHEL, BP, NVS, TTE, UBS, BBVA, SAN, RACE
- **Mode**: Conservative, monitor-only by default
- **Duration**: 1 hour (3600 seconds)

### 2. US Tech Regular Hours (`config/us_tech_regular.json`)
- **Focus**: Major US tech stocks during regular hours
- **Symbols**: AAPL, MSFT, GOOGL, AMZN, NVDA, META, TSLA, AMD, INTC, CRM
- **Mode**: Standard HFT parameters
- **Duration**: Full trading day (23400 seconds)

### 3. Crypto 24/7 (`config/crypto_24h.json`)
- **Focus**: Major cryptocurrencies
- **Symbols**: BTC/USD, ETH/USD, SOL/USD, etc.
- **Mode**: High-frequency, tight spreads
- **Duration**: Indefinite (24/7 operation)

### 4. Aggressive Scalping (`config/aggressive_scalping.json`)
- **Focus**: ETF scalping
- **Symbols**: SPY, QQQ, IWM, DIA, VXX
- **Mode**: Ultra-aggressive, live trading
- **Duration**: Indefinite

### 5. Conservative Swing (`config/conservative_swing.json`)
- **Focus**: Long-term ETFs
- **Symbols**: SPY, VOO, VTI, IVV, AGG, GLD, TLT, VNQ, EFA, EEM
- **Mode**: Very conservative, large spreads
- **Duration**: Full trading day

## 🔐 Security

### Environment Variables
API credentials are never stored in configuration files:
```bash
export ALPACA_API_KEY="your_api_key_here"
export ALPACA_API_SECRET="your_api_secret_here"
export ALPACA_PAPER_TRADING="true"  # Optional, defaults to true
```

### Configuration Validation
The system validates:
- API credentials presence
- Symbol list not empty
- Risk parameters within safe ranges
- All required fields present

## 🚦 Startup Modes

### Monitor-Only Mode
- Receives real market data
- Analyzes and generates signals
- **Does NOT execute orders**
- Perfect for testing strategies

### Live Trading Mode
- Full order execution enabled
- Real positions and P&L
- Use with caution

### Simulation Mode
- Middle ground between monitor and live
- Simulates order execution locally
- No real orders sent

## 🎮 Usage Examples

### Quick Test
```bash
# Set credentials
export ALPACA_API_KEY="PK..."
export ALPACA_API_SECRET="sk..."

# Run European pre-market for 1 hour
./hft_alpaca_real --config config/european_premarket.json
```

### Production Deployment
```bash
# Load credentials from secure store
source /secure/credentials.sh

# Run US tech stocks all day
nohup ./hft_alpaca_real --config config/us_tech_regular.json > logs/trading.log 2>&1 &
```

### Testing New Strategy
```bash
# Create custom configuration
cp config/us_tech_regular.json config/my_strategy.json
# Edit my_strategy.json with your parameters

# Test in monitor mode first
./hft_alpaca_real --config config/my_strategy.json
```

## 🔍 Monitoring

The system provides real-time statistics:
- Connection status
- Messages/quotes/trades received
- HFT engine performance
- Signal generation rate
- Position tracking

## 🛠️ Creating Custom Configurations

1. Copy an existing configuration:
```bash
cp config/us_tech_regular.json config/my_config.json
```

2. Edit parameters to match your strategy

3. Test in monitor-only mode first:
```json
"startup_mode": "monitor_only"
```

4. Once validated, enable live trading:
```json
"startup_mode": "live_trading"
```

## 🎯 The Mission Control Advantage

1. **No Recompilation**: Change strategies without touching code
2. **Multiple Strategies**: Run different configurations for different market conditions
3. **A/B Testing**: Compare strategy performance side-by-side
4. **Rapid Iteration**: Test new ideas in minutes, not hours
5. **Production Safety**: Configuration validation prevents dangerous parameters
6. **Version Control**: Track strategy evolution through git

## 🚀 Next Steps

The configuration system is the foundation for:
- Web-based configuration UI
- Strategy backtesting framework
- Multi-instance orchestration
- Cloud deployment automation
- Real-time parameter tuning

Welcome to Mission Control. The engine is no longer a monolith—it's a flexible, configurable weapon ready for any market condition.

🔱 *The JesterNet Prevails* 🔱