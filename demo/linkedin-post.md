<!-- LinkedIn Post — copy-paste ready -->

**Open-sourced my tmux setup for running Claude Code Agent Teams — 12 templates covering the full SDLC**

I've been using Claude Code's agent teams feature to run 2-3 AI agents in parallel — one on backend, one on frontend, one writing tests — all visible in tmux split panes.

After months of tuning, I open-sourced the whole setup: claude-code-teams-tmux

What it includes:

- 12 team templates covering the full software lifecycle:
  - Build: feature-dev, full-stack
  - Quality: code-review, security-audit, testing
  - Maintenance: bug-fix, refactor, migration
  - Planning: architecture, exploration
  - Operations: devops, documentation
- `cct` CLI to manage team sessions, autonomous loops, and setup
- Quality gate hooks that block agents until code passes typecheck/lint/tests
- `cct loop` for autonomous multi-iteration development
- Layout presets that give the leader pane 65% of screen space
- One-command setup: `cct init`

The most useful part is the continuous loop. You give it a goal and a test command:

    cct loop "Build user auth with JWT" --test-cmd "npm test" --audit

It runs Claude Code in a loop, verifying each iteration passes tests, with optional self-audit and quality gates. Walk away and come back to working code.

Templates let you scaffold a team in seconds:

    cct session my-pr --template security-audit

This creates a tmux window with 4 panes: leader (65% width) + code-analysis + dependencies + config-review agents.

Built with pure bash + jq. No Python, no Node runtime dependencies beyond what Claude Code already needs.

Check it out: https://github.com/sethdford/claude-code-teams-tmux

What SDLC workflows are you running with multi-agent AI? Would love to hear what patterns work for you.

#ClaudeCode #AIEngineering #tmux #DeveloperTools #OpenSource #AgentTeams #Anthropic #SoftwareEngineering #SDLC
