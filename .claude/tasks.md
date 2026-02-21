# Tasks — Add shell completion installation to shipwright init

## Status: In Progress
Pipeline: autonomous | Branch: feat/add-shell-completion-installation-to-shi-1

## Checklist
- [ ] **Task 1**: Add `elif [[ "${SHELL:-}" == *"fish"* ]]; then SHELL_TYPE="fish"` to the shell detection block in `sw-init.sh`
- [ ] **Task 2**: Add fish completion installation block (`elif [[ "$SHELL_TYPE" == "fish" ]]`) in `sw-init.sh` before the closing `fi` of the completion section
- [ ] **Task 3**: Add fish case to the reload instructions block in `sw-init.sh`
- [ ] **Task 4**: Add idempotency check (already-installed guard) to the zsh installation block in `sw-init.sh`
- [ ] **Task 5**: Add idempotency check (already-installed guard) to the bash installation block in `sw-init.sh`
- [ ] **Task 6**: Write `test_zsh_completions_installed` in `sw-init-test.sh`
- [ ] **Task 7**: Write `test_zsh_fpath_configured` in `sw-init-test.sh`
- [ ] **Task 8**: Write `test_bash_completions_installed` in `sw-init-test.sh`
- [ ] **Task 9**: Write `test_fish_completions_installed` in `sw-init-test.sh`
- [ ] **Task 10**: Write `test_completions_idempotent` in `sw-init-test.sh`
- [ ] **Task 11**: Register new tests in the "Run All Tests" section under a "Shell Completions" group header
- [ ] **Task 12**: Run `npm test` and verify all 21 existing tests still pass plus the 5 new ones

## Notes
- Generated from pipeline plan at 2026-02-21T11:55:34Z
- Pipeline will update status as tasks complete
