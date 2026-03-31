#!/usr/bin/env python3
"""
Hydra TPU - Neural-Guided Exhaustive Search on TPU

Combines:
- Cerberus neural predictor (region scoring)
- Hydra exhaustive search (hash matching)
- TPU acceleration via JAX

Architecture:
1. Predictor scores regions (skip unpromising ones)
2. Exhaustive search on promising regions (vectorized on TPU)
3. Return matches

Usage:
    python hydra_tpu.py --start 0 --end 1000000000 --target deadbeef --model cerberus_predictor.keras
"""

import os
os.environ['JAX_ENABLE_X64'] = '1'
os.environ['KERAS_BACKEND'] = 'jax'

import jax
import jax.numpy as jnp
import numpy as np
import argparse
import time
from typing import Optional, Tuple
from dataclasses import dataclass

jax.config.update("jax_enable_x64", True)

# ==================== Hash Functions ====================

# SplitMix64 constants (same as Hydra GPU version)
HASH_C1 = np.uint64(0xbf58476d1ce4e5b9)
HASH_C2 = np.uint64(0x94d049bb133111eb)

@jax.jit
def splitmix64(x: jnp.ndarray) -> jnp.ndarray:
    """
    SplitMix64 hash - identical to Hydra GPU kernel

    __device__ u64 simple_hash(u64 x) {
        x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
        x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
        x = x ^ (x >> 31);
        return x;
    }
    """
    x = x.astype(jnp.uint64)

    # Step 1
    x = x ^ (x >> 30)
    x = x * HASH_C1

    # Step 2
    x = x ^ (x >> 27)
    x = x * HASH_C2

    # Step 3
    x = x ^ (x >> 31)

    return x

@jax.jit
def hash_batch(values: jnp.ndarray) -> jnp.ndarray:
    """Hash a batch of values (vectorized for TPU)"""
    return jax.vmap(splitmix64)(values)

# ==================== Search Kernels ====================

def search_region_impl(start, count, target):
    """
    Search a region for hash match (non-JIT implementation)

    Args:
        start: Starting value
        count: Number of values to test
        target: Target hash to match

    Returns:
        (found, match_value)
    """
    # Generate candidate values (not traced)
    candidates = jnp.arange(start, start + count, dtype=jnp.uint64)

    # Hash all candidates (vectorized on TPU)
    hashes = hash_batch(candidates)

    # Convert target to int64 for comparison (hashes are int64)
    # Use numpy to handle potential overflow from uint64 to int64
    target_int64 = np.int64(np.uint64(target).view(np.int64))

    # Find matches
    matches = hashes == target_int64

    # Return first match (if any)
    found = jnp.any(matches)
    match_idx = jnp.argmax(matches)  # First match index (0 if none)
    match_value = jnp.where(found, candidates[match_idx], jnp.uint64(0))

    return found, match_value

# Note: Don't JIT the outer search_region since it uses dynamic arange
# The hash_batch is already JIT'd which is where the TPU acceleration happens
search_region = search_region_impl

def search_regions_batch_impl(starts, count, target):
    """Batch search multiple regions"""
    results = []
    for start in starts:
        result = search_region(start, count, target)
        results.append(result)

    found_arr = jnp.array([r[0] for r in results])
    values_arr = jnp.array([r[1] for r in results])
    return found_arr, values_arr

search_regions_batch = search_regions_batch_impl

# ==================== Feature Extraction ====================

class RegionFeatureExtractor:
    """Extract features from search regions for neural predictor"""

    def __init__(self, region_size: int):
        self.region_size = region_size

    @staticmethod
    @jax.jit
    def extract_features_jax(start: jnp.ndarray, end: jnp.ndarray) -> jnp.ndarray:
        """
        Extract features from a region defined by [start, end).
        JAX-compatible version (same as Cerberus training notebook).
        """
        start_f = start.astype(jnp.float32)
        end_f = end.astype(jnp.float32)
        size_f = end_f - start_f

        max_val = 1e18

        features = jnp.array([
            # Position features (4)
            start_f / max_val,
            end_f / max_val,
            size_f / 1e9,
            jnp.log1p(start_f) / 50.0,

            # Bit pattern features (4)
            ((start.astype(jnp.int32) & 0xFF).astype(jnp.float32)) / 255.0,
            (((start.astype(jnp.int64) >> 8) % 256).astype(jnp.float32)) / 255.0,
            (((start.astype(jnp.int64) >> 16) % 256).astype(jnp.float32)) / 255.0,
            (((start.astype(jnp.int64) >> 32) % 256).astype(jnp.float32)) / 255.0,

            # Periodic features (4)
            jnp.sin(start_f / 1e6),
            jnp.cos(start_f / 1e6),
            jnp.sin(start_f / 1e9),
            jnp.cos(start_f / 1e9),

            # Derived features (4)
            jnp.mod(start_f, 1000.0) / 1000.0,
            jnp.mod(start_f, 1000000.0) / 1000000.0,
            jnp.float32(4.0) / 8.0,  # Placeholder for bit count
            jnp.sqrt(jnp.abs(start_f)) / 1e9,
        ])

        return features

    def extract_features(self, start, end):
        """Extract features (numpy interface)"""
        return np.array(self.extract_features_jax(
            jnp.array(start, dtype=jnp.int64),
            jnp.array(end, dtype=jnp.int64)
        ))

    def extract_batch(self, regions):
        """Extract features for a batch of regions"""
        features = []
        for start, count in regions:
            end = start + count
            f = self.extract_features(start, end)
            features.append(f)
        return np.array(features, dtype=np.float32)

