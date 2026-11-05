#!/bin/sh
# A stand-in for `claude -p --output-format json` and `codex exec`, for testing the LLM annotator
# without a model. It reads the prompt on stdin, fills the <reply-template> with canned values
# picked by a hash of each id, and prints the reply the way the real CLI does. The structural
# review prompt has no template; its reply is one canned finding on the first component listed.
#
#   reviewmap <repo> --llm-command scripts/fake-llm.sh             # imitates claude
#   reviewmap <repo> --llm codex --llm-command scripts/fake-llm.sh # imitates codex
#
# FAKE_LLM_MODE changes the reply: ok (default), prose (JSON wrapped in prose and a code fence),
# invalid (a risk outside 0...1), fail (exit 1), error (claude's is_error result).

mode=${FAKE_LLM_MODE:-ok}
out_file=""
codex=0
if [ "$1" = "exec" ]; then
  codex=1
  while [ $# -gt 0 ]; do
    if [ "$1" = "--output-last-message" ]; then out_file=$2; fi
    shift
  done
fi

if [ "$mode" = "fail" ]; then
  cat >/dev/null
  echo "fake-llm: simulated failure" >&2
  exit 1
fi

prompt=$(cat)

if printf '%s' "$prompt" | grep -q '^You are reviewing the structure'; then
  reply=$(printf '%s\n' "$prompt" | awk -v mode="$mode" '
/^## Components$/ { inside = 1; next }
inside && /^- / { id = $2; exit }
END {
  kind = mode == "invalid" ? "style" : "complexity"
  if (id == "") { print "{\"findings\": []}"; exit }
  printf "{\"findings\": [{\"kind\": \"%s\", \"severity\": \"medium\", \"message\": \"A lock guards state that only one isolation domain touches.\", \"evidence\": [\"Every caller is @MainActor.\"], \"suggestion\": \"Remove the lock.\", \"anchors\": [{\"component\": \"%s\"}]}]}\n", kind, id
}')
else
reply=$(printf '%s\n' "$prompt" | awk -v mode="$mode" '
BEGIN {
  for (i = 32; i < 127; i++) ord[sprintf("%c", i)] = i
  sums[0] = "Loads the data asynchronously and reports failures to the caller."
  sums[1] = "Stores one more field and keeps older payloads readable."
  sums[2] = "Runs on the main actor instead of a background queue."
  sums[3] = "Validates input before saving and returns early on bad values."
  sums[4] = "Shows the new state in the list and hides the old placeholder."
  rank = 0
}
function h(s,   i, x) { x = 7; for (i = 1; i <= length(s); i++) x = (x * 31 + ord[substr(s, i, 1)]) % 1000003; return x }
function idof(line,   s) { s = line; sub(/^.*"id": "/, "", s); sub(/".*$/, "", s); return s }
/^<reply-template>$/ { inside = 1; next }
/^<\/reply-template>$/ { inside = 0; done = 1; next }
!inside || done { next }
/"risk": null/ {
  id = idof($0); x = h(id)
  risk = (x % 90 + 5) / 100
  if (mode == "invalid" && !bad) { risk = 1.7; bad = 1 }
  sub(/"risk": null/, "\"risk\": " risk)
  print; next
}
/"keep": null/ {
  id = idof($0); x = h(id)
  if (x % 3 == 0) { sub(/"keep": null/, "\"keep\": false") }
  else { rank++; sub(/"keep": null/, "\"keep\": true"); sub(/"rank": null/, "\"rank\": " rank) }
  print; next
}
/"id": / { last = idof($0) }
/"summary": ""/ {
  x = h(last)
  sub(/"summary": ""/, "\"summary\": \"" sums[x % 5] "\"")
  print; next
}
/"regions": \[/ { rank = 0 }
{ print }
')
fi

if [ "$mode" = "prose" ]; then
  reply=$(printf 'Here is the annotation.\n\n```json\n%s\n```\n' "$reply")
fi

if [ $codex -eq 1 ]; then
  echo "fake-llm: codex exec" >&2
  if [ -n "$out_file" ]; then printf '%s\n' "$reply" >"$out_file"; fi
  printf '%s\n' "$reply"
  exit 0
fi

# claude -p --output-format json: one result object with the reply text as a JSON string.
escaped=$(printf '%s' "$reply" | awk '
  { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); s = s (NR > 1 ? "\\n" : "") $0 }
  END { printf "%s", s }')
is_error=false
if [ "$mode" = "error" ]; then is_error=true; escaped="Prompt is too long"; fi
printf '{"type":"result","subtype":"success","is_error":%s,"duration_ms":1200,"num_turns":1,"result":"%s","session_id":"00000000-0000-0000-0000-000000000000","total_cost_usd":0}\n' "$is_error" "$escaped"
