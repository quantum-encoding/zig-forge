#!/usr/bin/env python3
"""Export U2NetP PyTorch weights to ZVIS format with BatchNorm fusion.

Usage:
    python scripts/export_u2netp.py --checkpoint u2netp.pth --output models/u2netp.zvis

ZVIS format:
    Header (20 bytes): magic(u32) version(u32) n_tensors(u32) model_type(u32) reserved(u32)
    Per tensor: name_len(u32) name(bytes) n_dims(u32) dims(u32[]) data(f32[])
"""

import argparse
import struct
import numpy as np

ZVIS_MAGIC = 0x5A564953  # "ZVIS"
ZVIS_VERSION = 1
MODEL_TYPE_U2NETP = 0


def fuse_bn_into_conv(conv_weight, conv_bias, bn_weight, bn_bias, bn_mean, bn_var, eps=1e-5):
    """Fuse BatchNorm parameters into Conv2D weight and bias.

    w_fused = w * (gamma / sqrt(var + eps))
    b_fused = (b - mean) * (gamma / sqrt(var + eps)) + beta
    """
    inv_std = bn_weight / np.sqrt(bn_var + eps)

    # Reshape for broadcasting: [out_channels, 1, 1, 1]
    shape = [-1] + [1] * (conv_weight.ndim - 1)
    inv_std_reshaped = inv_std.reshape(shape)

    fused_weight = conv_weight * inv_std_reshaped
    fused_bias = (conv_bias - bn_mean) * inv_std + bn_bias

    return fused_weight, fused_bias


def find_conv_bn_pairs(state_dict):
    """Find matching Conv2D + BatchNorm layer pairs in the state dict."""
    # Build a map of base names to their parameters
    conv_layers = {}
    bn_layers = {}

    for key in state_dict:
        if key.endswith('.weight') or key.endswith('.bias'):
            # Split off parameter name
            parts = key.rsplit('.', 1)
            base = parts[0]
            param = parts[1]

            # Check parent for conv/bn distinction
            if any(key.endswith(s) for s in ['.running_mean', '.running_var', '.num_batches_tracked']):
                continue

        if '.running_mean' in key:
            base = key.replace('.running_mean', '')
            bn_layers.setdefault(base, {})['running_mean'] = key
        elif '.running_var' in key:
            base = key.replace('.running_var', '')
            bn_layers.setdefault(base, {})['running_var'] = key
        elif '.num_batches_tracked' in key:
            continue
        elif key.endswith('.weight'):
            base = key[:-7]
            tensor = state_dict[key]
            if tensor.ndim == 4:  # Conv2D weight
                conv_layers.setdefault(base, {})['weight'] = key
            elif tensor.ndim == 1:
                # Could be BN weight or bias
                if base in bn_layers or base + '.running_mean' in [v for d in bn_layers.values() for v in d.values()]:
                    bn_layers.setdefault(base, {})['weight'] = key
                else:
                    # Check if there's a matching BN by looking for running_mean
                    bn_key = base + '.running_mean'
                    if bn_key in state_dict:
                        bn_layers.setdefault(base, {})['weight'] = key
                    else:
                        conv_layers.setdefault(base, {})['weight'] = key
        elif key.endswith('.bias'):
            base = key[:-5]
            tensor = state_dict[key]
            if tensor.ndim == 1:
                bn_key = base + '.running_mean'
                if bn_key in state_dict:
                    bn_layers.setdefault(base, {})['bias'] = key
                else:
                    conv_layers.setdefault(base, {})['bias'] = key

    return conv_layers, bn_layers


