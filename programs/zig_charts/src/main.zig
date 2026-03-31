//! Zig Charts CLI
//!
//! High-performance chart generation from JSON specifications.
//! Designed for AI integration via structured output.
//!
//! Usage:
//!   zchart render <file.json>     # Render chart from JSON file
//!   zchart render -               # Render chart from stdin (for AI piping)
//!   zchart demo                   # Generate all demo charts
//!   zchart demo candlestick       # Generate specific demo chart
//!   zchart --output <file>        # Write to specific file

const std = @import("std");
const charts = @import("lib.zig");
const json = @import("json.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Parse args using new iterator pattern
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var output_file: ?[]const u8 = null;
    var output_dir: []const u8 = "/tmp";
    var command: ?[]const u8 = null;
    var input_file: ?[]const u8 = null;

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--output") or std.mem.eql(u8, args[i], "-o")) {
            if (i + 1 < args.len) {
                output_file = args[i + 1];
                output_dir = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, args[i], "--version") or std.mem.eql(u8, args[i], "-v")) {
            std.debug.print("zchart 1.0.0\n", .{});
            return;
        } else if (!std.mem.startsWith(u8, args[i], "-")) {
            if (command == null) {
                command = args[i];
            } else {
                input_file = args[i];
            }
        }
    }

    // Create IO context - Zig 0.16 compatible
    var io_impl = std.Io.Threaded.init(allocator, .{
        .environ = .{ .block = .{ .slice = @ptrCast(std.mem.span(std.c.environ)) } },
    });
    defer io_impl.deinit();
    const io = io_impl.io();

    const cmd = command orelse "demo";

    if (std.mem.eql(u8, cmd, "render")) {
        try renderFromJson(allocator, io, input_file, output_file);
    } else if (std.mem.eql(u8, cmd, "demo")) {
        try runDemos(allocator, io, input_file, output_dir);
    } else if (std.mem.eql(u8, cmd, "help")) {
        printUsage();
    } else {
        // Backwards compatibility: treat as chart type for demo
        try runDemos(allocator, io, cmd, output_dir);
    }
}

fn renderFromJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_file: ?[]const u8,
    output_file: ?[]const u8,
) !void {
    // Read JSON input
    var json_data: []u8 = undefined;

    if (input_file) |file| {
        if (std.mem.eql(u8, file, "-")) {
            // Read from stdin
            json_data = try readStdin(allocator, io);
        } else {
            // Read from file
            json_data = try readFile(allocator, io, file);
        }
    } else {
        // Default to stdin
        json_data = try readStdin(allocator, io);
    }
    defer allocator.free(json_data);

    // Parse and render
    const svg = json.chartFromJson(allocator, json_data) catch |err| {
        std.debug.print("Error parsing JSON: {}\n", .{err});
        return;
    };
    defer allocator.free(svg);

    // Output
    if (output_file) |file| {
        if (!std.mem.eql(u8, file, "-")) {
            try writeFile(io, file, svg);
            std.debug.print("Chart written to {s}\n", .{file});
            return;
        }
    }

    // Write to stdout (via stderr for now as stdout API changed in Zig 0.16)
    // For file output, use -o flag
    std.debug.print("{s}\n", .{svg});
}

fn readStdin(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    // Open stdin using the IO context
    const stdin = try std.Io.Dir.cwd().openFile(io, "/dev/stdin", .{});
    defer stdin.close(io);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    var pos: u64 = 0;
    while (true) {
        const n = stdin.readPositionalAll(io, &read_buf, pos) catch break;
        if (n == 0) break;
        try buf.appendSlice(allocator, read_buf[0..n]);
        pos += n;
    }

    return try buf.toOwnedSlice(allocator);
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);

    const data = try allocator.alloc(u8, size);
    _ = try file.readPositionalAll(io, data, 0);

    return data;
}

