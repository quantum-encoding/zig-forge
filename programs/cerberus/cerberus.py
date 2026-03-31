#!/usr/bin/env python3
"""
Cerberus - Neural Network Guided Smart Search Engine

"Hydra searches everything. Cerberus searches smart."

Architecture:
    The Three Heads of Cerberus:
    1. PREDICTOR HEAD - Neural network that predicts promising regions
    2. VERIFIER HEAD  - Fast hash verification on GPU
    3. LEARNER HEAD   - Online learning from found matches

    Unlike Hydra's brute-force approach, Cerberus uses ML to:
    - Skip unlikely candidate regions (guided search)
    - Learn from successful matches to improve predictions
    - Dynamically adjust search strategy based on pattern recognition

Design Philosophy:
    - TPU/GPU for neural inference (pattern recognition)
    - GPU for parallel hash verification
    - CPU for orchestration and online learning updates

Usage:
    python cerberus.py --mode benchmark
    python cerberus.py --mode search --target <hash> --start 0 --end 1000000000
"""

import tensorflow as tf
import numpy as np
import time
import argparse
from dataclasses import dataclass
from typing import Optional, List, Tuple
from enum import Enum


class SearchMode(Enum):
    BRUTE_FORCE = "brute"      # Like Hydra - check everything
    GUIDED = "guided"          # Use neural predictor
    HYBRID = "hybrid"          # Smart regions + brute force gaps


@dataclass
class SearchConfig:
    """Configuration for Cerberus search"""
    start: int = 0
    end: int = 100_000_000
    target_hash: bytes = b'\xde\xad\xbe\xef' + b'\x00' * 28
    batch_size: int = 1_000_000
    mode: SearchMode = SearchMode.GUIDED
    learning_rate: float = 0.001
    prediction_threshold: float = 0.5


@dataclass
class SearchStats:
    """Statistics from a search run"""
    candidates_checked: int = 0
    candidates_skipped: int = 0
    matches_found: int = 0
    elapsed_seconds: float = 0.0
    predictor_accuracy: float = 0.0

    @property
    def throughput(self) -> float:
        if self.elapsed_seconds == 0:
            return 0
        return self.candidates_checked / self.elapsed_seconds

    @property
    def skip_ratio(self) -> float:
        total = self.candidates_checked + self.candidates_skipped
        if total == 0:
            return 0
        return self.candidates_skipped / total


class SplitMix64:
    """Vectorized SplitMix64 hash implementation for TensorFlow"""

    @staticmethod
    @tf.function
    def hash_batch(values: tf.Tensor) -> tf.Tensor:
        """Hash a batch of uint64 values using SplitMix64"""
        # Ensure we're working with int64
        x = tf.cast(values, tf.int64)

        # SplitMix64 algorithm
        x = tf.bitwise.bitwise_xor(x, tf.bitwise.right_shift(x, 30))
        x = tf.math.multiply_no_nan(
            tf.cast(x, tf.float64),
            tf.constant(0xbf58476d1ce4e5b9, dtype=tf.float64)
        )
        x = tf.cast(x, tf.int64)

        x = tf.bitwise.bitwise_xor(x, tf.bitwise.right_shift(x, 27))
        x = tf.math.multiply_no_nan(
            tf.cast(x, tf.float64),
            tf.constant(0x94d049bb133111eb, dtype=tf.float64)
        )
        x = tf.cast(x, tf.int64)

        x = tf.bitwise.bitwise_xor(x, tf.bitwise.right_shift(x, 31))
        return x


