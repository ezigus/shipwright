#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-detection test — Unit tests for detection fns   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: pipeline-detection Tests"

setup_test_env "sw-lib-pipeline-detection-test"
trap cleanup_test_env EXIT

mock_git
mock_gh
mock_claude

# Source the lib (needs PROJECT_ROOT set)
export PROJECT_ROOT="$TEST_TEMP_DIR/project"
_PIPELINE_DETECTION_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-detection.sh"

mkdir -p "$PROJECT_ROOT/scripts"
cat > "$PROJECT_ROOT/scripts/run-xcode-tests.sh" <<'SH'
#!/usr/bin/env bash
cat <<'HELP'
Usage: scripts/run-xcode-tests.sh [OPTIONS]
  -t <tests>        Use "Packages" to run every SwiftPM package test
  -p [suite]        Verify test plan coverage
  --help            Show this message
HELP
SH
chmod +x "$PROJECT_ROOT/scripts/run-xcode-tests.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# detect_test_cmd
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_test_cmd"

# Node.js project with npm
mkdir -p "$PROJECT_ROOT"
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"test":"jest --coverage"}}
JSON
result=$(detect_test_cmd)
assert_eq "Node.js project defaults to npm test" "npm test" "$result"

# Node.js with pnpm lock
touch "$PROJECT_ROOT/pnpm-lock.yaml"
result=$(detect_test_cmd)
assert_eq "pnpm lockfile detected" "pnpm test" "$result"
rm -f "$PROJECT_ROOT/pnpm-lock.yaml"

# Node.js with yarn lock
touch "$PROJECT_ROOT/yarn.lock"
result=$(detect_test_cmd)
assert_eq "yarn lockfile detected" "yarn test" "$result"
rm -f "$PROJECT_ROOT/yarn.lock"

# Node.js with bun lock
touch "$PROJECT_ROOT/bun.lockb"
result=$(detect_test_cmd)
assert_eq "bun lockfile detected" "bun test" "$result"
rm -f "$PROJECT_ROOT/bun.lockb"

# No test script in package.json
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"start":"node index.js"}}
JSON
rm -f "$PROJECT_ROOT/Cargo.toml" "$PROJECT_ROOT/go.mod" "$PROJECT_ROOT/Gemfile" "$PROJECT_ROOT/pom.xml" "$PROJECT_ROOT/build.gradle" "$PROJECT_ROOT/build.gradle.kts" "$PROJECT_ROOT/Makefile"
result=$(detect_test_cmd)
assert_eq "package.json without test script defaults to npm test" "npm test" "$result"

# "no test specified" placeholder
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}
JSON
result=$(detect_test_cmd)
assert_eq "npm 'no test specified' defaults to npm test" "npm test" "$result"
rm -f "$PROJECT_ROOT/package.json"

# SwiftPM defaults to helper script with Packages target
touch "$PROJECT_ROOT/Package.swift"
result=$(detect_test_cmd)
assert_eq "SwiftPM defaults to helper packages mode" "bash ./scripts/run-xcode-tests.sh -t Packages" "$result"
rm -f "$PROJECT_ROOT/Package.swift"

# iOS/Xcode defaults to helper script
mkdir -p "$PROJECT_ROOT/App.xcodeproj"
result=$(detect_test_cmd)
assert_eq "iOS defaults to helper script" "bash ./scripts/run-xcode-tests.sh" "$result"
rm -rf "$PROJECT_ROOT/App.xcodeproj"

# Mixed iOS + SwiftPM: full run covers packages — swiftpm deduped
mkdir -p "$PROJECT_ROOT/App.xcodeproj"
touch "$PROJECT_ROOT/Package.swift"
result=$(detect_test_cmd)
assert_eq "Mixed env: full suite covers packages (swiftpm deduped)" "bash ./scripts/run-xcode-tests.sh" "$result"
rm -rf "$PROJECT_ROOT/App.xcodeproj" "$PROJECT_ROOT/Package.swift"

