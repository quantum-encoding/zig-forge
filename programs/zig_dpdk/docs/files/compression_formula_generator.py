#!/usr/bin/env python3
"""
Compression Algorithm Generative Grammar Engine
================================================

A systematic enumeration engine for generating mathematically-grounded compression
algorithm formulas, their parametric variations, and valid pipeline combinations.

This implements a "generative grammar" approach to compression algorithm design space
exploration:
    - ALPHABET: Fundamental compression primitives (transforms, predictors, entropy coders)
    - GRAMMAR: Valid pipeline composition rules
    - DIALECTS: Parametric variations of each component

Architecture:
    CompressionComponent (dataclass) - Individual algorithm building blocks
    ComponentCategory (enum) - Taxonomy of component types
    CompressionFormulaGenerator - Main engine for enumeration and combination
    PipelineGenerator - Generates valid multi-stage compression pipelines

Output Format:
    CSV with columns: category, name, formula_latex, formula_ascii, description,
                      parameters, parameter_values, complexity_time, complexity_space,
                      pipeline_stage, is_lossless

Author: Generated for Rich @ Quantum Encoding LTD
License: MIT
"""

from __future__ import annotations

import csv
import itertools
import json
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum, auto
from pathlib import Path
from typing import Any, Generator, Iterable


class ComponentCategory(Enum):
    """
    Taxonomy of compression algorithm component types.
    
    This categorization follows the standard compression pipeline architecture:
    Pre-processing → Transform → Modeling/Prediction → Entropy Coding
    """
    ENTROPY_MEASURE = auto()       # Information-theoretic foundations
    TRANSFORM = auto()             # Reversible data transformations
    PREDICTOR = auto()             # Statistical modeling / prediction
    DICTIONARY = auto()            # Dictionary-based methods (LZ family)
    ENTROPY_CODER = auto()         # Final bit-level encoding
    RUN_LENGTH = auto()            # Run-length encoding variants
    CONTEXT_MODEL = auto()         # Context mixing and modeling
    FILTER = auto()                # Pre/post processing filters
    INTEGER_CODER = auto()         # Integer/universal codes


@dataclass(frozen=True, slots=True)
class CompressionComponent:
    """
    Immutable representation of a compression algorithm component.
    
    Attributes:
        category: The functional category of this component
        name: Human-readable identifier
        formula_latex: Mathematical formula in LaTeX notation
        formula_ascii: Plain-text ASCII representation of the formula
        description: Explanation of what the component does
        parameters: Dict mapping parameter names to descriptions
        default_params: Default parameter values for generation
        time_complexity: Big-O time complexity
        space_complexity: Big-O space complexity
        pipeline_stages: Valid positions in a compression pipeline
        is_lossless: Whether this component preserves all information
        prerequisites: Other components that should precede this one
        incompatible_with: Components that cannot be combined with this one
    """
    category: ComponentCategory
    name: str
    formula_latex: str
    formula_ascii: str
    description: str
    parameters: dict[str, str] = field(default_factory=dict)
    default_params: dict[str, list[Any]] = field(default_factory=dict)
    time_complexity: str = "O(n)"
    space_complexity: str = "O(n)"
    pipeline_stages: tuple[int, ...] = (1,)
    is_lossless: bool = True
    prerequisites: tuple[str, ...] = ()
    incompatible_with: tuple[str, ...] = ()
    
    def generate_variations(self) -> Generator[dict[str, Any], None, None]:
        """
        Generate all parametric variations of this component.
        
        Yields dictionaries containing the component with specific parameter values.
        Uses Cartesian product of all parameter value ranges.
        """
        if not self.default_params:
            yield {"component": self, "params": {}}
            return
        
        param_names = list(self.default_params.keys())
        param_values = list(self.default_params.values())
        
        for combination in itertools.product(*param_values):
            yield {
                "component": self,
                "params": dict(zip(param_names, combination))
            }


