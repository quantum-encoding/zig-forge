# Cerberus TPU v6e-1 Setup Guide

## Quick Start (cerberus2 Ready!)

**Jupyter is already running!** Just connect:

### Option 1: SSH Tunnel (Recommended)

Open a new terminal and run:

```bash
gcloud compute tpus tpu-vm ssh cerberus2 \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1 \
  -- -L 8888:localhost:8888
```

Then open: **http://localhost:8888/tree?token=2f7637b21b5131a6b51da73241cc4fb4f6093fd8baa35df1**

### Option 2: Direct Access

Open: **http://34.34.77.243:8888/tree?token=2f7637b21b5131a6b51da73241cc4fb4f6093fd8baa35df1**

(Only works if firewall allows port 8888)

### Open the Notebook

Once connected, open `cerberus_tpu_training.ipynb` and run all cells.

---

## TPU Details
- **Name:** cerberus2
- **Zone:** europe-west4-a
- **Type:** v6e-1 (8 cores, 16GB HBM)
- **Runtime:** v2-alpha-tpuv6e (JAX pre-configured)
- **External IP:** 34.34.77.243
- **Status:** Running with Jupyter

---

## If You Need to Restart Jupyter

If Jupyter stops or you need to restart it:

```bash
# SSH into TPU and start Jupyter
gcloud compute tpus tpu-vm ssh cerberus2 \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1 \
  --command="nohup jupyter notebook --ip=0.0.0.0 --port=8888 --no-browser > jupyter.log 2>&1 &"

# Wait a few seconds, then get the token
gcloud compute tpus tpu-vm ssh cerberus2 \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1 \
  --command="sleep 5 && cat jupyter.log | grep token"
```

---

## Creating a New TPU (For Reference)

**IMPORTANT:** v6e TPUs require the `v2-alpha-tpuv6e` runtime (not base Ubuntu images).

From your **local machine**:

```bash
# Create TPU with ML runtime
gcloud compute tpus tpu-vm create cerberus2 \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1 \
  --accelerator-type=v6e-1 \
  --version=v2-alpha-tpuv6e \
  --preemptible
```

Wait ~2 minutes for TPU to provision.

---

## Step 1: Verify TPU and Install Dependencies (Run on TPU)

SSH into the TPU:

```bash
gcloud compute tpus tpu-vm ssh cerberus2 \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1
```

Verify JAX and TPU connectivity:

```bash
python3 -c "
import jax
print(f'JAX version: {jax.__version__}')
print(f'JAX devices: {jax.devices()}')
print(f'TPU cores: {len(jax.devices())}')
"
```

You should see output showing 8 TPU cores detected.

Install additional dependencies:

```bash
pip install jupyter matplotlib keras
```

---

## Step 2: Upload Training Notebook

From your **local machine**, upload the notebook to TPU:

```bash
gcloud compute tpus tpu-vm scp \
  /home/founder/github_public/quantum-zig-forge/programs/cerberus/cerberus_tpu_training.ipynb \
  cerberus2: \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1
```

---

## Step 3: Start Jupyter (Run on TPU)

```bash
# Start Jupyter server
jupyter notebook --ip=0.0.0.0 --port=8888 --no-browser
```

Keep this running. It will output a URL with a token.

---

## Step 4: SSH Tunnel (Run on Local Machine)

Open a **new terminal** on your local machine:

```bash
gcloud compute tpus tpu-vm ssh cerberus2 \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1 \
  -- -L 8888:localhost:8888
```

Then open in browser: `http://localhost:8888`

Use the token from Step 3.

---

## Step 5: Run Training

Open `cerberus_tpu_training.ipynb` in Jupyter and run all cells.

Training will take approximately 10-15 minutes on v6e-1.

---

## Monitoring

### Check TPU Utilization (Run on TPU)
```bash
watch -n 1 nvidia-smi  # Won't work - TPUs don't use nvidia-smi
```

For TPU metrics, use Cloud Console:
https://console.cloud.google.com/compute/tpus

---

## Cleanup When Done

### Download Model Files (Optional)

Before deleting the TPU, download the trained model:

```bash
# Download all generated files
gcloud compute tpus tpu-vm scp cerberus2:cerberus_predictor.keras . \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1

gcloud compute tpus tpu-vm scp cerberus2:cerberus_config.json . \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1

gcloud compute tpus tpu-vm scp cerberus2:training_history.json . \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1
```

### Delete TPU

```bash
# Delete TPU VM (from local machine)
gcloud compute tpus tpu-vm delete cerberus2 \
  --zone=europe-west4-a \
  --project=metatron-cloud-prod-v1
```

**IMPORTANT:** TPU v6e-1 costs ~$1.50/hour. Delete when done to avoid charges!

---

## Troubleshooting

### JAX doesn't detect TPU
```bash
# Check libtpu is installed
pip list | grep libtpu

# Reinstall if needed
pip install --upgrade libtpu
```

### Out of memory during training
Reduce batch size in notebook:
```python
config.batch_size = 2048  # Instead of 4096
```

### Jupyter connection refused
Make sure SSH tunnel is running and using correct port (8888).
