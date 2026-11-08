#!/bin/bash
# Tests for pr-push-guard.sh: builds throwaway repos with different origins and
# CLAUDE.local.md records, pipes Bash-tool commands into the hook, and checks whether it
# asks. Post mode runs in the foreground against a fake `gh`, so nothing touches GitHub.
#
# usage: bash pr-push-guard.test.sh   (from any directory; exit 1 on any failure)

hook="$(cd "$(dirname "$0")" && pwd)/pr-push-guard.sh"
export PR_PUSH_GUARD_NO_AUTOREVIEW_OWNERS='Example-Owner another-owner'
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0

mk() { # mk <name> <origin url or ""> [CLAUDE.local.md content] -> prints repo dir
  local d="$tmp/$1"
  git init -q "$d"
  [ -n "$2" ] && git -C "$d" remote add origin "$2"
  [ -n "$3" ] && printf '%s\n' "$3" >"$d/CLAUDE.local.md"
  echo "$d"
}

run() { # run pre|post <cwd> <command>
  jq -n --arg c "$3" --arg d "$2" '{tool_input:{command:$c},cwd:$d}' | "$hook" "$1"
}

ok() { # ok <description> <condition result: 0 pass>
  if [ "$2" -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi
}

check() { # check ask|allow <cwd> <command>
  local got
  [[ $(run pre "$2" "$3") == *'"ask"'* ]] && got=ask || got=allow
  [ "$got" = "$1" ]; ok "want $1, got $got: [$2] $3" $?
}

own=$(mk own 'https://github.com/example-owner/a.git')
own_ssh=$(mk own_ssh 'git@github.com:example-owner/a.git')
own_sshurl=$(mk own_sshurl 'ssh://git@github.com/example-owner/a.git')
own_case=$(mk own_case 'https://github.com/Example-Owner/a.git')
own_yes=$(mk own_yes 'https://github.com/example-owner/a.git' 'Auto-review on push: yes')
own_boldyes=$(mk own_boldyes 'https://github.com/example-owner/a.git' '- Auto-review on push: **yes**. Copilot on every push.')
own_headno=$(mk own_headno 'https://github.com/example-owner/a.git' '## Auto-review on push: NO')
other=$(mk other 'https://github.com/someone-else/a.git')
other_no=$(mk other_no 'https://github.com/someone-else/a.git' 'Auto-review on push: no')
other_boldno=$(mk other_boldno 'git@github.com:someone-else/a.git' '- Auto-review on push: **no**. Checked 2026-10-12.')
other_not=$(mk other_not 'https://github.com/someone-else/a.git' 'Auto-review on push: not recorded yet')
lookalike=$(mk lookalike 'https://github.com/example-owner-x/a.git')
lookhost=$(mk lookhost 'https://github.com.evil.example/example-owner/a.git')
noorigin=$(mk noorigin '')

# Repos under a listed owner with nothing recorded: no prompt.
check allow "$own" 'git push'
check allow "$own" 'git push -u origin feature'
check allow "$own_ssh" 'git push'
check allow "$own_sshurl" 'git push'
check allow "$own_case" 'git push'
check allow "$own" 'gh pr ready 12'
check allow "$other" "git -C $own push"
check allow "$other" "cd $own && git push"

# An explicit record wins over ownership, in any of the formats agents write.
check ask "$own_yes" 'git push'
check ask "$own_boldyes" 'git push'
check allow "$own_headno" 'git push'

# Repos under any other owner: the record decides, and no record asks.
check ask "$other" 'git push'
check ask "$own" "git -C $other push"
check allow "$other_no" 'git push'
check allow "$other_boldno" 'git push'
check ask "$other_not" 'git push'
check ask "$lookalike" 'git push'
check ask "$lookhost" 'git push'
check ask "$noorigin" 'git push'

# The owner list: any listed owner counts, and with no list every unrecorded repo asks.
another=$(mk another 'https://github.com/another-owner/a.git')
check allow "$another" 'git push'
[[ $(jq -n --arg c 'git push' --arg d "$own" '{tool_input:{command:$c},cwd:$d}' |
  PR_PUSH_GUARD_NO_AUTOREVIEW_OWNERS= "$hook") == *'"ask"'* ]]; ok 'an empty owner list asks for an unrecorded repo' $?
[[ $(jq -n --arg c 'git push' --arg d "$own" '{tool_input:{command:$c},cwd:$d}' |
  env -u PR_PUSH_GUARD_NO_AUTOREVIEW_OWNERS "$hook") == *'"ask"'* ]]; ok 'an unset owner list asks for an unrecorded repo' $?

# Not a push: never asks.
check allow "$other" 'git status'
check allow "$other" 'git log --grep=push'

# Post mode: a Copilot review request after the push records "yes".
bin="$tmp/bin"; mkdir -p "$bin"
cat >"$bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  'pr list') echo 7 ;;
  'api --paginate') cat "$FAKE_TIMELINE" ;;
