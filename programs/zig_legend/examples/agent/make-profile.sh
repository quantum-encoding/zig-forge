#!/bin/sh
# Build a review panel (implementer, reviewer, red-team) on one filed work
# item, then print the `baton launch` lines.
#
#   examples/agent/make-profile.sh <work-id> <project> [out-dir]
#
# <project> is one of the PROJECT enum values in legend.toml. Each scenario
# gets its own role text from the baton role library via a scoped --set.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin=${ZIG_LEGEND:-"$here/../../zig-out/bin/zig_legend"}
work_id=${1:?work id}
project=${2:?project}
out=${3:-"$here/out"}

mkdir -p "$out"
baton work show "$work_id" --json > "$out/goal.json"
for role in implementer reviewer red-team; do
  baton role text "$role" > "$out/role-$role.txt"
done

"$bin" profile \
  -l "$here/legend.toml" -t "$here/brief.txt" \
  --bind "$out/goal.json" \
  --set "PROJECT=$project" \
  --set "implementer:ROLE_TEXT=@$out/role-implementer.txt" \
  --set "reviewer:ROLE_TEXT=@$out/role-reviewer.txt" \
  --set "red-team:ROLE_TEXT=@$out/role-red-team.txt" \
  --each-scenario \
  --out-dir "$out"

echo "review: $out/*.md   then: baton workflow run $out/workflow.json" >&2