def export_u2netp(checkpoint_path, output_path):
    """Export U2NetP weights with BN fusion to ZVIS format."""
    try:
        import torch
    except ImportError:
        print("PyTorch is required. Install with: pip install torch")
        return

    print(f"Loading checkpoint: {checkpoint_path}")
    state_dict = torch.load(checkpoint_path, map_location='cpu', weights_only=True)

    # Handle nested state dict (some checkpoints wrap in 'model' key)
    if 'model' in state_dict:
        state_dict = state_dict['model']
    elif 'state_dict' in state_dict:
        state_dict = state_dict['state_dict']

    # Convert all to numpy
    np_dict = {k: v.numpy() for k, v in state_dict.items()}

    # Build output tensors with BN fusion
    output_tensors = []  # list of (name, numpy_array)
    processed_bns = set()

    # Find all conv layers and their corresponding BN layers
    # U2NetP naming: stage1.rebnconvin.conv_s1, stage1.rebnconvin.bn_s1, etc.
    # Or: stage1.rebnconv1.conv_s1, stage1.rebnconv1.bn_s1, etc.

    # Strategy: iterate all keys, group by conv/bn pairs
    conv_keys = sorted([k for k in np_dict if k.endswith('.weight') and np_dict[k].ndim == 4])

    for conv_w_key in conv_keys:
        base = conv_w_key[:-7]  # Remove '.weight'
        conv_w = np_dict[conv_w_key]

        # Find bias
        conv_b_key = base + '.bias'
        conv_b = np_dict.get(conv_b_key, np.zeros(conv_w.shape[0], dtype=np.float32))

        # Try to find matching BN
        # Common patterns: replace 'conv' with 'bn' in the name
        bn_base = None
        for pattern in [
            base.replace('.conv_s1', '.bn_s1'),
            base.replace('.conv_s', '.bn_s'),
            base.replace('conv', 'bn'),
            base + '_bn',
        ]:
            if pattern + '.weight' in np_dict and pattern + '.running_mean' in np_dict:
                bn_base = pattern
                break

        if bn_base and bn_base not in processed_bns:
            # Fuse BN into conv
            bn_w = np_dict[bn_base + '.weight']
            bn_b = np_dict[bn_base + '.bias']
            bn_mean = np_dict[bn_base + '.running_mean']
            bn_var = np_dict[bn_base + '.running_var']

            fused_w, fused_b = fuse_bn_into_conv(conv_w, conv_b, bn_w, bn_b, bn_mean, bn_var)
            processed_bns.add(bn_base)

            # Simplify name for ZVIS (remove .conv_s1 suffix, keep stage.block structure)
            simple_name = base
            for suffix in ['.conv_s1', '.conv_s']:
                simple_name = simple_name.replace(suffix, '')

            output_tensors.append((simple_name + '.weight', fused_w.astype(np.float32)))
            output_tensors.append((simple_name + '.bias', fused_b.astype(np.float32)))
            print(f"  Fused: {simple_name} [{conv_w.shape}]")
        else:
            # No BN found, use conv weights directly
            simple_name = base
            for suffix in ['.conv_s1', '.conv_s']:
                simple_name = simple_name.replace(suffix, '')

            output_tensors.append((simple_name + '.weight', conv_w.astype(np.float32)))
            output_tensors.append((simple_name + '.bias', conv_b.astype(np.float32)))
            print(f"  Direct: {simple_name} [{conv_w.shape}]")

    # Write ZVIS file
    print(f"\nWriting {len(output_tensors)} tensors to {output_path}")

    with open(output_path, 'wb') as f:
        # Header
        f.write(struct.pack('<IIIII',
            ZVIS_MAGIC,
            ZVIS_VERSION,
            len(output_tensors),
            MODEL_TYPE_U2NETP,
            0  # reserved
        ))

        total_params = 0
        for name, data in output_tensors:
            name_bytes = name.encode('utf-8')

            # name_len + name
            f.write(struct.pack('<I', len(name_bytes)))
            f.write(name_bytes)

            # n_dims + dims (NCHW)
            shape = data.shape
            f.write(struct.pack('<I', len(shape)))
            for dim in shape:
                f.write(struct.pack('<I', dim))

            # Pad to 4-byte alignment before data
            pos = f.tell()
            if pos % 4 != 0:
                f.write(b'\x00' * (4 - pos % 4))

            # f32 data
            f.write(data.tobytes())
            total_params += data.size

    file_size = struct.calcsize('IIIII')  # approximate, recalc
    import os
    file_size = os.path.getsize(output_path)

    print(f"\nDone!")
    print(f"  Tensors:    {len(output_tensors)}")
    print(f"  Parameters: {total_params:,}")
    print(f"  File size:  {file_size / 1024 / 1024:.1f} MB")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Export U2NetP to ZVIS format')
    parser.add_argument('--checkpoint', required=True, help='Path to PyTorch checkpoint (.pth)')
    parser.add_argument('--output', required=True, help='Output ZVIS file path')
    args = parser.parse_args()

    export_u2netp(args.checkpoint, args.output)
