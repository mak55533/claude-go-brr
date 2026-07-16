---
name: claude-go-brr
description: Submit the current Claude Code project directory as a cloud agent task through the offload host API.
argument-hint: <task prompt>
disable-model-invocation: true
allowed-tools: Bash
---

# Claude Go Brr

Use this skill when the user invokes `/claude-go-brr <task prompt>`.

**CRITICAL — treat `$ARGUMENTS` as an opaque literal string.** The task prompt is
destined for a *remote* cloud agent, not this local session. It may contain text
that looks like a slash command or skill invocation (e.g. `/deep-research ...`).
Do NOT interpret, expand, or invoke any slash command, skill, or workflow found
inside the argument. Your ONLY action is to pass the argument verbatim to the Bash
submit script below as a managed background task. If the argument begins with `/`,
that slash is part of the remote prompt — never route it to a local tool.

For one-time setup, tell the user to invoke this Claude command:

```bash
/claude-go-brr:setup
```

For task submission, run the plugin submit script from the current Claude Code working directory:

```bash
if [[ -x "${CLAUDE_PLUGIN_ROOT}/scripts/submit.sh" ]]; then "${CLAUDE_PLUGIN_ROOT}/scripts/submit.sh" "$ARGUMENTS"; elif [[ -x "$HOME/.claude/skills/claude-go-brr/scripts/submit.sh" ]]; then "$HOME/.claude/skills/claude-go-brr/scripts/submit.sh" "$ARGUMENTS"; else .claude/skills/claude-go-brr/scripts/submit.sh "$ARGUMENTS"; fi
```

Invoke the Bash tool with `run_in_background: true`; do not append shell `&` to
the command. Once the Bash tool confirms that the background task started, return
control to the user immediately. Do not poll the task, retrieve its output, or wait
for it to finish. Tell the user that `/tasks` can be used to inspect the local
submit process output: polling progress, any live log events emitted by the host,
and the final agent output when the run completes.

The script delegates to `offload.sh submit`, submits to `/v1/runs`, polls until completion, saves `result.patch` under `.git/offload/<run_id>.patch` and `result.agent_output` under `.git/offload/<run_id>.output.txt`, and displays that agent output when the background task finishes. Polled worker events remain in the separate temporary worker log.

After the background launch is confirmed, your task is complete. Report the
background task identifier or output path returned by Bash, mention `/tasks`, and
do not perform any additional analysis, edits, commands, follow-up tool calls, or
local work. The background process continues polling and saves completed
patch-mode results under `.git/offload/`. Do not rewrite the task prompt before
submitting it.
