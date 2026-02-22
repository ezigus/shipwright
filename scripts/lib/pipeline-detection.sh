# pipeline-detection.sh — Auto-detection (test cmd, lang, reviewers, task type) for sw-pipeline.sh
# Source from sw-pipeline.sh. Requires SCRIPT_DIR, REPO_DIR.
[[ -n "${_PIPELINE_DETECTION_LOADED:-}" ]] && return 0
_PIPELINE_DETECTION_LOADED=1

_pipeline_cd_get() {
    local key="$1" fallback="${2:-}"
    if [[ "$(type -t _config_get 2>/dev/null)" == "function" ]]; then
        _config_get "$key" "$fallback"
    else
        echo "$fallback"
    fi
}

_pipeline_cd_help_args() {
    _pipeline_cd_get "pipeline.command_discovery.help_args" "--help"
}

_pipeline_cd_helpers_json() {
    local configured
    configured=$(_pipeline_cd_get "pipeline.command_discovery.helpers" "")
    if [[ -n "$configured" && "$configured" != "null" && "$configured" != "[]" ]]; then
        echo "$configured"
        return
    fi
    # Universal default: run-xcode-tests helper powers iOS + SwiftPM.
    cat <<'JSON'
[{
  "id": "xcode_runner",
  "script": "scripts/run-xcode-tests.sh",
  "environments": ["ios_xcode", "swiftpm"],
  "help_args": "--help",
  "parser": "xcode_runner_help_v1",
  "default_mode": "unit",
  "mode_flags": {
    "swiftpm_all": "-t Packages"
  },
  "prefer_helper": true
}]
JSON
}

_append_env_json() {
    local envs_json="$1" env_id="$2" marker="$3"
    jq -c --arg id "$env_id" --arg marker "$marker" \
        'if any(.[]; .id == $id) then . else . + [{"id": $id, "marker": $marker}] end' <<<"$envs_json"
}

detect_repo_environments_json() {
    local root="${PROJECT_ROOT:-$(pwd)}"
    local envs='[]'
    local max_depth
    max_depth=$(_pipeline_cd_get "pipeline.command_discovery.search_max_depth" "6")
    local xc_workspace xc_project
    xc_workspace=$(find "$root" -maxdepth "$max_depth" -name "*.xcworkspace" 2>/dev/null | head -1 || true)
    xc_project=$(find "$root" -maxdepth "$max_depth" -name "*.xcodeproj" 2>/dev/null | head -1 || true)

    if [[ -n "$xc_workspace" || -n "$xc_project" ]]; then
        envs=$(_append_env_json "$envs" "ios_xcode" "${xc_workspace:-$xc_project}")
    fi
    local swiftpm_marker
    swiftpm_marker=$(find "$root" -maxdepth "$max_depth" -name "Package.swift" 2>/dev/null | head -1 || true)
    if [[ -n "$swiftpm_marker" ]]; then
        envs=$(_append_env_json "$envs" "swiftpm" "${swiftpm_marker#$root/}")
    fi
    local node_marker
    node_marker=$(find "$root" -maxdepth "$max_depth" -name "package.json" -type f 2>/dev/null | head -1 || true)
    if [[ -n "$node_marker" ]]; then
        envs=$(_append_env_json "$envs" "node" "${node_marker#$root/}")
    fi
    local python_marker
    python_marker=$(find "$root" -maxdepth "$max_depth" \( -name "pyproject.toml" -o -name "setup.py" -o -name "requirements.txt" -o -name "pytest.ini" \) -type f 2>/dev/null | head -1 || true)
    if [[ -n "$python_marker" ]]; then
        envs=$(_append_env_json "$envs" "python" "${python_marker#$root/}")
    fi
    local go_marker
    go_marker=$(find "$root" -maxdepth "$max_depth" -name "go.mod" -type f 2>/dev/null | head -1 || true)
    if [[ -n "$go_marker" ]]; then
        envs=$(_append_env_json "$envs" "go" "${go_marker#$root/}")
    fi
    local rust_marker
    rust_marker=$(find "$root" -maxdepth "$max_depth" -name "Cargo.toml" -type f 2>/dev/null | head -1 || true)
    if [[ -n "$rust_marker" ]]; then
        envs=$(_append_env_json "$envs" "rust" "${rust_marker#$root/}")
    fi
    local ruby_marker
    ruby_marker=$(find "$root" -maxdepth "$max_depth" -name "Gemfile" -type f 2>/dev/null | head -1 || true)
    if [[ -n "$ruby_marker" ]]; then
        envs=$(_append_env_json "$envs" "ruby" "${ruby_marker#$root/}")
    fi
    local maven_marker
    maven_marker=$(find "$root" -maxdepth "$max_depth" -name "pom.xml" -type f 2>/dev/null | head -1 || true)
    if [[ -n "$maven_marker" ]]; then
        envs=$(_append_env_json "$envs" "java_maven" "${maven_marker#$root/}")
    fi
    local gradle_marker
    gradle_marker=$(find "$root" -maxdepth "$max_depth" \( -name "build.gradle" -o -name "build.gradle.kts" \) -type f 2>/dev/null | head -1 || true)
    if [[ -n "$gradle_marker" ]]; then
        envs=$(_append_env_json "$envs" "java_gradle" "${gradle_marker#$root/}")
    fi
    local make_marker
    make_marker=$(find "$root" -maxdepth "$max_depth" -name "Makefile" -type f 2>/dev/null | head -1 || true)
    if [[ -n "$make_marker" ]] && grep -q "^test:" "$make_marker" 2>/dev/null; then
        envs=$(_append_env_json "$envs" "make" "${make_marker#$root/}")
    fi

    echo "$envs"
}

