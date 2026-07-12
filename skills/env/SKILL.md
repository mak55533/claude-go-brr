---
name: env
description: Show offload project environment variable key names and the browser settings URL.
argument-hint: "[-d DIR]"
disable-model-invocation: true
allowed-tools: Bash
---

# Claude Go Brr Env

Use this skill when the user invokes `/claude-go-brr:env`.

Run this command exactly:

```bash
if [[ -x "${CLAUDE_PLUGIN_ROOT}/scripts/env.sh" ]]; then "${CLAUDE_PLUGIN_ROOT}/scripts/env.sh" "$ARGUMENTS"; elif [[ -x "$HOME/.claude/skills/claude-go-brr/scripts/env.sh" ]]; then "$HOME/.claude/skills/claude-go-brr/scripts/env.sh" "$ARGUMENTS"; else .claude/skills/claude-go-brr/scripts/env.sh "$ARGUMENTS"; fi
```

The script delegates to `offload.sh env`, which derives the current project's `folder_id`, fetches metadata containing env variable key names only, and prints the project settings URL.

Env variable VALUES are set in the browser, never through this command. This command must not accept, request, echo, or store secret values.

Report the script output directly.
