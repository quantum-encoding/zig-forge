#!/usr/bin/env python3
"""
Cerberus v2 Training Script - 50/50 Balanced Dataset

Trains neural predictor with balanced positive/negative examples
to improve region filtering effectiveness.
"""

import os
os.environ['KERAS_BACKEND'] = 'jax'
os.environ['JAX_ENABLE_X64'] = '1'

import jax
import jax.numpy as jnp
jax.config.update("jax_enable_x64", True)

import keras
import numpy as np
import time
import json
from dataclasses import dataclass
from typing import List, Tuple

# ==================== Configuration ====================

@dataclass
class CerberusConfig:
    """Configuration for Cerberus v2 training"""
    # Model architecture
    embedding_dim: int = 64
    hidden_units: List[int] = None
    dropout_rate: float = 0.2

    # Training
    batch_size: int = 4096
    learning_rate: float = 0.001
    epochs: int = 50
    warmup_epochs: int = 5

    # Search space
    region_size: int = 10_000_000
    num_features: int = 16

    # Data generation (v2: 50/50 balanced)
    train_regions: int = 100_000
    val_regions: int = 10_000
    match_probability: float = 0.5  # 50/50 balance

    def __post_init__(self):
        if self.hidden_units is None:
            self.hidden_units = [256, 128, 64]

# ==================== Hash Functions ====================

HASH_C1 = np.uint64(0xbf58476d1ce4e5b9)
HASH_C2 = np.uint64(0x94d049bb133111eb)

@jax.jit
def splitmix64(x: jnp.ndarray) -> jnp.ndarray:
    """SplitMix64 hash"""
    x = x.astype(jnp.uint64)
    x = x ^ (x >> 30)
    x = x * HASH_C1
    x = x ^ (x >> 27)
    x = x * HASH_C2
    x = x ^ (x >> 31)
    return x.astype(jnp.int64)

# ==================== Feature Extraction ====================

class RegionFeatureExtractor:
    """Extract features from search regions"""

    @staticmethod
    @jax.jit
    def extract_features_jax(start: jnp.ndarray, end: jnp.ndarray) -> jnp.ndarray:
        """Extract 16 features from region"""
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
            jnp.float32(4.0) / 8.0,
            jnp.sqrt(jnp.abs(start_f)) / 1e9,
        ])

        return features

    def extract_features(self, start, end):
        """Extract features (numpy interface)"""
        return np.array(self.extract_features_jax(
            jnp.array(start, dtype=jnp.int64),
            jnp.array(end, dtype=jnp.int64)
        ))

    def extract_batch(self, starts: np.ndarray, ends: np.ndarray) -> np.ndarray:
        """Extract features for batch"""
        features = []
        for s, e in zip(starts, ends):
            f = self.extract_features(int(s), int(e))
            features.append(f)
        return np.array(features)

# ==================== Model ====================

def create_predictor_model(config):
    """Create predictor neural network"""
    inputs = keras.Input(shape=(config.num_features,), name='region_features')

    x = inputs
    for i, units in enumerate(config.hidden_units):
        x = keras.layers.Dense(
            units,
            activation=None,
            kernel_initializer='he_normal',
            name=f'dense_{i}'
        )(x)
        x = keras.layers.BatchNormalization(name=f'bn_{i}')(x)
        x = keras.layers.Activation('relu', name=f'relu_{i}')(x)
        x = keras.layers.Dropout(config.dropout_rate, name=f'dropout_{i}')(x)

    outputs = keras.layers.Dense(1, activation='sigmoid', name='prediction')(x)

    model = keras.Model(inputs=inputs, outputs=outputs, name='CerberusPredictor')
    return model

# ==================== Data Generation ====================

class TrainingDataGenerator:
    """Generate synthetic training data"""

    def __init__(self, config, seed: int = 42):
        self.config = config
        self.rng = np.random.default_rng(seed)
        self.extractor = RegionFeatureExtractor()

        # Hot patterns for matches
        self.hot_patterns = [
            lambda x: (x % 1000000) < 1000,
            lambda x: ((x >> 20) & 0xF) == 0xA,
            lambda x: x % 7919 == 0,
        ]

    def _region_has_match(self, start: int, end: int) -> bool:
        """Determine if region has match"""
        for pattern in self.hot_patterns:
            if pattern(start):
                return self.rng.random() < 0.8
        return self.rng.random() < self.config.match_probability

    def generate_dataset(self, num_regions: int, max_start: int = 10**15) -> Tuple[np.ndarray, np.ndarray]:
        """Generate training dataset"""
        print(f"Generating {num_regions:,} regions...")

        starts = self.rng.integers(0, max_start, size=num_regions)
        ends = starts + self.config.region_size

        features = []
        labels = []

        for i, (s, e) in enumerate(zip(starts, ends)):
            if i % 10000 == 0:
                print(f"  Processing: {i:,}/{num_regions:,}", end='\r')

            f = self.extractor.extract_features(int(s), int(e))
            features.append(f)

            has_match = self._region_has_match(int(s), int(e))
            labels.append([1.0 if has_match else 0.0])

        print(f"  Generated {num_regions:,} regions")

        features = np.array(features, dtype=np.float32)
        labels = np.array(labels, dtype=np.float32)

        positive_rate = labels.mean()
        print(f"  Positive rate: {positive_rate*100:.2f}%")

        return features, labels

# ==================== Main Training ====================

