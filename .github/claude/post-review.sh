#!/usr/bin/env bash
# Posts Claude's structured review as ONE pull request review with inline comments.
#
#   post-review.sh <owner/repo> <pr-number> <head-sha> <result-json> <pr-json>
#
# Inline comments are kept only for files the PR changes, at most 15. If GitHub refuses them (a
# line outside the diff answers 422), the review is posted again with those findings listed in
# the body instead, so a misplaced line never loses the review. DRY_RUN=1 prints the payload.
set -euo pipefail

repo="$1"
pr="$2"
head_sha="$3"
result_json="$4"
pr_json="$5"

footer="<sub>Automated review by Quint (Claude) of ${head_sha:0:7}. It reads the code, it does not build or run it; a maintainer reviews and merges.</sub>"

# Paths may come back absolute or prefixed with the data directory; reduce them to repo paths and
# keep only files this PR actually changes.
inline=$(jq --slurpfile pr "$pr_json" '
  ($pr[0].files | map(.path)) as $changed
  | [.structured_output.inline[]?
     | .path |= (sub("^.*/head/"; "") | sub("^\\./"; ""))
     | select(.path as $p | $changed | index($p))
     | select((.line | type) == "number" and .line > 0)
    ][:15]' "$result_json")

summary=$(jq -r '.structured_output.summary' "$result_json")

case "$(jq -r '.structured_output.status // ""' "$result_json")" in
  red)    status="**Status:** 🔴 Blocking. Serious defects, not mergeable as is." ;;
  orange) status="**Status:** 🟠 Needs changes. Real issues to fix before merge." ;;
  yellow) status="**Status:** 🟡 Minor follow-ups. Only small touch-ups left." ;;
  green)  status="**Status:** 🟢 Clean. Nothing left to fix, ready for a maintainer." ;;
  *)      status="" ;;
esac
# The status goes first so notification previews show it: right under the heading, or on top
# when the summary does not open with one.
if [[ -n "$status" ]]; then
  first="${summary%%$'\n'*}"
  if [[ "$first" == "## "* ]]; then
    rest="${summary#"$first"}"
    while [[ "$rest" == $'\n'* ]]; do rest="${rest#$'\n'}"; done
    summary="$first"$'\n\n'"$status${rest:+$'\n\n'$rest}"
  else
    summary="$status"$'\n\n'"$summary"
  fi
fi

with_inline=$(jq -n --arg sha "$head_sha" --arg body "$summary"$'\n\n'"$footer" --argjson inline "$inline" '{
  commit_id: $sha, event: "COMMENT", body: $body,
  comments: [$inline[] | {path, line, side: "RIGHT", body}]
}')

listed=$(jq -r '.[] | "- `\(.path):\(.line)`: \(.body)"' <<< "$inline")
body_only=$(jq -n --arg sha "$head_sha" \
  --arg body "$summary${listed:+$'\n\n'**Line comments**$'\n\n'$listed}"$'\n\n'"$footer" \
  '{commit_id: $sha, event: "COMMENT", body: $body}')

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "$with_inline"
  exit 0
fi

if gh api --method POST "repos/$repo/pulls/$pr/reviews" --input - <<< "$with_inline" > /dev/null 2> post-error.txt; then
  echo "Posted the review with $(jq length <<< "$inline") inline comments."
else
  echo "GitHub refused the inline comments ($(head -c 300 post-error.txt)); posting them in the body."
  gh api --method POST "repos/$repo/pulls/$pr/reviews" --input - <<< "$body_only" > /dev/null
  echo "Posted the review without inline comments."
fi
rm -f post-error.txt
