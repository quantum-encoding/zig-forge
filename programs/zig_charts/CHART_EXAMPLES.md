# Zig Charts - JSON API Examples

High-performance chart generation from JSON specifications. Designed for AI integration via structured output.

## Usage

```bash
# From JSON file
./chart-demo render chart.json -o output.svg

# Generate all demo charts
./chart-demo demo
```

## Universal JSON Schema

```json
{
  "type": "pie|gauge|progress|scatter|area|heatmap|line|bar|candlestick|sparkline",
  "width": 800,
  "height": 400,
  "data": { },
  "config": { }
}
```

---

## Pie / Donut Chart

Circular charts for showing proportions of a whole.

```json
{
  "type": "pie",
  "width": 600,
  "height": 400,
  "data": {
    "segments": [
      { "label": "Sales", "value": 45 },
      { "label": "Marketing", "value": 30 },
      { "label": "Development", "value": 25 }
    ]
  },
  "config": {
    "show_percentage": true,
    "inner_radius": 0
  }
}
```

**Donut variant** (set inner_radius > 0):

```json
{
  "type": "pie",
  "data": {
    "segments": [
      { "label": "Complete", "value": 75 },
      { "label": "Remaining", "value": 25 }
    ]
  },
  "config": {
    "inner_radius": 0.5,
    "show_percentage": true
  }
}
```

**Config options:**
- `inner_radius`: 0 = full pie, 0.5 = donut (default: 0)
- `show_percentage`: Show percentage in labels (default: true)
- `show_labels`: Show segment labels (default: true)

---

## Gauge Chart

Arc gauges for displaying single values within a range.

```json
{
  "type": "gauge",
  "width": 400,
  "height": 300,
  "data": {
    "value": 72,
    "label": "CPU Usage"
  },
  "config": {
    "min": 0,
    "max": 100
  }
}
```

**With colored zones:**

```json
{
  "type": "gauge",
  "data": {
    "value": 85,
    "label": "Temperature"
  },
  "config": {
    "min": 0,
    "max": 120,
    "zones": [
      { "max": 60, "color": "#10B981" },
      { "max": 90, "color": "#F59E0B" },
      { "max": 120, "color": "#EF4444" }
    ]
  }
}
```

**Config options:**
- `min`: Minimum value (default: 0)
- `max`: Maximum value (default: 100)
- `zones`: Array of `{ max, color }` for colored ranges
- `show_value`: Display value text (default: true)
- `show_label`: Display label text (default: true)

---

## Progress Bars

Horizontal progress bars for displaying completion status.

```json
{
  "type": "progress",
  "width": 600,
  "height": 200,
  "data": {
    "bars": [
      { "label": "Project Alpha", "current": 85, "target": 100 },
      { "label": "Project Beta", "current": 60, "target": 100 },
      { "label": "Project Gamma", "current": 100, "target": 100 }
    ]
  },
  "config": {
    "show_percentage": true
  }
}
```

**Config options:**
- `show_percentage`: Show percentage instead of values (default: true)
- `show_labels`: Show bar labels (default: true)
- `show_values`: Show current/target values (default: true)

Status colors are automatic:
- Green: >= 100% (achieved)
- Blue: >= 75% (on track)
- Amber: >= 50% (pending)
- Red: < 50% (at risk)

---

## Scatter Plot

XY scatter plots for showing relationships between variables.

```json
{
  "type": "scatter",
  "width": 800,
  "height": 500,
  "data": {
    "series": [
      {
        "name": "Dataset A",
        "points": [
          { "x": 1, "y": 5 },
          { "x": 2, "y": 8 },
          { "x": 3, "y": 4 },
          { "x": 4, "y": 9 },
          { "x": 5, "y": 6 }
        ]
      }
    ]
  },
  "config": {
    "show_trend_line": true,
    "x_label": "Time (hours)",
    "y_label": "Value"
  }
}
```

**Bubble chart** (with size encoding):