# Python with pyproject.toml + pytest
cat > "$PROJECT_ROOT/pyproject.toml" <<'TOML'
[tool.pytest.ini_options]
testpaths = ["tests"]
TOML
result=$(detect_test_cmd)
assert_eq "Python pyproject.toml with pytest" "pytest" "$result"
rm -f "$PROJECT_ROOT/pyproject.toml"

# Python with setup.py + tests dir
cat > "$PROJECT_ROOT/setup.py" <<'PY'
from setuptools import setup
PY
mkdir -p "$PROJECT_ROOT/tests"
result=$(detect_test_cmd)
assert_eq "Python setup.py + tests dir" "pytest" "$result"
rm -f "$PROJECT_ROOT/setup.py"
rm -rf "$PROJECT_ROOT/tests"

# Rust
cat > "$PROJECT_ROOT/Cargo.toml" <<'TOML'
[package]
name = "test"
TOML
result=$(detect_test_cmd)
assert_eq "Rust project" "cargo test" "$result"
rm -f "$PROJECT_ROOT/Cargo.toml"

# Go
cat > "$PROJECT_ROOT/go.mod" <<'GO'
module example.com/test
GO
result=$(detect_test_cmd)
assert_eq "Go project" "go test ./..." "$result"
rm -f "$PROJECT_ROOT/go.mod"

# Ruby with rspec
cat > "$PROJECT_ROOT/Gemfile" <<'RUBY'
gem 'rspec'
RUBY
result=$(detect_test_cmd)
assert_eq "Ruby with rspec" "bundle exec rspec" "$result"

# Ruby without rspec
cat > "$PROJECT_ROOT/Gemfile" <<'RUBY'
gem 'rails'
RUBY
result=$(detect_test_cmd)
assert_eq "Ruby without rspec" "bundle exec rake test" "$result"
rm -f "$PROJECT_ROOT/Gemfile"

# Maven
touch "$PROJECT_ROOT/pom.xml"
result=$(detect_test_cmd)
assert_eq "Maven project" "mvn test" "$result"
rm -f "$PROJECT_ROOT/pom.xml"

# Gradle
touch "$PROJECT_ROOT/build.gradle"
result=$(detect_test_cmd)
assert_eq "Gradle project" "./gradlew test" "$result"
rm -f "$PROJECT_ROOT/build.gradle"

# Gradle Kotlin DSL
touch "$PROJECT_ROOT/build.gradle.kts"
result=$(detect_test_cmd)
assert_eq "Gradle Kotlin DSL project" "./gradlew test" "$result"
rm -f "$PROJECT_ROOT/build.gradle.kts"

# Makefile with test target
cat > "$PROJECT_ROOT/Makefile" <<'MAKE'
test:
	echo "running tests"
MAKE
result=$(detect_test_cmd)
assert_eq "Makefile with test target" "make test" "$result"
rm -f "$PROJECT_ROOT/Makefile"

# Empty project
result=$(detect_test_cmd)
assert_eq "Empty project returns empty" "" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# Environment inventory and context selection
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "environment selection"

mkdir -p "$PROJECT_ROOT/App.xcodeproj"
touch "$PROJECT_ROOT/Package.swift"
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"name":"test-project"}
JSON
envs=$(detect_repo_environments_json)
assert_contains "Detects iOS environment" "$envs" "\"ios_xcode\""
assert_contains "Detects SwiftPM environment" "$envs" "\"swiftpm\""
assert_contains "Detects Node environment" "$envs" "\"node\""
ios_marker=$(jq -r 'map(select(.id == "ios_xcode")) | first | .marker // ""' <<<"$envs")
assert_eq "iOS marker is repo-relative" "App.xcodeproj" "$ios_marker"

# Nested environments are detected (not root-only hierarchy)
rm -f "$PROJECT_ROOT/Package.swift" "$PROJECT_ROOT/package.json"
mkdir -p "$PROJECT_ROOT/apps/mobile"
touch "$PROJECT_ROOT/apps/mobile/Package.swift"
mkdir -p "$PROJECT_ROOT/apps/web"
cat > "$PROJECT_ROOT/apps/web/package.json" <<'JSON'
{"name":"nested-web"}
JSON
envs=$(detect_repo_environments_json)
assert_contains "Detects nested SwiftPM environment" "$envs" "apps/mobile/Package.swift"
assert_contains "Detects nested Node environment" "$envs" "apps/web/package.json"
result=$(detect_test_cmd)
assert_contains "Nested Node command executes in package directory" "$result" "(cd -- apps/web && npm test)"

