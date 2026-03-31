#!/usr/bin/env python3
"""
Export Piper VITS ONNX model to ZVIS v2 format for zig_inference.

Usage:
  python export_piper.py --onnx model.onnx --config model.onnx.json --output model.zvis

Requires: pip install onnx numpy
"""

import argparse
import json
import struct
import sys
from pathlib import Path

import numpy as np
import onnx
from onnx import numpy_helper

ZVIS_MAGIC = 0x5A564953  # "ZVIS"
ZVIS_VERSION = 2
MODEL_TYPE_VITS = 2

# Tensor name mapping: ONNX graph → our convention
# Piper ONNX uses numbered initializer names; we map by shape/position.
# This mapping covers the standard Piper VITS architecture.

def remap_tensor_name(onnx_name):
    """Map ONNX tensor names to our ZVIS convention."""
    # Piper uses descriptive names like:
    #   enc_p.emb.weight, enc_p.encoder.attn_layers.0.*, etc.
    name = onnx_name

    # Text encoder
    name = name.replace("enc_p.", "enc.")
    name = name.replace("encoder.attn_layers", "encoder.attn")
    name = name.replace("encoder.norm_layers_1", "encoder.ln1")
    name = name.replace("encoder.norm_layers_2", "encoder.ln2")
    name = name.replace("encoder.ffn_layers", "encoder.ffn")
    name = name.replace(".conv_1.", ".conv1.")
    name = name.replace(".conv_2.", ".conv2.")

    # Duration predictor / SDP
    name = name.replace("dp.", "sdp.")
    name = name.replace("stochastic_duration_predictor.", "sdp.")

    # Flow
    name = name.replace("flow.", "flow.")

    # Decoder (HiFi-GAN)
    name = name.replace("dec.", "dec.")

    # proj (encoder output projection)
    name = name.replace("enc.proj.", "enc.proj.")

    return name


def export_piper(onnx_path, config_path, output_path):
    print(f"Loading ONNX model: {onnx_path}")
    model = onnx.load(str(onnx_path))

    print(f"Loading config: {config_path}")
    with open(config_path) as f:
        config = json.load(f)

    # Extract TTS config from Piper's JSON
    audio_cfg = config.get("audio", {})
    model_cfg = config.get("inference", config)

    n_vocab = config.get("num_symbols", 256)
    d_model = config.get("inter_channels", 192)
    # Piper config structure varies; try common paths
    if "model" in config:
        mc = config["model"]
        n_vocab = mc.get("num_symbols", n_vocab)
        d_model = mc.get("inter_channels", d_model)

    sample_rate = audio_cfg.get("sample_rate", 22050)
    hop_length = audio_cfg.get("hop_length", 256)

    # Count layers by examining tensor names
    n_enc_layers = 0
    n_flow_layers = 0
    n_ups = 0
    for init in model.graph.initializer:
        name = remap_tensor_name(init.name)
        if "enc.encoder.attn." in name:
            try:
                idx = int(name.split("enc.encoder.attn.")[1].split(".")[0])
                n_enc_layers = max(n_enc_layers, idx + 1)
            except (ValueError, IndexError):
                pass
        if "flow." in name and "flows." in init.name:
            try:
                idx = int(init.name.split("flows.")[1].split(".")[0])
                n_flow_layers = max(n_flow_layers, idx + 1)
            except (ValueError, IndexError):
                pass
        if "dec.ups." in name or "dec.ups." in init.name:
            try:
                parts = init.name.split("ups.")[1] if "ups." in init.name else name.split("dec.ups.")[1]
                idx = int(parts.split(".")[0])
                n_ups = max(n_ups, idx + 1)
            except (ValueError, IndexError):
                pass

    if n_enc_layers == 0:
        n_enc_layers = 6  # default
    if n_flow_layers == 0:
        n_flow_layers = 4  # default
    if n_ups == 0:
        n_ups = 4  # default

    print(f"Config: vocab={n_vocab}, d_model={d_model}, enc_layers={n_enc_layers}, "
          f"flow_layers={n_flow_layers}, ups={n_ups}, sr={sample_rate}, hop={hop_length}")

    # Collect tensors
    tensors = []
    for init in model.graph.initializer:
        arr = numpy_helper.to_array(init).astype(np.float32)
        name = remap_tensor_name(init.name)
        tensors.append((name, arr))

    print(f"Exporting {len(tensors)} tensors to {output_path}")

    with open(output_path, "wb") as f:
        # ZVIS v2 header (20 bytes)
        f.write(struct.pack("<I", ZVIS_MAGIC))
        f.write(struct.pack("<I", ZVIS_VERSION))
        f.write(struct.pack("<I", len(tensors)))
        f.write(struct.pack("<I", MODEL_TYPE_VITS))
        f.write(struct.pack("<I", 0))  # reserved

        # TtsConfig (28 bytes)
        f.write(struct.pack("<I", n_vocab))
        f.write(struct.pack("<I", d_model))
        f.write(struct.pack("<I", n_enc_layers))
        f.write(struct.pack("<I", n_flow_layers))
        f.write(struct.pack("<I", n_ups))
        f.write(struct.pack("<I", sample_rate))
        f.write(struct.pack("<I", hop_length))

        # Tensors
        for name, arr in tensors:
            name_bytes = name.encode("utf-8")
            f.write(struct.pack("<I", len(name_bytes)))
            f.write(name_bytes)

            dims = arr.shape
            f.write(struct.pack("<I", len(dims)))
            for d in dims:
                f.write(struct.pack("<I", d))

            f.write(arr.tobytes())

    file_size = Path(output_path).stat().st_size
    print(f"Done! Output: {output_path} ({file_size / 1024 / 1024:.1f} MB)")


def main():
    parser = argparse.ArgumentParser(description="Export Piper VITS to ZVIS v2")
    parser.add_argument("--onnx", required=True, help="Path to Piper .onnx model")
    parser.add_argument("--config", required=True, help="Path to Piper .onnx.json config")
    parser.add_argument("--output", required=True, help="Output .zvis path")
    args = parser.parse_args()

    if not Path(args.onnx).exists():
        print(f"Error: ONNX file not found: {args.onnx}", file=sys.stderr)
        sys.exit(1)
    if not Path(args.config).exists():
        print(f"Error: Config file not found: {args.config}", file=sys.stderr)
        sys.exit(1)

    export_piper(args.onnx, args.config, args.output)


if __name__ == "__main__":
    main()
