#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#   shipwright detect — Shared project detection library
#   Source this from any script: source "$SCRIPT_DIR/lib/detect.sh"
#
#   Provides:
#     detect_project()         — sets DETECTED_* globals
#     recommend_template()     — echoes "fast"|"standard"|"full"
#     detect_base_branch()     — echoes "main"|"master"|<branch>
#     generate_daemon_config() — writes .claude/daemon-config.json
# ═══════════════════════════════════════════════════════════════════

# ─── Double-source guard ─────────────────────────────────────────
[[ -n "${_SW_DETECT_LOADED:-}" ]] && return 0
_SW_DETECT_LOADED=1

# ─── detect_project() ────────────────────────────────────────────
# Input:  PROJECT_ROOT (env var, defaults to pwd)
# Output: Sets DETECTED_LANG, DETECTED_FRAMEWORK, DETECTED_TEST_CMD,
#         DETECTED_BUILD_CMD, DETECTED_PKG_MANAGER, DETECTED_TEST_FRAMEWORK,
#         DETECTED_LINT_CMD, DETECTED_HAS_CI, DETECTED_HAS_DOCKER
# Errors: Never fails — unknown projects get empty/default values
detect_project() {
    local root="${PROJECT_ROOT:-$(pwd)}"

    # Initialize all globals
    DETECTED_LANG="unknown"
    DETECTED_FRAMEWORK=""
    DETECTED_TEST_CMD=""
    DETECTED_BUILD_CMD=""
    DETECTED_PKG_MANAGER=""
    DETECTED_TEST_FRAMEWORK=""
    DETECTED_LINT_CMD=""
    DETECTED_HAS_CI="false"
    DETECTED_HAS_DOCKER="false"

    # ── Language & Framework detection (priority order) ──

    if [[ -f "$root/package.json" ]]; then
        _detect_nodejs "$root"
    elif [[ -f "$root/go.mod" ]]; then
        _detect_go "$root"
    elif [[ -f "$root/Cargo.toml" ]]; then
        _detect_rust "$root"
    elif [[ -f "$root/pyproject.toml" ]] || [[ -f "$root/setup.py" ]] || [[ -f "$root/requirements.txt" ]]; then
        _detect_python "$root"
    elif [[ -f "$root/Gemfile" ]]; then
        _detect_ruby "$root"
    elif [[ -f "$root/pom.xml" ]]; then
        _detect_java_maven "$root"
    elif [[ -f "$root/build.gradle" ]] || [[ -f "$root/build.gradle.kts" ]]; then
        _detect_java_gradle "$root"
    fi

    # ── Infrastructure detection ──
    if [[ -f "$root/Dockerfile" ]] || [[ -f "$root/docker-compose.yml" ]] || \
       [[ -f "$root/docker-compose.yaml" ]] || [[ -f "$root/compose.yml" ]]; then
        DETECTED_HAS_DOCKER="true"
    fi
    if [[ -d "$root/.github/workflows" ]] || [[ -d "$root/.circleci" ]] || \
       [[ -f "$root/.gitlab-ci.yml" ]] || [[ -f "$root/Jenkinsfile" ]]; then
        DETECTED_HAS_CI="true"
    fi

    # ── Makefile fallbacks ──
    if [[ -f "$root/Makefile" ]]; then
        [[ -z "$DETECTED_TEST_CMD" ]] && grep -q "^test:" "$root/Makefile" 2>/dev/null && DETECTED_TEST_CMD="make test"
        [[ -z "$DETECTED_BUILD_CMD" ]] && grep -q "^build:" "$root/Makefile" 2>/dev/null && DETECTED_BUILD_CMD="make build"
        [[ -z "$DETECTED_LINT_CMD" ]] && grep -q "^lint:" "$root/Makefile" 2>/dev/null && DETECTED_LINT_CMD="make lint"
    fi
}