class ComponentRegistry:
    """
    Central registry of all known compression algorithm components.
    
    This is the "alphabet" of our generative grammar - the fundamental
    building blocks from which compression algorithms are constructed.
    """
    
    @staticmethod
    def get_all_components() -> list[CompressionComponent]:
        """Return the complete catalog of compression components."""
        return [
            *ComponentRegistry._entropy_measures(),
            *ComponentRegistry._transforms(),
            *ComponentRegistry._predictors(),
            *ComponentRegistry._dictionary_methods(),
            *ComponentRegistry._entropy_coders(),
            *ComponentRegistry._run_length_encoders(),
            *ComponentRegistry._context_models(),
            *ComponentRegistry._filters(),
            *ComponentRegistry._integer_coders(),
        ]
    
    @staticmethod
    def _entropy_measures() -> list[CompressionComponent]:
        """Information-theoretic foundations."""
        return [
            CompressionComponent(
                category=ComponentCategory.ENTROPY_MEASURE,
                name="Shannon Entropy",
                formula_latex=r"H(X) = -\sum_{i=1}^{n} p(x_i) \log_2 p(x_i)",
                formula_ascii="H(X) = -SUM(p(x_i) * log2(p(x_i))) for i=1 to n",
                description="Fundamental measure of information content; theoretical minimum bits per symbol",
                parameters={"n": "alphabet size", "p(x_i)": "probability of symbol i"},
                default_params={"base": [2, "e", 10]},
                time_complexity="O(n)",
                space_complexity="O(n)",
                pipeline_stages=(0,),
            ),
            CompressionComponent(
                category=ComponentCategory.ENTROPY_MEASURE,
                name="Conditional Entropy",
                formula_latex=r"H(X|Y) = -\sum_{y} p(y) \sum_{x} p(x|y) \log_2 p(x|y)",
                formula_ascii="H(X|Y) = -SUM_y(p(y) * SUM_x(p(x|y) * log2(p(x|y))))",
                description="Expected entropy of X given knowledge of Y; basis for context modeling",
                parameters={"X": "target variable", "Y": "conditioning variable"},
                time_complexity="O(|X| * |Y|)",
                space_complexity="O(|X| * |Y|)",
                pipeline_stages=(0,),
            ),
            CompressionComponent(
                category=ComponentCategory.ENTROPY_MEASURE,
                name="Mutual Information",
                formula_latex=r"I(X;Y) = H(X) - H(X|Y) = \sum_{x,y} p(x,y) \log_2 \frac{p(x,y)}{p(x)p(y)}",
                formula_ascii="I(X;Y) = H(X) - H(X|Y) = SUM(p(x,y) * log2(p(x,y) / (p(x)*p(y))))",
                description="Information shared between two variables; guides context selection",
                parameters={"X": "first variable", "Y": "second variable"},
                time_complexity="O(|X| * |Y|)",
                space_complexity="O(|X| * |Y|)",
                pipeline_stages=(0,),
            ),
            CompressionComponent(
                category=ComponentCategory.ENTROPY_MEASURE,
                name="Kolmogorov Complexity",
                formula_latex=r"K(x) = \min\{|p| : U(p) = x\}",
                formula_ascii="K(x) = min{|p| : U(p) = x} (length of shortest program)",
                description="Theoretical minimum description length; incomputable but guides algorithm design",
                parameters={"U": "universal Turing machine", "p": "program"},
                time_complexity="Incomputable",
                space_complexity="Incomputable",
                pipeline_stages=(0,),
            ),
            CompressionComponent(
                category=ComponentCategory.ENTROPY_MEASURE,
                name="Rényi Entropy",
                formula_latex=r"H_\alpha(X) = \frac{1}{1-\alpha} \log_2 \sum_{i=1}^{n} p_i^\alpha",
                formula_ascii="H_alpha(X) = (1/(1-alpha)) * log2(SUM(p_i^alpha))",
                description="Generalized entropy; alpha=1 gives Shannon entropy, alpha=0 gives Hartley entropy",
                parameters={"alpha": "order parameter (α ≥ 0, α ≠ 1)"},
                default_params={"alpha": [0, 0.5, 2, float("inf")]},
                time_complexity="O(n)",
                space_complexity="O(n)",
                pipeline_stages=(0,),
            ),
        ]
    
    @staticmethod
    def _transforms() -> list[CompressionComponent]:
        """Reversible data transformations."""
        return [
            CompressionComponent(
                category=ComponentCategory.TRANSFORM,
                name="Burrows-Wheeler Transform",
                formula_latex=r"BWT(s) = L \text{ where } M = \text{sort}(\text{rotations}(s)), L = \text{last\_column}(M)",
                formula_ascii="BWT(s) = last_column(sort(all_rotations(s)))",
                description="Reversible transform that groups similar contexts together; basis for bzip2",
                parameters={"s": "input string"},
                time_complexity="O(n log n)",
                space_complexity="O(n)",
                pipeline_stages=(1,),
            ),
            CompressionComponent(
                category=ComponentCategory.TRANSFORM,
                name="Move-to-Front Transform",
                formula_latex=r"MTF(s_i) = \text{position of } s_i \text{ in list } L; \text{ move } s_i \text{ to front}",
                formula_ascii="MTF(s_i) = index_of(s_i, L); then move s_i to L[0]",
                description="Exploits locality by outputting small numbers for recently-seen symbols",
                parameters={"alphabet_size": "size of symbol alphabet"},
                default_params={"alphabet_size": [256, 65536]},
                time_complexity="O(n * |Σ|)",
                space_complexity="O(|Σ|)",
                pipeline_stages=(2,),
                prerequisites=("Burrows-Wheeler Transform",),
            ),
            CompressionComponent(
                category=ComponentCategory.TRANSFORM,
                name="Discrete Cosine Transform",
                formula_latex=r"X_k = \sum_{n=0}^{N-1} x_n \cos\left[\frac{\pi}{N}\left(n+\frac{1}{2}\right)k\right]",
                formula_ascii="X_k = SUM(x_n * cos(pi/N * (n + 0.5) * k)) for n=0 to N-1",
                description="Frequency-domain transform; used in JPEG (lossy variant exists)",
                parameters={"N": "block size"},
                default_params={"N": [8, 16, 32]},
                time_complexity="O(n log n)",
                space_complexity="O(n)",
                pipeline_stages=(1,),
                is_lossless=True,  # DCT itself is lossless; quantization makes it lossy
            ),
            CompressionComponent(
                category=ComponentCategory.TRANSFORM,
                name="Delta Encoding",
                formula_latex=r"\Delta_i = x_i - x_{i-1}, \quad x_0' = x_0",
                formula_ascii="delta_i = x_i - x_{i-1}; x_0' = x_0",
                description="Stores differences between consecutive values; effective for sorted/smooth data",
                parameters={"order": "delta order (1=first difference, 2=second difference)"},
                default_params={"order": [1, 2, 3]},
                time_complexity="O(n)",
                space_complexity="O(1)",
                pipeline_stages=(1,),
            ),
            CompressionComponent(
                category=ComponentCategory.TRANSFORM,
                name="XOR Delta",
                formula_latex=r"d_i = x_i \oplus x_{i-1}",
                formula_ascii="d_i = x_i XOR x_{i-1}",
                description="Bitwise delta; preserves structure in binary data with similar consecutive values",
                time_complexity="O(n)",
                space_complexity="O(1)",
                pipeline_stages=(1,),
            ),
            CompressionComponent(
                category=ComponentCategory.TRANSFORM,
                name="Integer Wavelet Transform (Lifting)",
                formula_latex=r"d_j[n] = x[2n+1] - \lfloor(x[2n] + x[2n+2])/2\rfloor; \quad s_j[n] = x[2n] + \lfloor d_j[n]/4 \rfloor",
                formula_ascii="d_j[n] = x[2n+1] - floor((x[2n] + x[2n+2])/2); s_j[n] = x[2n] + floor(d_j[n]/4)",
                description="Lossless wavelet via integer lifting scheme; used in JPEG 2000 lossless mode",
                parameters={"levels": "decomposition levels"},
                default_params={"levels": [1, 2, 3, 4]},
                time_complexity="O(n)",
                space_complexity="O(n)",
                pipeline_stages=(1,),
            ),
            CompressionComponent(
                category=ComponentCategory.TRANSFORM,
                name="Byte Pair Encoding (Transform)",
                formula_latex=r"BPE(s) = \text{replace most frequent pair } (a,b) \text{ with new symbol } c",
                formula_ascii="BPE(s) = iteratively_replace(most_frequent_pair, new_symbol)",
                description="Iteratively replaces frequent byte pairs; creates implicit dictionary",
                parameters={"max_iterations": "maximum replacement iterations"},
                default_params={"max_iterations": [100, 1000, 10000]},
                time_complexity="O(n * iterations)",
                space_complexity="O(|vocab|)",
                pipeline_stages=(1,),
            ),
        ]
    
    @staticmethod
    def _predictors() -> list[CompressionComponent]:
        """Statistical modeling and prediction components."""
        return [
            CompressionComponent(
                category=ComponentCategory.PREDICTOR,
                name="Order-N Markov Predictor",
                formula_latex=r"P(x_i | x_{i-1}, ..., x_{i-n}) = \frac{C(x_{i-n}...x_i)}{C(x_{i-n}...x_{i-1})}",
                formula_ascii="P(x_i | context) = count(context + x_i) / count(context)",
                description="Predicts next symbol based on preceding n symbols; basis for PPM",
                parameters={"order": "context length n"},
                default_params={"order": [0, 1, 2, 3, 4, 5, 6]},
                time_complexity="O(n)",
                space_complexity="O(|Σ|^order)",
                pipeline_stages=(2,),
            ),
            CompressionComponent(
                category=ComponentCategory.PREDICTOR,
                name="Prediction by Partial Matching (PPM)",
                formula_latex=r"P(x) = \lambda_n P_n(x) + (1-\lambda_n)[\lambda_{n-1} P_{n-1}(x) + ...]",
                formula_ascii="P(x) = weighted_blend(P_order_n(x), P_order_n-1(x), ..., P_order_0(x))",
                description="Blends predictions from multiple context orders with escape mechanism",
                parameters={"max_order": "maximum context order", "escape": "escape method"},
                default_params={
                    "max_order": [4, 5, 6, 8],
                    "escape": ["PPMA", "PPMB", "PPMC", "PPMD", "PPMD+"]
                },
                time_complexity="O(n * max_order)",
                space_complexity="O(|Σ|^max_order)",
                pipeline_stages=(2,),
            ),
            CompressionComponent(
                category=ComponentCategory.PREDICTOR,
                name="Dynamic Markov Compression (DMC)",
                formula_latex=r"P(b|state) = \frac{count(state, b) + 1}{count(state) + 2}; \text{ clone states adaptively}",
                formula_ascii="P(bit|state) = (count(state,bit) + 1) / (count(state) + 2); clone when threshold exceeded",
                description="Bit-level Markov model that dynamically clones states",
                parameters={"threshold": "cloning threshold"},
                default_params={"threshold": [2, 4, 8, 16]},
                time_complexity="O(n)",
                space_complexity="O(states)",
                pipeline_stages=(2,),
            ),
            CompressionComponent(
                category=ComponentCategory.PREDICTOR,
                name="Linear Predictor",
                formula_latex=r"\hat{x}_i = \sum_{j=1}^{p} a_j x_{i-j}",
                formula_ascii="x_hat_i = SUM(a_j * x_{i-j}) for j=1 to p",
                description="Linear combination of previous samples; used in FLAC, PNG",
                parameters={"order": "predictor order p", "coefficients": "predictor coefficients"},
                default_params={"order": [1, 2, 3, 4]},
                time_complexity="O(n * p)",
                space_complexity="O(p)",
                pipeline_stages=(1, 2),
            ),
            CompressionComponent(
                category=ComponentCategory.PREDICTOR,
                name="PNG Predictors (Paeth)",
                formula_latex=r"Paeth(a,b,c) = \text{argmin}_{x \in \{a,b,c\}} |x - (a+b-c)|",
                formula_ascii="Paeth(left, above, upper_left) = closest_to(left + above - upper_left)",
                description="2D predictor selecting from left/above/diagonal based on gradient",
                time_complexity="O(1) per pixel",
                space_complexity="O(width)",
                pipeline_stages=(1,),
            ),
            CompressionComponent(
                category=ComponentCategory.PREDICTOR,
                name="Context Tree Weighting (CTW)",
                formula_latex=r"P_s = \frac{1}{2}P_e(s) + \frac{1}{2}P_{s0}P_{s1}",
                formula_ascii="P_s = 0.5 * P_estimated(s) + 0.5 * P_child0 * P_child1",
                description="Bayesian mixture over all context tree depths; theoretically optimal",
                parameters={"max_depth": "maximum tree depth"},
                default_params={"max_depth": [8, 16, 24, 32, 48]},
                time_complexity="O(n * depth)",
                space_complexity="O(2^depth)",
                pipeline_stages=(2,),
            ),
        ]
    
    @staticmethod
    def _dictionary_methods() -> list[CompressionComponent]:
        """Dictionary-based compression (LZ family)."""
        return [
            CompressionComponent(
                category=ComponentCategory.DICTIONARY,
                name="LZ77 (Sliding Window)",
                formula_latex=r"(d, l, c) \text{ where } d = \text{distance}, l = \text{length}, c = \text{next char}",
                formula_ascii="encode(match) = (distance_back, match_length, next_char)",
                description="Replace repeated sequences with back-references; basis for DEFLATE",
                parameters={
                    "window_size": "sliding window size",
                    "lookahead_size": "lookahead buffer size"
                },
                default_params={
                    "window_size": [4096, 8192, 32768, 65536],
                    "lookahead_size": [16, 32, 64, 256]
                },
                time_complexity="O(n * window)",
                space_complexity="O(window)",
                pipeline_stages=(1, 2),
            ),
            CompressionComponent(
                category=ComponentCategory.DICTIONARY,
                name="LZ78 (Explicit Dictionary)",
                formula_latex=r"(i, c) \text{ where } i = \text{dict index}, c = \text{extending char}",
                formula_ascii="encode(phrase) = (dictionary_index, extending_character)",
                description="Builds explicit dictionary of phrases; basis for LZW",
                parameters={"max_dict_size": "maximum dictionary entries"},
                default_params={"max_dict_size": [4096, 16384, 65536]},
                time_complexity="O(n)",
                space_complexity="O(dict_size)",
                pipeline_stages=(1, 2),
            ),
            CompressionComponent(
                category=ComponentCategory.DICTIONARY,
                name="LZW (Lempel-Ziv-Welch)",
                formula_latex=r"\text{output } dict[w]; \text{ add } w+c \text{ to dict}; w = c",
                formula_ascii="output(dict[w]); dict[next_index] = w + c; w = c",
                description="Outputs only dictionary indices; used in GIF, early Unix compress",
                parameters={"max_bits": "maximum code bits"},
                default_params={"max_bits": [12, 14, 16]},
                time_complexity="O(n)",
                space_complexity="O(2^max_bits)",
                pipeline_stages=(1, 2),
            ),
            CompressionComponent(
                category=ComponentCategory.DICTIONARY,
                name="LZSS (LZ77 + flags)",
                formula_latex=r"\text{flag bit } + \begin{cases} \text{literal byte} & \text{if flag}=0 \\ (d, l) & \text{if flag}=1 \end{cases}",
                formula_ascii="flag_bit + (literal OR (distance, length))",
                description="LZ77 variant with flag bits; more efficient for short matches",
                parameters={"min_match": "minimum match length"},
                default_params={"min_match": [2, 3, 4]},
                time_complexity="O(n * window)",
                space_complexity="O(window)",
                pipeline_stages=(1, 2),
            ),
            CompressionComponent(
                category=ComponentCategory.DICTIONARY,
                name="LZMA (Lempel-Ziv-Markov chain)",
                formula_latex=r"LZ77 + \text{range coder} + \text{context-dependent bit models}",
                formula_ascii="LZMA = LZ77_matches + range_coder(context_modeled_bits)",
                description="LZ77 with range coding and sophisticated context modeling; used in 7z, xz",
                parameters={
                    "dict_size": "dictionary size",
                    "lc": "literal context bits",
                    "lp": "literal position bits",
                    "pb": "position bits"
                },
                default_params={
                    "dict_size": [2**16, 2**20, 2**24, 2**26],
                    "lc": [3, 4],
                    "lp": [0, 1, 2],
                    "pb": [0, 1, 2]
                },
                time_complexity="O(n)",
                space_complexity="O(dict_size)",
                pipeline_stages=(1, 2, 3),
            ),
            CompressionComponent(
                category=ComponentCategory.DICTIONARY,
                name="LZ4 (Fast LZ)",
                formula_latex=r"\text{token} = (lit\_len : 4, match\_len : 4) + \text{literals} + \text{offset}",
                formula_ascii="token = (literal_length:4bits, match_length:4bits) + literals + offset16",
                description="Extremely fast LZ77 variant optimized for decompression speed",
                parameters={"acceleration": "compression level"},
                default_params={"acceleration": [1, 2, 4, 8]},
                time_complexity="O(n)",
                space_complexity="O(64KB)",
                pipeline_stages=(1, 2),
            ),
            CompressionComponent(
                category=ComponentCategory.DICTIONARY,
                name="Zstandard (ZSTD)",
                formula_latex=r"FSE(\text{literals}) + FSE(\text{sequences}) + \text{match copying}",
                formula_ascii="ZSTD = FSE_entropy(literals) + FSE_entropy(sequences) + matches",
                description="Modern LZ77 + ANS entropy coding; excellent ratio/speed tradeoff",
                parameters={"level": "compression level"},
                default_params={"level": list(range(1, 23))},
                time_complexity="O(n)",
                space_complexity="O(window_size)",
                pipeline_stages=(1, 2, 3),
            ),
        ]
    
    @staticmethod
    def _entropy_coders() -> list[CompressionComponent]:
        """Entropy coding - final stage bit-level encoding."""
        return [
            CompressionComponent(
                category=ComponentCategory.ENTROPY_CODER,
                name="Huffman Coding",
                formula_latex=r"L(x) = \lceil -\log_2 p(x) \rceil \text{ (optimal prefix code)}",
                formula_ascii="code_length(x) = ceil(-log2(p(x)))",
                description="Optimal prefix-free code for known distributions; used in DEFLATE",
                parameters={"adaptive": "whether to adapt code dynamically"},
                default_params={"adaptive": [False, True]},
                time_complexity="O(n + |Σ| log |Σ|)",
                space_complexity="O(|Σ|)",
                pipeline_stages=(3,),
            ),
            CompressionComponent(
                category=ComponentCategory.ENTROPY_CODER,
                name="Canonical Huffman",
                formula_latex=r"\text{code}(s) = \text{base}[len(s)] + \text{rank within length}",
                formula_ascii="code(s) = base[length(s)] + rank_within_same_length",
                description="Huffman variant requiring only code lengths to reconstruct; used in DEFLATE",
                time_complexity="O(n + |Σ| log |Σ|)",
                space_complexity="O(|Σ|)",
                pipeline_stages=(3,),
            ),
            CompressionComponent(
                category=ComponentCategory.ENTROPY_CODER,
                name="Arithmetic Coding",
                formula_latex=r"[low, high) \leftarrow [low + range \cdot CDF(x-1), low + range \cdot CDF(x))",
                formula_ascii="[low, high) = [low + range*CDF(x-1), low + range*CDF(x))",
                description="Near-optimal entropy coding; approaches H(X) bits per symbol",
                parameters={"precision": "arithmetic precision bits"},
                default_params={"precision": [16, 24, 32, 64]},
                time_complexity="O(n)",
                space_complexity="O(1)",
                pipeline_stages=(3,),
            ),
            CompressionComponent(
                category=ComponentCategory.ENTROPY_CODER,
                name="Range Coding",
                formula_latex=r"range = high - low; \quad high = low + range \cdot p_{cum}(x); \quad low += range \cdot p_{cum}(x-1)",
                formula_ascii="range = high - low; update [low, high) based on cumulative probability",
                description="Arithmetic coding variant with byte-aligned output; used in LZMA",
                time_complexity="O(n)",
                space_complexity="O(1)",
                pipeline_stages=(3,),
            ),
            CompressionComponent(
                category=ComponentCategory.ENTROPY_CODER,
                name="Asymmetric Numeral Systems (ANS)",
                formula_latex=r"C(x, s) = \lfloor x/f_s \rfloor \cdot 2^n + CDF(s) + (x \mod f_s)",
                formula_ascii="C(state, symbol) = floor(state/freq) * 2^n + CDF(symbol) + (state mod freq)",
                description="Modern entropy coder combining arithmetic efficiency with table-based speed",
                parameters={"table_log": "log2 of state table size"},
                default_params={"table_log": [9, 10, 11, 12]},
                time_complexity="O(n)",
                space_complexity="O(2^table_log)",
                pipeline_stages=(3,),
            ),
            CompressionComponent(
                category=ComponentCategory.ENTROPY_CODER,
                name="tANS (Tabled ANS)",
                formula_latex=r"state' = table[state][symbol]; \quad \text{output} = state' \gg \text{bits}",
                formula_ascii="new_state = encoding_table[state][symbol]; output overflowing bits",
                description="Table-driven ANS for very fast encoding/decoding; used in ZSTD",
                parameters={"table_log": "log2 of table size"},
                default_params={"table_log": [9, 10, 11, 12]},
                time_complexity="O(n)",
                space_complexity="O(|Σ| * 2^table_log)",
                pipeline_stages=(3,),
            ),
            CompressionComponent(
                category=ComponentCategory.ENTROPY_CODER,
                name="rANS (Range ANS)",
                formula_latex=r"x' = (x // f_s) \cdot M + CDF(s) + (x \mod f_s)",
                formula_ascii="new_state = (state // freq) * total_freq + CDF(symbol) + (state mod freq)",
                description="Range-based ANS; good for adaptive coding",
                parameters={"precision": "frequency precision bits"},
                default_params={"precision": [12, 14, 16]},
                time_complexity="O(n)",
                space_complexity="O(|Σ|)",
                pipeline_stages=(3,),
            ),
        ]
    
    @staticmethod
    def _run_length_encoders() -> list[CompressionComponent]:
        """Run-length encoding variants."""
        return [
            CompressionComponent(
                category=ComponentCategory.RUN_LENGTH,
                name="Basic RLE",
                formula_latex=r"\text{encode}(s^n) = (n, s)",
                formula_ascii="encode(symbol repeated n times) = (count, symbol)",
                description="Replace runs of identical symbols with (count, symbol) pairs",
                parameters={"max_run": "maximum run length"},
                default_params={"max_run": [127, 255, 65535]},
                time_complexity="O(n)",
                space_complexity="O(1)",
                pipeline_stages=(2, 3),
            ),
            CompressionComponent(
                category=ComponentCategory.RUN_LENGTH,
                name="PackBits RLE",
                formula_latex=r"\begin{cases} n \geq 0: & n+1 \text{ literal bytes follow} \\ n < 0: & \text{repeat next byte } |n|+1 \text{ times} \end{cases}",
                formula_ascii="n >= 0: (n+1) literals follow; n < 0: repeat next byte (|n|+1) times",
                description="Apple's RLE variant; efficient for mixed runs and literals",
                time_complexity="O(n)",
                space_complexity="O(1)",
                pipeline_stages=(2, 3),
            ),
            CompressionComponent(
                category=ComponentCategory.RUN_LENGTH,
                name="Zero RLE",
                formula_latex=r"\text{encode}(0^n) = (\text{ZERO\_TOKEN}, n); \text{ others literal}",
                formula_ascii="encode(n zeros) = (ZERO_TOKEN, count); non-zeros passed through",
                description="RLE specialized for runs of zeros; common after BWT+MTF",
                parameters={"threshold": "minimum zeros to encode"},
                default_params={"threshold": [1, 2, 3]},
                time_complexity="O(n)",
                space_complexity="O(1)",
                pipeline_stages=(2,),
                prerequisites=("Move-to-Front Transform",),
            ),
            CompressionComponent(
                category=ComponentCategory.RUN_LENGTH,
                name="Golomb-Rice RLE",
                formula_latex=r"q = \lfloor n/m \rfloor, r = n \mod m; \text{ encode } q \text{ in unary, } r \text{ in binary}",
                formula_ascii="quotient = n // m; remainder = n mod m; output unary(q) + binary(r)",
                description="Variable-length RLE using Golomb coding; optimal for geometric distribution",
                parameters={"m": "Golomb divisor (power of 2 for Rice)"},
                default_params={"m": [1, 2, 4, 8, 16, 32]},
                time_complexity="O(n)",
                space_complexity="O(1)",
                pipeline_stages=(2, 3),
            ),
        ]
    
    @staticmethod
    def _context_models() -> list[CompressionComponent]:
        """Context mixing and modeling."""
        return [
            CompressionComponent(
                category=ComponentCategory.CONTEXT_MODEL,
                name="Context Mixing (Linear)",
                formula_latex=r"P = \sum_{i} w_i \cdot P_i \text{ where } \sum w_i = 1",
                formula_ascii="P = SUM(weight_i * P_i) where weights sum to 1",
                description="Weighted combination of multiple context model predictions",
                parameters={"num_models": "number of models to mix"},
                default_params={"num_models": [2, 4, 8, 16]},
                time_complexity="O(n * num_models)",
                space_complexity="O(num_models * model_size)",
                pipeline_stages=(2,),
            ),
            CompressionComponent(
                category=ComponentCategory.CONTEXT_MODEL,
                name="Context Mixing (Logistic/PAQ)",
                formula_latex=r"P = \sigma\left(\sum_i w_i \cdot \text{stretch}(P_i)\right) \text{ where stretch}(p) = \ln\frac{p}{1-p}",
                formula_ascii="P = sigmoid(SUM(w_i * ln(P_i / (1 - P_i))))",
                description="Logistic mixing in log-odds space; more stable than linear mixing",
                parameters={"learning_rate": "weight adaptation rate"},
                default_params={"learning_rate": [0.001, 0.005, 0.01, 0.05]},
                time_complexity="O(n * num_models)",
                space_complexity="O(num_models * model_size)",
                pipeline_stages=(2,),
            ),
            CompressionComponent(
                category=ComponentCategory.CONTEXT_MODEL,
                name="Secondary Symbol Estimation (SSE)",
                formula_latex=r"P' = T[context][discretize(P)]",
                formula_ascii="P_adjusted = lookup_table[context][quantized_probability]",
                description="Table-based probability adjustment; sharpens mixer output",
                parameters={"table_bits": "bits for probability quantization"},
                default_params={"table_bits": [5, 6, 7, 8]},
                time_complexity="O(1)",
                space_complexity="O(contexts * 2^table_bits)",
                pipeline_stages=(2,),
            ),
            CompressionComponent(
                category=ComponentCategory.CONTEXT_MODEL,
                name="Indirect Context Model",
                formula_latex=r"context = hash(byte_{-1}, byte_{-2}, ..., bit\_pos)",
                formula_ascii="context = hash(previous_bytes, current_bit_position)",
                description="Uses hash of recent bytes plus bit position as context",
                parameters={"context_bits": "bits for context hash"},
                default_params={"context_bits": [16, 18, 20, 22, 24]},
                time_complexity="O(1)",
                space_complexity="O(2^context_bits)",
                pipeline_stages=(2,),
            ),
            CompressionComponent(
                category=ComponentCategory.CONTEXT_MODEL,
                name="Match Model",
                formula_latex=r"P(bit) = \begin{cases} 0.99 & \text{if match and bit matches} \\ 0.01 & \text{if match and bit differs} \\ 0.5 & \text{no match} \end{cases}",
                formula_ascii="P(bit) = 0.99 if matching_context AND bit_matches, else 0.01 if differs, else 0.5",
                description="Predicts based on longest context match in history",
                parameters={"min_match": "minimum match length"},
                default_params={"min_match": [4, 8, 16]},
                time_complexity="O(n)",
                space_complexity="O(history_size)",
                pipeline_stages=(2,),
            ),
        ]
    
    @staticmethod
    def _filters() -> list[CompressionComponent]:
        """Pre-processing and post-processing filters."""
        return [
            CompressionComponent(
                category=ComponentCategory.FILTER,
                name="E8/E9 Transform (x86 filter)",
                formula_latex=r"\text{CALL/JMP}(rel) \rightarrow \text{CALL/JMP}(abs)",
                formula_ascii="convert relative x86 CALL/JMP addresses to absolute",
                description="Converts relative x86 jump addresses to absolute for better compression",
                time_complexity="O(n)",
                space_complexity="O(1)",
                pipeline_stages=(0,),
            ),
            CompressionComponent(
                category=ComponentCategory.FILTER,
                name="ARM Filter",
                formula_latex=r"\text{BL}(rel) \rightarrow \text{BL}(abs)",
                formula_ascii="convert relative ARM branch-link addresses to absolute",
                description="Converts relative ARM BL addresses to absolute",
                time_complexity="O(n)",
                space_complexity="O(1)",
                pipeline_stages=(0,),
            ),
            CompressionComponent(
                category=ComponentCategory.FILTER,
                name="Record Reordering",
                formula_latex=r"interleave(col_1, col_2, ..., col_n) \text{ from } (rec_1, rec_2, ...)",
                formula_ascii="reorder [rec1, rec2, ...] to [col1_values, col2_values, ...]",
                description="Reorders columnar data for better locality",
                parameters={"record_size": "fixed record size in bytes"},
                default_params={"record_size": [4, 8, 16, 32, 64, 128]},
                time_complexity="O(n)",
                space_complexity="O(n)",
                pipeline_stages=(0,),
            ),
            CompressionComponent(
                category=ComponentCategory.FILTER,
                name="RGB → YCbCr (Lossless)",
                formula_latex=r"Y = R + G + B; Cb = B - G; Cr = R - G",
                formula_ascii="Y = R + G + B; Cb = B - G; Cr = R - G (reversible integer version)",
                description="Reversible color space transform; decorrelates image data",
                time_complexity="O(n)",
                space_complexity="O(1)",
                pipeline_stages=(0,),
            ),
            CompressionComponent(
                category=ComponentCategory.FILTER,
                name="Bit Plane Separation",
                formula_latex=r"planes[i] = (bytes >> i) \& 1 \text{ for } i \in [0, 7]",
                formula_ascii="split bytes into 8 bit planes: plane[i] = all i-th bits",
                description="Separates data into bit planes for better entropy coding",
                time_complexity="O(n)",
                space_complexity="O(n)",
                pipeline_stages=(0,),
            ),
        ]
    
    @staticmethod
    def _integer_coders() -> list[CompressionComponent]:
        """Universal codes for integers."""
        return [
            CompressionComponent(
                category=ComponentCategory.INTEGER_CODER,
                name="Unary Code",
                formula_latex=r"U(n) = 1^n 0 \text{ (n ones followed by zero)}",
                formula_ascii="U(n) = n ones followed by a zero",
                description="Simplest universal code; optimal for geometric(0.5) distribution",
                time_complexity="O(n) per integer",
                space_complexity="O(1)",
                pipeline_stages=(3,),
            ),
            CompressionComponent(
                category=ComponentCategory.INTEGER_CODER,
                name="Elias Gamma Code",
                formula_latex=r"\gamma(n) = U(\lfloor\log_2 n\rfloor) \cdot bin(n)",
                formula_ascii="gamma(n) = unary(floor(log2(n))) + binary(n)",
                description="Universal code: unary length prefix + binary value",
                time_complexity="O(log n) per integer",
                space_complexity="O(1)",
                pipeline_stages=(3,),
            ),
            CompressionComponent(
                category=ComponentCategory.INTEGER_CODER,
                name="Elias Delta Code",
                formula_latex=r"\delta(n) = \gamma(\lfloor\log_2 n\rfloor + 1) \cdot bin(n \mod 2^{\lfloor\log_2 n\rfloor})",
                formula_ascii="delta(n) = gamma(floor(log2(n)) + 1) + binary(n mod 2^floor(log2(n)))",
                description="More efficient than gamma for larger integers",
                time_complexity="O(log log n) per integer",
                space_complexity="O(1)",
                pipeline_stages=(3,),
            ),
            CompressionComponent(
                category=ComponentCategory.INTEGER_CODER,
                name="Golomb Code",
                formula_latex=r"G_m(n) = U(\lfloor n/m \rfloor) \cdot bin_m(n \mod m)",
                formula_ascii="G_m(n) = unary(n // m) + binary(n mod m, ceil(log2(m)) bits)",
                description="Optimal for geometric distribution with parameter p; m ≈ -1/log2(1-p)",
                parameters={"m": "Golomb parameter"},
                default_params={"m": [1, 2, 3, 4, 5, 6, 7, 8, 10, 16, 32]},
                time_complexity="O(n/m + log m) per integer",
                space_complexity="O(1)",
                pipeline_stages=(3,),
            ),
            CompressionComponent(
                category=ComponentCategory.INTEGER_CODER,
                name="Rice Code",
                formula_latex=r"R_k(n) = U(n >> k) \cdot bin(n \& (2^k - 1), k)",
                formula_ascii="R_k(n) = unary(n >> k) + k lowest bits of n",
                description="Golomb code with m = 2^k; simpler and faster",
                parameters={"k": "Rice parameter (log2 of divisor)"},
                default_params={"k": [0, 1, 2, 3, 4, 5, 6]},
                time_complexity="O(n >> k + k) per integer",
                space_complexity="O(1)",
                pipeline_stages=(3,),
            ),
            CompressionComponent(
                category=ComponentCategory.INTEGER_CODER,
                name="Exponential Golomb",
                formula_latex=r"Exp(n, k) = \gamma(1 + (n >> k)) \cdot bin(n \& (2^k-1), k)",
                formula_ascii="ExpGolomb(n, k) = gamma(1 + (n >> k)) + k lowest bits",
                description="Used in H.264/AVC video coding",
                parameters={"k": "order parameter"},
                default_params={"k": [0, 1, 2, 3]},
                time_complexity="O(log(n >> k) + k) per integer",
                space_complexity="O(1)",
                pipeline_stages=(3,),
            ),
            CompressionComponent(
                category=ComponentCategory.INTEGER_CODER,
                name="VByte / Varint",
                formula_latex=r"\text{VByte}(n) = \text{7 bits data + 1 continuation bit per byte}",
                formula_ascii="VByte(n) = sequence of 7-bit chunks with high-bit continuation flag",
                description="Simple variable-byte integer encoding; used in Protocol Buffers",
                time_complexity="O(log n / 7) per integer",
                space_complexity="O(1)",
                pipeline_stages=(3,),
            ),
        ]