changed='["Packages/CoreModels/Sources/CoreModels/Model.swift","Packages/CoreModels/Tests/CoreModelsTests/ModelTests.swift"]'
relevant=$(resolve_relevant_environments_json "$envs" "$changed")
assert_contains "SwiftPM selected for Packages/ source changes" "$relevant" "\"swiftpm\""
if echo "$relevant" | grep -q "\"node\""; then
    assert_fail "Node not selected for package-only changes" "unexpected node env: $relevant"
else
    assert_pass "Node not selected for package-only changes"
fi

changed='["web/src/app.ts"]'
relevant=$(resolve_relevant_environments_json "$envs" "$changed")
assert_contains "Node selected for JS/TS changes" "$relevant" "\"node\""

# collect_changed_files_json should not fall back to HEAD~1 history when tree is clean
cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK_GIT'
#!/usr/bin/env bash
if [[ "${1:-}" == "-C" ]]; then
    shift 2
fi
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--is-inside-work-tree" ]]; then
            echo "true"
        else
            echo "/tmp/mock-repo"
        fi
        ;;
    diff)
        if [[ "${2:-}" == "--name-only" && "${3:-}" == "HEAD~1" ]]; then
            echo "historical-only-change.txt"
        fi
        ;;
esac
exit 0
MOCK_GIT
chmod +x "$TEST_TEMP_DIR/bin/git"
changed_from_git=$(collect_changed_files_json)
assert_eq "collect_changed_files_json ignores HEAD~1 fallback" "[]" "$changed_from_git"
rm -rf "$PROJECT_ROOT/App.xcodeproj" "$PROJECT_ROOT/Package.swift" "$PROJECT_ROOT/package.json" "$PROJECT_ROOT/apps"

# command_discovery.enabled=false disables auto command selection
export SHIPWRIGHT_PIPELINE_COMMAND_DISCOVERY_ENABLED=false
result=$(detect_test_cmd)
assert_eq "command discovery can be disabled via config/env" "" "$result"
unset SHIPWRIGHT_PIPELINE_COMMAND_DISCOVERY_ENABLED

# ═══════════════════════════════════════════════════════════════════════════════
# detect_project_lang
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_project_lang"

# TypeScript
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"devDependencies":{"typescript":"^5.0"}}
JSON
result=$(detect_project_lang)
assert_eq "TypeScript detected" "typescript" "$result"

# Next.js
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"dependencies":{"next":"^14.0"}}
JSON
result=$(detect_project_lang)
assert_eq "Next.js detected" "nextjs" "$result"

# React
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"dependencies":{"react":"^18.0"}}
JSON
result=$(detect_project_lang)
assert_eq "React detected" "react" "$result"

# Plain Node.js
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"dependencies":{"express":"^4.0"}}
JSON
result=$(detect_project_lang)
assert_eq "Node.js detected" "nodejs" "$result"
rm -f "$PROJECT_ROOT/package.json"

# Rust
cat > "$PROJECT_ROOT/Cargo.toml" <<'TOML'
[package]
name = "test"
TOML
result=$(detect_project_lang)
assert_eq "Rust lang detected" "rust" "$result"
rm -f "$PROJECT_ROOT/Cargo.toml"

# Go
cat > "$PROJECT_ROOT/go.mod" <<'GO'
module example.com/test
GO
result=$(detect_project_lang)
assert_eq "Go lang detected" "go" "$result"
rm -f "$PROJECT_ROOT/go.mod"

# Python
cat > "$PROJECT_ROOT/requirements.txt" <<'PY'
flask==2.0
PY
result=$(detect_project_lang)
assert_eq "Python detected" "python" "$result"
rm -f "$PROJECT_ROOT/requirements.txt"

# Ruby
cat > "$PROJECT_ROOT/Gemfile" <<'RUBY'
gem 'rails'
RUBY
result=$(detect_project_lang)
assert_eq "Ruby detected" "ruby" "$result"
rm -f "$PROJECT_ROOT/Gemfile"

