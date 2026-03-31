# The Great Synapse - Unified HFT Trading System

A high-frequency trading system combining Zig's ultra-low latency processing with Go's networking capabilities and AI-enhanced decision making.

## System Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    THE GREAT SYNAPSE                     │
├─────────────────────────────────────────────────────────┤
│                                                           │
│  🧠 Brain: Zig HFT Engine (Sub-microsecond latency)     │
│  👁️ Eyes: Go Data Collector (Real-time market feeds)     │
│  🗣️ Voice: Order Execution (Alpaca API integration)      │
│  🤖 Mind: AI Enrichment (ML feature engineering)         │
│                                                           │
└─────────────────────────────────────────────────────────┘
```

## Performance Metrics

- **Throughput**: 290,000+ ticks/second (benchmark mode)
- **Latency**: Sub-microsecond processing in Zig engine
- **Go Bridge**: 5μs average latency
- **Live Trading**: 70+ ticks/second sustained
- **Memory**: Zero-GC with custom memory pools

## Quick Start

### Prerequisites

1. Zig compiler (0.16.0-dev or later)
2. Go 1.21 or later
3. Linux system (Ubuntu/Debian recommended)
4. Alpaca trading account (paper or live)

### Installation

```bash
# Clone the repository
cd /home/rich/productions/zig-financial-engine

# Build the Zig HFT engine
/path/to/zig build-lib src/c_api.zig -dynamic -O ReleaseFast -femit-bin=go-bridge/libc_api.so

# Build the Go components
cd go-bridge
go mod tidy
CGO_ENABLED=1 go build -o unified_system_daemon unified_system_daemon.go

# Make control script executable
cd ..
chmod +x synapse-ctl
```

### Configuration

Set your Alpaca API credentials:

```bash
export ALPACA_API_KEY="your_api_key"
export ALPACA_API_SECRET="your_api_secret"
```

Or edit them directly in the daemon configuration.

## Usage

### Control Commands

The system is controlled via the `synapse-ctl` script:

```bash
# Start the daemon
./synapse-ctl start

# Stop the daemon
./synapse-ctl stop

# Check status
./synapse-ctl status

# Restart the daemon
./synapse-ctl restart

# View live logs
./synapse-ctl logs

# Install as system service (requires sudo)
./synapse-ctl install
```

### Running as a System Service

To run the Great Synapse as a persistent system service:

```bash
# Install the service
sudo ./synapse-ctl install

# Enable auto-start on boot
sudo systemctl enable great-synapse

# Start the service
sudo systemctl start great-synapse

# Check service status
sudo systemctl status great-synapse

# View service logs
sudo journalctl -u great-synapse -f
```

## Components

### 1. Zig HFT Engine (`src/`)

The core high-frequency trading engine written in Zig:

- **`hft_system.zig`**: Main HFT system with strategy engine
- **`order_book_v2.zig`**: Lock-free order book implementation
- **`memory_pool.zig`**: Custom memory allocator for zero-GC
- **`decimal.zig`**: Fixed-point decimal arithmetic
- **`c_api.zig`**: C FFI exports for Go integration

### 2. Go Bridge (`go-bridge/`)

Network layer and API integration:

- **`unified_system_daemon.go`**: Main daemon process
- **`live_trader.go`**: Alpaca paper trading integration
- **`data_collector_v2.go`**: Automated market data collection
- **`check_account.go`**: Account verification utility

### 3. Data Collection

The data collector saves market data in AI-readable formats:

```bash
# Run standalone data collector
./data_collector_v2

# Data is saved to:
./market_data/
├── raw/           # CSV and JSON tick data
├── processed/     # Aggregated data
├── features/      # ML-ready features
└── models/        # Trained models (future)
```

### 4. Live Trading

Execute paper trades with real market connections:

```bash
# Run live paper trader
LD_LIBRARY_PATH=. ./live_trader

