#!/usr/bin/env bash
# Build every library other repos link from this checkout (libs.toml), the way they
# must link it, and prove each one.
#
#   scripts/build-consumed-libs.sh                       # every row of libs.toml
#   scripts/build-consumed-libs.sh terminal_mux zsss     # the named rows
#   scripts/build-consumed-libs.sh --no-release-stamp    # build and check only
#
# For each row it runs the row's `build` from the repo root, then checks that
#   - every artifact exists;
#   - no artifact carries Zig's safety-check panic strings ("index out of bounds"), so
#     none is a Debug or ReleaseSafe build;
#   - the `-source-id.txt` beside each artifact equals scripts/zig-source-id.sh <dir>;
#   - the row's `sources` cover every directory the build reads
#     (scripts/zig-source-id.sh --deps <dir>), so a consumer declaring them sees every
#     change that alters the bytes.
#
# Then it writes the stamp `baton release plan` reads (<artifact>.release-stamp.json)
# for each product in the row's `consumers`, through `baton release stamp`, after
# checking that the product's release.toml declares the input with the row's exact
# build, first artifact and sources. A product whose release.toml points at another
# checkout of zig-forge is skipped, so a scratch copy never stamps the real one.
# Release identities are git trees, so without a git checkout (or without baton) this
# step is skipped and says so; building never needs .git.
#
# Exit status: 0 only when every selected row built and passed every check, and every
# release stamp attempted was written.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LIBS="$ROOT/libs.toml"
SEP=$'\037'

release_stamp=1
want=""
for arg in "$@"; do
  case "$arg" in
    --no-release-stamp) release_stamp=0 ;;
    -h | --help) sed -n '2,28p' "$0"; exit 0 ;;
    -*) echo "error: unknown option $arg" >&2; exit 2 ;;
    *) want="$want $arg" ;;
  esac
done

