# TPU v6e-1 Troubleshooting

## Error: "Failed to get global TPU topology"

**Root Cause:** Using wrong TPU runtime version.

v6e TPUs require the `v2-alpha-tpuv6e` runtime, which has JAX pre-configured with proper TPU support. Base Ubuntu images (`tpu-ubuntu2204-base`, etc.) don't work because manually installed JAX can't communicate with TPU hardware.

---

## Solution: Recreate TPU with Correct Runtime

```bash
# 1. Delete current TPU
gcloud compute tpus tpu-vm delete cerberus \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1 \
  --quiet

# 2. Create TPU with ML runtime
gcloud compute tpus tpu-vm create cerberus \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1 \
  --accelerator-type=v6e-1 \
  --version=v2-alpha-tpuv6e \
  --preemptible

# 3. Wait ~2 minutes, then SSH and verify
gcloud compute tpus tpu-vm ssh cerberus \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1

# 4. Test JAX (should work immediately)
python3 -c "
import jax
print(f'JAX devices: {jax.devices()}')
print(f'TPU cores: {len(jax.devices())}')
"
```

---

## Why Base Images Don't Work

| Runtime | JAX Status | TPU Support | Recommendation |
|---------|-----------|-------------|----------------|
| `tpu-ubuntu2204-base` | ❌ Manual install fails | ❌ No topology | Don't use |
| `v2-alpha-tpuv6e` | ✅ Pre-configured | ✅ Full support | **Use this** |
| `v6e-ubuntu-2404` | ❌ Manual install fails | ❌ No topology | Don't use |

---

## Deprecated Fixes (Don't Work with Base Images)

<details>
<summary>Old troubleshooting steps (kept for reference)</summary>

### Fix 1: Enable Transparent Hugepages

```bash
# Enable transparent hugepages (as root)
sudo sh -c "echo always > /sys/kernel/mm/transparent_hugepage/enabled"

# Verify
cat /sys/kernel/mm/transparent_hugepage/enabled
# Should show: [always] madvise never
```

### Fix 2: Check TPU Runtime

```bash
# Check if TPU is visible
ls /dev/accel*
# Should show: /dev/accel0

# Check TPU info
cat /proc/tpu/info
```

**Note:** v6e with Ubuntu base images don't have `/dev/accel*` or `/proc/tpu/*` devices.

### Fix 3: Use Correct JAX/jaxlib Versions for v6e

```bash
# Uninstall current JAX
pip uninstall jax jaxlib -y

# Install specific versions for TPU v6e
pip install jax==0.4.23
pip install "jaxlib[tpu]==0.4.23" -f https://storage.googleapis.com/jax-releases/libtpu_releases.html

# Verify
python3 -c "import jax; print(jax.__version__)"
```

**Note:** Manual JAX installation doesn't work on base images. Use `v2-alpha-tpuv6e` runtime instead.

</details>

---

## Fix 4: Set JAX Backend Explicitly

```bash
# Test with explicit TPU backend
python3 -c "
import os
os.environ['JAX_PLATFORMS'] = 'tpu'
import jax
print(f'JAX version: {jax.__version__}')
print(f'JAX devices: {jax.devices()}')
print(f'TPU cores: {len(jax.devices())}')
"
```

---

## Fix 5: Try TensorFlow Instead (Fallback)

If JAX still doesn't work, we can use TensorFlow (already installed):

```bash
python3 -c "
import tensorflow as tf
resolver = tf.distribute.cluster_resolver.TPUClusterResolver()
tf.config.experimental_connect_to_cluster(resolver)
tf.tpu.experimental.initialize_tpu_system(resolver)
print('TPU devices:', tf.config.list_logical_devices('TPU'))
"
```

---

## Fix 6: Restart TPU Runtime

Sometimes the TPU runtime needs a restart:

```bash
# Check TPU runtime status
sudo systemctl status tpu-runtime

# Restart TPU runtime
sudo systemctl restart tpu-runtime

# Wait a few seconds, then test again
sleep 5
python3 -c "import jax; print(jax.devices())"
```

---

## Fix 7: Check TPU VM Configuration

```bash
# Verify TPU type
gcloud compute tpus tpu-vm describe cerberus \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1
```

---

## Alternative: Use TensorFlow Backend in Keras

Since TensorFlow 2.20.0 is already working, we can modify the notebook to use TensorFlow backend instead of JAX:

In the notebook, change:
```python
# OLD:
os.environ['KERAS_BACKEND'] = 'jax'

# NEW:
os.environ['KERAS_BACKEND'] = 'tensorflow'
```

This will work with TPU v6e and use TensorFlow's TPU support directly.

---

## Quick Test Order

Try these in order:

1. **Enable hugepages** (Fix 1)
2. **Check TPU device exists** (Fix 2)
3. **Try TensorFlow test** (Fix 5) - If this works, use TF backend
4. **Try older JAX version** (Fix 3)
5. **Restart TPU runtime** (Fix 6)

---

## If Nothing Works

The v6e TPUs might require a different approach. Let me know which fix works or if we need to switch to TensorFlow backend entirely.