default_test_cmd_for_environment() {
    local env_id="$1"
    local root="${PROJECT_ROOT:-$(pwd)}"
    case "$env_id" in
        ios_xcode)
            if [[ -x "$root/scripts/run-xcode-tests.sh" ]]; then
                echo "bash ./scripts/run-xcode-tests.sh"
            else
                echo "xcodebuild test"
            fi
            ;;
        swiftpm)
            if [[ -x "$root/scripts/run-xcode-tests.sh" ]]; then
                echo "bash ./scripts/run-xcode-tests.sh -t Packages"
            else
                echo "swift test"
            fi
            ;;
        node)
            if [[ -f "$root/pnpm-lock.yaml" ]]; then
                echo "pnpm test"
            elif [[ -f "$root/yarn.lock" ]]; then
                echo "yarn test"
            elif [[ -f "$root/bun.lockb" ]]; then
                echo "bun test"
            else
                echo "npm test"
            fi
            ;;
        python) echo "pytest" ;;
        go) echo "go test ./..." ;;
        rust) echo "cargo test" ;;
        ruby)
            if [[ -f "$root/Gemfile" ]] && grep -q "rspec" "$root/Gemfile" 2>/dev/null; then
                echo "bundle exec rspec"
            else
                echo "bundle exec rake test"
            fi
            ;;
        java_maven) echo "mvn test" ;;
        java_gradle) echo "./gradlew test" ;;
        make) echo "make test" ;;
        *) echo "" ;;
    esac
}

parse_helper_help_output() {
    local parser_id="$1" output="$2"
    local flags='{}'
    case "$parser_id" in
        xcode_runner_help_v1)
            if echo "$output" | grep -q 'use "Packages" to run every SwiftPM package test'; then
                flags=$(jq -c '. + {"swiftpm_all":"-t Packages"}' <<<"$flags")
            fi
            if echo "$output" | grep -q '\-p \[suite\]'; then
                flags=$(jq -c '. + {"integration":"-p IntegrationTests","ui":"-p zpodUITests","smoke":"-p AppSmokeTests"}' <<<"$flags")
            fi
            ;;
        *)
            ;;
    esac
    echo "$flags"
}

