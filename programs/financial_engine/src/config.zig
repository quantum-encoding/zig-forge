// CONFIGURATION MANAGEMENT
// Loads and validates service configuration from JSON

const std = @import("std");
const praetorian = @import("praetorian_guard.zig");

pub const ServiceConfig = struct {
    service: ServiceInfo,
    market_data: MarketDataConfig,
    api: ApiConfig,
    risk_management: RiskConfig,
    tenants: []TenantConfig,
    observability: ObservabilityConfig,
    operations: OperationsConfig,
    performance: PerformanceConfig,
    billing: BillingConfig,
    
    pub const ServiceInfo = struct {
        name: []const u8,
        version: []const u8,
        environment: []const u8,
        runtime_mode: []const u8,
        node_id: []const u8,
        shutdown_timeout_seconds: u32,
    };
    
    pub const MarketDataConfig = struct {
        provider: []const u8,
        mode: []const u8,
        websocket: struct {
            reconnect_attempts: u32,
            reconnect_delay_ms: u32,
            heartbeat_interval_seconds: u32,
        },
        symbols: [][]const u8,
    };
    
    pub const ApiConfig = struct {
        base_url: []const u8,
        key_env_var: []const u8,
        secret_env_var: []const u8,
        rate_limits: struct {
            orders_per_minute: u32,
            api_calls_per_minute: u32,
        },
    };
    
    pub const RiskConfig = struct {
        global: struct {
            max_daily_loss_usd: f64,
            max_total_exposure_percent: f64,
            position_sizing_mode: []const u8,
            update_account_interval_seconds: u32,
        },
        default_tenant_limits: praetorian.RiskLimits,
    };
    
    pub const TenantConfig = struct {
        id: []const u8,
        name: []const u8,
        enabled: bool,
        tier: []const u8,
        algorithm: struct {
            type: []const u8,
            parameters: std.json.Value,
        },
        capital_allocation_percent: f64,
        risk_override: ?praetorian.RiskLimits,
        symbols: ?[][]const u8 = null, // Optional tenant-specific symbols
    };
    
    pub const ObservabilityConfig = struct {
        logging: struct {
            level: []const u8,
            format: []const u8,
            output: []const u8,
            include_timestamp: bool,
            include_caller: bool,
        },
        metrics: struct {
            enabled: bool,
            prometheus: struct {
                port: u16,
                path: []const u8,
            },
        },
        telemetry: struct {
            enabled: bool,
            export_interval_seconds: u32,
            destinations: []struct {
                type: []const u8,
                path: []const u8,
            },
        },
    };
    
    pub const OperationsConfig = struct {
        health_check: struct {
            enabled: bool,
            port: u16,
            path: []const u8,
        },
        graceful_shutdown: struct {
            enabled: bool,
            drain_timeout_seconds: u32,
            cancel_pending_orders: bool,
            close_positions: bool,
        },
        backup: struct {
            state_snapshot_interval_minutes: u32,
            state_file_path: []const u8,
        },
    };
    
    pub const PerformanceConfig = struct {
        thread_pool_size: u32,
        order_queue_size: u32,
        quote_queue_size: u32,
        memory_limit_mb: u32,
        cpu_affinity: []u32,
    };
    
    pub const BillingConfig = struct {
        enabled: bool,
        rates: struct {
            per_1000_packets: f64,
            per_order: f64,
            per_api_call: f64,
        },
        export_interval_hours: u32,
        export_path: []const u8,
    };
    
    pub fn deinit(self: *ServiceConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.tenants);
    }
};

pub const ConfigLoader = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ConfigLoader {
        return .{ .allocator = allocator };
    }
    
    pub fn loadFromFile(self: *ConfigLoader, path: []const u8) !ServiceConfig {
        const file = try std.Io.Dir.cwd().openFile(path, .{});
        defer file.close();
        
        const file_size = try file.getEndPos();
        const contents = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(contents);
        
        _ = try file.read(contents);
        
        return self.loadFromString(contents);
    }
    
    pub fn loadFromString(self: *ConfigLoader, json_str: []const u8) !ServiceConfig {
        const parsed = try std.json.parseFromSlice(
            ServiceConfig,
            self.allocator,
            json_str,
            .{ 
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            },
        );
        
        // Validate configuration
        try self.validateConfig(&parsed.value);
        
        return parsed.value;
    }
    
    fn validateConfig(self: *ConfigLoader, config: *const ServiceConfig) !void {
        _ = self;
        
        // Validate service info
        if (config.service.version.len == 0) {
            return error.InvalidConfig;
        }
        
        // Validate tenants
        if (config.tenants.len == 0) {
            return error.NoTenantsConfigured;
        }
        
        var total_allocation: f64 = 0;
        for (config.tenants) |tenant| {
            if (!tenant.enabled) continue;
            total_allocation += tenant.capital_allocation_percent;
        }
        
        if (total_allocation > 100.0) {
            std.log.err("Total capital allocation exceeds 100%: {d:.2}%", .{total_allocation});
            return error.InvalidCapitalAllocation;
        }
        
        // Validate risk limits
        if (config.risk_management.global.max_daily_loss_usd <= 0) {
            return error.InvalidRiskLimits;
        }
    }
    
    pub fn getEnvironmentVariable(key: []const u8) ![]const u8 {
        return std.process.getEnvVarOwned(std.heap.page_allocator, key) catch {
            std.log.err("Missing environment variable: {s}", .{key});
            return error.MissingEnvironmentVariable;
        };
    }
};

// Structured JSON logging
pub const JsonLogger = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) JsonLogger {
        return .{
            .allocator = allocator,
        };
    }
    
    pub fn log(self: *JsonLogger, level: []const u8, message: []const u8, fields: anytype) !void {
        _ = self;
        _ = fields;
        // Structured logging output with level prefix
        std.log.info("[{s}] {s}", .{ level, message });
    }
};