# ==================== Configuration ====================

@dataclass
class HydraConfig:
    """Configuration for Hydra TPU search"""
    region_size: int = 10_000_000  # 10M candidates per region
    batch_size: int = 100  # Process 100 regions at once on TPU
    prediction_threshold: float = 0.3  # Skip regions with score < threshold

# ==================== Hydra TPU Searcher ====================

class HydraTpu:
    """Neural-guided exhaustive search on TPU"""

    def __init__(self, predictor=None, config: Optional[HydraConfig] = None):
        """
        Initialize Hydra TPU

        Args:
            predictor: Optional Cerberus predictor model for guided search
            config: Search configuration
        """
        self.predictor = predictor
        self.config = config or HydraConfig()
        self.feature_extractor = RegionFeatureExtractor(self.config.region_size)

        # Warm up JIT compilation
        print("Warming up TPU kernels...")
        start_time = time.time()
        _ = search_region(0, 1000, 12345)
        jax.block_until_ready(_)
        print(f"  Warmup complete ({(time.time() - start_time)*1000:.1f} ms)")

        # Warm up predictor if available
        if self.predictor:
            print("Warming up predictor...")
            test_features = self.feature_extractor.extract_batch([(0, 1000)])
            _ = self.predictor.predict(test_features, verbose=0)
            print(f"  Predictor ready")

    def search(
        self,
        start: int,
        end: int,
        target_hash: int,
        guided: bool = True
    ) -> Optional[int]:
        """
        Search for a value that hashes to target

        Args:
            start: Start of search range
            end: End of search range
            target_hash: Target hash value (64-bit)
            guided: Use neural predictor to skip regions (if available)

        Returns:
            Matching value if found, None otherwise
        """
        print(f"\n{'='*60}")
        print(f"Hydra TPU Search")
        print(f"{'='*60}")
        print(f"Range: {start:,} to {end:,}")
        print(f"Target: {target_hash:016x}")
        print(f"Guided: {guided and self.predictor is not None}")
        print()

        # Divide into regions
        regions = []
        current = start
        while current < end:
            region_end = min(current + self.config.region_size, end)
            regions.append((current, region_end - current))
            current = region_end

        print(f"Total regions: {len(regions):,}")
        print(f"Region size: {self.config.region_size:,}")
        print()

        # Optional: Use predictor to filter regions
        promising_regions = regions
        if guided and self.predictor is not None:
            print("Running neural predictor...")
            promising_regions = self._filter_regions(regions)
            skip_rate = 1.0 - (len(promising_regions) / len(regions))
            print(f"  Promising regions: {len(promising_regions):,} / {len(regions):,}")
            print(f"  Skip rate: {skip_rate*100:.1f}%")
            print()

        # Search regions in batches
        total_candidates = sum(count for _, count in promising_regions)
        print(f"Searching {total_candidates:,} candidates...")

        start_time = time.time()
        candidates_searched = 0

        for batch_idx in range(0, len(promising_regions), self.config.batch_size):
            batch = promising_regions[batch_idx:batch_idx + self.config.batch_size]

            # Prepare batch
            starts = [s for s, _ in batch]
            count = self.config.region_size
            target = target_hash

            # Search batch on TPU
            found, match_values = search_regions_batch(starts, count, target)

            # Check for matches
            if jnp.any(found):
                match_idx = jnp.argmax(found)
                match_value = int(match_values[match_idx])

                elapsed = time.time() - start_time
                throughput = candidates_searched / elapsed if elapsed > 0 else 0

                print(f"\n{'='*60}")
                print(f"MATCH FOUND!")
                print(f"{'='*60}")
                print(f"Value: {match_value}")
                print(f"Hash:  {int(splitmix64(jnp.uint64(match_value))):016x}")
                print(f"\nSearch stats:")
                print(f"  Candidates searched: {candidates_searched:,}")
                print(f"  Time: {elapsed:.2f} seconds")
                print(f"  Throughput: {throughput/1e9:.2f} billion/sec")

                return match_value

            candidates_searched += len(batch) * self.config.region_size

            # Progress update
            if batch_idx % (self.config.batch_size * 10) == 0:
                progress = candidates_searched / total_candidates
                elapsed = time.time() - start_time
                throughput = candidates_searched / elapsed if elapsed > 0 else 0
                print(f"  Progress: {progress*100:.1f}% | "
                      f"Searched: {candidates_searched:,} | "
                      f"Throughput: {throughput/1e9:.2f} billion/sec",
                      end='\r')

        elapsed = time.time() - start_time
        throughput = candidates_searched / elapsed if elapsed > 0 else 0

        print(f"\n\nNo match found")
        print(f"  Candidates searched: {candidates_searched:,}")
        print(f"  Time: {elapsed:.2f} seconds")
        print(f"  Throughput: {throughput/1e9:.2f} billion/sec")

        return None

    def _filter_regions(self, regions):
        """
        Use predictor to filter promising regions

        Args:
            regions: List of (start, count) tuples

        Returns:
            Filtered list of promising regions
        """
        if not self.predictor:
            return regions

        # Extract features for all regions
        print("  Extracting features...", end='', flush=True)
        start_time = time.time()
        features = self.feature_extractor.extract_batch(regions)
        extract_time = time.time() - start_time
        print(f" {extract_time*1000:.1f} ms")

        # Predict promise scores
        print("  Running predictor...", end='', flush=True)
        start_time = time.time()
        predictions = self.predictor.predict(features, verbose=0).flatten()
        predict_time = time.time() - start_time
        print(f" {predict_time*1000:.1f} ms")

        # Filter by threshold
        promising_mask = predictions >= self.config.prediction_threshold
        promising_regions = [r for r, keep in zip(regions, promising_mask) if keep]

        # Show score distribution
        print(f"  Score distribution:")
        print(f"    Min:  {predictions.min():.4f}")
        print(f"    Max:  {predictions.max():.4f}")
        print(f"    Mean: {predictions.mean():.4f}")
        print(f"    Threshold: {self.config.prediction_threshold:.4f}")

        return promising_regions

