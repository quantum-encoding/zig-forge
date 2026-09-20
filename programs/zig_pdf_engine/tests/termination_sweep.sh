#!/bin/zsh
# Run pdf-text over every PDF under a directory and report what came back.
#
#   tests/termination_sweep.sh <dir> [seconds-per-file] [path-to-pdf-text]
#
# One line per file on stdout (status, bytes of text, path), a summary on
# stderr. Statuses:
#   text    exit 0 with text on stdout
#   empty   exit 0 with nothing on stdout: no text layer, i.e. a scan
#   error   non-zero exit: extraction failed and the empty stdout means nothing
#   HANG    still running at the limit and killed. This must be zero. The limit
#           only separates "returns" from "never returns"; a healthy run takes
#           milliseconds per file.
# Exits non-zero if anything hung.
set -u
dir=${1:?usage: termination_sweep.sh <dir> [seconds] [pdf-text]}
secs=${2:-10}
bin=${3:-${0:A:h}/../zig-out/bin/pdf-text}
[[ -x $bin ]] || { print -u2 "no pdf-text at $bin (zig build first)"; exit 2 }

typeset -A count
count=(text 0 empty 0 error 0 HANG 0)
while IFS= read -r -d '' f; do
  bytes=$(perl -e 'alarm shift; exec @ARGV' $secs $bin $f 2>/dev/null | wc -c; exit $pipestatus[1])
  rc=$?
  bytes=${bytes// /}
  if (( rc == 142 )); then st=HANG
  elif (( rc != 0 )); then st=error
  elif (( bytes <= 1 )); then st=empty
  else st=text
  fi
  (( count[$st]++ ))
  print -r -- "$st	$bytes	$f"
done < <(find $dir -type f -iname '*.pdf' -print0)

print -u2 "text ${count[text]}  empty ${count[empty]}  error ${count[error]}  HANG ${count[HANG]}"
(( count[HANG] == 0 ))
