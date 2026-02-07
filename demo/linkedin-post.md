<!-- LinkedIn Post — copy-paste ready -->

**Open-sourced my tmux setup for running Claude Code Agent Teams**

I've been using Claude Code's agent teams feature to run 2-3 AI agents in parallel -- one on backend, one on frontend, one writing tests -- all visible in tmux split panes.

After months of tuning, I open-sourced the whole setup: claude-code-teams-tmux

What it does:

- Premium dark tmux theme with agent names in pane borders
- 12 team templates covering the full SDLC (feature-dev, testing, security-audit, bug-fix, migration, devops, and more)
- `cct` CLI to manage team sessions from templates
- Quality gate hooks that block agents until code passes typecheck/lint/tests
- `cct loop` for autonomous multi-iteration development (agent works until a goal is achieved)
- Layout presets that give the leader pane 65% of screen space
- One-command setup: `cct init`

The most useful part is the continuous loop. You give it a goal and a test command:

    cct loop "Build user auth with JWT" --test-cmd "npm test" --audit

It runs Claude Code in a loop, verifying each iteration passes tests, with optional self-audit and quality gates. Walk away and come back to working code.

Templates let you scaffold a team in seconds:

    cct session my-feature --template feature-dev

This creates a tmux window with 4 panes: leader (65% width) + backend + frontend + tests agents.

Built with pure bash + jq. No Python, no Node runtime dependencies beyond what Claude Code already needs.

Check it out: https://github.com/sethdford/claude-code-teams-tmux

Would love feedback from anyone running multi-agent AI workflows. What patterns have you found that work?

#ClaudeCode #AIEngineering #tmux #DeveloperTools #OpenSource #AgentTeams #Anthropic #SoftwareEngineering
