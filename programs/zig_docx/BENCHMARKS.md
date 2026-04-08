# zig-docx Benchmark Results

Date: 2026-04-08T19:48:37Z


## 1. PDF → Markdown (11MB, 1529 pages)
```
Benchmark 1: ./zig-out/bin/zig-docx '/Users/director/Downloads/arm_neoverse_v2_core_trm_102375_0002_03_en.pdf' -o /tmp/zig-docx-bench/arm_neoverse.md
  Time (mean ± σ):      4.143 s ±  0.050 s    [User: 3.745 s, System: 0.259 s]
  Range (min … max):    4.095 s …  4.195 s    3 runs
 
```

## 2. PDF → Chunked (11MB, 1529 pages → 417 chunks)
```
Benchmark 1: ./zig-out/bin/zig-docx --chunk '/Users/director/Downloads/arm_neoverse_v2_core_trm_102375_0002_03_en.pdf' -o /tmp/zig-docx-bench/pdf_chunks
  Time (mean ± σ):      4.200 s ±  0.032 s    [User: 3.877 s, System: 0.275 s]
  Range (min … max):    4.180 s …  4.237 s    3 runs
 
  Warning: Statistical outliers were detected. Consider re-running this benchmark on a quiet system without any interferences from other programs.
 
```

## 3. PDF → Markdown (small, 6 pages)
```
Benchmark 1: ./zig-out/bin/zig-docx '/Users/director/Downloads/AI Coding and Vibe Coding_ The Fastest-Growing SaaS Category in History.pdf' -o /tmp/zig-docx-bench/ai_coding.md
  Time (mean ± σ):      38.5 ms ±   0.6 ms    [User: 31.9 ms, System: 5.3 ms]
  Range (min … max):    38.1 ms …  39.4 ms    5 runs
 
```

## 4. XLSX → CSV
```
Benchmark 1: ./zig-out/bin/zig-docx '/Users/director/Downloads/metatron_full_compute_valuation.xlsx' -o /tmp/zig-docx-bench/xlsx_out/valuation.csv
  Time (mean ± σ):      18.2 ms ±   0.3 ms    [User: 16.6 ms, System: 1.1 ms]
  Range (min … max):    17.8 ms …  18.8 ms    10 runs
 
```

## 5. XLSX → Markdown Table
```
Benchmark 1: ./zig-out/bin/zig-docx --markdown '/Users/director/Downloads/metatron_full_compute_valuation.xlsx' -o /tmp/zig-docx-bench/xlsx_out/valuation.md
  Time (mean ± σ):      18.3 ms ±   0.6 ms    [User: 16.8 ms, System: 1.1 ms]
  Range (min … max):    17.5 ms …  19.5 ms    10 runs
 
```

## 6. DOCX → MDX
```
Benchmark 1: ./zig-out/bin/zig-docx '/Users/director/work/poly-repo/crg-direct-polyrepo/blog-stuff/How Much Electricity Does a 4kW Solar System Produce.docx' -o /tmp/zig-docx-bench/docx_out/solar.mdx
  Time (mean ± σ):      20.8 ms ±   0.6 ms    [User: 18.9 ms, System: 1.3 ms]
  Range (min … max):    20.0 ms …  22.3 ms    10 runs
 
```

## System Info
```
Binary: 2.7M
Apple M2
RAM: 24 GB
OS: macOS 26.3.1
```
