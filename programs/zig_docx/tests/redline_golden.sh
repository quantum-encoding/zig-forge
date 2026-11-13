#!/usr/bin/env bash
# Golden check of the redline sheet, outside Zig: build the CLI, make the
# reference sheet (and its tracked-changes twin) from the JSON fixture, then
# prove the files open — the ZIP tests clean, every XML part is well formed
# (xmllint), and macOS's own .docx reader (textutil) reads the expected text.
#
#   tests/redline_golden.sh            (from programs/zig_docx; ZIG=… to pick the Zig)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
zig="${ZIG:-zig}"
out="$(mktemp -d "${TMPDIR:-/tmp}/zig-docx-redline.XXXXXX")"
fixture="$here/src/testdata/redline_sheet.json"
fail=0

(cd "$here" && "$zig" build)
cli="$here/zig-out/bin/zig-docx"

"$cli" "$fixture" --redline -o "$out/sheet.docx"
"$cli" "$fixture" --redline --tracked --author "Proofreader" --date 2026-01-02 -o "$out/tracked.docx"

check() { # description, command…
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok    $what"; else echo "FAIL  $what"; fail=1; fi
}

for doc in sheet tracked; do
  f="$out/$doc.docx"
  check "$doc: zip entries test clean" unzip -tq "$f"
  mkdir -p "$out/$doc"
  unzip -oq "$f" -d "$out/$doc"
  while IFS= read -r part; do
    check "$doc: ${part#"$out/$doc/"} is well-formed XML" xmllint --noout "$part"
  done < <(find "$out/$doc" -type f \( -name '*.xml' -o -name '*.rels' \) | sort)
done

doc="$out/sheet/word/document.xml"
check "landscape A4"                 grep -q 'w:w="16838" w:h="11906" w:orient="landscape"' "$doc"
check "header row repeats"           grep -q '<w:tblHeader/>' "$doc"
check "four group rows over 3 cols"  test "$(grep -o '<w:gridSpan w:val="3"/>' "$doc" | wc -l | tr -d ' ')" = 4
check "rows do not split"            test "$(grep -o '<w:cantSplit/>' "$doc" | wc -l | tr -d ' ')" = 14
check "removed words: red, struck"   grep -q '<w:strike/><w:color w:val="A00000"/><w:shd w:val="clear" w:color="auto" w:fill="FDDADA"/>' "$doc"
check "added words: green, bold"     grep -q '<w:b/><w:color w:val="006400"/><w:shd w:val="clear" w:color="auto" w:fill="D7F5D7"/>' "$doc"
check "note: grey italic"            grep -q '<w:i/><w:color w:val="555555"/><w:sz w:val="17"/>' "$doc"
tdoc="$out/tracked/word/document.xml"
check "tracked: deletions"           grep -q '<w:del w:id="1" w:author="Proofreader" w:date="2026-01-02T00:00:00Z"><w:r><w:rPr></w:rPr><w:delText' "$tdoc"
check "tracked: insertions"          grep -q '<w:ins w:id="2" w:author="Proofreader" w:date="2026-01-02T00:00:00Z">' "$tdoc"

if command -v textutil >/dev/null 2>&1; then
  textutil -convert txt -output "$out/sheet.txt" "$out/sheet.docx"
  textutil -convert txt -output "$out/tracked.txt" "$out/tracked.docx"
  for line in "Proofread: 12 Example Road" "Should be" "Flat 3" "Tel.0100 0000001" "Tel. 0100 000 0002" \
              "kept free free from storage" "The fire door action is number 7 in this report."; do
    check "textutil reads: $line" grep -qF "$line" "$out/sheet.txt"
  done
  # Tracked: the reader shows the text with every change accepted.
  check "textutil reads the accepted text" grep -qF "Electrical switchgear cupboard to be kept free from storage" "$out/tracked.txt"
else
  echo "skip  textutil (not macOS)"
fi

# LibreOffice, when installed, is a second reader: it must see every w:del and
# w:ins as a tracked change by the named author.
if command -v soffice >/dev/null 2>&1; then
  soffice -env:UserInstallation="file://$out/lo-profile" --headless --convert-to odt --outdir "$out" "$out/tracked.docx" >/dev/null 2>&1 || true
  if [ -f "$out/tracked.odt" ]; then
    unzip -oq "$out/tracked.odt" content.xml -d "$out/odt"
    want=$(( $(grep -o '<w:del ' "$tdoc" | wc -l) + $(grep -o '<w:ins ' "$tdoc" | wc -l) ))
    got=$(grep -o '<text:changed-region' "$out/odt/content.xml" | wc -l | tr -d ' ')
    check "LibreOffice reads $want tracked changes (got $got)" test "$got" = "$want"
    check "LibreOffice names the author" grep -q 'dc:creator>Proofreader<' "$out/odt/content.xml"
  else
    echo "FAIL  LibreOffice could not convert tracked.docx"; fail=1
  fi
else
  echo "skip  LibreOffice (soffice not installed)"
fi

echo "output: $out"
exit "$fail"
