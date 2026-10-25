#!/usr/bin/env bash
# Runs renovo against a fake home and handbook, with a 1-second interval.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rw=$here/bin/renovo
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

export HOME=$t/home RENOVO_STATE=$t/state RENOVO_HANDBOOK=$t/handbook RENOVO_INTERVAL=1
mkdir -p "$HOME/.claude" "$t/handbook/sops" "$t/proj/.agents/personas"
echo v1 >"$HOME/.claude/CLAUDE.md"
echo v1 >"$t/handbook/AGENTS.md"
echo v1 >"$t/handbook/sops/a.md"
echo v1 >"$t/proj/.agents/personas/sadr.md"
echo v1 >"$t/proj/.agents/persona.md"
mkdir -p "$t/personas" && echo v1 >"$t/personas/proj.md"
# A stand-in persona resolver: --resolve <cwd> prints <dir>/personas/<repo>.md.
printf '#!/bin/sh\n[ "$1" = --resolve ] && echo "%s/personas/$(basename "$2").md"\n' "$t" >"$t/persona-resolve"
chmod +x "$t/persona-resolve"
export RENOVO_PERSONA_CMD=$t/persona-resolve
input=$(jq -nc --arg cwd "$t/proj" --arg tr "$t/transcript.jsonl" '{session_id:"s1",cwd:$cwd,transcript_path:$tr,hook_event_name:"Stop"}')

pass=0 fail=0
check() { if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

"$rw" baseline <<<"$input"
check "baseline records 6 files, both persona kinds included" '[[ $(wc -l <"$t/state/sessions/s1/files") == 6 ]] && grep -q "personas/proj.md" "$t/state/sessions/s1/files" && grep -q "agents/persona.md" "$t/state/sessions/s1/files"'

# A change wakes the agent with exit 2 and names the file.
"$rw" watch <<<"$input" >"$t/out" & w=$!
sleep 1.5
"$rw" watch <<<"$input" >/dev/null; second=$?
check "second watcher exits at once (lock)" '[[ $second == 0 ]]'
check "status shows a running watcher" '"$rw" status | grep -q running'
echo v2 >"$t/handbook/sops/a.md"
echo new >"$t/handbook/sops/b.md"
rc=0; wait $w || rc=$?
check "change exits 2" '[[ $rc == 2 ]]'
check "names the changed file" 'grep -q "changed: $t/handbook/sops/a.md" "$t/out"'
check "names the added file" 'grep -q "added:   $t/handbook/sops/b.md" "$t/out"'
check "notice shows the diff" 'grep -q "^+v2" "$t/out" && grep -q "^-v1" "$t/out"'
check "session is told (not current) after the wake" '"$rw" status | grep -q " told "'

# Confirmed only when the transcript shows a Read of every file the notice named.
# The Read lands in the same second as the notice, with a millisecond stamp as Claude Code writes.
now=$(awk -F'\t' '$1=="at"{print substr($2,1,19)".001Z"}' "$t/state/sessions/s1/told")
read_line() { jq -nc --arg ts "$now" --arg f "$1" '{timestamp:$ts,type:"assistant",message:{content:[{type:"tool_use",name:"Read",input:{file_path:$f}}]}}'; }
echo 'not json' >"$t/transcript.jsonl"
read_line "$t/handbook/sops/a.md" >>"$t/transcript.jsonl"
quiet() { RENOVO_MAX_RUN=1 RENOVO_REARM=0 "$rw" watch <<<"$input" >/dev/null; }
quiet
check "one of two files reread: still told" '"$rw" status | grep -q " told "'
read_line "$t/handbook/sops/b.md" >>"$t/transcript.jsonl"
quiet
check "both reread (same second, ms stamps): current" '"$rw" status | grep -q " current "'

# A change with no watcher running shows the session as behind.
echo v3 >"$t/proj/.agents/personas/sadr.md"
check "status shows BEHIND" '"$rw" status | grep -q BEHIND'

# A removed file is a change.
"$rw" baseline <<<"$input"
"$rw" watch <<<"$input" >"$t/out" & w=$!
sleep 1.5
rm "$t/handbook/sops/b.md"
rc=0; wait $w || rc=$?
check "removed file exits 2" '[[ $rc == 2 ]] && grep -q "removed: $t/handbook/sops/b.md" "$t/out"'

# At MAX_RUN with no change: re-arm wake (exit 2), or a quiet exit 0 when REARM=0.
rc=0; RENOVO_MAX_RUN=1 RENOVO_REARM=1 "$rw" watch <<<"$input" >"$t/out" || rc=$?
check "re-arm wake exits 2" '[[ $rc == 2 ]] && grep -q re-arms "$t/out"'
rc=0; RENOVO_MAX_RUN=1 "$rw" watch <<<"$input" >/dev/null || rc=$?
check "REARM=0 (default) exits 0" '[[ $rc == 0 ]]'

echo "$pass passed, $fail failed"
(( fail == 0 ))
