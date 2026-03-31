#!/bin/bash
# Add dual-license headers to C files

C_LICENSE_HEADER='// SPDX-License-Identifier: GPL-2.0
/*
 * Guardian Shield - eBPF-based System Security Framework
 *
 * Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
 * Author: Richard Tune
 * Contact: info@quantumencoding.io
 * Website: https://quantumencoding.io
 *
 * License: Dual License - MIT (Non-Commercial) / Commercial License
 *
 * NON-COMMERCIAL USE (MIT License):
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction for NON-COMMERCIAL purposes, including
 * without limitation the rights to use, copy, modify, merge, publish, distribute,
 * sublicense, and/or sell copies of the Software for non-commercial purposes,
 * and to permit persons to whom the Software is furnished to do so, subject to
 * the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 * COMMERCIAL USE:
 * Commercial use of this software requires a separate commercial license.
 * Contact info@quantumencoding.io for commercial licensing terms.
 */

'

echo "Adding dual-license to C files..."

# List of C files to update (excluding already updated ones)
FILES=(
    "oracle-probe-template.bpf.c"
    "oracle-probe.c"
    "test_simple.c"
    "test-target.c"
    "test-lsm-attach.c"
    "test-file-open-loader.c"
)

for file in "${FILES[@]}"; do
    if [ -f "$file" ] && ! grep -q "Copyright (c) 2025 Richard Tune" "$file"; then
        echo "Adding license to: $file"
        
        # Get first line (should be comment)
        FIRST_LINE=$(head -1 "$file")
        
        # Create temp file
        {
            echo "$C_LICENSE_HEADER"
            # Keep original header comment if it's meaningful
            if [[ "$FIRST_LINE" != "//"* ]] && [[ "$FIRST_LINE" != "/*"* ]]; then
                cat "$file"
            else
                # Keep the original description
                head -3 "$file" | tail -1
                echo ""
                tail -n +4 "$file"
            fi
        } > "${file}.tmp"
        
        mv "${file}.tmp" "$file"
    fi
done

echo "✓ C file licensing complete!"
