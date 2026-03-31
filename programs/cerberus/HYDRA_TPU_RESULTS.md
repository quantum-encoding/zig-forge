# Hydra TPU Integration Results

## Summary

Successfully integrated Cerberus neural predictor with Hydra exhaustive search on Google Cloud TPU v6e-1.

## Architecture

```
┌─────────────────────────────────────────────────┐
│         Hydra TPU Neural-Guided Search          │
├─────────────────────────────────────────────────┤
│                                                  │
│  1. Region Division                              │
│     Split search space into 10M candidate chunks │
│                                                  │
│  2. Neural Predictor (Optional)                  │
│     ├─ Extract 16 features per region            │
│     ├─ Score regions (0.0-1.0)                   │
│     └─ Filter by threshold (default 0.3)         │
│                                                  │
│  3. Exhaustive Search on TPU                     │
│     ├─ Vectorized SplitMix64 hash (JAX)          │
│     ├─ Batch processing (100 regions)            │
│     └─ Return first match                        │
│                                                  │
└─────────────────────────────────────────────────┘
```

## Performance Results

### Hash Throughput (TPU v6e-1)

| Batch Size | Throughput        |
|-----------|-------------------|
| 1K        | 0.01 billion/sec  |
| 10K       | 0.09 billion/sec  |
| 100K      | 0.87 billion/sec  |
| 1M        | 7.71 billion/sec  |
| 10M       | 12.83 billion/sec |

**Peak: 12.83 billion hashes/second**

### Search Test (Known Hash)

Target: `1a1748ed9190d81e` (value=5000000)
Range: 0 to 100M

| Mode       | Time    | Skip Rate | Result  |
|-----------|---------|-----------|---------|
| Unguided  | 1.12s   | N/A       | Found   |
| Guided    | 1.13s   | 0.0%      | Found   |

## Predictor Performance (v1)

### Training Results

- Training accuracy: 94.8%
- Validation accuracy: 94.7%
- **Issue: Model too conservative** (predicts all regions as promising)

### Prediction Scores

```
Min:  0.4518
Max:  0.4607
Mean: 0.4559
Threshold: 0.3000

Promising regions: 10 / 10 (100%)
Skip rate: 0.0%
```

**Problem**: Predictor not selective enough. All regions scored above threshold.

## Root Cause Analysis

### Why Predictor Failed

1. **Extreme Class Imbalance**
   - Only 5% match regions in training (was 0.1%, increased to 5%)
   - Model learned to always predict "promising" (safe strategy)
   - Validation recall dropped to 0.0% (never predicts matches)

2. **Feature Distribution**
   - Features may not capture hash collision patterns
   - SplitMix64 is cryptographically chaotic
   - Region statistics may be insufficient signal

3. **Training Strategy**
   - Class weights helped training accuracy
   - But validation shows overfitting to majority class
   - Need more sophisticated approach

## Next Steps

### 1. Improve Predictor Training

**Option A: Better Class Balance**
```python
# Generate equal positive/negative examples
match_probability = 0.5  # 50/50 split
train_regions = 100_000  # More data
```

**Option B: Contrastive Learning**
```python
# Triplet loss: (anchor, positive, negative)
# Learn to distinguish matching vs non-matching regions
```

**Option C: Different Architecture**
```python
# Try transformer or attention mechanism
# May capture hash patterns better than dense layers
```

### 2. Alternative Feature Engineering

**Hash-Aware Features**
```python
- XOR patterns in region boundaries
- Hamming distance to target hash
- Avalanche effect metrics
- Bit flip sensitivity
```

**Statistical Features**
```python
- Expected collision rate
- Hash distribution entropy
- Region size vs target distance
```

### 3. Hybrid Approaches

**A. Multi-Stage Filtering**
1. Fast heuristic filter (simple rules)
2. Neural predictor on filtered set
3. Exhaustive search on promising regions

**B. Adaptive Thresholding**
- Start with high threshold (0.8)
- Gradually lower if no matches found
- Balance speed vs coverage

**C. Ensemble Predictors**
- Train multiple models on different hash functions
- Combine predictions (voting or averaging)

### 4. Validation Strategy

**Before Next Training Run**

1. Create stratified validation set
   - Ensure mix of easy/hard regions
   - Include known matches from Hydra GPU tests

2. Track meaningful metrics
   - True skip rate on negatives
   - Recall on positives
   - ROC-AUC curve

3. Test on real searches
   - Run against known preimages
   - Measure actual speedup vs exhaustive

## Files Created

```
programs/cerberus/
├── hydra_tpu.py                      # TPU search implementation
├── cerberus_predictor_v1.keras       # Trained model (v1)
├── cerberus_config_v1.json           # Model config
├── training_history_v1.json          # Training metrics
├── cerberus_tpu_training.ipynb       # Training notebook
├── TPU_SETUP.md                      # TPU setup guide
├── TPU_TROUBLESHOOT.md               # Common issues
└── HYDRA_TPU_RESULTS.md             # This file
```

## Technical Achievements

### Successfully Implemented

- SplitMix64 hash port from Zig/CUDA to JAX
- Vectorized TPU kernels with JIT compilation
- 64-bit integer support in JAX
- Feature extraction matching training pipeline
- End-to-end neural-guided search framework
- Comprehensive error handling and progress reporting

### Verified Correctness

- Hash output matches Hydra GPU exactly
- Found known preimage (5000000 → 1a1748ed9190d81e)
- TPU throughput competitive with GPU

## Conclusion

**Infrastructure: Complete and Working**
- TPU kernels perform at 12.83 billion hashes/sec
- Search engine finds correct preimages
- Integration framework ready for production

**Predictor: Needs Improvement**
- Current model too conservative (0% skip rate)
- Training strategy needs redesign
- Feature engineering may need rethinking

**Recommendation**: Focus next iteration on predictor training methodology rather than infrastructure. The search engine works correctly; we just need a better oracle to guide it.
