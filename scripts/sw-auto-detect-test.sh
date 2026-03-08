#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright auto-detect test — Validates project detection library       ║
# ║  Tests detect_project(), recommend_template(), detect_base_branch(),     ║
# ║  and generate_daemon_config() across 7 languages + edge cases.           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$SCRIPT_DIR/lib/detect.sh"

# ─── Temp dir ─────────────────────────────────────────────────────────────────
setup_project() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-detect-test.XXXXXX")
    mkdir -p "$TEST_TEMP_DIR/project"
}

cleanup_project() {
    [[ -n "${TEST_TEMP_DIR:-}" && -d "${TEST_TEMP_DIR:-}" ]] && rm -rf "$TEST_TEMP_DIR"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST CASES
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Test 1: Node.js with Express + Jest ─────────────────────────────────────
test_detect_nodejs() {
    setup_project
    cat > "$TEST_TEMP_DIR/project/package.json" << 'EOF'
{
  "name": "my-app",
  "scripts": { "test": "jest", "build": "tsc", "lint": "eslint ." },
  "dependencies": { "express": "^4.18.0" },
  "devDependencies": { "jest": "^29.0.0" }
}
EOF

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project

    assert_eq "Node.js language detection" "nodejs" "$DETECTED_LANG"
    assert_eq "Express framework detection" "express" "$DETECTED_FRAMEWORK"
    assert_eq "Jest test framework" "jest" "$DETECTED_TEST_FRAMEWORK"
    assert_eq "npm package manager" "npm" "$DETECTED_PKG_MANAGER"
    assert_eq "npm test command" "npm test" "$DETECTED_TEST_CMD"
    assert_eq "npm build command" "npm run build" "$DETECTED_BUILD_CMD"
    assert_eq "npm lint command" "npm run lint" "$DETECTED_LINT_CMD"
    cleanup_project
}

# ─── Test 2: TypeScript with Next.js + Vitest ────────────────────────────────
test_detect_typescript() {
    setup_project
    cat > "$TEST_TEMP_DIR/project/package.json" << 'EOF'
{
  "name": "next-app",
  "scripts": { "test": "vitest", "build": "next build" },
  "dependencies": { "next": "^14.0.0", "react": "^18.0.0" },
  "devDependencies": { "typescript": "^5.0.0", "vitest": "^1.0.0" }
}
EOF
    touch "$TEST_TEMP_DIR/project/pnpm-lock.yaml"

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project

    assert_eq "TypeScript language detection" "typescript" "$DETECTED_LANG"
    assert_eq "Next.js framework detection" "next.js" "$DETECTED_FRAMEWORK"
    assert_eq "Vitest test framework" "vitest" "$DETECTED_TEST_FRAMEWORK"
    assert_eq "pnpm package manager" "pnpm" "$DETECTED_PKG_MANAGER"
    cleanup_project
}

# ─── Test 3: Go with Gin ─────────────────────────────────────────────────────
test_detect_go() {
    setup_project
    cat > "$TEST_TEMP_DIR/project/go.mod" << 'EOF'
module example.com/myapp

go 1.21

require github.com/gin-gonic/gin v1.9.0
EOF

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project

    assert_eq "Go language detection" "go" "$DETECTED_LANG"
    assert_eq "Gin framework detection" "gin" "$DETECTED_FRAMEWORK"
    assert_eq "Go test command" "go test ./..." "$DETECTED_TEST_CMD"
    assert_eq "Go build command" "go build ./..." "$DETECTED_BUILD_CMD"
    assert_eq "Go modules pkg manager" "go modules" "$DETECTED_PKG_MANAGER"
    cleanup_project
}

# ─── Test 4: Rust with Axum ──────────────────────────────────────────────────
test_detect_rust() {
    setup_project
    cat > "$TEST_TEMP_DIR/project/Cargo.toml" << 'EOF'
[package]
name = "my-api"
version = "0.1.0"

[dependencies]
axum = "0.7"
tokio = { version = "1", features = ["full"] }
EOF

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project

    assert_eq "Rust language detection" "rust" "$DETECTED_LANG"
    assert_eq "Axum framework detection" "axum" "$DETECTED_FRAMEWORK"
    assert_eq "Cargo test command" "cargo test" "$DETECTED_TEST_CMD"
    assert_eq "Cargo package manager" "cargo" "$DETECTED_PKG_MANAGER"
    cleanup_project
}

# ─── Test 5: Python with FastAPI + Pytest ─────────────────────────────────────
test_detect_python() {
    setup_project
    cat > "$TEST_TEMP_DIR/project/pyproject.toml" << 'EOF'
[project]
name = "my-api"
dependencies = ["fastapi>=0.100.0", "uvicorn"]

[tool.pytest.ini_options]
testpaths = ["tests"]
EOF
    mkdir -p "$TEST_TEMP_DIR/project/tests"

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project

    assert_eq "Python language detection" "python" "$DETECTED_LANG"
    assert_eq "FastAPI framework detection" "fastapi" "$DETECTED_FRAMEWORK"
    assert_eq "Pytest test command" "pytest" "$DETECTED_TEST_CMD"
    assert_eq "Pytest test framework" "pytest" "$DETECTED_TEST_FRAMEWORK"
    assert_eq "pip package manager" "pip" "$DETECTED_PKG_MANAGER"
    cleanup_project
}

# ─── Test 6: Ruby with Rails + RSpec ─────────────────────────────────────────
test_detect_ruby() {
    setup_project
    cat > "$TEST_TEMP_DIR/project/Gemfile" << 'EOF'
source 'https://rubygems.org'
gem 'rails', '~> 7.0'
gem 'rspec-rails', group: :test
EOF

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project

    assert_eq "Ruby language detection" "ruby" "$DETECTED_LANG"
    assert_eq "Rails framework detection" "rails" "$DETECTED_FRAMEWORK"
    assert_eq "RSpec test command" "bundle exec rspec" "$DETECTED_TEST_CMD"
    assert_eq "RSpec test framework" "rspec" "$DETECTED_TEST_FRAMEWORK"
    assert_eq "Bundler package manager" "bundler" "$DETECTED_PKG_MANAGER"
    cleanup_project
}

# ─── Test 7: Java with Maven + Spring Boot ───────────────────────────────────
test_detect_java_maven() {
    setup_project
    cat > "$TEST_TEMP_DIR/project/pom.xml" << 'EOF'
<project>
  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.2.0</version>
  </parent>
  <artifactId>my-app</artifactId>
</project>
EOF

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project

    assert_eq "Java language detection" "java" "$DETECTED_LANG"
    assert_eq "Spring Boot framework" "spring-boot" "$DETECTED_FRAMEWORK"
    assert_eq "Maven test command" "mvn test" "$DETECTED_TEST_CMD"
    assert_eq "Maven package manager" "maven" "$DETECTED_PKG_MANAGER"
    cleanup_project
}

# ─── Test 8: Java with Gradle ────────────────────────────────────────────────
test_detect_java_gradle() {
    setup_project
    cat > "$TEST_TEMP_DIR/project/build.gradle" << 'EOF'
plugins {
    id 'org.springframework.boot' version '3.2.0'
    id 'java'
}
EOF

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project

    assert_eq "Java Gradle language detection" "java" "$DETECTED_LANG"
    assert_eq "Spring Boot (Gradle)" "spring-boot" "$DETECTED_FRAMEWORK"
    assert_eq "Gradle test command" "./gradlew test" "$DETECTED_TEST_CMD"
    assert_eq "Gradle package manager" "gradle" "$DETECTED_PKG_MANAGER"
    cleanup_project
}

# ─── Test 9: Empty repo — graceful fallback ──────────────────────────────────
test_detect_empty_repo() {
    setup_project

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project

    assert_eq "Empty repo → unknown language" "unknown" "$DETECTED_LANG"
    assert_eq "Empty repo → no framework" "" "$DETECTED_FRAMEWORK"
    assert_eq "Empty repo → no test cmd" "" "$DETECTED_TEST_CMD"
    assert_eq "Empty repo → no CI" "false" "$DETECTED_HAS_CI"
    assert_eq "Empty repo → no Docker" "false" "$DETECTED_HAS_DOCKER"
    cleanup_project
}

# ─── Test 10: Makefile fallbacks ─────────────────────────────────────────────
test_detect_makefile_fallback() {
    setup_project
    # Use printf to avoid tab issues with heredoc
    printf 'test:\n\techo "running tests"\n\nbuild:\n\techo "building"\n\nlint:\n\techo "linting"\n' \
        > "$TEST_TEMP_DIR/project/Makefile"

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project

    assert_eq "Makefile-only → unknown language" "unknown" "$DETECTED_LANG"
    assert_eq "Makefile test fallback" "make test" "$DETECTED_TEST_CMD"
    assert_eq "Makefile build fallback" "make build" "$DETECTED_BUILD_CMD"
    assert_eq "Makefile lint fallback" "make lint" "$DETECTED_LINT_CMD"
    cleanup_project
}

# ─── Test 11: Infrastructure detection ───────────────────────────────────────
test_detect_infra() {
    setup_project
    cat > "$TEST_TEMP_DIR/project/package.json" << 'EOF'
{ "name": "app", "scripts": { "test": "jest" }, "devDependencies": { "jest": "^29" } }
EOF
    touch "$TEST_TEMP_DIR/project/Dockerfile"
    mkdir -p "$TEST_TEMP_DIR/project/.github/workflows"

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project

    assert_eq "Docker detection" "true" "$DETECTED_HAS_DOCKER"
    assert_eq "CI detection (GitHub Actions)" "true" "$DETECTED_HAS_CI"
    cleanup_project
}

# ─── Test 12: Template recommendation ────────────────────────────────────────
test_recommend_template_standard() {
    setup_project
    cat > "$TEST_TEMP_DIR/project/package.json" << 'EOF'
{ "name": "app", "scripts": { "test": "vitest" }, "devDependencies": { "vitest": "^1" }, "dependencies": { "express": "^4" } }
EOF

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project
    local tpl
    tpl=$(recommend_template)

    assert_eq "Standard template for app with tests" "standard" "$tpl"
    cleanup_project
}

test_recommend_template_full() {
    setup_project
    cat > "$TEST_TEMP_DIR/project/package.json" << 'EOF'
{ "name": "app", "scripts": { "test": "jest" }, "devDependencies": { "jest": "^29" } }
EOF
    touch "$TEST_TEMP_DIR/project/Dockerfile"
    mkdir -p "$TEST_TEMP_DIR/project/.github/workflows"

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project
    local tpl
    tpl=$(recommend_template)

    assert_eq "Full template for CI + Docker project" "full" "$tpl"
    cleanup_project
}

test_recommend_template_fast() {
    setup_project
    touch "$TEST_TEMP_DIR/project/script.sh"

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project
    local tpl
    tpl=$(recommend_template)

    assert_eq "Fast template for minimal project" "fast" "$tpl"
    cleanup_project
}

# ─── Test 13: Config generation ──────────────────────────────────────────────
test_generate_daemon_config() {
    setup_project
    cat > "$TEST_TEMP_DIR/project/package.json" << 'EOF'
{ "name": "app", "scripts": { "test": "vitest" }, "devDependencies": { "vitest": "^1" } }
EOF

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project
    PROJECT_ROOT="$TEST_TEMP_DIR/project" generate_daemon_config
    local rc=$?

    assert_eq "Config generation succeeds" "0" "$rc"
    assert_file_exists "Config file created" "$TEST_TEMP_DIR/project/.claude/daemon-config.json"

    if command -v jq >/dev/null 2>&1; then
        jq . "$TEST_TEMP_DIR/project/.claude/daemon-config.json" >/dev/null 2>&1
        assert_eq "Generated config is valid JSON" "0" "$?"

        local tpl
        tpl=$(jq -r '.pipeline_template' "$TEST_TEMP_DIR/project/.claude/daemon-config.json")
        assert_eq "Config template is standard" "standard" "$tpl"

        local test_cmd
        test_cmd=$(jq -r '.loop.test_cmd' "$TEST_TEMP_DIR/project/.claude/daemon-config.json")
        assert_eq "Config test_cmd is npm test" "npm test" "$test_cmd"
    fi
    cleanup_project
}

# ─── Test 14: Existing config not overwritten ────────────────────────────────
test_existing_config_preserved() {
    setup_project
    mkdir -p "$TEST_TEMP_DIR/project/.claude"
    echo '{"custom": true}' > "$TEST_TEMP_DIR/project/.claude/daemon-config.json"

    cat > "$TEST_TEMP_DIR/project/package.json" << 'EOF'
{ "name": "app", "scripts": { "test": "vitest" }, "devDependencies": { "vitest": "^1" } }
EOF

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project
    PROJECT_ROOT="$TEST_TEMP_DIR/project" generate_daemon_config || true
    local rc=$?

    # generate_daemon_config returns 1 when file exists, but || true swallows it
    # Check that the file content is unchanged instead
    local content
    content=$(cat "$TEST_TEMP_DIR/project/.claude/daemon-config.json")
    assert_eq "Existing config preserved" '{"custom": true}' "$content"
    cleanup_project
}

# ─── Test 15: Python with Poetry ─────────────────────────────────────────────
test_detect_python_poetry() {
    setup_project
    cat > "$TEST_TEMP_DIR/project/pyproject.toml" << 'EOF'
[tool.poetry]
name = "my-project"

[tool.poetry.dependencies]
python = "^3.11"
django = "^4.2"

[tool.pytest.ini_options]
testpaths = ["tests"]
EOF

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project

    assert_eq "Python (Poetry) detection" "python" "$DETECTED_LANG"
    assert_eq "Poetry package manager" "poetry" "$DETECTED_PKG_MANAGER"
    assert_eq "Django framework" "django" "$DETECTED_FRAMEWORK"
    assert_eq "Pytest from pyproject.toml" "pytest" "$DETECTED_TEST_CMD"
    cleanup_project
}

# ─── Test 16: Monorepo — root package.json wins ─────────────────────────────
test_detect_monorepo() {
    setup_project
    cat > "$TEST_TEMP_DIR/project/package.json" << 'EOF'
{ "name": "monorepo", "scripts": { "test": "vitest" }, "devDependencies": { "vitest": "^1", "typescript": "^5" } }
EOF
    cat > "$TEST_TEMP_DIR/project/go.mod" << 'EOF'
module example.com/service
go 1.21
EOF

    _SW_DETECT_LOADED="" ; source "$SCRIPT_DIR/lib/detect.sh"
    PROJECT_ROOT="$TEST_TEMP_DIR/project" detect_project

    assert_eq "Monorepo: package.json wins" "typescript" "$DETECTED_LANG"
    cleanup_project
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_detect_nodejs
test_detect_typescript
test_detect_go
test_detect_rust
test_detect_python
test_detect_ruby
test_detect_java_maven
test_detect_java_gradle
test_detect_empty_repo
test_detect_makefile_fallback
test_detect_infra
test_recommend_template_standard
test_recommend_template_full
test_recommend_template_fast
test_generate_daemon_config
test_existing_config_preserved
test_detect_python_poetry
test_detect_monorepo

# ─── Summary ─────────────────────────────────────────────────────────────────
print_test_results
