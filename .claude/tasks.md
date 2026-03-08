# Tasks — Zero-config quick start with auto-detection and instant setup

## Status: In Progress
Pipeline: standard | Branch: feat/zero-config-quick-start-with-auto-detect-79

## Checklist
- [ ] Task 1: Create `scripts/lib/detect.sh` with `detect_project()` function — consolidate language, framework, test cmd, pkg manager, and infra detection from sw-prep.sh
- [ ] Task 2: Add `recommend_template()` to `lib/detect.sh` — maps detected project to optimal pipeline template
- [ ] Task 3: Add `generate_daemon_config()` to `lib/detect.sh` — generates tailored daemon-config.json with detected values
- [ ] Task 4: Enhance `scripts/sw-init.sh` — add Phase 0 (auto-detect + config generation) and `--no-detect` flag
- [ ] Task 5: Refactor `scripts/sw-setup.sh` Phase 2 — delegate to shared `lib/detect.sh`
- [ ] Task 6: Create `scripts/sw-auto-detect-test.sh` — tests for Node, TypeScript, Go, Rust, Python project detection
- [ ] Task 7: Add test cases for Ruby, Java, empty repo, and existing config scenarios
- [ ] Task 8: Add template recommendation tests — verify correct template selection per project type
- [ ] Task 9: Run full test suite (`npm test`) and fix any regressions
- [ ] Task 10: Verify end-to-end: clone a fresh repo, run `shipwright init`, confirm <2 minute setup
- [ ] `shipwright init` on a fresh Node.js repo auto-detects language, framework, test cmd, pkg manager
- [ ] `shipwright init` generates `.claude/daemon-config.json` with detected values
- [ ] `shipwright init` selects correct pipeline template based on project type
- [ ] `shipwright init` runs doctor automatically at the end
- [ ] Setup completes in <2 minutes on a fresh repo
- [ ] Detection works for Node.js, TypeScript, Go, Rust, Python, Ruby, Java (7 types)
- [ ] Graceful fallback to generic defaults when no project files detected
- [ ] Existing daemon-config.json is never overwritten
- [ ] `--no-detect` flag allows skipping auto-detection
- [ ] All existing tests pass (`npm test`)

## Notes
- Generated from pipeline plan at 2026-03-08T16:53:02Z
- Pipeline will update status as tasks complete