detect_helper_capabilities_json() {
    local root="${PROJECT_ROOT:-$(pwd)}"
    local helpers_json
    helpers_json=$(_pipeline_cd_helpers_json)
    local global_help
    global_help=$(_pipeline_cd_help_args)
    local out='[]'
    local helper
    while IFS= read -r helper; do
        [[ -z "$helper" ]] && continue
        local script help_args parser mode_flags parsed_flags merged_flags default_mode prefer_helper
        script=$(jq -r '.script // ""' <<<"$helper")
        [[ -z "$script" ]] && continue
        [[ ! -f "$root/$script" ]] && continue
        help_args=$(jq -r --arg g "$global_help" '.help_args // $g' <<<"$helper")
        parser=$(jq -r '.parser // "generic_usage_v1"' <<<"$helper")
        mode_flags=$(jq -c '.mode_flags // {}' <<<"$helper")
        default_mode=$(jq -r '.default_mode // "unit"' <<<"$helper")
        prefer_helper=$(jq -r '.prefer_helper // true' <<<"$helper")
        local help_output=""
        # Introspect helper capabilities without failing the pipeline when helper exits non-zero.
        help_output=$(bash "$root/$script" $help_args 2>&1 || true)
        parsed_flags=$(parse_helper_help_output "$parser" "$help_output")
        merged_flags=$(jq -c -s '.[0] * .[1]' <(echo "$mode_flags") <(echo "$parsed_flags"))
        out=$(jq -c --argjson helper "$(jq -c --arg h "$help_args" --arg m "$default_mode" --arg p "$prefer_helper" --argjson mf "$merged_flags" '. + {help_args:$h, default_mode:$m, prefer_helper:($p=="true"), mode_flags:$mf}' <<<"$helper")" '. + [$helper]' <<<"$out")
    done < <(jq -c '.[]?' <<<"$helpers_json")
    echo "$out"
}

collect_changed_files_json() {
    local root="${PROJECT_ROOT:-$(pwd)}"
    if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "[]"
        return
    fi
    local files
    files=$( (git -C "$root" diff --name-only 2>/dev/null;
              git -C "$root" diff --cached --name-only 2>/dev/null;
              git -C "$root" diff --name-only HEAD~1 2>/dev/null) | awk 'NF' | sort -u )
    jq -Rsc 'split("\n") | map(select(length > 0))' <<<"$files"
}

