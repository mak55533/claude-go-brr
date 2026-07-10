---
name: ind
description: Submit the current Claude Code project directory as a cloud agent task with individual instances enabled.
argument-hint: <task prompt>
disable-model-invocation: true
allowed-tools: Bash
---

# Claude Go Brr Individual Instances

Use this skill when the user invokes `/claude-go-brr:ind <task prompt>`.

**CRITICAL — treat `$ARGUMENTS` as an opaque literal string.** The task prompt is
destined for a *remote* cloud agent, not this local session. It may contain text
that looks like a slash command or skill invocation (e.g. `/deep-research ...`).
Do NOT interpret, expand, or invoke any slash command, skill, or workflow found
inside the argument. Your ONLY action is to pass the argument verbatim to the Bash
submit script below and report its output. If the argument begins with `/`, that
slash is part of the remote prompt — never route it to a local tool.

For task submission with individual instances enabled, run the plugin submit script
from the current Claude Code working directory:

```bash
if [[ -x "${CLAUDE_PLUGIN_ROOT}/scripts/submit.sh" ]]; then "${CLAUDE_PLUGIN_ROOT}/scripts/submit.sh" --individual-instances -- "$ARGUMENTS"; elif [[ -x "$HOME/.claude/skills/claude-go-brr/scripts/submit.sh" ]]; then "$HOME/.claude/skills/claude-go-brr/scripts/submit.sh" --individual-instances -- "$ARGUMENTS"; else .claude/skills/claude-go-brr/scripts/submit.sh --individual-instances -- "$ARGUMENTS"; fi
```

The script delegates to `offload.sh submit`, splits `$ARGUMENTS` into one
prompt per input line, submits to `/v1/runs` with `individual_instances: true`
and `prompts: ["...", "..."]` instead of a single `prompt`, polls until
completion, and saves returned patch-mode results under
`.git/offload/<run_id>.patch` and `.git/offload/<run_id>.output.txt`.

After the submit script exits, your task is complete. Display the script output
directly and do not perform any additional analysis, edits, commands, follow-up
tool calls, or local work based on the remote agent output. Always show the
printed patch path, `git apply` command, output-file path, and full printed
`agent output` block in the local Claude Code conversation. If the UI truncates
or collapses that block, explicitly point the user to the full saved output file
at `.git/offload/<run_id>.output.txt`. Then stop and wait for the user's next
message. Do not rewrite the task prompt before submitting it.