# ─── Node.js / TypeScript detection ──────────────────────────────
_detect_nodejs() {
    local root="$1"
    DETECTED_LANG="nodejs"

    local deps
    deps=$(cat "$root/package.json" 2>/dev/null) || return 0

    # Framework detection from dependencies
    if echo "$deps" | grep -q '"next"' 2>/dev/null; then
        DETECTED_FRAMEWORK="next.js"
        DETECTED_LANG="typescript"
    elif echo "$deps" | grep -q '"nuxt"' 2>/dev/null; then
        DETECTED_FRAMEWORK="nuxt"
        DETECTED_LANG="typescript"
    elif echo "$deps" | grep -q '"@angular/core"' 2>/dev/null; then
        DETECTED_FRAMEWORK="angular"
        DETECTED_LANG="typescript"
    elif echo "$deps" | grep -q '"@nestjs/core"' 2>/dev/null; then
        DETECTED_FRAMEWORK="nestjs"
        DETECTED_LANG="typescript"
    elif echo "$deps" | grep -q '"vue"' 2>/dev/null; then
        DETECTED_FRAMEWORK="vue"
    elif echo "$deps" | grep -q '"react"' 2>/dev/null; then
        DETECTED_FRAMEWORK="react"
    elif echo "$deps" | grep -q '"express"' 2>/dev/null; then
        DETECTED_FRAMEWORK="express"
    elif echo "$deps" | grep -q '"fastify"' 2>/dev/null; then
        DETECTED_FRAMEWORK="fastify"
    elif echo "$deps" | grep -q '"hono"' 2>/dev/null; then
        DETECTED_FRAMEWORK="hono"
    fi

    # TypeScript override
    if echo "$deps" | grep -q '"typescript"' 2>/dev/null; then
        DETECTED_LANG="typescript"
    fi

    # Test framework detection
    if echo "$deps" | grep -q '"vitest"' 2>/dev/null; then
        DETECTED_TEST_FRAMEWORK="vitest"
    elif echo "$deps" | grep -q '"jest"' 2>/dev/null; then
        DETECTED_TEST_FRAMEWORK="jest"
    elif echo "$deps" | grep -q '"mocha"' 2>/dev/null; then
        DETECTED_TEST_FRAMEWORK="mocha"
    elif echo "$deps" | grep -q '"ava"' 2>/dev/null; then
        DETECTED_TEST_FRAMEWORK="ava"
    fi

    # Package manager detection
    if [[ -f "$root/pnpm-lock.yaml" ]]; then
        DETECTED_PKG_MANAGER="pnpm"
    elif [[ -f "$root/yarn.lock" ]]; then
        DETECTED_PKG_MANAGER="yarn"
    elif [[ -f "$root/bun.lockb" ]] || [[ -f "$root/bun.lock" ]]; then
        DETECTED_PKG_MANAGER="bun"
    else
        DETECTED_PKG_MANAGER="npm"
    fi

    # Commands from package.json scripts
    local scripts_json
    scripts_json=$(jq -r '.scripts // {}' "$root/package.json" 2>/dev/null || echo "{}")

    local has_test
    has_test=$(echo "$scripts_json" | jq -r '.test // ""' 2>/dev/null || echo "")
    if [[ -n "$has_test" && "$has_test" != "null" && "$has_test" != *"no test specified"* ]]; then
        DETECTED_TEST_CMD="${DETECTED_PKG_MANAGER} test"
    fi

    local has_build
    has_build=$(echo "$scripts_json" | jq -r '.build // ""' 2>/dev/null || echo "")
    if [[ -n "$has_build" && "$has_build" != "null" ]]; then
        DETECTED_BUILD_CMD="${DETECTED_PKG_MANAGER} run build"
    fi

    local has_lint
    has_lint=$(echo "$scripts_json" | jq -r '.lint // ""' 2>/dev/null || echo "")
    if [[ -n "$has_lint" && "$has_lint" != "null" ]]; then
        DETECTED_LINT_CMD="${DETECTED_PKG_MANAGER} run lint"
    fi
}

# ─── Go detection ────────────────────────────────────────────────
_detect_go() {
    local root="$1"
    DETECTED_LANG="go"
    DETECTED_PKG_MANAGER="go modules"
    DETECTED_TEST_CMD="go test ./..."
    DETECTED_BUILD_CMD="go build ./..."
    DETECTED_LINT_CMD="golangci-lint run"

    if grep -q "gin-gonic" "$root/go.mod" 2>/dev/null; then
        DETECTED_FRAMEWORK="gin"
    elif grep -q "labstack/echo" "$root/go.mod" 2>/dev/null; then
        DETECTED_FRAMEWORK="echo"
    elif grep -q "go-chi/chi" "$root/go.mod" 2>/dev/null; then
        DETECTED_FRAMEWORK="chi"
    elif grep -q "gofiber/fiber" "$root/go.mod" 2>/dev/null; then
        DETECTED_FRAMEWORK="fiber"
    fi
}