# libs.toml rows as name SEP dir SEP build SEP artifacts SEP sources SEP consumers, list
# values joined with "|". Only the subset of TOML the file documents is accepted.
parse_libs() {
  awk -v SEP="$SEP" '
    function fail(msg) { printf "libs.toml:%d: %s\n", NR, msg > "/dev/stderr"; bad = 1; exit 1 }
    function emit(   k) {
      if (!open) return
      for (k in required) if (!(k in rec)) fail("[[lib]] " rec["name"] " has no " k)
      if (rec["name"] in seen) fail("duplicate lib name " rec["name"])
      seen[rec["name"]] = 1
      print rec["name"] SEP rec["dir"] SEP rec["build"] SEP rec["artifacts"] SEP rec["sources"] SEP rec["consumers"]
      split("", rec)
    }
    BEGIN {
      split("name dir build artifacts sources", r, " "); for (i in r) required[r[i]] = 1
      split("name dir build artifacts sources consumers notes", a, " "); for (i in a) allowed[a[i]] = 1
      split("artifacts sources consumers", l, " "); for (i in l) lists[l[i]] = 1
    }
    /^[ \t]*(#.*)?$/ { next }
    /^\[\[lib\]\][ \t]*(#.*)?$/ { emit(); open = 1; next }
    {
      if (!open) fail("key outside a [[lib]] table")
      if (!match($0, /^[a-z_]+[ \t]*=[ \t]*/)) fail("expected key = value")
      key = substr($0, 1, RLENGTH); sub(/[ \t]*=.*$/, "", key)
      rest = substr($0, RLENGTH + 1)
      if (!(key in allowed)) fail("unknown key " key)
      if (key in rec) fail("duplicate key " key)
      if (substr(rest, 1, 1) == "\"") {
        if (key in lists) fail(key " must be an array of strings")
        if (!match(rest, /^"[^"]*"/)) fail("unterminated string")
        val = substr(rest, 2, RLENGTH - 2)
      } else if (substr(rest, 1, 1) == "[") {
        if (!(key in lists)) fail(key " must be a string")
        if (!match(rest, /^\[[^]]*\]/)) fail("arrays must open and close on one line")
        inner = substr(rest, 2, RLENGTH - 2); val = ""
        n = split(inner, items, ",")
        for (i = 1; i <= n; i++) {
          it = items[i]; gsub(/^[ \t]+|[ \t]+$/, "", it)
          if (it == "" && (n == 1 || i == n)) continue
          if (it !~ /^"[^"]*"$/) fail("array items must be strings")
          it = substr(it, 2, length(it) - 2)
          val = (val == "") ? it : val "|" it
        }
      } else {
        fail("value must be a string or an array of strings")
      }
      if (substr(rest, RLENGTH + 1) !~ /^[ \t]*(#.*)?$/) fail("unexpected text after the value")
      if (key != "notes" && (val ~ /\|/ && !(key in lists) || index(val, SEP))) fail("value of " key " contains a reserved character")
      rec[key] = val
    }
    END { if (bad) exit 1; emit() }
  ' "$LIBS"
}

rows="$(parse_libs)" || { echo "error: $LIBS is malformed (see above)" >&2; exit 2; }

field() { # field <row> <1-based index>
  printf '%s\n' "$1" | awk -F "$SEP" -v i="$2" '{ print $i }'
}

selected=""
if [ -n "$want" ]; then
  for name in $want; do
    row="$(printf '%s\n' "$rows" | awk -F "$SEP" -v n="$name" '$1 == n')"
    [ -n "$row" ] || { echo "error: libs.toml has no lib named '$name'" >&2; exit 2; }
    selected="${selected:+$selected
}$row"
  done
else
  selected="$rows"
fi

misses=""
miss() {
  misses="${misses:+$misses
}  $1"
  echo "MISS  $1" >&2
}

# Repo-relative physical path for a path relative to $1 (a repo-relative directory).
repo_rel() {
  local base="$1" rel="$2" abs
  if [ -d "$ROOT/$base/$rel" ]; then
    abs="$(cd "$ROOT/$base/$rel" && pwd -P)"
  else
    abs="$(cd "$(dirname "$ROOT/$base/$rel")" && pwd -P)/$(basename "$rel")"
  fi
  case "$abs" in
    "$ROOT") echo "." ;;
    "$ROOT"/*) echo "${abs#"$ROOT"/}" ;;
    *) echo "OUTSIDE:$abs" ;;
  esac
}

built_ok=""
while IFS= read -r row; do
  [ -n "$row" ] || continue
  name="$(field "$row" 1)"; dir="$(field "$row" 2)"; build="$(field "$row" 3)"
  artifacts="$(field "$row" 4)"; sources="$(field "$row" 5)"

  echo
  echo "━━ $name: $build"
  if ! (cd "$ROOT" && /bin/sh -c "$build" </dev/null); then
    miss "$name: build failed ($build)"
    continue
  fi

  ok=1
  fresh="$("$ROOT/scripts/zig-source-id.sh" "$ROOT/$dir")"
  IFS='|' read -r -a arts <<<"$artifacts"
  for art in "${arts[@]}"; do
    if [ ! -f "$ROOT/$art" ]; then
      miss "$name: $art was not produced"; ok=0; continue
    fi
    if LC_ALL=C grep -a -q 'index out of bounds' "$ROOT/$art"; then
      miss "$name: $art carries safety-check panic strings (a Debug or ReleaseSafe build)"; ok=0
    fi
    stamp="$ROOT/${art%.a}-source-id.txt"
    if [ ! -f "$stamp" ]; then
      miss "$name: no ${stamp#"$ROOT"/}"; ok=0
    elif [ "$(tr -d '[:space:]' < "$stamp")" != "$fresh" ]; then
      miss "$name: ${stamp#"$ROOT"/} does not match zig-source-id.sh $dir"; ok=0
    fi
  done

  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    r="$(repo_rel "$dir" "$dep")"
    covered=0
    IFS='|' read -r -a srcs <<<"$sources"
    for s in "${srcs[@]}"; do
      case "$r" in "$s" | "$s"/*) covered=1 ;; esac
    done
    if [ "$covered" = 0 ]; then
      miss "$name: the build reads $r, which libs.toml sources do not cover"; ok=0
    fi
  done <<EOF
$("$ROOT/scripts/zig-source-id.sh" --deps "$ROOT/$dir")
EOF

  if [ "$ok" = 1 ]; then
    echo "ok    $name: built, release-mode, stamped $fresh"
    built_ok="${built_ok:+$built_ok
}$row"
  fi
done <<EOF
$selected
EOF

# ── release stamps ────────────────────────────────────────────────────────────
echo
skip_reason=""
if [ "$release_stamp" = 0 ]; then
  skip_reason="--no-release-stamp"
elif ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  skip_reason="not a git checkout (baton release identities are git trees)"
elif ! command -v baton >/dev/null 2>&1; then
  skip_reason="baton is not installed"
elif ! command -v python3 >/dev/null 2>&1; then
  skip_reason="python3 is not installed (needed to read baton's plan)"
elif [ -z "$built_ok" ]; then
  skip_reason="nothing built"
fi

if [ -n "$skip_reason" ]; then
  echo "release stamps: skipped — $skip_reason"
else
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  work="${BATON_RELEASE_WORK_ROOT:-$HOME/work}"
  registered="$(baton release products --json 2>/dev/null \
    | python3 -I -c 'import json,sys; print("\n".join(p["slug"] for p in json.load(sys.stdin)))' || true)"

  products="$(printf '%s\n' "$built_ok" | awk -F "$SEP" '{ n = split($6, c, "|"); for (i = 1; i <= n; i++) print c[i] }' | LC_ALL=C sort -u)"
  stamped_ids=""   # lines: name SEP identity SEP product
  for product in $products; do
    if ! printf '%s\n' "$registered" | grep -qx "$product"; then
      echo "release stamps: $product is not registered with baton release here — skipped"
      continue
    fi
    if ! baton release plan --product "$product" --json > "$scratch/plan.json" 2>"$scratch/plan.err" </dev/null; then
      miss "$product: baton release plan failed: $(head -1 "$scratch/plan.err")"
      continue
    fi
    # name SEP repo_rel SEP build SEP first artifact SEP sorted sources ("|")
    python3 -I - "$scratch/plan.json" "$SEP" > "$scratch/inputs" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
sep = sys.argv[2]
for p in plan["products"]:
    for i in p.get("inputs", []):
        repo = i.get("repo_rel") or ""
        srcs = sorted(s[len(repo) + 1:] if s.startswith(repo + "/") else s for s in i.get("sources") or [])
        arts = i.get("artifacts") or [""]
        print(sep.join([i.get("name", ""), repo, i.get("build") or "", arts[0], "|".join(srcs)]))
PY
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      case "|$(field "$row" 6)|" in *"|$product|"*) ;; *) continue ;; esac
      name="$(field "$row" 1)"; build="$(field "$row" 3)"
      first_art="$(field "$row" 4 | cut -d'|' -f1)"
      want_srcs="$(field "$row" 5 | tr '|' '\n' | LC_ALL=C sort | paste -sd'|' -)"
      line="$(awk -F "$SEP" -v n="$name" '$1 == n' "$scratch/inputs")"
      if [ -z "$line" ]; then
        miss "$product: its release.toml declares no input '$name'"
        continue
      fi
      their_repo="$(field "$line" 2)"
      their_root="$(cd "$work/$their_repo" 2>/dev/null && pwd -P || echo "$work/$their_repo")"
      if [ "$their_root" != "$ROOT" ]; then
        echo "release stamps: $product/$name builds from $their_root, not this checkout — skipped"
        continue
      fi
      drift=""
      [ "$(field "$line" 3)" = "$build" ] || drift="$drift build='$(field "$line" 3)'"
      [ "$(field "$line" 4)" = "$first_art" ] || drift="$drift artifact='$(field "$line" 4)'"
      [ "$(field "$line" 5)" = "$want_srcs" ] || drift="$drift sources='$(field "$line" 5)'"
      if [ -n "$drift" ]; then
        miss "$product declares $name differently from libs.toml:$drift"
        continue
      fi
      if ! out="$(baton release stamp "$product" "$name" --json 2>&1 </dev/null)"; then
        miss "$product/$name: baton release stamp refused: $out"
        continue
      fi
      id="$(printf '%s\n' "$out" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["identity"])')"
      echo "stamped $product/$name id=$id"
      stamped_ids="${stamped_ids:+$stamped_ids
}$name$SEP$id$SEP$product"
    done <<EOF
$built_ok
EOF
  done

  # One stamp file sits beside each artifact, so two products may only share it when
  # they compute the same identity for it.
  conflicts="$(printf '%s\n' "$stamped_ids" | awk -F "$SEP" 'NF { if ($1 in id && id[$1] != $2) print $1 ": " who[$1] "=" id[$1] ", " $3 "=" $2; id[$1] = $2; who[$1] = $3 }')"
  if [ -n "$conflicts" ]; then
    while IFS= read -r c; do
      miss "products disagree on the identity of $c — the stamp holds only the last"
    done <<EOF
$conflicts
EOF
  fi
fi

echo
if [ -n "$misses" ]; then
  echo "build-consumed-libs: FAILED"
  printf '%s\n' "$misses"
  exit 1
fi
echo "build-consumed-libs: every selected library built, checked and stamped where possible"
