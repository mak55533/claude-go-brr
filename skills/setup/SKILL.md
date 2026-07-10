---
name: setup
description: Start, complete, or clear the Claude offload browser login flow.
argument-hint: "[start|login|logout|DEVICE_CODE]"
disable-model-invocation: true
allowed-tools: Bash
---

# Claude Go Brr Setup

Use this skill when the user invokes `/claude-go-brr:setup`.

Run this command exactly:

```bash
if [[ -x "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" ]]; then "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" "$ARGUMENTS"; elif [[ -x "$HOME/.claude/skills/claude-go-brr/scripts/setup.sh" ]]; then "$HOME/.claude/skills/claude-go-brr/scripts/setup.sh" "$ARGUMENTS"; else .claude/skills/claude-go-brr/scripts/setup.sh "$ARGUMENTS"; fi
```

If no device code is provided and auth already exists, the script requests the GitHub App install URL for the current repo. If auth does not exist, it starts GitHub login and prints a login URL plus the follow-up `/claude-go-brr:setup DEVICE_CODE` command.

If a device code is provided, the script exchanges it for a client token and saves `~/.config/offload/config`.

If `logout` is provided, the script moves the saved local offload config aside so a different GitHub account can sign in.

Report the script output directly.