resolve_relevant_environments_json() {
    local envs_json="$1" changed_files_json="$2"
    local changed_count
    changed_count=$(jq 'length' <<<"$changed_files_json" 2>/dev/null || echo 0)
    if [[ "$changed_count" -eq 0 ]]; then
        jq -c '[.[].id]' <<<"$envs_json"
        return
    fi

    local relevant='[]'
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        case "$f" in
            *.swift|*.m|*.mm|*.h|*.xib|*.storyboard|*.xcworkspace/*|*.xcodeproj/*|*.pbxproj)
                relevant=$(jq -c '. + ["ios_xcode"]' <<<"$relevant")
                ;;
        esac
        case "$f" in
            Package.swift|*/Package.swift|Sources/*|*/Sources/*|Tests/*|*/Tests/*)
                relevant=$(jq -c '. + ["swiftpm"]' <<<"$relevant")
                ;;
        esac
        case "$f" in
            *.js|*.jsx|*.ts|*.tsx|package.json|pnpm-lock.yaml|yarn.lock|bun.lockb)
                relevant=$(jq -c '. + ["node"]' <<<"$relevant")
                ;;
        esac
        case "$f" in *.py|pyproject.toml|requirements.txt|setup.py|pytest.ini) relevant=$(jq -c '. + ["python"]' <<<"$relevant") ;; esac
        case "$f" in *.go|go.mod) relevant=$(jq -c '. + ["go"]' <<<"$relevant") ;; esac
        case "$f" in *.rs|Cargo.toml) relevant=$(jq -c '. + ["rust"]' <<<"$relevant") ;; esac
        case "$f" in *.rb|Gemfile) relevant=$(jq -c '. + ["ruby"]' <<<"$relevant") ;; esac
        case "$f" in pom.xml|*.java) relevant=$(jq -c '. + ["java_maven"]' <<<"$relevant") ;; esac
        case "$f" in build.gradle|build.gradle.kts|*.kt) relevant=$(jq -c '. + ["java_gradle"]' <<<"$relevant") ;; esac
        case "$f" in Makefile) relevant=$(jq -c '. + ["make"]' <<<"$relevant") ;; esac
    done < <(jq -r '.[]' <<<"$changed_files_json")

    local filtered
    filtered=$(jq -c --argjson envs "$envs_json" 'unique | map(select(. as $id | any($envs[]; .id == $id)))' <<<"$relevant")
    if [[ "$(jq 'length' <<<"$filtered")" -eq 0 ]]; then
        jq -c '[.[].id]' <<<"$envs_json"
    else
        echo "$filtered"
    fi
}

resolve_test_mode_for_env() {
    local env_id="$1" changed_files_json="$2"
    local mode_map default_map mode=""
    default_map='{"UITests":"ui","integration":"integration","Package.swift":"swiftpm_all"}'
    mode_map=$(_pipeline_cd_get "pipeline.command_discovery.mode_map" "$default_map")

    local pattern
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        if jq -r '.[]' <<<"$changed_files_json" | grep -q "$pattern" 2>/dev/null; then
            mode=$(jq -r --arg p "$pattern" '.[$p]' <<<"$mode_map")
            break
        fi
    done < <(jq -r 'keys[]?' <<<"$mode_map" 2>/dev/null || true)

    if [[ -n "$mode" ]]; then
        echo "$mode"
        return
    fi

    if [[ "$env_id" == "swiftpm" ]]; then
        echo "swiftpm_all"
    else
        echo "unit"
    fi
}

select_test_commands_for_context_json() {
    local enabled
    enabled=$(_pipeline_cd_get "pipeline.command_discovery.enabled" "true")
    case "$enabled" in
        false|0|off|no)
            echo "[]"
            return
            ;;
    esac

    local envs_json changed_files_json relevant_envs helpers_json
    envs_json=$(detect_repo_environments_json)
    changed_files_json=$(collect_changed_files_json)
    relevant_envs=$(resolve_relevant_environments_json "$envs_json" "$changed_files_json")
    helpers_json=$(detect_helper_capabilities_json)

    local out='[]'
    local env_id
    while IFS= read -r env_id; do
        [[ -z "$env_id" ]] && continue
        local mode cmd helper
        mode=$(resolve_test_mode_for_env "$env_id" "$changed_files_json")
        helper=$(jq -c --arg env "$env_id" 'map(select((.prefer_helper // true) and (.environments // [] | index($env)))) | first // empty' <<<"$helpers_json")
        cmd=""
        if [[ -n "$helper" ]]; then
            local script helper_flags
            script=$(jq -r '.script // ""' <<<"$helper")
            helper_flags=$(jq -r --arg mode "$mode" '.mode_flags[$mode] // ""' <<<"$helper")
            if [[ -n "$script" ]]; then
                cmd="bash ./${script}"
                [[ -n "$helper_flags" ]] && cmd="${cmd} ${helper_flags}"
            fi
        fi
        if [[ -z "$cmd" ]]; then
            cmd=$(default_test_cmd_for_environment "$env_id")
        fi
        [[ -z "$cmd" ]] && continue
        out=$(jq -c --arg env "$env_id" --arg mode "$mode" --arg cmd "$cmd" '. + [{"env":$env,"mode":$mode,"cmd":$cmd}]' <<<"$out")
    done < <(jq -r '.[]' <<<"$relevant_envs")
    echo "$out"
}

detect_test_cmd() {
    local selected separator
    selected=$(select_test_commands_for_context_json)
    separator=$(_pipeline_cd_get "pipeline.command_discovery.execution.separator" " && ")
    jq -r --arg sep "$separator" 'map(.cmd) | unique | join($sep)' <<<"$selected"
}

# Detect project language/framework
detect_project_lang() {
    local root="$PROJECT_ROOT"
    local detected=""

    # Fast heuristic detection (grep-based)
    if find "$root" -maxdepth 1 -name "*.xcodeproj" 2>/dev/null | grep -q .; then
        detected="swift"
    elif find "$root" -maxdepth 1 -name "*.xcworkspace" 2>/dev/null | grep -q .; then
        detected="swift"
    elif [[ -f "$root/Package.swift" ]]; then
        detected="swift"
    elif [[ -f "$root/package.json" ]]; then
        if grep -q "typescript" "$root/package.json" 2>/dev/null; then
            detected="typescript"
        elif grep -q "\"next\"" "$root/package.json" 2>/dev/null; then
            detected="nextjs"
        elif grep -q "\"react\"" "$root/package.json" 2>/dev/null; then
            detected="react"
        else
            detected="nodejs"
        fi
    elif [[ -f "$root/Cargo.toml" ]]; then
        detected="rust"
    elif [[ -f "$root/go.mod" ]]; then
        detected="go"
    elif [[ -f "$root/pyproject.toml" || -f "$root/setup.py" || -f "$root/requirements.txt" ]]; then
        detected="python"
    elif [[ -f "$root/Gemfile" ]]; then
        detected="ruby"
    elif [[ -f "$root/pom.xml" || -f "$root/build.gradle" ]]; then
        detected="java"
    else
        detected="unknown"
    fi

    # Intelligence: holistic analysis for polyglot/monorepo detection
    if [[ "$detected" == "unknown" ]] && type intelligence_search_memory >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
        local config_files
        config_files=$(ls "$root" 2>/dev/null | grep -E '\.(json|toml|yaml|yml|xml|gradle|lock|mod)$' | head -15)
        if [[ -n "$config_files" ]]; then
            local ai_lang
            ai_lang=$(claude --print --output-format text -p "Based on these config files in a project root, what is the primary language/framework? Reply with ONE word (e.g., typescript, python, rust, go, java, ruby, nodejs):

Files: ${config_files}" --model haiku < /dev/null 2>/dev/null || true)
            ai_lang=$(echo "$ai_lang" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            case "$ai_lang" in
                typescript|python|rust|go|java|ruby|nodejs|react|nextjs|kotlin|swift|elixir|scala)
                    detected="$ai_lang" ;;
            esac
        fi
    fi

    echo "$detected"
}

# Detect likely reviewers from CODEOWNERS or git log
detect_reviewers() {
    local root="$PROJECT_ROOT"

    # Check CODEOWNERS — common paths first, then broader search
    local codeowners=""
    for f in "$root/.github/CODEOWNERS" "$root/CODEOWNERS" "$root/docs/CODEOWNERS"; do
        if [[ -f "$f" ]]; then
            codeowners="$f"
            break
        fi
    done
    # Broader search if not found at common locations
    if [[ -z "$codeowners" ]]; then
        codeowners=$(find "$root" -maxdepth 3 -name "CODEOWNERS" -type f 2>/dev/null | head -1 || true)
    fi

    if [[ -n "$codeowners" ]]; then
        # Extract GitHub usernames from CODEOWNERS (lines like: * @user1 @user2)
        local owners
        owners=$(grep -oE '@[a-zA-Z0-9_-]+' "$codeowners" 2>/dev/null | sed 's/@//' | sort -u | head -3 | tr '\n' ',')
        owners="${owners%,}"  # trim trailing comma
        if [[ -n "$owners" ]]; then
            echo "$owners"
            return
        fi
    fi

    # Fallback: try to extract GitHub usernames from recent commit emails
    # Format: user@users.noreply.github.com → user, or noreply+user@... → user
    local current_user
    current_user=$(gh api user --jq '.login' 2>/dev/null || true)
    local contributors
    contributors=$(git log --format='%aE' -100 2>/dev/null | \
        grep -oE '[a-zA-Z0-9_-]+@users\.noreply\.github\.com' | \
        sed 's/@users\.noreply\.github\.com//' | sed 's/^[0-9]*+//' | \
        sort | uniq -c | sort -rn | \
        awk '{print $NF}' | \
        grep -v "^${current_user:-___}$" 2>/dev/null | \
        head -2 | tr '\n' ',')
    contributors="${contributors%,}"
    echo "$contributors"
}

# Get branch prefix from task type — checks git history for conventions first
branch_prefix_for_type() {
    local task_type="$1"

    # Analyze recent branches for naming conventions
    local branch_prefixes
    branch_prefixes=$(git branch -r 2>/dev/null | sed 's#origin/##' | grep -oE '^[a-z]+/' | sort | uniq -c | sort -rn | head -5 || true)
    if [[ -n "$branch_prefixes" ]]; then
        local total_branches dominant_prefix dominant_count
        total_branches=$(echo "$branch_prefixes" | awk '{s+=$1} END {print s}' || echo "0")
        dominant_prefix=$(echo "$branch_prefixes" | head -1 | awk '{print $2}' | tr -d '/' || true)
        dominant_count=$(echo "$branch_prefixes" | head -1 | awk '{print $1}' || echo "0")
        # If >80% of branches use a pattern, adopt it for the matching type
        if [[ "$total_branches" -gt 5 ]] && [[ "$dominant_count" -gt 0 ]]; then
            local pct=$(( (dominant_count * 100) / total_branches ))
            if [[ "$pct" -gt 80 && -n "$dominant_prefix" ]]; then
                # Map task type to the repo's convention
                local mapped=""
                case "$task_type" in
                    bug)      mapped=$(echo "$branch_prefixes" | awk '{print $2}' | tr -d '/' | grep -E '^(fix|bug|hotfix)$' | head -1 || true) ;;
                    feature)  mapped=$(echo "$branch_prefixes" | awk '{print $2}' | tr -d '/' | grep -E '^(feat|feature)$' | head -1 || true) ;;
                esac
                if [[ -n "$mapped" ]]; then
                    echo "$mapped"
                    return
                fi
            fi
        fi
    fi

    # Fallback: hardcoded mapping
    case "$task_type" in
        bug)          echo "fix" ;;
        refactor)     echo "refactor" ;;
        testing)      echo "test" ;;
        security)     echo "security" ;;
        docs)         echo "docs" ;;
        devops)       echo "ci" ;;
        migration)    echo "migrate" ;;
        architecture) echo "arch" ;;
        *)            echo "feat" ;;
    esac
}

# ─── State Management ──────────────────────────────────────────────────────

PIPELINE_STATUS="pending"
CURRENT_STAGE=""
STARTED_AT=""
UPDATED_AT=""
STAGE_STATUSES=""
LOG_ENTRIES=""

detect_task_type() {
    local goal="$1"

    # Intelligence: Claude classification with confidence score
    if type intelligence_search_memory >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
        local ai_result
        ai_result=$(claude --print --output-format text -p "Classify this task into exactly ONE category. Reply in format: CATEGORY|CONFIDENCE (0-100)

Categories: bug, refactor, testing, security, docs, devops, migration, architecture, feature

Task: ${goal}" --model haiku < /dev/null 2>/dev/null || true)
        if [[ -n "$ai_result" ]]; then
            local ai_type ai_conf
            ai_type=$(echo "$ai_result" | head -1 | cut -d'|' -f1 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            ai_conf=$(echo "$ai_result" | head -1 | cut -d'|' -f2 | grep -oE '[0-9]+' | head -1 || echo "0")
            # Use AI classification if confidence >= 70
            case "$ai_type" in
                bug|refactor|testing|security|docs|devops|migration|architecture|feature)
                    if [[ "${ai_conf:-0}" -ge 70 ]] 2>/dev/null; then
                        echo "$ai_type"
                        return
                    fi
                    ;;
            esac
        fi
    fi

    # Fallback: keyword matching
    local lower
    lower=$(echo "$goal" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        *fix*|*bug*|*broken*|*error*|*crash*)     echo "bug" ;;
        *refactor*|*clean*|*reorganize*|*extract*) echo "refactor" ;;
        *test*|*coverage*|*spec*)                  echo "testing" ;;
        *security*|*audit*|*vuln*|*cve*)           echo "security" ;;
        *doc*|*readme*|*guide*)                    echo "docs" ;;
        *deploy*|*ci*|*pipeline*|*docker*|*infra*) echo "devops" ;;
        *migrate*|*migration*|*schema*)            echo "migration" ;;
        *architect*|*design*|*rfc*|*adr*)          echo "architecture" ;;
        *)                                          echo "feature" ;;
    esac
}

template_for_type() {
    case "$1" in
        bug)          echo "bug-fix" ;;
        refactor)     echo "refactor" ;;
        testing)      echo "testing" ;;
        security)     echo "security-audit" ;;
        docs)         echo "documentation" ;;
        devops)       echo "devops" ;;
        migration)    echo "migration" ;;
        architecture) echo "architecture" ;;
        *)            echo "feature-dev" ;;
    esac
}

# ─── Stage Preview ──────────────────────────────────────────────────────────