```json
{
  "type": "scatter",
  "data": {
    "series": [
      {
        "name": "Countries",
        "points": [
          { "x": 50000, "y": 80, "size": 330 },
          { "x": 45000, "y": 82, "size": 67 },
          { "x": 35000, "y": 75, "size": 1400 }
        ]
      }
    ]
  },
  "config": {
    "x_label": "GDP per capita",
    "y_label": "Life expectancy"
  }
}
```

**Config options:**
- `show_trend_line`: Draw linear regression line (default: false)
- `x_label`, `y_label`: Axis labels
- `show_grid`: Show grid lines (default: true)
- `show_legend`: Show series legend (default: true)

---

## Area Chart

Filled area charts for time series and cumulative data.

```json
{
  "type": "area",
  "width": 800,
  "height": 400,
  "data": {
    "series": [
      {
        "name": "Revenue",
        "points": [
          { "x": 1, "y": 100 },
          { "x": 2, "y": 150 },
          { "x": 3, "y": 130 },
          { "x": 4, "y": 180 },
          { "x": 5, "y": 200 }
        ]
      }
    ]
  },
  "config": {
    "show_line": true,
    "opacity": 0.6
  }
}
```

**Stacked area chart:**

```json
{
  "type": "area",
  "data": {
    "series": [
      {
        "name": "Product A",
        "points": [
          { "x": 1, "y": 30 },
          { "x": 2, "y": 40 },
          { "x": 3, "y": 35 }
        ]
      },
      {
        "name": "Product B",
        "points": [
          { "x": 1, "y": 20 },
          { "x": 2, "y": 25 },
          { "x": 3, "y": 30 }
        ]
      }
    ]
  },
  "config": {
    "stack_mode": "stacked"
  }
}
```

**Config options:**
- `stack_mode`: "none", "stacked", "percent", "stream" (default: "none")
- `show_line`: Draw line on top of area (default: true)
- `opacity`: Fill opacity 0-1 (default: 0.6)
- `x_label`, `y_label`: Axis labels

---

## Heatmap

2D grid visualization with color-coded cell values.

```json
{
  "type": "heatmap",
  "width": 600,
  "height": 400,
  "data": {
    "matrix": [
      [1, 2, 3, 4],
      [5, 6, 7, 8],
      [9, 10, 11, 12]
    ],
    "x_labels": ["Q1", "Q2", "Q3", "Q4"],
    "y_labels": ["2022", "2023", "2024"]
  },
  "config": {
    "show_values": true,
    "title": "Quarterly Performance"
  }
}
```

**Correlation matrix:**

```json
{
  "type": "heatmap",
  "data": {
    "matrix": [
      [1.0, 0.8, 0.3],
      [0.8, 1.0, 0.5],
      [0.3, 0.5, 1.0]
    ],
    "x_labels": ["A", "B", "C"],
    "y_labels": ["A", "B", "C"]
  },
  "config": {
    "show_values": true,
    "color_scale": "diverging"
  }
}
```

**Config options:**
- `show_values`: Display values in cells (default: false)
- `title`: Chart title
- `color_scale`: "blue_to_red", "sequential", "diverging"

---

## Line Chart

Line charts for time series and trend visualization.

```json
{
  "type": "line",
  "width": 800,
  "height": 400,
  "data": {
    "series": [
      {
        "name": "Temperature",
        "values": [20, 22, 25, 23, 27, 30, 28]
      }
    ],
    "categories": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
  },
  "config": {
    "show_points": true,
    "show_grid": true
  }
}
```

**Multi-series:**

```json
{
  "type": "line",
  "data": {
    "series": [
      { "name": "2023", "values": [10, 15, 12, 18, 20] },
      { "name": "2024", "values": [12, 18, 15, 22, 25] }
    ],
    "categories": ["Jan", "Feb", "Mar", "Apr", "May"]
  },
  "config": {
    "show_legend": true
  }
}
```

**Config options:**
- `show_points`: Show data points (default: true)
- `show_grid`: Show grid lines (default: true)
- `show_legend`: Show series legend (default: true)
- `smooth`: Use curved lines (default: false)

---

## Bar Chart

Vertical bar charts for categorical comparisons.

