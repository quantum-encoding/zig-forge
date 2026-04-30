#!/bin/bash
# Add MIT licensing header to all Zig files in Guardian Shield

LICENSE_HEADER='//! Guardian Shield - eBPF-based System Security Framework
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! Author: Richard Tune
//! Contact: info@quantumencoding.io
//! Website: https://quantumencoding.io
//!
//! License: Source Available - MIT License
//!
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction, including without limitation the rights
//! to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//! copies of the Software, and to permit persons to whom the Software is
//! furnished to do so, subject to the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.

'

# Find all .zig files that don't have the copyright notice yet
find src/ -name "*.zig" -type f | while read -r file; do
    if ! grep -q "Copyright (c) 2025 Richard Tune" "$file"; then
        echo "Adding license to: $file"
        # Create temp file with license header
        echo "$LICENSE_HEADER" > "${file}.tmp"
        # Append original content
        cat "$file" >> "${file}.tmp"
        # Replace original
        mv "${file}.tmp" "$file"
    else
        echo "Skipping (already licensed): $file"
    fi
done

echo "✓ Licensing complete!"
