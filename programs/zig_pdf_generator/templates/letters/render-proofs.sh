#!/usr/bin/env bash
# Render every letter in the pack for every scenario to PDF and PNG.
#
#   templates/letters/render-proofs.sh [out_dir]    (default: output/legend-letters)
#
# Needs: zig, jq, and a rasteriser. Builds pdf-gen, writes one CLI input per
# letter/scenario to <out_dir>/inputs/, renders <name>.pdf, then rasterises
# each page to render-<name>-<page>.png at 120 dpi: with PDFKit on macOS
# (pdf2png.swift), else with poppler's pdftoppm.
set -euo pipefail

pack="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$pack/../.." && pwd)"
out="${1:-$root/output/legend-letters}"
mkdir -p "$out/inputs"
out="$(cd "$out" && pwd)"

(cd "$root" && zig build -Doptimize=ReleaseSafe)
gen="$root/zig-out/bin/pdf-gen"

# Paths inside an input are relative to the input file.
rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$pack" "$out/inputs")"

render() { # legend letter scenario stage
  local legend="$1" letter="$2" scenario="$3" stage="$4"
  local name="$letter--$scenario"
  local input="$out/inputs/$name.json"
  jq -n \
    --arg legend "$rel/$legend" --arg tpl "$rel/$letter.tpl.md" --arg frame "$rel/$letter.letter.json" \
    --arg scenario "$scenario" --arg stage "$stage" \
    --slurpfile stages "$pack/stages.json" \
    '{legend_file: $legend, template_file: $tpl, letter_file: $frame, scenario: $scenario,
      bindings: ($stages[0].creditor + (if $stage == "" then {} else $stages[0].stages[$stage] end))}' \
    > "$input"
  "$gen" --legend-letter "$input" "$out/$name.pdf"
  if [[ "$(uname)" == Darwin ]] && command -v swift >/dev/null; then
    swift "$pack/pdf2png.swift" "$out/$name.pdf" "$out/render-$name" 120
  else
    pdftoppm -r 120 -png "$out/$name.pdf" "$out/render-$name"
  fi
}

for letter in reminder second-reminder final-demand; do
  for scenario in company-unpaid company-partial sole-trader-plan individual-unpaid individual-instalments; do
    render debt-recovery.toml "$letter" "$scenario" "$letter"
  done
done
for scenario in company-unpaid company-paid-late sole-trader-unpaid; do
  render statutory-interest.toml statutory-interest "$scenario" ""
done
echo "proofs in $out"
