# claude-code-pr-push-guard

A [Claude Code](https://docs.claude.com/en/docs/claude-code) hook that stops an agent from
buying bot reviews by accident.

On many repositories, every push to a branch with an open pull request triggers an automatic
review: GitHub Copilot, CodeRabbit and similar bots re-review the **whole PR**, not just the new
commit. An agent working through review comments one at a time, or sweeping a fix across every
open PR, has no idea each push costs a full review.

## Why it exists

In one week, agent sweeps that pushed to every open PR at once (rebases, merging the base
branch in, one push per review comment) bought about 160 full Copilot reviews and used up the
review budget. Nothing in the agent's view said a push had a price.

This hook puts the price in front of a human before the push happens, and stays silent on
repositories where pushes are free.

## What it does

The hook runs on every Bash command Claude Code is about to run. It only acts on `git push`
(including `git -C <dir> push`) and `gh pr ready`; everything else passes straight through.

For those commands it works out which repository is targeted (from `git -C`, a leading
`cd <dir>`, or the session's working directory; worktrees resolve to their main checkout),
then reads that repository's answer to one question: **does it auto-review on push?**

| Recorded answer | Before the push                                                                  |
| --------------- | -------------------------------------------------------------------------------- |
| `no`            | Allowed silently.                                                                |
| `yes`           | Claude Code asks you, with the cost spelled out, and notes when the command loops over several PRs. |
| nothing         | Claude Code asks you, and tells the agent to find out and record the answer first. |

### Where the answer is recorded

In the repository's `CLAUDE.local.md`, a file Claude Code already reads as private,
per-checkout instructions:

```markdown
Auto-review on push: no
```

`yes` or `no`, case-insensitive; markdown emphasis such as `**no**` is read too. Keep the file
out of git: add `CLAUDE.local.md` to `.git/info/exclude` or your global gitignore.

When the answer is missing, the agent is told how to find it: look at recent PR timelines for
bot review requests landing within about a minute of a push, confirm with you, then write the
line. After that the hook never asks about that repository again unless the answer is `yes`.

### Owners whose repos never auto-review

If none of the repositories under some GitHub owners auto-review (personal repos without
Copilot, for example), list those owners so their repos count as `no` without recording
anything:

```bash
export PR_PUSH_GUARD_NO_AUTOREVIEW_OWNERS='your-github-user your-org'
```

Space-separated, case-insensitive, matched against the `origin` remote's owner on github.com.
Unset, no owner is presumed and every unrecorded repo asks. A record in `CLAUDE.local.md`
always wins over this list.

### Catching auto-review when it turns on

A repository that counts as `no` can start auto-reviewing later (someone enables Copilot code
review, or the owner list is wrong). In post mode, after each push to such a repository the
hook starts a detached background check: about 30 seconds later it asks GitHub whether a
Copilot review was requested on the pushed branch's PR within two minutes of the push. If so,
it writes `Auto-review on push: yes` into `CLAUDE.local.md` (flipping an existing `no` in
place, and noting the PR and times), so the next push asks. It never flips `yes` back to `no`.

This detection recognises Copilot review requests. For other bots, record `yes` by hand.

## Install

Requirements: `bash`, `git`, `jq`. Post mode also needs the GitHub CLI `gh`, signed in.
Tested on macOS and Linux.

1. Put `pr-push-guard.sh` somewhere stable and make it executable:

   ```bash
   chmod +x pr-push-guard.sh
   ```

2. Register it in `~/.claude/settings.json` (or a project's `.claude/settings.json`) as both a
   PreToolUse and a PostToolUse hook on the Bash tool. Use the absolute path to the script:

   ```json
   {
     "hooks": {
       "PreToolUse": [
         {
           "matcher": "Bash",
           "hooks": [{ "type": "command", "command": "/path/to/pr-push-guard.sh" }]
         }
       ],
       "PostToolUse": [
         {
           "matcher": "Bash",
           "hooks": [{ "type": "command", "command": "/path/to/pr-push-guard.sh post" }]
         }
       ]
     }
   }
   ```

   To set the owner list for the hook alone, put it in the command:
   `"PR_PUSH_GUARD_NO_AUTOREVIEW_OWNERS='your-github-user' /path/to/pr-push-guard.sh"`.

3. Restart Claude Code, or open `/hooks` to check they are loaded.

The PreToolUse hook only ever answers `ask` or stays silent; it never blocks a command
outright, so you keep the final say.

## Tests

```bash
bash pr-push-guard.test.sh
```

The suite builds throwaway git repositories with different origins and `CLAUDE.local.md`
records, pipes Bash-tool commands into the hook, and checks whether it asks. Post mode runs in
the foreground against a fake `gh`, so nothing touches GitHub. It exits non-zero on any
failure.

## License

[MIT](LICENSE)