esac
EOF
chmod +x "$bin/gh"
hit="$tmp/hit.json"; miss="$tmp/miss.json"
echo '[{"event":"review_requested","requested_reviewer":{"login":"Copilot"},"created_at":"2026-10-20T10:00:30Z"}]' >"$hit"
echo '[]' >"$miss"

post() { # post <timeline file> <cwd> <command>
  FAKE_TIMELINE=$1 PATH="$bin:$PATH" PR_PUSH_GUARD_FOREGROUND=1 PR_PUSH_GUARD_DELAY=0 \
    PR_PUSH_GUARD_SINCE=2026-10-20T10:00:00Z run post "$2" "$3" >/dev/null
}

p_own=$(mk p_own 'https://github.com/example-owner/a.git')
post "$hit" "$p_own" 'git push origin feature'
grep -qx 'Auto-review on push: yes' "$p_own/CLAUDE.local.md"; ok 'post: listed owner + unrecorded + hit writes yes' $?
grep -qxF CLAUDE.local.md "$p_own/.git/info/exclude"; ok 'post: a CLAUDE.local.md it creates is excluded from git' $?
check ask "$p_own" 'git push'

p_bold=$(mk p_bold 'https://github.com/example-owner/a.git' '- Auto-review on push: **no**. Checked 2026-10-12.')
post "$hit" "$p_bold" 'git push origin feature'
grep -q 'Auto-review on push: \*\*yes\*\*\. Checked' "$p_bold/CLAUDE.local.md"; ok 'post: a bold no is flipped in place' $?
[ "$(grep -ic 'auto-review on push:' "$p_bold/CLAUDE.local.md")" -eq 1 ]; ok 'post: flipping in place adds no second record' $?
check ask "$p_bold" 'git push'

p_prose=$(mk p_prose 'https://github.com/example-owner/a.git' 'This repository does **not** auto-review on push.')
post "$hit" "$p_prose" 'git push origin feature'
check ask "$p_prose" 'git push'

p_miss=$(mk p_miss 'https://github.com/example-owner/a.git')
post "$miss" "$p_miss" 'git push origin feature'
[ ! -e "$p_miss/CLAUDE.local.md" ]; ok 'post: no hit leaves a listed owner'"'"'s repo unrecorded' $?

p_other=$(mk p_other 'https://github.com/someone-else/a.git')
post "$hit" "$p_other" 'git push origin feature'
[ ! -e "$p_other/CLAUDE.local.md" ]; ok 'post: an unrecorded repo under another owner is left for the agent to record' $?

p_caps=$(mk p_caps 'https://github.com/example-owner/a.git' 'AUTO-REVIEW ON PUSH: no')
post "$hit" "$p_caps" 'git push origin feature'
grep -qx 'AUTO-REVIEW ON PUSH: yes' "$p_caps/CLAUDE.local.md"; ok 'post: a record in any capitals is flipped in place' $?
[ "$(grep -ic 'auto-review on push:' "$p_caps/CLAUDE.local.md")" -eq 1 ]; ok 'post: a capitalised record gets no second record' $?

# No jq: blocks loudly instead of reading nothing and allowing.
err=$(echo '{}' | PATH=/var/empty /bin/bash "$hook" 2>&1 >/dev/null); code=$?
[ "$code" -eq 2 ] && [[ $err == *'jq is required'* ]]; ok "no jq: exit 2 with a message (got $code: $err)" $?

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
