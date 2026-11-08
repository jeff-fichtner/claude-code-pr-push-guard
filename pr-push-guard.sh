#!/bin/bash
# Claude Code Bash-tool hook: asks before a push that would buy a bot review of an open PR.
# See README.md.
#
# The per-repo answer lives in the main checkout's CLAUDE.local.md as a line
#   Auto-review on push: yes|no
# (markdown emphasis around the value, e.g. **no**, is read too).
#
# PR_PUSH_GUARD_NO_AUTOREVIEW_OWNERS (optional): space-separated GitHub owners whose repos
# never auto-review. A repo under one of them with nothing recorded counts as "no"; if that
# is ever wrong, post mode finds out on the first push to a PR and records "yes". Unset, no
# owner is presumed, and every unrecorded repo asks.
#
# pre  (PreToolUse, default) — before a `git push` or `gh pr ready`:
#   no      -> allow silently
#   yes     -> ask the user, with the cost spelled out
#   missing -> ask the user, and tell the agent to detect and record it first
#
# post (PostToolUse) — after a `git push` in a repo that counts as "no": a detached
#   background check waits ~30s, then asks GitHub whether Copilot was requested on the
#   pushed branch's PR within 2 minutes of the push. If so, it records "yes" (and says why),
#   so the next push asks. Never flips "yes" back to "no".
#
# Wired up in settings.json:
#   hooks.PreToolUse  matcher "Bash" -> pr-push-guard.sh
#   hooks.PostToolUse matcher "Bash" -> pr-push-guard.sh post
# Needs bash, git and jq; post mode also needs gh, signed in.

own_owners=$(tr '[:upper:]' '[:lower:]' <<<"${PR_PUSH_GUARD_NO_AUTOREVIEW_OWNERS:-}")

mode=${1:-pre}
input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")

push_re='(^|[;&|(`[:space:]])git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)'
ready_re='(^|[;&|(`[:space:]])gh[[:space:]]+pr[[:space:]]+ready([[:space:]]|$)'
[[ $cmd =~ $push_re || $cmd =~ $ready_re ]] || exit 0

