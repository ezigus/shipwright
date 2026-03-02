# Pipeline Tasks — Add shell completion installation to shipwright init

## Implementation Checklist
- [x] Task 1: Verify `completions/` directory exists with `_shipwright`, `shipwright.bash`, `shipwright.fish`
- [x] Task 2: Add Shell Completions section header comment to `sw-init.sh`
- [x] Task 3: Implement shell type detection from `$SHELL` (not `$BASH_VERSION`)
- [x] Task 4: Implement zsh completion copy to `~/.zsh/completions/_shipwright`
- [x] Task 5: Implement `fpath` injection into `~/.zshrc` (idempotent, checks before appending)
- [x] Task 6: Implement `compinit` line injection into `~/.zshrc` (idempotent)
- [x] Task 7: Implement bash completion copy to `~/.local/share/bash-completion/completions/shipwright`
- [x] Task 8: Implement bash `source` line injection into `~/.bashrc` (idempotent)
- [x] Task 9: Implement fish completion copy to `~/.config/fish/completions/shipwright.fish`
- [x] Task 10: Print reload hint after successful installation
- [x] Task 11: Add `test_zsh_completions_installed` test with `SHELL=/bin/zsh`
- [x] Task 12: Add `test_zsh_fpath_configured` test asserting `.zshrc` fpath entry
- [x] Task 13: Add `test_bash_completions_installed` test with `SHELL=/bin/bash`
- [x] Task 14: Add `test_fish_completions_installed` test with `SHELL=/usr/local/bin/fish`
- [x] Task 15: Add `test_completions_idempotent` test running init twice and verifying no corruption

## Context
- Pipeline: autonomous
- Branch: feat/add-shell-completion-installation-to-shi-1
- Issue: #1
- Generated: 2026-02-21T17:07:58Z