class PipelineGenerator:
    """
    Generates valid compression algorithm pipelines.
    
    This is the "grammar" of our generative system - the rules for
    combining components into valid compression algorithms.
    """
    
    # Valid pipeline structure: stages that can follow each other
    VALID_TRANSITIONS: dict[int, tuple[int, ...]] = {
        0: (1, 2, 3),  # Filter/preprocessing → any stage
        1: (2, 3),     # Transform → modeling or entropy coding
        2: (2, 3),     # Modeling → more modeling or entropy coding
        3: (),         # Entropy coding → terminal
    }
    
    # Maximum pipeline depth to prevent combinatorial explosion
    MAX_PIPELINE_DEPTH = 6
    
    def __init__(self, components: list[CompressionComponent]):
        """Initialize with available components."""
        self.components = components
        self._by_stage: dict[int, list[CompressionComponent]] = {}
        for comp in components:
            for stage in comp.pipeline_stages:
                if stage not in self._by_stage:
                    self._by_stage[stage] = []
                self._by_stage[stage].append(comp)
    
    def generate_pipelines(
        self, 
        min_depth: int = 2,
        max_depth: int | None = None,
        require_entropy_coder: bool = True
    ) -> Generator[list[CompressionComponent], None, None]:
        """
        Generate all valid compression pipelines.
        
        Args:
            min_depth: Minimum number of components in pipeline
            max_depth: Maximum pipeline depth (default: MAX_PIPELINE_DEPTH)
            require_entropy_coder: If True, only yield pipelines ending with entropy coder
        
        Yields:
            Lists of CompressionComponents representing valid pipelines
        """
        max_depth = max_depth or self.MAX_PIPELINE_DEPTH
        
        def extend_pipeline(
            pipeline: list[CompressionComponent],
            current_stage: int
        ) -> Generator[list[CompressionComponent], None, None]:
            """Recursively extend pipeline following grammar rules."""
            
            # Check if pipeline is complete
            if len(pipeline) >= min_depth:
                if not require_entropy_coder:
                    yield list(pipeline)
                elif pipeline and pipeline[-1].category == ComponentCategory.ENTROPY_CODER:
                    yield list(pipeline)
            
            # Stop if at max depth
            if len(pipeline) >= max_depth:
                return
            
            # Get valid next stages
            next_stages = self.VALID_TRANSITIONS.get(current_stage, ())
            
            for next_stage in next_stages:
                for component in self._by_stage.get(next_stage, []):
                    # Check prerequisites
                    if component.prerequisites:
                        pipeline_names = {c.name for c in pipeline}
                        if not all(p in pipeline_names for p in component.prerequisites):
                            continue
                    
                    # Check incompatibilities
                    if component.incompatible_with:
                        pipeline_names = {c.name for c in pipeline}
                        if any(i in pipeline_names for i in component.incompatible_with):
                            continue
                    
                    # Extend pipeline
                    pipeline.append(component)
                    yield from extend_pipeline(pipeline, next_stage)
                    pipeline.pop()
        
        # Start from each possible starting stage
        for start_stage in [0, 1, 2]:
            for component in self._by_stage.get(start_stage, []):
                yield from extend_pipeline([component], start_stage)
    
    def get_classic_pipelines(self) -> list[tuple[str, list[str]]]:
        """Return well-known compression algorithm pipelines."""
        return [
            ("DEFLATE", ["LZ77 (Sliding Window)", "Canonical Huffman"]),
            ("bzip2", ["Burrows-Wheeler Transform", "Move-to-Front Transform", "Zero RLE", "Huffman Coding"]),
            ("LZMA/7z", ["Delta Encoding", "LZMA (Lempel-Ziv-Markov chain)"]),
            ("Zstandard", ["Zstandard (ZSTD)"]),
            ("PPMd", ["Prediction by Partial Matching (PPM)", "Range Coding"]),
            ("PAQ", ["Context Mixing (Logistic/PAQ)", "Arithmetic Coding"]),
            ("LZ4", ["LZ4 (Fast LZ)"]),
            ("FLAC", ["Linear Predictor", "Rice Code"]),
            ("PNG", ["PNG Predictors (Paeth)", "Delta Encoding", "LZ77 (Sliding Window)", "Canonical Huffman"]),
            ("CTW", ["Context Tree Weighting (CTW)", "Arithmetic Coding"]),
        ]


