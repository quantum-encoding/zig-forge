#!/bin/bash
# Update all Zig and C files to use dual-license model (MIT Non-Commercial / Commercial)

ZIG_LICENSE_HEADER='//! Guardian Shield - eBPF-based System Security Framework
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! Author: Richard Tune
//! Contact: info@quantumencoding.io
//! Website: https://quantumencoding.io
//!
//! License: Dual License - MIT (Non-Commercial) / Commercial License
//!
//! NON-COMMERCIAL USE (MIT License):
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction for NON-COMMERCIAL purposes, including
//! without limitation the rights to use, copy, modify, merge, publish, distribute,
//! sublicense, and/or sell copies of the Software for non-commercial purposes,
//! and to permit persons to whom the Software is furnished to do so, subject to
//! the following conditions:
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
//!
//! COMMERCIAL USE:
//! Commercial use of this software requires a separate commercial license.
//! Contact info@quantumencoding.io for commercial licensing terms.

'

echo "Updating Zig files to dual-license model..."

# Find all .zig files that have the old MIT license
find src/ -name "*.zig" -type f | while read -r file; do
    if grep -q "License: Source Available - MIT License" "$file"; then
        echo "Updating: $file"

        # Use sed to replace the old license section with new dual-license
        # This is complex, so we'll use a temporary file
        awk '
        BEGIN { in_license=0; skip_until_end=0; printed_new_license=0 }

        # Detect start of old license
        /License: Source Available - MIT License/ {
            if (!printed_new_license) {
                # Print new license header
                print "//! License: Dual License - MIT (Non-Commercial) / Commercial License"
                print "//!"
                print "//! NON-COMMERCIAL USE (MIT License):"
                print "//! Permission is hereby granted, free of charge, to any person obtaining a copy"
                print "//! of this software and associated documentation files (the \"Software\"), to deal"
                print "//! in the Software without restriction for NON-COMMERCIAL purposes, including"
                print "//! without limitation the rights to use, copy, modify, merge, publish, distribute,"
                print "//! sublicense, and/or sell copies of the Software for non-commercial purposes,"
                print "//! and to permit persons to whom the Software is furnished to do so, subject to"
                print "//! the following conditions:"
                print "//!"
                print "//! The above copyright notice and this permission notice shall be included in all"
                print "//! copies or substantial portions of the Software."
                print "//!"
                print "//! THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR"
                print "//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,"
                print "//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE"
                print "//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER"
                print "//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,"
                print "//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE"
                print "//! SOFTWARE."
                print "//!"
                print "//! COMMERCIAL USE:"
                print "//! Commercial use of this software requires a separate commercial license."
                print "//! Contact info@quantumencoding.io for commercial licensing terms."
                printed_new_license=1
            }
            skip_until_end=1
            next
        }

        # Skip old license content
        skip_until_end && /^\/\/! SOFTWARE\.$/ {
            skip_until_end=0
            next
        }

        # Skip lines while in old license
        skip_until_end { next }

        # Print all other lines
        { print }
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
done

echo "✓ Dual-license update complete for Zig files!"
echo ""
echo "Updated licensing model:"
echo "  • Non-commercial use: MIT License (free)"
echo "  • Commercial use: Separate commercial license required"
echo "  • Contact: info@quantumencoding.io"
