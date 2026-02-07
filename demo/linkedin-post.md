<!-- LinkedIn Post — copy-paste ready -->

**I got tired of watching Claude Code agents stomp on each other's files, so I built a tmux setup to fix it.**

Here's what kept happening: I'd tell Claude Code to spin up a team — backend agent, frontend agent, test agent — and they'd all cram into one terminal. No visibility into who's doing what. Agents editing the same files. Context windows blowing up because I gave one agent too many tasks.

So I started building a tmux wrapper around it. Split panes so I can see each agent working. Templates so I don't have to explain the team composition every time. Quality gates so agents can't say "I'm done" when there are TypeScript errors.

It's called `cct` (Claude Code Teams) and I just open-sourced it.

The thing I use the most is `cct loop`:

    cct loop "Build user auth with JWT" --test-cmd "npm test" --audit

It runs Claude in a loop — build, test, self-review, repeat — until the tests pass. I've walked away from my desk and come back to working features. Not always, but often enough that it changed how I work.

There are 12 team templates covering most of what I do day to day — feature dev, bug fixes, security audits, migrations, code review, testing, architecture planning. Each one assigns agents to different files so they don't conflict.

The whole thing is bash + jq. No Python, no frameworks, nothing fancy.

If you're running Claude Code agent teams and fighting the same problems I was, check it out: https://github.com/sethdford/claude-code-teams-tmux

What's working (and not working) for you with multi-agent AI dev? Genuinely curious.

#ClaudeCode #AIEngineering #DeveloperTools #OpenSource