class CompressionFormulaGenerator:
    """
    Main engine for generating compression algorithm formulas and pipelines.
    
    This brings together the alphabet (components), grammar (pipeline rules),
    and dialects (parameter variations) to systematically explore the
    compression algorithm design space.
    """
    
    def __init__(self):
        """Initialize the generator with all components and pipeline rules."""
        self.components = ComponentRegistry.get_all_components()
        self.pipeline_generator = PipelineGenerator(self.components)
        self._generation_stats: dict[str, int] = {}
    
    def generate_component_formulas(self) -> Generator[dict[str, Any], None, None]:
        """
        Generate all component formulas with their parametric variations.
        
        Yields dictionaries containing:
            - category: Component category name
            - name: Component name  
            - formula_latex: LaTeX formula
            - formula_ascii: ASCII formula
            - description: Component description
            - parameters: Parameter descriptions as JSON
            - parameter_values: Current parameter values as JSON
            - complexity_time: Time complexity
            - complexity_space: Space complexity
            - pipeline_stage: Valid pipeline stages
            - is_lossless: Whether lossless
        """
        for component in self.components:
            for variation in component.generate_variations():
                yield {
                    "category": component.category.name,
                    "name": component.name,
                    "formula_latex": component.formula_latex,
                    "formula_ascii": component.formula_ascii,
                    "description": component.description,
                    "parameters": json.dumps(component.parameters),
                    "parameter_values": json.dumps(variation["params"]),
                    "complexity_time": component.time_complexity,
                    "complexity_space": component.space_complexity,
                    "pipeline_stages": json.dumps(component.pipeline_stages),
                    "is_lossless": component.is_lossless,
                    "prerequisites": json.dumps(component.prerequisites),
                }
    
    def generate_pipelines(
        self,
        max_depth: int = 4,
        include_parameters: bool = False
    ) -> Generator[dict[str, Any], None, None]:
        """
        Generate all valid compression pipelines.
        
        Args:
            max_depth: Maximum number of components in pipeline
            include_parameters: If True, generate all parameter variations
        
        Yields dictionaries containing:
            - pipeline_id: Unique pipeline identifier
            - pipeline_name: Human-readable pipeline description
            - pipeline_components: JSON list of component names
            - pipeline_formula: Combined formula representation
            - total_time_complexity: Estimated combined time complexity
            - total_space_complexity: Estimated combined space complexity
            - num_stages: Number of components
        """
        pipeline_id = 0
        
        for pipeline in self.pipeline_generator.generate_pipelines(
            min_depth=2, 
            max_depth=max_depth
        ):
            pipeline_id += 1
            
            component_names = [c.name for c in pipeline]
            pipeline_formula = " → ".join([c.formula_ascii for c in pipeline])
            
            yield {
                "pipeline_id": pipeline_id,
                "pipeline_name": " → ".join(component_names),
                "pipeline_components": json.dumps(component_names),
                "pipeline_formula": pipeline_formula,
                "total_time_complexity": self._combine_complexity([c.time_complexity for c in pipeline]),
                "total_space_complexity": self._combine_complexity([c.space_complexity for c in pipeline]),
                "num_stages": len(pipeline),
                "all_lossless": all(c.is_lossless for c in pipeline),
            }
    
    def generate_classic_pipelines(self) -> Generator[dict[str, Any], None, None]:
        """Generate entries for well-known compression algorithms."""
        component_lookup = {c.name: c for c in self.components}
        
        for algo_name, component_names in self.pipeline_generator.get_classic_pipelines():
            components = []
            for name in component_names:
                if name in component_lookup:
                    components.append(component_lookup[name])
            
            if not components:
                continue
            
            yield {
                "algorithm_name": algo_name,
                "pipeline_components": json.dumps(component_names),
                "pipeline_formula": " → ".join([c.formula_ascii for c in components]),
                "combined_description": "; ".join([c.description for c in components]),
                "total_time_complexity": self._combine_complexity([c.time_complexity for c in components]),
                "total_space_complexity": self._combine_complexity([c.space_complexity for c in components]),
                "num_stages": len(components),
            }
    
    @staticmethod
    def _combine_complexity(complexities: list[str]) -> str:
        """Combine multiple complexity expressions (simplified heuristic)."""
        # Simple heuristic: return the "worst" complexity
        complexity_order = [
            "O(1)", "O(log n)", "O(n)", "O(n log n)", 
            "O(n * max_order)", "O(n * window)", "O(n * depth)",
            "O(n^2)", "O(|Σ|^order)", "Incomputable"
        ]
        worst_idx = -1
        worst = complexities[0] if complexities else "O(n)"
        for c in complexities:
            for idx, pattern in enumerate(complexity_order):
                if pattern in c and idx > worst_idx:
                    worst_idx = idx
                    worst = c
        return worst
    
    def export_to_csv(
        self,
        output_dir: Path,
        include_pipelines: bool = True,
        pipeline_max_depth: int = 4
    ) -> dict[str, Path]:
        """
        Export all generated data to CSV files.
        
        Args:
            output_dir: Directory to write CSV files
            include_pipelines: Whether to generate pipeline combinations
            pipeline_max_depth: Maximum pipeline depth for combinations
        
        Returns:
            Dictionary mapping output type to file path
        """
        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        
        outputs: dict[str, Path] = {}
        
        # 1. Component formulas with variations
        components_file = output_dir / "compression_components.csv"
        component_count = self._write_csv(
            components_file,
            self.generate_component_formulas(),
            fieldnames=[
                "category", "name", "formula_latex", "formula_ascii",
                "description", "parameters", "parameter_values",
                "complexity_time", "complexity_space", "pipeline_stages",
                "is_lossless", "prerequisites"
            ]
        )
        outputs["components"] = components_file
        self._generation_stats["components"] = component_count
        
        # 2. Classic/known algorithms
        classics_file = output_dir / "classic_algorithms.csv"
        classic_count = self._write_csv(
            classics_file,
            self.generate_classic_pipelines(),
            fieldnames=[
                "algorithm_name", "pipeline_components", "pipeline_formula",
                "combined_description", "total_time_complexity", 
                "total_space_complexity", "num_stages"
            ]
        )
        outputs["classics"] = classics_file
        self._generation_stats["classics"] = classic_count
        
        # 3. Generated pipeline combinations
        if include_pipelines:
            pipelines_file = output_dir / "pipeline_combinations.csv"
            pipeline_count = self._write_csv(
                pipelines_file,
                self.generate_pipelines(max_depth=pipeline_max_depth),
                fieldnames=[
                    "pipeline_id", "pipeline_name", "pipeline_components",
                    "pipeline_formula", "total_time_complexity",
                    "total_space_complexity", "num_stages", "all_lossless"
                ]
            )
            outputs["pipelines"] = pipelines_file
            self._generation_stats["pipelines"] = pipeline_count
        
        # 4. Summary/metadata file
        summary_file = output_dir / "generation_summary.csv"
        summary_data = [
            {
                "metric": "total_components",
                "value": str(len(self.components)),
                "description": "Number of unique compression components"
            },
            {
                "metric": "total_component_variations", 
                "value": str(self._generation_stats.get("components", 0)),
                "description": "Components × parameter variations"
            },
            {
                "metric": "classic_algorithms",
                "value": str(self._generation_stats.get("classics", 0)),
                "description": "Well-known algorithm pipelines"
            },
            {
                "metric": "generated_pipelines",
                "value": str(self._generation_stats.get("pipelines", 0)),
                "description": f"Valid pipeline combinations (depth ≤ {pipeline_max_depth})"
            },
            {
                "metric": "generation_timestamp",
                "value": datetime.utcnow().isoformat(),
                "description": "UTC timestamp of generation"
            },
            {
                "metric": "categories",
                "value": ", ".join(c.name for c in ComponentCategory),
                "description": "Component categories in taxonomy"
            },
        ]
        self._write_csv(
            summary_file,
            iter(summary_data),
            fieldnames=["metric", "value", "description"]
        )
        outputs["summary"] = summary_file
        
        return outputs
    
    @staticmethod
    def _write_csv(
        path: Path,
        data: Iterable[dict[str, Any]],
        fieldnames: list[str]
    ) -> int:
        """Write data to CSV and return row count."""
        count = 0
        with open(path, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
            writer.writeheader()
            for row in data:
                writer.writerow(row)
                count += 1
        return count
    
    def get_stats(self) -> dict[str, Any]:
        """Return generation statistics."""
        return {
            "unique_components": len(self.components),
            "categories": len(ComponentCategory),
            "by_category": {
                cat.name: sum(1 for c in self.components if c.category == cat)
                for cat in ComponentCategory
            },
            **self._generation_stats
        }


def main():
    """Main entry point for CLI usage."""
    import argparse
    
    parser = argparse.ArgumentParser(
        description="Generate compression algorithm formulas and pipelines"
    )
    parser.add_argument(
        "-o", "--output",
        type=Path,
        default=Path("/mnt/user-data/outputs"),
        help="Output directory for CSV files"
    )
    parser.add_argument(
        "--max-depth",
        type=int,
        default=4,
        help="Maximum pipeline depth for combinations"
    )
    parser.add_argument(
        "--no-pipelines",
        action="store_true",
        help="Skip generating pipeline combinations"
    )
    parser.add_argument(
        "--stats",
        action="store_true",
        help="Print generation statistics"
    )
    
    args = parser.parse_args()
    
    print("Initializing Compression Formula Generator...")
    generator = CompressionFormulaGenerator()
    
    print(f"Exporting to {args.output}...")
    outputs = generator.export_to_csv(
        output_dir=args.output,
        include_pipelines=not args.no_pipelines,
        pipeline_max_depth=args.max_depth
    )
    
    print("\nGenerated files:")
    for name, path in outputs.items():
        print(f"  {name}: {path}")
    
    if args.stats:
        print("\nStatistics:")
        stats = generator.get_stats()
        for key, value in stats.items():
            if isinstance(value, dict):
                print(f"  {key}:")
                for k, v in value.items():
                    print(f"    {k}: {v}")
            else:
                print(f"  {key}: {value}")
    
    print("\nDone!")
    return 0


if __name__ == "__main__":
    exit(main())
