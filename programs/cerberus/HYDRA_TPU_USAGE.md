# Hydra TPU Usage Guide

Quick reference for running neural-guided exhaustive search on TPU.

## Prerequisites

1. TPU v6e-1 running with v2-alpha-tpuv6e runtime
2. Files uploaded to TPU:
   - `hydra_tpu.py`
   - `cerberus_predictor_v1.keras` (optional, for guided search)

## Basic Commands

### Upload Files

```bash
# Upload search script
gcloud compute tpus tpu-vm scp hydra_tpu.py cerberus2: \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1

# Upload predictor model
gcloud compute tpus tpu-vm scp cerberus_predictor_v1.keras cerberus2: \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1
```

### Run Benchmark

```bash
gcloud compute tpus tpu-vm ssh cerberus2 \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1 \
  --command='python3 hydra_tpu.py --benchmark'
```

Output:
```
       1,000 candidates:   0.01 billion/sec
      10,000 candidates:   0.09 billion/sec
     100,000 candidates:   0.87 billion/sec
   1,000,000 candidates:   7.71 billion/sec
  10,000,000 candidates:  12.83 billion/sec
```

### Unguided Search (Pure Exhaustive)

```bash
gcloud compute tpus tpu-vm ssh cerberus2 \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1 \
  --command='python3 hydra_tpu.py \
    --start 0 \
    --end 100000000 \
    --target 1a1748ed9190d81e \
    --no-guided'
```

### Guided Search (With Neural Predictor)

```bash
gcloud compute tpus tpu-vm ssh cerberus2 \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1 \
  --command='python3 hydra_tpu.py \
    --start 0 \
    --end 100000000 \
    --target 1a1748ed9190d81e \
    --model cerberus_predictor_v1.keras'
```

## Command Line Options

```
usage: hydra_tpu.py [-h] [--start START] [--end END] [--target TARGET]
                    [--model MODEL] [--benchmark] [--no-guided]

options:
  --start START        Start of search range (default: 0)
  --end END           End of search range (default: 100000000)
  --target TARGET     Target hash in hex (required for search)
  --model MODEL       Path to Cerberus predictor model (.keras)
  --benchmark         Run throughput benchmark
  --no-guided         Disable guided search (pure exhaustive)
```

## Search Configuration

Edit `hydra_tpu.py` to adjust:

```python
@dataclass
class HydraConfig:
    region_size: int = 10_000_000           # Candidates per region
    batch_size: int = 100                   # Regions per batch
    prediction_threshold: float = 0.3       # Predictor cutoff
```

**region_size**: Larger = better TPU utilization, but less granular filtering
**batch_size**: Larger = better parallelism, but more memory
**prediction_threshold**: Higher = skip more regions (faster but may miss matches)

## Known Test Cases

### Test Case 1: Small Value
```bash
Value:  5000000
Hash:   1a1748ed9190d81e
Range:  0 - 100000000
Time:   ~1.1 seconds
```

Command:
```bash
python3 hydra_tpu.py --start 0 --end 100000000 --target 1a1748ed9190d81e
```

### Test Case 2: Generate Your Own

```python
# On TPU or locally with JAX
import jax.numpy as jnp
import numpy as np

HASH_C1 = np.uint64(0xbf58476d1ce4e5b9)
HASH_C2 = np.uint64(0x94d049bb133111eb)

def splitmix64(x):
    x = np.uint64(x)
    x = x ^ (x >> 30)
    x = x * HASH_C1
    x = x ^ (x >> 27)
    x = x * HASH_C2
    x = x ^ (x >> 31)
    return x

value = 12345678
hash_val = splitmix64(value)
print(f"Value: {value}")
print(f"Hash:  {hash_val:016x}")
```

## Output Format

### Successful Match

```
============================================================
MATCH FOUND!
============================================================
Value: 5000000
Hash:  1a1748ed9190d81e

Search stats:
  Candidates searched: 10,000,000
  Time: 1.12 seconds
  Throughput: 8.93 billion/sec
```

### No Match

```
No match found
  Candidates searched: 100,000,000
  Time: 9.45 seconds
  Throughput: 10.58 billion/sec
```

### Guided Search Info

```
Running neural predictor...
  Extracting features... 4.0 ms
  Running predictor... 109.2 ms
  Score distribution:
    Min:  0.4518
    Max:  0.4607
    Mean: 0.4559
    Threshold: 0.3000
  Promising regions: 10 / 10
  Skip rate: 0.0%
```

## Performance Expectations

### TPU v6e-1 (Single Core)

- **Peak throughput**: 12.83 billion hashes/sec
- **Optimal batch size**: 10M candidates
- **Warmup time**: ~300ms (first run)
- **Predictor overhead**: ~110ms per batch

### Scaling Estimates

| Range Size | Unguided Time | Guided Time (50% skip) |
|-----------|---------------|------------------------|
| 100M      | ~9 seconds    | ~5 seconds             |
| 1B        | ~90 seconds   | ~45 seconds            |
| 10B       | ~15 minutes   | ~7.5 minutes           |
| 100B      | ~2.5 hours    | ~1.25 hours            |

*Assumes predictor achieves 50% skip rate (not yet achieved in v1)*

## Troubleshooting

### TPU Already in Use

```bash
# Kill Jupyter if running
gcloud compute tpus tpu-vm ssh cerberus2 \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1 \
  --command='pkill -f jupyter'
```

### JAX 64-bit Mode Error

Ensure `hydra_tpu.py` has:
```python
os.environ['JAX_ENABLE_X64'] = '1'
os.environ['KERAS_BACKEND'] = 'jax'
```

### Model File Not Found

Upload the model file:
```bash
gcloud compute tpus tpu-vm scp cerberus_predictor_v1.keras cerberus2: \
  --zone=europe-west4-a --project=metatron-cloud-prod-v1
```

### TensorFlow Import Error

Ensure Keras backend set to JAX (see above). Model must be trained with JAX backend.

## Next Steps

1. **Test with larger ranges**: Try 1B to 10B candidates
2. **Benchmark against Hydra GPU**: Compare TPU vs A100 throughput
3. **Improve predictor**: Train v2 with better class balance
4. **Multi-core TPU**: Scale to 8 cores (v6e-8) for 8x throughput