# ─── Rust detection ──────────────────────────────────────────────
_detect_rust() {
    local root="$1"
    DETECTED_LANG="rust"
    DETECTED_PKG_MANAGER="cargo"
    DETECTED_TEST_CMD="cargo test"
    DETECTED_BUILD_CMD="cargo build"
    DETECTED_LINT_CMD="cargo clippy"

    if grep -q "actix-web" "$root/Cargo.toml" 2>/dev/null; then
        DETECTED_FRAMEWORK="actix-web"
    elif grep -q "axum" "$root/Cargo.toml" 2>/dev/null; then
        DETECTED_FRAMEWORK="axum"
    elif grep -q "rocket" "$root/Cargo.toml" 2>/dev/null; then
        DETECTED_FRAMEWORK="rocket"
    fi
}

# ─── Python detection ────────────────────────────────────────────
_detect_python() {
    local root="$1"
    DETECTED_LANG="python"

    # Package manager
    if [[ -f "$root/pyproject.toml" ]]; then
        if grep -q "poetry" "$root/pyproject.toml" 2>/dev/null; then
            DETECTED_PKG_MANAGER="poetry"
        elif grep -q "pdm" "$root/pyproject.toml" 2>/dev/null; then
            DETECTED_PKG_MANAGER="pdm"
        else
            DETECTED_PKG_MANAGER="pip"
        fi
    else
        DETECTED_PKG_MANAGER="pip"
    fi

    # Framework detection
    local py_deps=""
    [[ -f "$root/requirements.txt" ]] && py_deps=$(cat "$root/requirements.txt" 2>/dev/null)
    [[ -f "$root/pyproject.toml" ]] && py_deps="$py_deps$(cat "$root/pyproject.toml" 2>/dev/null)"
    if echo "$py_deps" | grep -qi "django" 2>/dev/null; then
        DETECTED_FRAMEWORK="django"
    elif echo "$py_deps" | grep -qi "fastapi" 2>/dev/null; then
        DETECTED_FRAMEWORK="fastapi"
    elif echo "$py_deps" | grep -qi "flask" 2>/dev/null; then
        DETECTED_FRAMEWORK="flask"
    fi

    # Test command
    if [[ -f "$root/pyproject.toml" ]] && grep -q "pytest" "$root/pyproject.toml" 2>/dev/null; then
        DETECTED_TEST_CMD="pytest"
        DETECTED_TEST_FRAMEWORK="pytest"
    elif [[ -d "$root/tests" ]]; then
        DETECTED_TEST_CMD="pytest"
        DETECTED_TEST_FRAMEWORK="pytest"
    fi

    DETECTED_LINT_CMD="ruff check ."
}

# ─── Ruby detection ──────────────────────────────────────────────
_detect_ruby() {
    local root="$1"
    DETECTED_LANG="ruby"
    DETECTED_PKG_MANAGER="bundler"

    if grep -q "rails" "$root/Gemfile" 2>/dev/null; then
        DETECTED_FRAMEWORK="rails"
        DETECTED_TEST_CMD="bundle exec rails test"
    fi
    if grep -q "rspec" "$root/Gemfile" 2>/dev/null; then
        DETECTED_TEST_CMD="bundle exec rspec"
        DETECTED_TEST_FRAMEWORK="rspec"
    else
        DETECTED_TEST_FRAMEWORK="minitest"
    fi
    DETECTED_LINT_CMD="bundle exec rubocop"
}

# ─── Java (Maven) detection ──────────────────────────────────────
_detect_java_maven() {
    local root="$1"
    DETECTED_LANG="java"
    DETECTED_PKG_MANAGER="maven"
    DETECTED_TEST_CMD="mvn test"
    DETECTED_BUILD_CMD="mvn package"

    if grep -qE "spring-boot|springframework\.boot" "$root/pom.xml" 2>/dev/null; then
        DETECTED_FRAMEWORK="spring-boot"
    fi
}

# ─── Java (Gradle) detection ─────────────────────────────────────
_detect_java_gradle() {
    local root="$1"
    DETECTED_LANG="java"
    DETECTED_PKG_MANAGER="gradle"
    DETECTED_TEST_CMD="./gradlew test"
    DETECTED_BUILD_CMD="./gradlew build"

    if grep -qE "spring-boot|springframework\.boot" "$root/build.gradle" 2>/dev/null || \
       grep -qE "spring-boot|springframework\.boot" "$root/build.gradle.kts" 2>/dev/null; then
        DETECTED_FRAMEWORK="spring-boot"
    fi
}