# ==================== Benchmark ====================

def benchmark():
    """Benchmark TPU hash throughput"""
    print(f"\n{'='*60}")
    print(f"Hydra TPU Benchmark")
    print(f"{'='*60}\n")

    print("TPU Info:")
    devices = jax.devices()
    for device in devices:
        print(f"  {device}")
    print()

    # Test different batch sizes
    test_sizes = [1_000, 10_000, 100_000, 1_000_000, 10_000_000]

    for size in test_sizes:
        # Generate test data
        values = jnp.arange(0, size, dtype=jnp.uint64)

        # Warmup
        _ = hash_batch(values)
        jax.block_until_ready(_)

        # Benchmark
        num_trials = 10
        start_time = time.time()
        for _ in range(num_trials):
            hashes = hash_batch(values)
            jax.block_until_ready(hashes)
        elapsed = time.time() - start_time

        throughput = (size * num_trials) / elapsed
        print(f"  {size:>10,} candidates: {throughput/1e9:>6.2f} billion/sec")

    print()

# ==================== Main ====================

def main():
    parser = argparse.ArgumentParser(description='Hydra TPU - Neural-guided exhaustive search')
    parser.add_argument('--start', type=int, default=0, help='Start of search range')
    parser.add_argument('--end', type=int, default=100_000_000, help='End of search range')
    parser.add_argument('--target', type=str, help='Target hash (hex)')
    parser.add_argument('--model', type=str, help='Path to Cerberus predictor model')
    parser.add_argument('--benchmark', action='store_true', help='Run benchmark')
    parser.add_argument('--no-guided', action='store_true', help='Disable guided search')

    args = parser.parse_args()

    if args.benchmark:
        benchmark()
        return

    if not args.target:
        parser.error('--target is required for search mode')

    # Parse target hash
    target_hash = int(args.target, 16)

    # Load predictor if provided
    predictor = None
    if args.model:
        print(f"Loading predictor from {args.model}...")
        import keras
        predictor = keras.models.load_model(args.model)
        print(f"  Loaded: {predictor.name}")

    # Create searcher
    hydra = HydraTpu(predictor=predictor)

    # Run search
    result = hydra.search(
        args.start,
        args.end,
        target_hash,
        guided=not args.no_guided
    )

    if result is None:
        exit(1)

if __name__ == '__main__':
    main()