# Java
touch "$PROJECT_ROOT/pom.xml"
result=$(detect_project_lang)
assert_eq "Java detected" "java" "$result"
rm -f "$PROJECT_ROOT/pom.xml"

# Unknown
result=$(detect_project_lang)
assert_eq "Unknown for empty project" "unknown" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# detect_task_type (keyword fallback only — no Claude available)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_task_type"

assert_eq "Bug from 'fix' keyword" "bug" "$(detect_task_type "Fix the broken login")"
assert_eq "Bug from 'crash' keyword" "bug" "$(detect_task_type "App crashes on startup")"
assert_eq "Refactor keyword" "refactor" "$(detect_task_type "Refactor the database layer")"
assert_eq "Testing keyword" "testing" "$(detect_task_type "Add test coverage for auth")"
assert_eq "Security keyword" "security" "$(detect_task_type "Security audit for API")"
assert_eq "Docs keyword" "docs" "$(detect_task_type "Update the README guide")"
assert_eq "DevOps keyword" "devops" "$(detect_task_type "Setup CI pipeline")"
assert_eq "Migration keyword" "migration" "$(detect_task_type "Database migration for users")"
assert_eq "Architecture keyword" "architecture" "$(detect_task_type "Design new architecture RFC")"
assert_eq "Feature default" "feature" "$(detect_task_type "Add user profile page")"

# ═══════════════════════════════════════════════════════════════════════════════
# branch_prefix_for_type (fallback paths — no git branches)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "branch_prefix_for_type"

assert_eq "Bug prefix" "fix" "$(branch_prefix_for_type bug)"
assert_eq "Refactor prefix" "refactor" "$(branch_prefix_for_type refactor)"
assert_eq "Testing prefix" "test" "$(branch_prefix_for_type testing)"
assert_eq "Security prefix" "security" "$(branch_prefix_for_type security)"
assert_eq "Docs prefix" "docs" "$(branch_prefix_for_type docs)"
assert_eq "DevOps prefix" "ci" "$(branch_prefix_for_type devops)"
assert_eq "Migration prefix" "migrate" "$(branch_prefix_for_type migration)"
assert_eq "Architecture prefix" "arch" "$(branch_prefix_for_type architecture)"
assert_eq "Feature prefix (default)" "feat" "$(branch_prefix_for_type feature)"
assert_eq "Unknown type defaults to feat" "feat" "$(branch_prefix_for_type something_else)"

# ═══════════════════════════════════════════════════════════════════════════════
# template_for_type
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "template_for_type"

assert_eq "Bug template" "bug-fix" "$(template_for_type bug)"
assert_eq "Refactor template" "refactor" "$(template_for_type refactor)"
assert_eq "Testing template" "testing" "$(template_for_type testing)"
assert_eq "Security template" "security-audit" "$(template_for_type security)"
assert_eq "Docs template" "documentation" "$(template_for_type docs)"
assert_eq "DevOps template" "devops" "$(template_for_type devops)"
assert_eq "Migration template" "migration" "$(template_for_type migration)"
assert_eq "Architecture template" "architecture" "$(template_for_type architecture)"
assert_eq "Feature template" "feature-dev" "$(template_for_type feature)"
assert_eq "Unknown template" "feature-dev" "$(template_for_type other)"

# ═══════════════════════════════════════════════════════════════════════════════
# iOS smart test targeting
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "iOS smart test targeting"

# Setup: project with both xcodeproj and Package.swift (mixed iOS+SwiftPM repo)
mkdir -p "$PROJECT_ROOT/App.xcodeproj"
touch "$PROJECT_ROOT/Package.swift"
envs_mixed=$(detect_repo_environments_json)

# ── resolve_relevant_environments_json: package source → swiftpm only ─────────
changed_pkg='["Packages/PlaylistFeature/Sources/PlaylistFeature/Foo.swift"]'
relevant=$(resolve_relevant_environments_json "$envs_mixed" "$changed_pkg")
if echo "$relevant" | grep -q '"ios_xcode"'; then
    assert_fail "Package source: ios_xcode not activated" "ios_xcode unexpectedly present: $relevant"