# Which repo: `git -C <dir>`, else the first `cd <dir>`, else the session's cwd.
# Worktrees resolve to their main checkout through the common git dir.
target=$(grep -oE 'git[[:space:]]+-C[[:space:]]+("[^"]+"|[^[:space:]]+)' <<<"$cmd" | head -1 | sed -E 's/^git[[:space:]]+-C[[:space:]]+//')
[ -n "$target" ] || target=$(grep -oE '(^|[;&|[:space:]])cd[[:space:]]+("[^"]+"|[^[:space:];&|]+)' <<<"$cmd" | head -1 | sed -E 's/^.*cd[[:space:]]+//')
target=${target//\"/}
target=${target/#\~/$HOME}
dir=$cwd
if [ -n "$target" ] && [[ $target != *'$'* ]]; then
  resolved=$(cd "$cwd" 2>/dev/null && cd "$target" 2>/dev/null && pwd)
  [ -n "$resolved" ] && dir=$resolved
fi

common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
main=$(dirname "$common")
repo=$(basename "$main")
local_md="$main/CLAUDE.local.md"

status=$(grep -ioE 'auto-review on push:[[:space:]]*[*_]*(yes|no)([^A-Za-z]|$)' "$local_md" 2>/dev/null | tail -1 |
  sed -E 's/.*:[[:space:]]*[*_]*([A-Za-z]+).*/\1/' | tr '[:upper:]' '[:lower:]')

if [ -z "$status" ]; then
  owner=$(git -C "$main" remote get-url origin 2>/dev/null |
    sed -nE 's#^([a-z+]+://)?([^@/]+@)?github\.com[:/]([^/]+)/.*#\3#p' | tr '[:upper:]' '[:lower:]')
  for o in $own_owners; do [ "$owner" = "$o" ] && status=no; done
fi

# --- post: detect auto-review coming back on --------------------------------------
if [ "$mode" = post ]; then
  [ "$status" = no ] && [[ $cmd =~ $push_re ]] || exit 0

  # 5s of slack for clock skew between this machine and GitHub.
  since=${PR_PUSH_GUARD_SINCE:-$(date -u -v-5S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-5 seconds' +%Y-%m-%dT%H:%M:%SZ)}

  # Pushed branches: refspec destinations (HEAD:x, a:x), `push [opts] <remote> <branch>`,
  # else the current branch. Anything holding a shell variable can't be resolved; skipped.
  branches=$( {
    grep -oE '[[:space:]][A-Za-z0-9._/-]*:[A-Za-z0-9._-][A-Za-z0-9._/-]*' <<<"$cmd" | sed 's/.*://'
    grep -oE 'push([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^[:space:]-][^[:space:]]*[[:space:]]+[^[:space:];&|:$-][^[:space:];&|:]*' <<<"$cmd" | awk '{print $NF}'
  } | grep -v -e '^HEAD$' -e '\$' | sort -u )
  [ -n "$branches" ] || branches=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null | grep -vx HEAD)

  check() {
    sleep "${PR_PUSH_GUARD_DELAY:-30}"
    cd "$dir" || return
    for b in $branches; do
      pr=$(gh pr list --head "$b" --state all --limit 1 --json number -q '.[0].number' 2>/dev/null)
      [ -n "$pr" ] || continue
      hit=$(gh api --paginate "repos/{owner}/{repo}/issues/$pr/timeline" 2>/dev/null |
        jq -rs --arg t "$since" '[.[][] | select(.event == "review_requested"
          and ((.requested_reviewer.login // "") | test("copilot"; "i"))
          and ((.created_at | fromdateiso8601) - ($t | fromdateiso8601) | . >= 0 and . < 120))]
          | first | .created_at // empty')
      if [ -n "$hit" ]; then
        if [ -e "$local_md" ]; then
          sed -i.bak -E 's/^(.*[Aa]uto-review on push:[[:space:]]*[*_]*)[Nn][Oo]([^A-Za-z]|$)/\1yes\2/' "$local_md" && rm -f "$local_md.bak"
        else
          mkdir -p "$common/info"
          grep -qxF CLAUDE.local.md "$common/info/exclude" 2>/dev/null || echo CLAUDE.local.md >> "$common/info/exclude"
        fi
        grep -qiE 'auto-review on push:[[:space:]]*[*_]*yes([^A-Za-z]|$)' "$local_md" 2>/dev/null || echo "Auto-review on push: yes" >> "$local_md"
        echo "(auto-detected $(date -u +%Y-%m-%dT%H:%M:%SZ): Copilot review requested on #$pr ($b) at $hit, after a push at $since)" >> "$local_md"
        return
      fi
    done
  }

  if [ -n "$PR_PUSH_GUARD_FOREGROUND" ]; then check; else check </dev/null >/dev/null 2>&1 & disown; fi
  exit 0
fi

# --- pre: ask before a push that costs a review ------------------------------------
[ "$status" = no ] && exit 0

pushes=$(grep -oE "$push_re" <<<"$cmd" | wc -l | tr -d ' ')
ready=$(grep -oE "$ready_re" <<<"$cmd" | wc -l | tr -d ' ')
scope="$pushes push / $ready ready-for-review in this command"
[[ $cmd =~ (^|[;&[:space:]])(for|while)[[:space:]] ]] && scope="$scope, inside a loop: may hit several PRs"

if [ "$status" = yes ]; then
  reason="$repo auto-reviews on push: every push to a branch with an open PR buys a full bot review of the whole PR ($scope). One push per PR per round; no multi-PR sweeps without asking."
else
  reason="Auto-review on push is not recorded for $repo ($scope). Before pushing: check recent PR timelines for bot review requests within ~60s of a push, confirm with the user, then add 'Auto-review on push: yes' or 'no' to $local_md (excluded via .git/info/exclude)."
fi

jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