def main():
    print("=" * 60)
    print("Cerberus v2 Training - 50/50 Balanced")
    print("=" * 60)

    # Show environment
    print(f"\nEnvironment:")
    print(f"  Keras: {keras.__version__}")
    print(f"  Backend: {keras.backend.backend()}")
    print(f"  JAX: {jax.__version__}")
    print(f"  Devices: {jax.devices()}")

    # Config
    config = CerberusConfig()
    print(f"\nConfiguration:")
    print(f"  Training regions: {config.train_regions:,}")
    print(f"  Validation regions: {config.val_regions:,}")
    print(f"  Match probability: {config.match_probability*100:.1f}%")
    print(f"  Batch size: {config.batch_size}")
    print(f"  Epochs: {config.epochs}")

    # Generate data
    print(f"\n{'='*60}")
    print("Generating Training Data")
    print("=" * 60)

    data_gen = TrainingDataGenerator(config)
    X_train, y_train = data_gen.generate_dataset(config.train_regions)
    print()
    X_val, y_val = data_gen.generate_dataset(config.val_regions)

    print(f"\nDataset shapes:")
    print(f"  Train: X={X_train.shape}, y={y_train.shape}")
    print(f"  Val:   X={X_val.shape}, y={y_val.shape}")

    # Create model
    print(f"\n{'='*60}")
    print("Creating Model")
    print("=" * 60)

    predictor = create_predictor_model(config)

    predictor.compile(
        optimizer=keras.optimizers.Adam(learning_rate=config.learning_rate),
        loss='binary_crossentropy',
        metrics=[
            'accuracy',
            keras.metrics.AUC(name='auc'),
            keras.metrics.Precision(name='precision'),
            keras.metrics.Recall(name='recall')
        ]
    )

    predictor.summary()

    # Class weights
    positive_rate = y_train.mean()
    negative_rate = 1 - positive_rate
    class_weight = {
        0: 1.0,
        1: negative_rate / positive_rate
    }

    print(f"\nClass weights:")
    print(f"  Negative (0): {class_weight[0]:.2f}")
    print(f"  Positive (1): {class_weight[1]:.2f}")

    # Callbacks
    callbacks = [
        keras.callbacks.LearningRateScheduler(
            lambda epoch, lr: config.learning_rate * min(1.0, (epoch + 1) / config.warmup_epochs)
            if epoch < config.warmup_epochs
            else config.learning_rate * (0.95 ** (epoch - config.warmup_epochs))
        ),
        keras.callbacks.EarlyStopping(
            monitor='val_auc',
            patience=10,
            restore_best_weights=True,
            mode='max'
        ),
        keras.callbacks.ModelCheckpoint(
            'cerberus_predictor_v2_best.keras',
            monitor='val_auc',
            save_best_only=True,
            mode='max'
        ),
    ]

    # Train
    print(f"\n{'='*60}")
    print("Training")
    print("=" * 60)

    start_time = time.time()

    history = predictor.fit(
        X_train, y_train,
        validation_data=(X_val, y_val),
        batch_size=config.batch_size,
        epochs=config.epochs,
        callbacks=callbacks,
        class_weight=class_weight,
        verbose=1
    )

    training_time = time.time() - start_time
    print(f"\nTraining completed in {training_time:.2f} seconds")

    # Evaluate
    print(f"\n{'='*60}")
    print("Evaluation")
    print("=" * 60)

    results = predictor.evaluate(X_val, y_val, batch_size=config.batch_size, verbose=0)
    metrics = dict(zip(predictor.metrics_names, results))

    print(f"\nValidation Metrics:")
    for name, value in metrics.items():
        print(f"  {name}: {value:.4f}")

    # Prediction analysis
    predictions = predictor.predict(X_val, verbose=0)
    print(f"\nPrediction Distribution:")
    print(f"  Min:  {predictions.min():.4f}")
    print(f"  Max:  {predictions.max():.4f}")
    print(f"  Mean: {predictions.mean():.4f}")
    print(f"  Std:  {predictions.std():.4f}")

    # Threshold analysis
    print(f"\nThreshold Analysis:")
    for threshold in [0.3, 0.5, 0.7, 0.9]:
        pred_positive = (predictions >= threshold).sum()
        skip_rate = 1.0 - (pred_positive / len(predictions))
        print(f"  Threshold {threshold}: Skip {skip_rate*100:.1f}% of regions")

    # Save
    print(f"\n{'='*60}")
    print("Saving Model (v2)")
    print("=" * 60)

    predictor.save('cerberus_predictor_v2.keras')
    print("  Saved: cerberus_predictor_v2.keras")

    config_dict = {
        'embedding_dim': config.embedding_dim,
        'hidden_units': config.hidden_units,
        'dropout_rate': config.dropout_rate,
        'num_features': config.num_features,
        'region_size': config.region_size,
        'backend': keras.backend.backend(),
        'version': 'v2',
        'match_probability': config.match_probability,
        'train_regions': config.train_regions,
    }
    with open('cerberus_config_v2.json', 'w') as f:
        json.dump(config_dict, f, indent=2)
    print("  Saved: cerberus_config_v2.json")

    history_dict = {k: [float(v) for v in vals] for k, vals in history.history.items()}
    with open('training_history_v2.json', 'w') as f:
        json.dump(history_dict, f, indent=2)
    print("  Saved: training_history_v2.json")

    print("\nTraining complete!")

if __name__ == '__main__':
    main()