class PredictorHead(tf.keras.Model):
    """
    HEAD 1: The Predictor

    Neural network that predicts probability of a region containing matches.
    Input: Region features (start index, region stats, historical patterns)
    Output: Probability score [0, 1] that region contains a match
    """

    def __init__(self, hidden_units: int = 128):
        super().__init__()
        self.dense1 = tf.keras.layers.Dense(hidden_units, activation='relu')
        self.dense2 = tf.keras.layers.Dense(hidden_units // 2, activation='relu')
        self.dense3 = tf.keras.layers.Dense(hidden_units // 4, activation='relu')
        self.output_layer = tf.keras.layers.Dense(1, activation='sigmoid')

    def call(self, inputs, training=False):
        x = self.dense1(inputs)
        x = self.dense2(x)
        x = self.dense3(x)
        return self.output_layer(x)

    @tf.function
    def predict_regions(self, region_features: tf.Tensor) -> tf.Tensor:
        """Predict promise scores for multiple regions"""
        return self(region_features, training=False)


class VerifierHead:
    """
    HEAD 2: The Verifier

    GPU-accelerated hash verification. Takes candidate batches and
    checks them against the target hash.
    """

    def __init__(self, device: str = '/GPU:0'):
        self.device = device

    @tf.function
    def verify_batch(
        self,
        candidates: tf.Tensor,
        target_hash: tf.Tensor
    ) -> Tuple[tf.Tensor, tf.Tensor]:
        """
        Verify a batch of candidates against target hash.

        Returns:
            matches: Boolean tensor of matches
            hashes: Computed hashes (for learning)
        """
        with tf.device(self.device):
            hashes = SplitMix64.hash_batch(candidates)

            # Convert first 8 bytes of target to u64
            # target_hash is uint8[32], we want first 8 bytes as int64
            target_bytes = tf.cast(target_hash[:8], tf.int64)
            target_u64 = tf.bitwise.bitwise_or(
                tf.bitwise.bitwise_or(
                    tf.bitwise.bitwise_or(
                        tf.bitwise.bitwise_or(
                            target_bytes[0],
                            tf.bitwise.left_shift(target_bytes[1], 8)
                        ),
                        tf.bitwise.bitwise_or(
                            tf.bitwise.left_shift(target_bytes[2], 16),
                            tf.bitwise.left_shift(target_bytes[3], 24)
                        )
                    ),
                    tf.bitwise.bitwise_or(
                        tf.bitwise.left_shift(target_bytes[4], 32),
                        tf.bitwise.left_shift(target_bytes[5], 40)
                    )
                ),
                tf.bitwise.bitwise_or(
                    tf.bitwise.left_shift(target_bytes[6], 48),
                    tf.bitwise.left_shift(target_bytes[7], 56)
                )
            )

            matches = tf.equal(hashes, target_u64)
            return matches, hashes


class LearnerHead:
    """
    HEAD 3: The Learner

    Online learning component that updates the Predictor based on
    search results. Learns patterns from found matches.
    """

    def __init__(self, predictor: PredictorHead, learning_rate: float = 0.001):
        self.predictor = predictor
        self.optimizer = tf.keras.optimizers.Adam(learning_rate)
        self.history: List[Tuple[np.ndarray, bool]] = []

    def record_result(self, region_features: np.ndarray, had_match: bool):
        """Record a region search result for learning"""
        self.history.append((region_features, had_match))

    @tf.function
    def _train_step(self, features: tf.Tensor, labels: tf.Tensor):
        """Single training step"""
        with tf.GradientTape() as tape:
            predictions = self.predictor(features, training=True)
            loss = tf.keras.losses.binary_crossentropy(labels, predictions)
            loss = tf.reduce_mean(loss)

        gradients = tape.gradient(loss, self.predictor.trainable_variables)
        self.optimizer.apply_gradients(
            zip(gradients, self.predictor.trainable_variables)
        )
        return loss

    def learn_from_history(self, batch_size: int = 32) -> float:
        """Train predictor on accumulated history"""
        if len(self.history) < batch_size:
            return 0.0

        # Sample from history
        indices = np.random.choice(len(self.history), batch_size, replace=False)
        features = np.array([self.history[i][0] for i in indices])
        labels = np.array([[1.0 if self.history[i][1] else 0.0] for i in indices])

        loss = self._train_step(
            tf.constant(features, dtype=tf.float32),
            tf.constant(labels, dtype=tf.float32)
        )
        return float(loss)


class Cerberus:
    """
    The Three-Headed Beast: Neural-Guided Smart Search Engine

    Combines prediction, verification, and learning for intelligent
    brute-force search that adapts to patterns in the search space.
    """

    def __init__(self, config: SearchConfig):
        self.config = config

        # Initialize the three heads
        self.predictor = PredictorHead()
        self.verifier = VerifierHead()
        self.learner = LearnerHead(self.predictor, config.learning_rate)

        # Build predictor with dummy input
        dummy_input = tf.zeros([1, 8], dtype=tf.float32)
        _ = self.predictor(dummy_input)

        self.stats = SearchStats()

    def _extract_region_features(self, start: int, end: int) -> np.ndarray:
        """Extract features for a region to feed to predictor"""
        size = end - start
        return np.array([
            start / 1e18,              # Normalized start
            end / 1e18,                # Normalized end
            size / 1e9,                # Normalized size
            np.log10(start + 1) / 20,  # Log-scale position
            np.log10(size + 1) / 10,   # Log-scale size
            (start >> 32) / 1e9,       # High bits
            (start & 0xFFFFFFFF) / 1e9, # Low bits
            np.sin(start / 1e6),       # Periodic feature
        ], dtype=np.float32)

    def search_brute_force(self) -> SearchStats:
        """Pure brute-force search (like Hydra)"""
        start_time = time.time()
        target_tensor = tf.constant(
            list(self.config.target_hash),
            dtype=tf.uint8
        )

        current = self.config.start
        while current < self.config.end:
            batch_end = min(current + self.config.batch_size, self.config.end)
            candidates = tf.range(current, batch_end, dtype=tf.int64)

            matches, _ = self.verifier.verify_batch(candidates, target_tensor)

            match_indices = tf.where(matches)
            if tf.size(match_indices) > 0:
                self.stats.matches_found += int(tf.size(match_indices))

            self.stats.candidates_checked += int(batch_end - current)
            current = batch_end

        self.stats.elapsed_seconds = time.time() - start_time
        return self.stats

    def search_guided(self) -> SearchStats:
        """Neural-guided smart search"""
        start_time = time.time()
        target_tensor = tf.constant(
            list(self.config.target_hash),
            dtype=tf.uint8
        )

        # Divide search space into regions
        region_size = self.config.batch_size * 10
        regions = []
        current = self.config.start

        while current < self.config.end:
            region_end = min(current + region_size, self.config.end)
            regions.append((current, region_end))
            current = region_end

        # Score all regions with predictor
        region_features = np.array([
            self._extract_region_features(s, e) for s, e in regions
        ])
        scores = self.predictor.predict_regions(
            tf.constant(region_features, dtype=tf.float32)
        ).numpy().flatten()

        # Sort regions by promise score (descending)
        sorted_indices = np.argsort(-scores)

        # Search high-promise regions first
        for idx in sorted_indices:
            region_start, region_end = regions[idx]
            score = scores[idx]

            # Skip low-promise regions (unless hybrid mode)
            if score < self.config.prediction_threshold:
                if self.config.mode == SearchMode.GUIDED:
                    self.stats.candidates_skipped += region_end - region_start
                    continue

            # Search this region
            current = region_start
            region_had_match = False

            while current < region_end:
                batch_end = min(current + self.config.batch_size, region_end)
                candidates = tf.range(current, batch_end, dtype=tf.int64)

                matches, _ = self.verifier.verify_batch(candidates, target_tensor)

                match_indices = tf.where(matches)
                if tf.size(match_indices) > 0:
                    self.stats.matches_found += int(tf.size(match_indices))
                    region_had_match = True

                self.stats.candidates_checked += int(batch_end - current)
                current = batch_end

            # Record for learning
            self.learner.record_result(region_features[idx], region_had_match)

        # Online learning step
        if len(self.learner.history) >= 32:
            self.learner.learn_from_history()

        self.stats.elapsed_seconds = time.time() - start_time
        return self.stats

    def search(self) -> SearchStats:
        """Run search with configured mode"""
        if self.config.mode == SearchMode.BRUTE_FORCE:
            return self.search_brute_force()
        else:
            return self.search_guided()


def run_benchmark():
    """Benchmark Cerberus performance"""
    print("\n" + "=" * 60)
    print("CERBERUS BENCHMARK")
    print("Neural-Guided Smart Search Engine")
    print("=" * 60)

    # Show GPU info
    gpus = tf.config.list_physical_devices('GPU')
    if gpus:
        for gpu in gpus:
            details = tf.config.experimental.get_device_details(gpu)
            print(f"\nGPU: {details.get('device_name', 'unknown')}")
            print(f"Compute Capability: {details.get('compute_capability', 'unknown')}")

    test_sizes = [1_000_000, 10_000_000, 100_000_000]

    # Impossible target = no early exit, fair comparison
    target = b'\xff' * 32

    print("\n--- Brute Force Mode (like Hydra) ---")
    for size in test_sizes:
        config = SearchConfig(
            start=0,
            end=size,
            target_hash=target,
            mode=SearchMode.BRUTE_FORCE,
            batch_size=1_000_000
        )

        cerberus = Cerberus(config)
        stats = cerberus.search()

        print(f"\n{size:,} candidates:")
        print(f"  Time: {stats.elapsed_seconds*1000:.2f} ms")
        print(f"  Throughput: {stats.throughput/1e6:.2f}M/sec")

    print("\n--- Guided Mode (Smart Search) ---")
    for size in test_sizes:
        config = SearchConfig(
            start=0,
            end=size,
            target_hash=target,
            mode=SearchMode.GUIDED,
            batch_size=1_000_000,
            prediction_threshold=0.3  # Search top 70% of regions
        )

        cerberus = Cerberus(config)
        stats = cerberus.search()

        print(f"\n{size:,} candidates:")
        print(f"  Checked: {stats.candidates_checked:,}")
        print(f"  Skipped: {stats.candidates_skipped:,} ({stats.skip_ratio*100:.1f}%)")
        print(f"  Time: {stats.elapsed_seconds*1000:.2f} ms")
        print(f"  Effective throughput: {(stats.candidates_checked + stats.candidates_skipped)/stats.elapsed_seconds/1e6:.2f}M/sec")

    print("\n" + "=" * 60)
    print("Benchmark complete")
    print("=" * 60)


def main():
    parser = argparse.ArgumentParser(
        description="Cerberus - Neural-Guided Smart Search Engine"
    )
    parser.add_argument(
        "--mode",
        choices=["benchmark", "search"],
        default="benchmark",
        help="Operation mode"
    )
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--end", type=int, default=100_000_000)
    parser.add_argument("--target", type=str, default="deadbeef")

    args = parser.parse_args()

    if args.mode == "benchmark":
        run_benchmark()
    else:
        # Parse hex target
        target_bytes = bytes.fromhex(args.target.ljust(64, '0'))

        config = SearchConfig(
            start=args.start,
            end=args.end,
            target_hash=target_bytes,
            mode=SearchMode.HYBRID
        )

        print(f"\nSearching {args.start:,} to {args.end:,} for {args.target}...")
        cerberus = Cerberus(config)
        stats = cerberus.search()

        print(f"\nResults:")
        print(f"  Matches found: {stats.matches_found}")
        print(f"  Candidates checked: {stats.candidates_checked:,}")
        print(f"  Time: {stats.elapsed_seconds:.2f}s")
        print(f"  Throughput: {stats.throughput/1e6:.2f}M/sec")


if __name__ == "__main__":
    main()