```json
{
  "type": "bar",
  "width": 600,
  "height": 400,
  "data": {
    "series": [
      {
        "name": "Sales",
        "values": [150, 230, 180, 290]
      }
    ],
    "categories": ["Q1", "Q2", "Q3", "Q4"]
  },
  "config": {
    "show_values": true
  }
}
```

**Grouped bar chart:**

```json
{
  "type": "bar",
  "data": {
    "series": [
      { "name": "2023", "values": [100, 150, 120] },
      { "name": "2024", "values": [120, 180, 150] }
    ],
    "categories": ["Product A", "Product B", "Product C"]
  },
  "config": {
    "mode": "grouped"
  }
}
```

**Stacked bar chart:**

```json
{
  "type": "bar",
  "data": {
    "series": [
      { "name": "Revenue", "values": [100, 150, 120] },
      { "name": "Expenses", "values": [80, 100, 90] }
    ],
    "categories": ["Jan", "Feb", "Mar"]
  },
  "config": {
    "mode": "stacked"
  }
}
```

**Config options:**
- `mode`: "grouped" or "stacked" (default: "grouped")
- `show_values`: Display values on bars (default: false)

---

## Candlestick Chart

OHLC charts for financial data visualization.

```json
{
  "type": "candlestick",
  "width": 800,
  "height": 400,
  "data": {
    "candles": [
      { "open": 100, "high": 110, "low": 95, "close": 105 },
      { "open": 105, "high": 115, "low": 100, "close": 112 },
      { "open": 112, "high": 120, "low": 108, "close": 108 },
      { "open": 108, "high": 112, "low": 102, "close": 110 },
      { "open": 110, "high": 118, "low": 105, "close": 115 }
    ]
  },
  "config": {
    "bull_color": "#10B981",
    "bear_color": "#EF4444"
  }
}
```

**With timestamps:**

```json
{
  "type": "candlestick",
  "data": {
    "candles": [
      { "timestamp": 1704067200, "open": 100, "high": 110, "low": 95, "close": 105, "volume": 1000000 },
      { "timestamp": 1704153600, "open": 105, "high": 115, "low": 100, "close": 112, "volume": 1200000 }
    ]
  },
  "config": {
    "show_volume": true
  }
}
```

**Config options:**
- `bull_color`: Color for bullish candles (close > open)
- `bear_color`: Color for bearish candles (close < open)
- `show_volume`: Show volume bars (default: false)

---

## Sparkline

Compact inline charts for dashboards and tables.

```json
{
  "type": "sparkline",
  "width": 200,
  "height": 50,
  "data": {
    "values": [5, 10, 8, 15, 12, 18, 14, 20, 17, 22]
  },
  "config": {
    "fill": true,
    "show_min": true,
    "show_max": true
  }
}
```

**Line sparkline (no fill):**

```json
{
  "type": "sparkline",
  "width": 150,
  "height": 40,
  "data": {
    "values": [3, 7, 4, 8, 5, 9, 6]
  },
  "config": {
    "fill": false,
    "line_color": "#3B82F6"
  }
}
```

**Config options:**
- `fill`: Fill area under line (default: true)
- `show_min`: Highlight minimum point (default: false)
- `show_max`: Highlight maximum point (default: false)
- `line_color`: Line color (default: blue)
- `fill_color`: Fill color (default: light blue)

---

## Color Reference

Standard hex colors for consistent styling:

| Color | Hex | Usage |
|-------|-----|-------|
| Blue | `#3B82F6` | Primary, links |
| Red | `#EF4444` | Errors, bearish |
| Green | `#10B981` | Success, bullish |
| Amber | `#F59E0B` | Warnings |
| Purple | `#8B5CF6` | Accents |
| Pink | `#EC4899` | Highlights |
| Cyan | `#06B6D4` | Info |
| Orange | `#F97316` | Alerts |

**Grayscale:**
- `#F5F5F5` (gray-100) - Backgrounds
- `#A3A3A3` (gray-400) - Borders
- `#525252` (gray-600) - Secondary text
- `#171717` (gray-900) - Primary text