fn runDemos(
    allocator: std.mem.Allocator,
    io: std.Io,
    chart_type: ?[]const u8,
    output_dir: []const u8,
) !void {
    if (chart_type) |ct| {
        if (std.mem.eql(u8, ct, "candlestick")) {
            try generateCandlestick(allocator, io, output_dir);
        } else if (std.mem.eql(u8, ct, "line")) {
            try generateLine(allocator, io, output_dir);
        } else if (std.mem.eql(u8, ct, "bar")) {
            try generateBar(allocator, io, output_dir);
        } else if (std.mem.eql(u8, ct, "sparkline")) {
            try generateSparkline(allocator, io, output_dir);
        } else if (std.mem.eql(u8, ct, "pie")) {
            try generatePie(allocator, io, output_dir);
        } else if (std.mem.eql(u8, ct, "gauge")) {
            try generateGauge(allocator, io, output_dir);
        } else if (std.mem.eql(u8, ct, "progress")) {
            try generateProgress(allocator, io, output_dir);
        } else if (std.mem.eql(u8, ct, "scatter")) {
            try generateScatter(allocator, io, output_dir);
        } else if (std.mem.eql(u8, ct, "area")) {
            try generateArea(allocator, io, output_dir);
        } else if (std.mem.eql(u8, ct, "heatmap")) {
            try generateHeatmap(allocator, io, output_dir);
        } else {
            std.debug.print("Unknown chart type: {s}\n", .{ct});
            printUsage();
        }
    } else {
        // Generate all demos
        std.debug.print("Zig Charts Demo - Generating sample charts\n\n", .{});

        try generateCandlestick(allocator, io, output_dir);
        try generateLine(allocator, io, output_dir);
        try generateBar(allocator, io, output_dir);
        try generateSparkline(allocator, io, output_dir);
        try generatePie(allocator, io, output_dir);
        try generateGauge(allocator, io, output_dir);
        try generateProgress(allocator, io, output_dir);
        try generateScatter(allocator, io, output_dir);
        try generateArea(allocator, io, output_dir);
        try generateHeatmap(allocator, io, output_dir);

        std.debug.print("\nAll charts generated in {s}/\n", .{output_dir});
    }
}