# Executes trades on Alpaca paper account
# Monitors positions and P&L in real-time
```

## File Structure

```
zig-financial-engine/
├── src/                    # Zig source code
│   ├── hft_system.zig     # Main HFT engine
│   ├── order_book_v2.zig  # Order matching engine
│   ├── memory_pool.zig    # Memory management
│   ├── decimal.zig        # Financial arithmetic
│   └── c_api.zig          # FFI interface
├── go-bridge/             # Go integration layer
│   ├── unified_system_daemon.go  # Main daemon
│   ├── live_trader.go     # Trading implementation
│   ├── data_collector_v2.go      # Data collection
│   └── libc_api.so        # Compiled Zig library
├── market_data/           # Collected market data
├── synapse-ctl           # Control script
├── great-synapse.service  # Systemd service file
└── README.md             # This file
```

## Monitoring

### View Performance Metrics

```bash
# Real-time metrics in logs
tail -f ~/.great-synapse/logs/synapse_*.log | grep METRICS

# Example output:
# METRICS: uptime=5m0s ticks=21000 signals=150 orders=45 tps=70.00 latency=5μs
```

### Check System Health

```bash
# Full system status
./synapse-ctl status

# Process information
ps aux | grep unified_system_daemon

# Resource usage
top -p $(pgrep unified_system_daemon)
```

## Log Files

Logs are stored in multiple locations:

1. **User logs**: `~/.great-synapse/logs/synapse_YYYYMMDD.log`
2. **System logs**: `/var/log/great-synapse/` (if running as root)
3. **Startup logs**: `~/.great-synapse/logs/startup.log`
4. **Journald**: `journalctl -u great-synapse` (if using systemd)

## Troubleshooting

### Daemon Won't Start

```bash
# Check for existing process
ps aux | grep unified_system_daemon

# Remove stale PID file
rm ~/.great-synapse/synapse.pid

# Check logs for errors
cat ~/.great-synapse/logs/startup.log
```

### Build Errors

```bash
# Ensure Zig library is built
ls -la go-bridge/libc_api.so

# Rebuild if missing
/path/to/zig build-lib src/c_api.zig -dynamic -O ReleaseFast -femit-bin=go-bridge/libc_api.so

# Set library path
export LD_LIBRARY_PATH=/home/rich/productions/zig-financial-engine/go-bridge:$LD_LIBRARY_PATH
```

### API Connection Issues

```bash
# Verify credentials
./go-bridge/check_account

# Test with environment variables
export ALPACA_API_KEY="your_key"
export ALPACA_API_SECRET="your_secret"
./synapse-ctl restart
```

## Advanced Configuration

### Performance Tuning

Edit `/etc/systemd/system/great-synapse.service`:

```ini
[Service]
# CPU affinity (pin to specific cores)
CPUAffinity=0-3

# Real-time scheduling
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=99

# Memory limits
LimitNOFILE=65536
LimitNPROC=32768
```

### Custom Strategies

Add trading strategies in `src/hft_system.zig`:

```zig
pub const Strategy = struct {
    name: []const u8,
    params: StrategyParams,
    
    pub fn evaluate(self: *Strategy, tick: MarketTick) Signal {
        // Custom strategy logic
    }
};
```

## Safety Features

- **Paper trading mode** by default
- **Rate limiting** on order execution
- **Maximum position limits**
- **Automatic shutdown** on critical errors
- **State persistence** across restarts

## API Documentation

### Zig Engine API

```c
// Initialize engine
int hft_init();

// Process market tick
int hft_process_tick(const CMarketTick* tick);

// Get trading signal
int hft_get_next_signal(CSignal* signal_out);

// Get statistics
int hft_get_stats(CSystemStats* stats);

// Cleanup
void hft_cleanup();
```

### Data Formats

Market data is saved in multiple formats:

1. **CSV**: For spreadsheets and pandas
2. **JSON**: For web APIs and NoSQL databases
3. **Parquet**: For columnar storage (future)

## Contributing

The system is designed for extension:

1. Add new strategies in `src/hft_system.zig`
2. Implement new data sources in `go-bridge/`
3. Add ML models for signal generation
4. Extend order types and execution algorithms

## License

Proprietary - The Great Synapse

## Support

For issues or questions:
- Check logs in `~/.great-synapse/logs/`
- Review this documentation
- Examine source code comments

---

**Remember**: The Great Synapse is an immortal daemon. Once started, it runs continuously, monitoring markets and executing trades 24/7. Use `./synapse-ctl` to control its power.