# ─── recommend_template() ────────────────────────────────────────
# Input:  Reads DETECTED_* globals (call detect_project() first)
# Output: Echoes "fast"|"standard"|"full" to stdout
recommend_template() {
    if [[ "${DETECTED_HAS_CI:-false}" == "true" ]] && [[ "${DETECTED_HAS_DOCKER:-false}" == "true" ]]; then
        echo "full"
    elif [[ -z "${DETECTED_FRAMEWORK:-}" ]] && [[ -z "${DETECTED_TEST_CMD:-}" ]] && [[ "${DETECTED_HAS_CI:-false}" == "false" ]]; then
        echo "fast"
    else
        echo "standard"
    fi
}

# ─── detect_base_branch() ────────────────────────────────────────
# Input:  PROJECT_ROOT (env var, defaults to pwd)
# Output: Echoes branch name to stdout
detect_base_branch() {
    local root="${PROJECT_ROOT:-$(pwd)}"

    # Try git symbolic-ref for the remote HEAD
    if command -v git >/dev/null 2>&1; then
        local remote_head
        remote_head=$(git -C "$root" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
        if [[ -n "$remote_head" ]]; then
            echo "$remote_head"
            return 0
        fi

        # Fallback: check if main or master exist
        if git -C "$root" rev-parse --verify refs/heads/main >/dev/null 2>&1; then
            echo "main"
            return 0
        elif git -C "$root" rev-parse --verify refs/heads/master >/dev/null 2>&1; then
            echo "master"
            return 0
        fi
    fi

    echo "main"
}

# ─── generate_daemon_config() ────────────────────────────────────
# Input:  All DETECTED_* globals, PROJECT_ROOT
# Output: Writes .claude/daemon-config.json
# Returns: 0 on success, 1 if file already exists
generate_daemon_config() {
    local root="${PROJECT_ROOT:-$(pwd)}"
    local config_file="$root/.claude/daemon-config.json"

    # Never overwrite existing config
    if [[ -f "$config_file" ]]; then
        return 1
    fi

    mkdir -p "$root/.claude"

    local template
    template=$(recommend_template)

    local base_branch
    base_branch=$(detect_base_branch)

    local test_cmd="${DETECTED_TEST_CMD:-}"
    local lang="${DETECTED_LANG:-unknown}"

    # Build config with jq for proper JSON escaping
    local tmp
    tmp=$(mktemp)

    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg template "$template" \
            --arg test_cmd "$test_cmd" \
            --arg base_branch "$base_branch" \
            --arg lang "$lang" \
            --arg framework "${DETECTED_FRAMEWORK:-}" \
            --arg pkg_manager "${DETECTED_PKG_MANAGER:-}" \
            '{
                "pipeline_template": $template,
                "base_branch": $base_branch,
                "max_parallel": 2,
                "max_retries": 2,
                "auto_template": false,
                "loop": {
                    "max_iterations": 20,
                    "test_cmd": $test_cmd
                },
                "plan": {
                    "timeout": 120
                },
                "_detected": {
                    "language": $lang,
                    "framework": $framework,
                    "package_manager": $pkg_manager,
                    "generated_by": "shipwright init --auto-detect"
                }
            }' > "$tmp" && mv "$tmp" "$config_file"
    else
        # Fallback without jq — heredoc with safe values
        cat > "$tmp" << HEREDOC_EOF
{
  "pipeline_template": "${template}",
  "base_branch": "${base_branch}",
  "max_parallel": 2,
  "max_retries": 2,
  "auto_template": false,
  "loop": {
    "max_iterations": 20,
    "test_cmd": "${test_cmd}"
  },
  "plan": {
    "timeout": 120
  },
  "_detected": {
    "language": "${lang}",
    "framework": "${DETECTED_FRAMEWORK:-}",
    "package_manager": "${DETECTED_PKG_MANAGER:-}",
    "generated_by": "shipwright init --auto-detect"
  }
}
HEREDOC_EOF
        mv "$tmp" "$config_file"
    fi

    # Emit event if helpers are available
    if [[ "$(type -t emit_event 2>/dev/null)" == "function" ]]; then
        emit_event "detect" "action=generate_config" "lang=$lang" "template=$template" 2>/dev/null || true
    fi

    return 0
}