fn printUsage() void {
    const usage =
        \\Zig Charts - High-performance chart generation
        \\
        \\Usage:
        \\  zchart <command> [options] [args]
        \\
        \\Commands:
        \\  render <file>  Render chart from JSON file (use - for stdin)
        \\  demo [type]    Generate demo charts (all or specific type)
        \\  help           Show this help
        \\
        \\Chart Types (for demo command):
        \\  candlestick    OHLCV candlestick chart
        \\  line           Multi-series line chart
        \\  bar            Grouped bar chart
        \\  sparkline      Compact inline chart
        \\  pie            Pie/donut chart
        \\  gauge          Arc gauge chart
        \\  progress       Progress bars
        \\  scatter        Scatter plot
        \\  area           Area chart
        \\  heatmap        Heatmap grid
        \\
        \\Options:
        \\  -o, --output <file>   Output file (default: stdout for render, /tmp for demo)
        \\  -h, --help            Show this help
        \\  -v, --version         Show version
        \\
        \\Examples:
        \\  zchart demo                           # Generate all demo charts
        \\  zchart demo pie                       # Generate pie chart demo
        \\  zchart render chart.json -o out.svg   # Render JSON to file
        \\  echo '{"type":"pie",...}' | zchart render -   # Pipe JSON from AI
        \\
        \\JSON Schema:
        \\  {
        \\    "type": "pie|bar|line|scatter|gauge|progress|area|heatmap",
        \\    "width": 800,
        \\    "height": 400,
        \\    "data": { ... chart-specific data ... },
        \\    "config": { ... optional styling ... }
        \\  }
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

fn generateCandlestick(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8) !void {
    std.debug.print("Generating candlestick chart... ", .{});

    // Generate sample OHLCV data
    const candles = try charts.generateSampleCandles(allocator, 30, 100.0);
    defer allocator.free(candles);

    // Create SVG canvas
    var svg = charts.SvgCanvas.init(allocator, 800, 400);
    defer svg.deinit();
    svg.setBackground(charts.Color.white);

    const layout = charts.Layout{
        .width = 800,
        .height = 400,
        .margin_top = 20,
        .margin_right = 30,
        .margin_bottom = 50,
        .margin_left = 70,
    };

    var chart = charts.CandlestickChart.init(allocator, candles, layout, .{
        .show_volume = true,
    });
    try chart.render(svg.canvas());

    const output = try svg.canvas().finish();

    // Write to file
    const path = try std.fmt.allocPrint(allocator, "{s}/chart-candlestick.svg", .{output_dir});
    defer allocator.free(path);

    try writeFile(io, path, output);
    std.debug.print("done ({s})\n", .{path});
}

fn generateLine(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8) !void {
    std.debug.print("Generating line chart... ", .{});

    // Sample data: revenue vs expenses over 12 months
    const revenue_data = [_]charts.DataPoint{
        .{ .x = 1, .y = 100 },  .{ .x = 2, .y = 120 },  .{ .x = 3, .y = 115 },
        .{ .x = 4, .y = 140 },  .{ .x = 5, .y = 160 },  .{ .x = 6, .y = 155 },
        .{ .x = 7, .y = 170 },  .{ .x = 8, .y = 180 },  .{ .x = 9, .y = 175 },
        .{ .x = 10, .y = 200 }, .{ .x = 11, .y = 210 }, .{ .x = 12, .y = 230 },
    };

    const expenses_data = [_]charts.DataPoint{
        .{ .x = 1, .y = 80 },  .{ .x = 2, .y = 85 },   .{ .x = 3, .y = 90 },
        .{ .x = 4, .y = 95 },  .{ .x = 5, .y = 100 },  .{ .x = 6, .y = 105 },
        .{ .x = 7, .y = 110 }, .{ .x = 8, .y = 115 },  .{ .x = 9, .y = 120 },
        .{ .x = 10, .y = 125 }, .{ .x = 11, .y = 130 }, .{ .x = 12, .y = 140 },
    };

    const series = [_]charts.LineSeries{
        .{
            .name = "Revenue",
            .data = &revenue_data,
            .color = charts.Color.bull_green,
            .fill = true,
            .fill_opacity = 0.15,
        },
        .{
            .name = "Expenses",
            .data = &expenses_data,
            .color = charts.Color.bear_red,
            .dashed = true,
        },
    };

    var svg = charts.SvgCanvas.init(allocator, 700, 350);
    defer svg.deinit();
    svg.setBackground(charts.Color.white);

    const layout = charts.Layout{
        .width = 700,
        .height = 350,
        .margin_top = 20,
        .margin_right = 140,
        .margin_bottom = 50,
        .margin_left = 60,
    };

    var chart = charts.LineChart.init(allocator, &series, layout, .{
        .x_label = "Month",
        .y_label = "Value ($K)",
        .show_legend = true,
    });
    try chart.render(svg.canvas());

    const output = try svg.canvas().finish();

    const path = try std.fmt.allocPrint(allocator, "{s}/chart-line.svg", .{output_dir});
    defer allocator.free(path);

    try writeFile(io, path, output);
    std.debug.print("done ({s})\n", .{path});
}

fn generateBar(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8) !void {
    std.debug.print("Generating bar chart... ", .{});

    const categories = [_][]const u8{ "Q1", "Q2", "Q3", "Q4" };
    const series = [_]charts.BarSeries{
        .{ .name = "2024", .values = &[_]f64{ 150, 180, 165, 200 } },
        .{ .name = "2025", .values = &[_]f64{ 170, 195, 185, 220 } },
    };

    var svg = charts.SvgCanvas.init(allocator, 500, 300);
    defer svg.deinit();
    svg.setBackground(charts.Color.white);

    const layout = charts.Layout{
        .width = 500,
        .height = 300,
        .margin_top = 20,
        .margin_right = 20,
        .margin_bottom = 50,
        .margin_left = 60,
    };

    var chart = charts.BarChart.init(allocator, &categories, &series, layout, .{
        .show_values = true,
    });
    try chart.render(svg.canvas());

    const output = try svg.canvas().finish();

    const path = try std.fmt.allocPrint(allocator, "{s}/chart-bar.svg", .{output_dir});
    defer allocator.free(path);

    try writeFile(io, path, output);
    std.debug.print("done ({s})\n", .{path});
}

fn generateSparkline(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8) !void {
    std.debug.print("Generating sparklines... ", .{});

    // Multiple sparkline variants
    const data1 = [_]f64{ 10, 15, 8, 22, 18, 25, 20, 28, 24, 30 };
    const data2 = [_]f64{ 50, 48, 52, 45, 47, 42, 44, 40, 38, 35 };

    var svg = charts.SvgCanvas.init(allocator, 400, 120);
    defer svg.deinit();
    svg.setBackground(charts.Color.white);

    const c = svg.canvas();

    // Label for first sparkline
    c.drawText("Uptrend:", 10, 30, .{
        .font_size = 12,
        .color = charts.Color.gray_600,
        .baseline = .middle,
    });

    // First sparkline - uptrend with fill
    try charts.renderSparkline(allocator, c, &data1, 80, 10, 150, 40, .{
        .line_color = charts.Color.bull_green,
        .fill = true,
        .show_first = true,
        .show_last = true,
        .show_min = true,
        .show_max = true,
    });

    // Label for second sparkline
    c.drawText("Downtrend:", 10, 80, .{
        .font_size = 12,
        .color = charts.Color.gray_600,
        .baseline = .middle,
    });

    // Second sparkline - downtrend
    try charts.renderSparkline(allocator, c, &data2, 80, 60, 150, 40, .{
        .line_color = charts.Color.bear_red,
        .fill = true,
        .show_last = true,
    });

    // Bar sparkline
    c.drawText("Bars:", 250, 30, .{
        .font_size = 12,
        .color = charts.Color.gray_600,
        .baseline = .middle,
    });

    const bar_data = [_]f64{ 5, -3, 8, -2, 6, -5, 9, -1, 4, -4 };
    charts.renderSparklineBars(c, &bar_data, 290, 10, 100, 40, charts.Color.bull_green, charts.Color.bear_red);

    // Win/Loss sparkline
    c.drawText("W/L:", 250, 80, .{
        .font_size = 12,
        .color = charts.Color.gray_600,
        .baseline = .middle,
    });

    const win_loss = [_]bool{ true, true, false, true, false, false, true, true, true, false };
    charts.renderWinLoss(c, &win_loss, 290, 60, 100, 40, charts.Color.bull_green, charts.Color.bear_red);

    const output = try c.finish();

    const path = try std.fmt.allocPrint(allocator, "{s}/chart-sparklines.svg", .{output_dir});
    defer allocator.free(path);

    try writeFile(io, path, output);
    std.debug.print("done ({s})\n", .{path});
}

fn generatePie(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8) !void {
    std.debug.print("Generating pie chart... ", .{});

    const segments = [_]charts.PieSegment{
        .{ .label = "Product A", .value = 35 },
        .{ .label = "Product B", .value = 25 },
        .{ .label = "Product C", .value = 20 },
        .{ .label = "Product D", .value = 15 },
        .{ .label = "Other", .value = 5 },
    };

    var svg = charts.SvgCanvas.init(allocator, 500, 400);
    defer svg.deinit();
    svg.setBackground(charts.Color.white);

    const layout = charts.Layout{
        .width = 500,
        .height = 400,
        .margin_top = 20,
        .margin_right = 20,
        .margin_bottom = 20,
        .margin_left = 20,
    };

    var chart = charts.PieChart.init(allocator, &segments, layout, .{
        .inner_radius = 0.4, // Donut style
        .show_percentage = true,
    });
    try chart.render(svg.canvas());

    const output = try svg.canvas().finish();

    const path = try std.fmt.allocPrint(allocator, "{s}/chart-pie.svg", .{output_dir});
    defer allocator.free(path);

    try writeFile(io, path, output);
    std.debug.print("done ({s})\n", .{path});
}

fn generateGauge(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8) !void {
    std.debug.print("Generating gauge chart... ", .{});

    var svg = charts.SvgCanvas.init(allocator, 400, 300);
    defer svg.deinit();
    svg.setBackground(charts.Color.white);

    const layout = charts.Layout{
        .width = 400,
        .height = 300,
        .margin_top = 20,
        .margin_right = 20,
        .margin_bottom = 20,
        .margin_left = 20,
    };

    var chart = charts.GaugeChart.init(allocator, 73, "Performance", layout, .{
        .min = 0,
        .max = 100,
    });
    try chart.render(svg.canvas());

    const output = try svg.canvas().finish();

    const path = try std.fmt.allocPrint(allocator, "{s}/chart-gauge.svg", .{output_dir});
    defer allocator.free(path);

    try writeFile(io, path, output);
    std.debug.print("done ({s})\n", .{path});
}

fn generateProgress(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8) !void {
    std.debug.print("Generating progress bars... ", .{});

    const bars = [_]charts.ProgressBar{
        .{ .label = "Project Alpha", .current = 100, .target = 100 },
        .{ .label = "Project Beta", .current = 78, .target = 100 },
        .{ .label = "Project Gamma", .current = 55, .target = 100 },
        .{ .label = "Project Delta", .current = 25, .target = 100 },
    };

    var svg = charts.SvgCanvas.init(allocator, 600, 200);
    defer svg.deinit();
    svg.setBackground(charts.Color.white);

    const layout = charts.Layout{
        .width = 600,
        .height = 200,
        .margin_top = 20,
        .margin_right = 20,
        .margin_bottom = 20,
        .margin_left = 20,
    };

    var chart = charts.ProgressChart.init(allocator, &bars, layout, .{});
    try chart.render(svg.canvas());

    const output = try svg.canvas().finish();

    const path = try std.fmt.allocPrint(allocator, "{s}/chart-progress.svg", .{output_dir});
    defer allocator.free(path);

    try writeFile(io, path, output);
    std.debug.print("done ({s})\n", .{path});
}

fn generateScatter(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8) !void {
    std.debug.print("Generating scatter plot... ", .{});

    const points1 = [_]charts.ScatterPoint{
        .{ .x = 1, .y = 2 },   .{ .x = 2, .y = 4 },   .{ .x = 3, .y = 5 },
        .{ .x = 4, .y = 4 },   .{ .x = 5, .y = 7 },   .{ .x = 6, .y = 8 },
        .{ .x = 7, .y = 9 },   .{ .x = 8, .y = 11 },  .{ .x = 9, .y = 10 },
        .{ .x = 10, .y = 13 },
    };

    const points2 = [_]charts.ScatterPoint{
        .{ .x = 1, .y = 5 },   .{ .x = 2, .y = 6 },   .{ .x = 3, .y = 4 },
        .{ .x = 4, .y = 7 },   .{ .x = 5, .y = 6 },   .{ .x = 6, .y = 5 },
        .{ .x = 7, .y = 8 },   .{ .x = 8, .y = 7 },   .{ .x = 9, .y = 6 },
        .{ .x = 10, .y = 9 },
    };

    const series = [_]charts.ScatterSeries{
        .{ .name = "Group A", .points = &points1, .color = charts.Color.blue_500 },
        .{ .name = "Group B", .points = &points2, .color = charts.Color.bear_red },
    };

    var svg = charts.SvgCanvas.init(allocator, 600, 400);
    defer svg.deinit();
    svg.setBackground(charts.Color.white);

    const layout = charts.Layout{
        .width = 600,
        .height = 400,
        .margin_top = 20,
        .margin_right = 140,
        .margin_bottom = 50,
        .margin_left = 60,
    };

    var chart = charts.ScatterChart.init(allocator, &series, layout, .{
        .trend_line = .{ .enabled = true },
        .x_label = "X Value",
        .y_label = "Y Value",
    });
    try chart.render(svg.canvas());

    const output = try svg.canvas().finish();

    const path = try std.fmt.allocPrint(allocator, "{s}/chart-scatter.svg", .{output_dir});
    defer allocator.free(path);

    try writeFile(io, path, output);
    std.debug.print("done ({s})\n", .{path});
}

fn generateArea(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8) !void {
    std.debug.print("Generating area chart... ", .{});

    const data1 = [_]charts.AreaPoint{
        .{ .x = 0, .y = 10 }, .{ .x = 1, .y = 15 }, .{ .x = 2, .y = 12 },
        .{ .x = 3, .y = 20 }, .{ .x = 4, .y = 18 }, .{ .x = 5, .y = 25 },
        .{ .x = 6, .y = 22 }, .{ .x = 7, .y = 30 },
    };

    const data2 = [_]charts.AreaPoint{
        .{ .x = 0, .y = 8 },  .{ .x = 1, .y = 10 }, .{ .x = 2, .y = 12 },
        .{ .x = 3, .y = 14 }, .{ .x = 4, .y = 16 }, .{ .x = 5, .y = 15 },
        .{ .x = 6, .y = 18 }, .{ .x = 7, .y = 20 },
    };

    const data3 = [_]charts.AreaPoint{
        .{ .x = 0, .y = 5 },  .{ .x = 1, .y = 6 },  .{ .x = 2, .y = 8 },
        .{ .x = 3, .y = 7 },  .{ .x = 4, .y = 10 }, .{ .x = 5, .y = 12 },
        .{ .x = 6, .y = 11 }, .{ .x = 7, .y = 14 },
    };

    const series = [_]charts.AreaSeries{
        .{ .name = "Desktop", .data = &data1, .color = charts.Color.blue_500 },
        .{ .name = "Mobile", .data = &data2, .color = charts.Color.bull_green },
        .{ .name = "Tablet", .data = &data3, .color = charts.Color.fromHex("F59E0B").? },
    };

    var svg = charts.SvgCanvas.init(allocator, 700, 400);
    defer svg.deinit();
    svg.setBackground(charts.Color.white);

    const layout = charts.Layout{
        .width = 700,
        .height = 400,
        .margin_top = 20,
        .margin_right = 140,
        .margin_bottom = 50,
        .margin_left = 60,
    };

    var chart = charts.AreaChart.init(allocator, &series, layout, .{
        .stack_mode = .stacked,
        .x_label = "Month",
        .y_label = "Users (K)",
    });
    try chart.render(svg.canvas());

    const output = try svg.canvas().finish();

    const path = try std.fmt.allocPrint(allocator, "{s}/chart-area.svg", .{output_dir});
    defer allocator.free(path);

    try writeFile(io, path, output);
    std.debug.print("done ({s})\n", .{path});
}

fn generateHeatmap(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8) !void {
    std.debug.print("Generating heatmap... ", .{});

    const row1 = [_]f64{ 10, 25, 40, 55, 70 };
    const row2 = [_]f64{ 15, 30, 45, 60, 75 };
    const row3 = [_]f64{ 20, 35, 50, 65, 80 };
    const row4 = [_]f64{ 25, 40, 55, 70, 85 };
    const row5 = [_]f64{ 30, 45, 60, 75, 90 };

    const matrix = [_][]const f64{
        &row1, &row2, &row3, &row4, &row5,
    };

    const x_labels = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri" };
    const y_labels = [_][]const u8{ "9am", "12pm", "3pm", "6pm", "9pm" };

    var svg = charts.SvgCanvas.init(allocator, 500, 400);
    defer svg.deinit();
    svg.setBackground(charts.Color.white);

    const layout = charts.Layout{
        .width = 500,
        .height = 400,
        .margin_top = 40,
        .margin_right = 80,
        .margin_bottom = 60,
        .margin_left = 80,
    };

    var chart = charts.HeatmapChart.init(allocator, &matrix, layout, .{
        .x_labels = &x_labels,
        .y_labels = &y_labels,
        .show_values = true,
        .title = "Activity Heatmap",
    });
    try chart.render(svg.canvas());

    const output = try svg.canvas().finish();

    const path = try std.fmt.allocPrint(allocator, "{s}/chart-heatmap.svg", .{output_dir});
    defer allocator.free(path);

    try writeFile(io, path, output);
    std.debug.print("done ({s})\n", .{path});
}