else
    assert_pass "Package source: ios_xcode not activated"
fi
assert_contains "Package source: swiftpm activated" "$relevant" '"swiftpm"'

# ── resolve_relevant_environments_json: app source → ios_xcode, swiftpm deduped
changed_app='["zpod/Views/SomeView.swift"]'
relevant=$(resolve_relevant_environments_json "$envs_mixed" "$changed_app")
assert_contains "App source: ios_xcode activated" "$relevant" '"ios_xcode"'
if echo "$relevant" | grep -q '"swiftpm"'; then
    assert_fail "App source: swiftpm deduped when ios_xcode present" "swiftpm unexpectedly present: $relevant"
else
    assert_pass "App source: swiftpm deduped when ios_xcode present"
fi

# ── detect_changed_non_package_classes ───────────────────────────────────────
classes=$(detect_changed_non_package_classes '["zpod/Views/SomeView.swift"]')
assert_eq "Single non-package class extracted" "SomeView" "$classes"

classes=$(detect_changed_non_package_classes '["zpodUITests/BatchOperationUITests.swift","zpod/Views/BarView.swift"]')
assert_eq "Multiple non-package classes (sorted,deduped)" "BarView,BatchOperationUITests" "$classes"

classes=$(detect_changed_non_package_classes '["Packages/PlaylistFeature/Sources/Foo.swift"]')
assert_eq "Package files excluded from class extraction" "" "$classes"

classes=$(detect_changed_non_package_classes '[]')
assert_eq "Empty changed list returns empty" "" "$classes"

# ── detect_test_cmd: app source → class-targeted command ─────────────────────
cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-C" ]]; then shift 2; fi
case "${1:-}" in
    rev-parse) echo "true" ;;
    diff) printf 'zpod/Views/SomeView.swift\n' ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/git"
result=$(detect_test_cmd)
assert_eq "App source: class-targeted command" "bash ./scripts/run-xcode-tests.sh -t SomeView" "$result"

# ── detect_test_cmd: UITest file → class-targeted command ────────────────────
cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-C" ]]; then shift 2; fi
case "${1:-}" in
    rev-parse) echo "true" ;;
    diff) printf 'zpodUITests/BatchOperationUITests.swift\n' ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/git"
result=$(detect_test_cmd)
assert_eq "UITest file: class-targeted command" "bash ./scripts/run-xcode-tests.sh -t BatchOperationUITests" "$result"

# ── detect_test_cmd: multiple non-package files → comma-separated ─────────────
cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-C" ]]; then shift 2; fi
case "${1:-}" in
    rev-parse) echo "true" ;;
    diff) printf 'zpodUITests/FooTests.swift\nzpod/Views/BarView.swift\n' ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/git"
result=$(detect_test_cmd)
assert_eq "Multiple non-package files: comma-separated targeting" "bash ./scripts/run-xcode-tests.sh -t BarView,FooTests" "$result"

# ── detect_test_cmd: mixed package+app → ClassName,Packages ──────────────────
cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-C" ]]; then shift 2; fi
case "${1:-}" in
    rev-parse) echo "true" ;;
    diff) printf 'Packages/PlaylistFeature/Sources/Foo.swift\nzpod/AppDelegate.swift\n' ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/git"
result=$(detect_test_cmd)
assert_eq "Mixed package+app: combined ClassName,Packages targeting" "bash ./scripts/run-xcode-tests.sh -t AppDelegate,Packages" "$result"

# ── detect_test_cmd: package-only → -t Packages, no full Xcode suite ─────────
cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-C" ]]; then shift 2; fi
case "${1:-}" in
    rev-parse) echo "true" ;;
    diff) printf 'Packages/PlaylistFeature/Sources/PlaylistFeature/Foo.swift\n' ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/git"
result=$(detect_test_cmd)
assert_eq "Package-only: run-xcode-tests.sh -t Packages" "bash ./scripts/run-xcode-tests.sh -t Packages" "$result"

rm -rf "$PROJECT_ROOT/App.xcodeproj" "$PROJECT_ROOT/Package.swift"

print_test_results
