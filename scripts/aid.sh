#!/usr/bin/env bash
#
# aid - Autonomous AI workflow for OpenCode
#
# Usage:
#   aid                              Open OpenCode TUI interactively for user to provide task
#   aid <github-issue-url>           Work on a GitHub issue (TUI mode)
#   aid <github-pr-url>              Work on a GitHub PR (TUI mode)
#   aid "task description"           Work on a plain text task (TUI mode)
#   aid review <pr-url>              Review a PR and post feedback (TUI mode, read-only)
#   aid list                         List active dispatch sessions
#   aid view <session-id>            View session details and optionally resume
#   aid cleanup [--failed|--all] [--force]  Clean up sessions
#   aid resume <session-id>          Resume a previous session
#   aid help                         Show help message
#   aid --version                    Show version information
#
# Environment:
#   AID_DEBUG=1                      Enable debug output
#   AID_DRY_RUN=1                    Show what would be done without executing
#   AID_NO_CONTEXT=1                 Disable task context injection

set -euo pipefail

# ==============================================================================
# Version
# ==============================================================================

readonly VERSION="0.2.0"

# ==============================================================================
# Configuration
# ==============================================================================

readonly OPENCODE_CONFIG_DIR="${HOME}/.config/opencode"
readonly DISPATCH_DIR="${OPENCODE_CONFIG_DIR}/dispatch"
readonly WORKTREES_DIR="${OPENCODE_CONFIG_DIR}/worktrees"
readonly TASKS_DIR="${OPENCODE_CONFIG_DIR}/tasks"

# Colors for output (bash 3.2 compatible)
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[0;33m')
BLUE=$(printf '\033[0;34m')
CYAN=$(printf '\033[0;36m')
BOLD=$(printf '\033[1m')
NC=$(printf '\033[0m')

# ==============================================================================
# Utility Functions
# ==============================================================================

log_info() {
    printf '%b\n' "${BLUE}[info]${NC} $*"
}

log_success() {
    printf '%b\n' "${GREEN}[done]${NC} $*"
}

log_warn() {
    printf '%b\n' "${YELLOW}[warn]${NC} $*"
}

log_error() {
    printf '%b\n' "${RED}[error]${NC} $*" >&2
}

log_debug() {
    if [[ "${AID_DEBUG:-}" == "1" ]]; then
        printf '%b\n' "${CYAN}[debug]${NC} $*" >&2
    fi
}

die() {
    log_error "$@"
    exit 1
}

# Check if a command exists
require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        die "Required command not found: $cmd"
    fi
}

# Generate a unique session ID
generate_session_id() {
    date +%Y%m%d-%H%M%S-$$
}

# ==============================================================================
# GitHub Issue Parsing
# ==============================================================================

# Check if input looks like a GitHub issue URL
is_github_issue_url() {
    local input="$1"
    [[ "$input" =~ ^https?://github\.com/[^/]+/[^/]+/issues/[0-9]+$ ]]
}

# Check if input looks like a GitHub PR URL
is_github_pr_url() {
    local input="$1"
    [[ "$input" =~ ^https?://github\.com/[^/]+/[^/]+/pull/[0-9]+$ ]]
}

# Extract issue number from GitHub URL
extract_issue_number() {
    local url="$1"
    echo "$url" | grep -oE '[0-9]+$'
}

# Extract owner/repo from GitHub URL (works for both issues and PRs)
extract_repo_path() {
    local url="$1"
    echo "$url" | sed -E 's|https?://github\.com/([^/]+/[^/]+)/[^/]+/[0-9]+.*|\1|'
}

# Get the current repository's GitHub owner/repo path
get_current_repo_path() {
    local remote_url

    # Try to get the origin remote URL
    remote_url=$(git config --get remote.origin.url 2>/dev/null) || return 1

    # Extract owner/repo from various GitHub URL formats:
    # - https://github.com/owner/repo.git
    # - git@github.com:owner/repo.git
    # - https://github.com/owner/repo
    if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/]+)(\.git)?$ ]]; then
        local repo_path="${BASH_REMATCH[1]}"
        # Remove .git suffix if present
        repo_path="${repo_path%.git}"
        echo "$repo_path"
        return 0
    fi

    return 1
}

# Validate that a GitHub URL belongs to the current repository
validate_github_url_repo() {
    local url="$1"
    local url_repo current_repo

    # Extract repo path from the provided URL
    url_repo=$(extract_repo_path "$url")
    if [[ -z "$url_repo" ]]; then
        log_error "Failed to extract repository from URL: $url"
        return 1
    fi

    # Get current repository's GitHub path
    current_repo=$(get_current_repo_path)
    if [[ -z "$current_repo" ]]; then
        log_warn "Could not determine current repository's GitHub remote"
        log_warn "Skipping repository validation"
        return 0  # Allow to proceed if we can't determine current repo
    fi

    # Compare repo paths (case-insensitive)
    if [[ "$(echo "$url_repo" | tr '[:upper:]' '[:lower:]')" != "$(echo "$current_repo" | tr '[:upper:]' '[:lower:]')" ]]; then
        log_error "Repository mismatch!"
        log_error "  URL points to:    ${url_repo}"
        log_error "  Current repo is:  ${current_repo}"
        log_error ""
        log_error "This command would work on the wrong repository."
        log_error "Please run this command from the correct repository."
        return 1
    fi

    log_debug "Repository validation passed: $current_repo"
    return 0
}

# Fetch issue details using gh CLI
fetch_issue_details() {
    local url="$1"
    local repo_path issue_number

    repo_path=$(extract_repo_path "$url")
    issue_number=$(extract_issue_number "$url")

    log_debug "Fetching issue #${issue_number} from ${repo_path}"

    if ! gh issue view "$issue_number" --repo "$repo_path" --json title,body,labels 2>/dev/null; then
        die "Failed to fetch issue details. Make sure you're authenticated with 'gh auth login'"
    fi
}

# ==============================================================================
# State Management
# ==============================================================================

# Create a state file for tracking the session
create_state_file() {
    local session_id="$1"
    local branch_name="$2"
    local worktree_path="$3"
    local task_type="$4"
    local task_source="$5"
    local task_description="$6"
    local source_repo="$7"

    local state_file="${DISPATCH_DIR}/${session_id}.json"

    cat > "$state_file" <<EOF
{
  "session_id": "${session_id}",
  "branch_name": "${branch_name}",
  "worktree_path": "${worktree_path}",
  "task_type": "${task_type}",
  "task_source": "${task_source}",
  "task_description": $(echo "$task_description" | jq -Rs .),
  "source_repo": "${source_repo}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "running",
  "pid": $$
}
EOF

    echo "$state_file"
}

# Update state file status
update_state_status() {
    local state_file="$1"
    local status="$2"

    if [[ -f "$state_file" ]]; then
        local tmp_file updated_at
        tmp_file=$(mktemp)
        updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        jq --arg status "$status" --arg updated_at "$updated_at" \
            '.status = $status | .updated_at = $updated_at' "$state_file" > "$tmp_file"
        mv "$tmp_file" "$state_file"
    fi
}

# Read state file
read_state() {
    local session_id="$1"
    local state_file="${DISPATCH_DIR}/${session_id}.json"

    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        return 1
    fi
}

# ==============================================================================
# Task Context Management
# ==============================================================================

# Derive a stable task ID from a branch name or issue number.
# Examples:
#   aid/20260313-143052-12345  -> aid-20260313-143052-12345
#   feature/my-thing           -> feature-my-thing
#   issue-42                   -> issue-42  (already slug-safe)
derive_task_id() {
    local branch="$1"
    # Replace slashes with hyphens; trim leading/trailing hyphens
    echo "$branch" | tr '/' '-' | sed 's/^-*//;s/-*$//'
}

# Return the task directory for a given task ID
task_dir() {
    local task_id="$1"
    echo "${TASKS_DIR}/${task_id}"
}

# Return the current task ID based on the worktree's branch (or "" if none)
# Usage: current_task_id [worktree_path]
current_task_id_for_worktree() {
    local worktree_path="${1:-$(pwd)}"
    local branch
    branch=$(git -C "$worktree_path" symbolic-ref --short HEAD 2>/dev/null) || return 1
    derive_task_id "$branch"
}

# Create task context directory + task.json for a new task.
# Returns the task directory path.
create_task_context() {
    local task_id="$1"
    local branch_name="$2"
    local repo="$3"    # owner/repo
    local pr_number="${4:-}"
    local pr_url="${5:-}"

    local tdir
    tdir=$(task_dir "$task_id")
    mkdir -p "$tdir"

    # Only create task.json if it doesn't exist (don't overwrite existing context)
    if [[ ! -f "${tdir}/task.json" ]]; then
        # Validate pr_number: --argjson requires a valid JSON value; guard against
        # non-numeric strings (e.g. a failed grep) that would make jq exit non-zero
        # and leave a zero-byte task.json on disk.
        local pr_number_json
        if [[ "${pr_number:-}" =~ ^[0-9]+$ ]]; then
            pr_number_json="$pr_number"
        else
            pr_number_json="null"
        fi

        jq -n \
            --arg id "$task_id" \
            --arg branch "$branch_name" \
            --arg repo "$repo" \
            --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --argjson pr_number "$pr_number_json" \
            --arg pr_url "${pr_url:-}" \
            '{
                id: $id,
                branch: $branch,
                repo: $repo,
                created: $created,
                phase: "research",
                pr_number: $pr_number,
                pr_url: (if $pr_url == "" then null else $pr_url end),
                status: "active"
            }' > "${tdir}/task.json"
    fi

    echo "$tdir"
}

# Update a field in task.json
update_task_json() {
    local task_id="$1"
    local key="$2"
    local value="$3"   # raw jq value (strings must be pre-quoted)

    local tfile
    tfile="$(task_dir "$task_id")/task.json"
    [[ -f "$tfile" ]] || return 1

    local tmp
    tmp=$(mktemp)
    jq --arg k "$key" --argjson v "$value" 'setpath([$k]; $v)' "$tfile" > "$tmp" && mv "$tmp" "$tfile"
}

# Update task phase
update_task_phase() {
    local task_id="$1"
    local phase="$2"
    update_task_json "$task_id" "phase" "\"${phase}\""
}

# Attach a PR number + URL to a task and advance phase to "review".
# Called by the create-pr command (via the shell snippet in create-pr.md) after
# gh pr create succeeds.
update_task_pr() {
    local task_id="$1"
    local pr_number="$2"
    local pr_url="$3"

    local tfile
    tfile="$(task_dir "$task_id")/task.json"
    [[ -f "$tfile" ]] || return 1

    local tmp
    tmp=$(mktemp)
    jq --argjson n "$pr_number" --arg u "$pr_url" \
        '.pr_number = $n | .pr_url = $u | .phase = "review" | .status = "active"' \
        "$tfile" > "$tmp" && mv "$tmp" "$tfile"
}

# Mark a task as done (phase=done, status=done).
# Called automatically by tasks_cleanup when it detects a branch has been
# merged/deleted on the remote before removing the task directory.
complete_task() {
    local task_id="$1"
    update_task_json "$task_id" "phase" '"done"'
    update_task_json "$task_id" "status" '"done"'
}

# Build the context injection block for prompts.
# Returns "" if no task context exists.
build_task_context_block() {
    local task_id="$1"
    local tdir
    tdir=$(task_dir "$task_id")

    [[ -d "$tdir" ]] || return 0

    local task_json=""
    local context_md=""
    local plan_md=""
    local phase="unknown"

    [[ -f "${tdir}/task.json" ]] && task_json=$(cat "${tdir}/task.json")
    [[ -f "${tdir}/context.md" ]] && context_md=$(cat "${tdir}/context.md")
    [[ -f "${tdir}/plan.md" ]] && plan_md=$(cat "${tdir}/plan.md")

    # Nothing useful yet — only task.json exists, no agent-written content
    if [[ -z "$context_md" && -z "$plan_md" ]]; then
        return 0
    fi

    [[ -n "$task_json" ]] && phase=$(echo "$task_json" | jq -r '.phase // "unknown"')

    local block=""
    block+="## Resuming task: ${task_id} (phase: ${phase})"$'\n'$'\n'

    if [[ -n "$context_md" ]]; then
        local line_count
        line_count=$(echo "$context_md" | wc -l | tr -d ' ')
        block+="### Previous Research (context.md)"
        if (( line_count > 200 )); then
            block+=" ⚠️  context.md exceeds 200 lines (${line_count} lines) — consider summarising"
        fi
        block+=$'\n'
        block+="${context_md}"$'\n'$'\n'
    fi

    if [[ -n "$plan_md" ]]; then
        block+="### Implementation Plan (plan.md)"$'\n'
        block+="${plan_md}"$'\n'$'\n'
    fi

    block+="---"$'\n'$'\n'
    echo "$block"
}

# Look up a task ID by PR URL or PR head branch
find_task_by_pr() {
    local pr_url="${1:-}"
    local pr_branch="${2:-}"

    [[ -d "$TASKS_DIR" ]] || return 1

    for tfile in "${TASKS_DIR}"/*/task.json; do
        [[ -f "$tfile" ]] || continue

        if [[ -n "$pr_url" ]]; then
            local stored_url
            stored_url=$(jq -r '.pr_url // ""' "$tfile" 2>/dev/null)
            if [[ "$stored_url" == "$pr_url" ]]; then
                jq -r '.id' "$tfile"
                return 0
            fi
        fi

        if [[ -n "$pr_branch" ]]; then
            local stored_branch
            stored_branch=$(jq -r '.branch // ""' "$tfile" 2>/dev/null)
            if [[ "$stored_branch" == "$pr_branch" ]]; then
                jq -r '.id' "$tfile"
                return 0
            fi
        fi
    done

    return 1
}

# ==============================================================================
# Cleanup Functions
# ==============================================================================

# Global variables for cleanup (set during dispatch)
CLEANUP_STATE_FILE=""
CLEANUP_WORKTREE_PATH=""
CLEANUP_BRANCH_NAME=""
CLEANUP_SOURCE_REPO=""

cleanup() {
    local exit_code=$?

    log_debug "Cleanup triggered (exit code: $exit_code)"

    # Update state to completed/failed
    if [[ -n "$CLEANUP_STATE_FILE" && -f "$CLEANUP_STATE_FILE" ]]; then
        if [[ $exit_code -eq 0 ]]; then
            update_state_status "$CLEANUP_STATE_FILE" "completed"
        else
            update_state_status "$CLEANUP_STATE_FILE" "failed"
        fi
    fi

    # Remove worktree if it exists
    if [[ -n "$CLEANUP_WORKTREE_PATH" && -d "$CLEANUP_WORKTREE_PATH" ]]; then
        log_info "Removing worktree: $CLEANUP_WORKTREE_PATH"

        if [[ -n "$CLEANUP_SOURCE_REPO" && -d "$CLEANUP_SOURCE_REPO" ]]; then
            (
                cd "$CLEANUP_SOURCE_REPO"
                git worktree remove --force "$CLEANUP_WORKTREE_PATH" 2>/dev/null || true
            )
        fi

        # Force remove if still exists
        if [[ -d "$CLEANUP_WORKTREE_PATH" ]]; then
            rm -rf "$CLEANUP_WORKTREE_PATH"
        fi
    fi

    # Delete branch if it wasn't pushed
    if [[ -n "$CLEANUP_BRANCH_NAME" && -n "$CLEANUP_SOURCE_REPO" && -d "$CLEANUP_SOURCE_REPO" ]]; then
        (
            cd "$CLEANUP_SOURCE_REPO"

            # Check if branch was pushed
            if ! git ls-remote --heads origin "$CLEANUP_BRANCH_NAME" 2>/dev/null | grep -q .; then
                log_info "Deleting unpushed branch: $CLEANUP_BRANCH_NAME"
                git branch -D "$CLEANUP_BRANCH_NAME" 2>/dev/null || true
            else
                log_info "Branch '$CLEANUP_BRANCH_NAME' was pushed, keeping it"
            fi
        )
    fi

    # Remove state file for completed sessions
    if [[ -n "$CLEANUP_STATE_FILE" && -f "$CLEANUP_STATE_FILE" ]]; then
        local status
        status=$(jq -r '.status' "$CLEANUP_STATE_FILE" 2>/dev/null || echo "unknown")
        if [[ "$status" == "completed" ]]; then
            rm -f "$CLEANUP_STATE_FILE"
        fi
    fi

    log_debug "Cleanup completed"
}

# Clean up orphaned sessions
cleanup_sessions() {
    local mode="${1:-}" # "orphaned", "failed", or "all"
    local force="${2:-false}"
    local cleaned=0
    local found=0

    case "$mode" in
        orphaned) log_info "Scanning for orphaned sessions..." ;;
        failed) log_info "Scanning for failed sessions..." ;;
        all) log_info "Scanning for all cleanable sessions..." ;;
        *) die "Invalid cleanup mode: $mode" ;;
    esac

    for state_file in "${DISPATCH_DIR}"/*.json; do
        [[ -f "$state_file" ]] || continue

        local session_id status pid worktree_path branch_name source_repo
        session_id=$(jq -r '.session_id' "$state_file" 2>/dev/null || echo "")
        status=$(jq -r '.status' "$state_file" 2>/dev/null || echo "")
        pid=$(jq -r '.pid' "$state_file" 2>/dev/null || echo "")
        worktree_path=$(jq -r '.worktree_path' "$state_file" 2>/dev/null || echo "")
        branch_name=$(jq -r '.branch_name' "$state_file" 2>/dev/null || echo "")
        source_repo=$(jq -r '.source_repo' "$state_file" 2>/dev/null || echo "")

        local should_clean=false
        local reason=""

        # Check if this session should be cleaned based on mode
        if [[ "$status" == "failed" && ("$mode" == "failed" || "$mode" == "all") ]]; then
            should_clean=true
            reason="failed"
        elif [[ "$status" == "running" ]]; then
            # Check if process is still running
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                log_debug "Session $session_id (PID $pid) is still running"
            elif [[ "$mode" == "orphaned" || "$mode" == "all" ]]; then
                should_clean=true
                reason="orphaned"
            fi
        fi

        if [[ "$should_clean" == "true" ]]; then
            found=$((found + 1))
            log_info "Found $reason session: $session_id"

            if [[ "$force" == "true" ]]; then
                # Set cleanup variables and run cleanup
                CLEANUP_STATE_FILE="$state_file"
                CLEANUP_WORKTREE_PATH="$worktree_path"
                CLEANUP_BRANCH_NAME="$branch_name"
                CLEANUP_SOURCE_REPO="$source_repo"

                update_state_status "$state_file" "$reason"
                cleanup
                cleaned=$((cleaned + 1))

                # Reset cleanup variables
                CLEANUP_STATE_FILE=""
                CLEANUP_WORKTREE_PATH=""
                CLEANUP_BRANCH_NAME=""
                CLEANUP_SOURCE_REPO=""
            else
                echo "  Session: $session_id"
                echo "  Status: $reason"
                echo "  Branch: $branch_name"
                echo "  Worktree: $worktree_path"
                echo ""
            fi
        fi
    done

    if [[ "$force" == "true" ]]; then
        log_success "Cleaned up $cleaned session(s)"
    elif [[ $found -eq 0 ]]; then
        log_success "No sessions to clean up"
    else
        log_info "Run with --force to remove these $found session(s)"
    fi
}

# ==============================================================================
# List Sessions
# ==============================================================================

list_sessions() {
    local count=0
    
    # Column widths
    local col_session=20
    local col_status=12
    local col_branch=35
    local col_created=20
    local total_width=$((col_session + col_status + col_branch + col_created))
    
    # Generate separator line
    local separator
    separator=$(printf '%*s' "$total_width" '' | tr ' ' '─')

    echo ""
    printf '%b\n' "${BOLD}Active AI Dispatch Sessions${NC}"
    echo "$separator"
    printf "%-${col_session}s %-${col_status}s %-${col_branch}s %-${col_created}s\n" \
        "SESSION" "STATUS" "BRANCH" "CREATED"
    echo "$separator"

    for state_file in "${DISPATCH_DIR}"/*.json; do
        [[ -f "$state_file" ]] || continue

        local session_id status branch_name created_at
        session_id=$(jq -r '.session_id' "$state_file" 2>/dev/null || echo "unknown")
        status=$(jq -r '.status' "$state_file" 2>/dev/null || echo "unknown")
        branch_name=$(jq -r '.branch_name' "$state_file" 2>/dev/null || echo "unknown")
        created_at=$(jq -r '.created_at' "$state_file" 2>/dev/null || echo "unknown")
        
        # Truncate branch name if too long
        if [[ ${#branch_name} -gt $((col_branch - 2)) ]]; then
            branch_name="${branch_name:0:$((col_branch - 5))}..."
        fi

        # Color status
        local status_colored
        case "$status" in
            running) status_colored="${GREEN}${status}${NC}" ;;
            completed) status_colored="${BLUE}${status}${NC}" ;;
            failed) status_colored="${RED}${status}${NC}" ;;
            *) status_colored="${YELLOW}${status}${NC}" ;;
        esac

        printf "%-${col_session}s %-${col_status}b %-${col_branch}s %-${col_created}s\n" \
            "$session_id" "$status_colored" "$branch_name" "$created_at"
        count=$((count + 1))
    done

    echo "$separator"

    if [[ $count -eq 0 ]]; then
        echo "No active sessions"
    else
        echo "Total: $count session(s)"
    fi
    echo ""
}

# ==============================================================================
# Interactive Mode
# ==============================================================================

interactive_dispatch() {
    local source_repo session_id branch_name worktree_path

    # Get current repo path
    source_repo=$(git rev-parse --show-toplevel 2>/dev/null) || die "Not in a git repository"

    # Get the default branch (main or master)
    local default_branch
    default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

    log_debug "Source repo: $source_repo"
    log_debug "Default branch: $default_branch"

    # Generate session ID and branch name
    session_id=$(generate_session_id)
    branch_name="aid/${session_id}"
    worktree_path="${WORKTREES_DIR}/${session_id}"

    log_info "Session ID: $session_id"
    log_info "Branch: $branch_name"
    log_info "Worktree: $worktree_path"

    # Dry run check
    if [[ "${AID_DRY_RUN:-}" == "1" ]]; then
        log_warn "Dry run mode - not executing"
        return 0
    fi

    # Fetch latest changes
    log_info "Fetching latest changes..."
    git fetch origin "$default_branch" 2>/dev/null || log_warn "Failed to fetch, continuing anyway"

    # Create worktree with new branch
    log_info "Creating worktree..."
    git worktree add -b "$branch_name" "$worktree_path" "origin/${default_branch}" 2>/dev/null ||
        git worktree add -b "$branch_name" "$worktree_path" "$default_branch" ||
        die "Failed to create worktree"

    # Create state file
    local state_file
    state_file=$(create_state_file "$session_id" "$branch_name" "$worktree_path" "interactive" "tui" "Interactive session" "$source_repo")

    # Set cleanup variables
    CLEANUP_STATE_FILE="$state_file"
    CLEANUP_WORKTREE_PATH="$worktree_path"
    CLEANUP_BRANCH_NAME="$branch_name"
    CLEANUP_SOURCE_REPO="$source_repo"

    # Set up cleanup trap
    trap cleanup EXIT SIGTERM SIGHUP SIGINT

    log_success "Worktree created successfully"

    # Change to worktree and run OpenCode with interactive TUI
    cd "$worktree_path"
    
    # Run OpenCode with the dispatch agent in interactive TUI mode
    opencode --agent dispatch

    log_success "Interactive session completed"
}

# ==============================================================================
# PR Review (Read-Only and Interactive)
# ==============================================================================

review_pr() {
    local pr_url="$1"

    # Validate it's a PR URL (not issue)
    if ! is_github_pr_url "$pr_url"; then
        die "Invalid PR URL. Expected: https://github.com/owner/repo/pull/123"
    fi

    # Validate repository match
    validate_github_url_repo "$pr_url" || die "Repository validation failed"

    # Require a git repo in the caller's CWD (needed for worktree creation)
    local source_repo
    source_repo=$(git rev-parse --show-toplevel 2>/dev/null) || die "Not in a git repository"

    local repo_path pr_number
    repo_path=$(echo "$pr_url" | sed -E 's|https?://github\.com/([^/]+/[^/]+)/pull/[0-9]+|\1|')
    pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$')

    log_info "Reviewing PR #${pr_number} in ${repo_path}..."

    # Fetch PR details (include headRefName and isCrossRepository for worktree setup)
    local pr_json
    pr_json=$(gh pr view "$pr_number" --repo "$repo_path" \
        --json title,body,files,additions,deletions,commits,author,comments,reviews,headRefName,isCrossRepository \
        2>/dev/null) ||
        die "Failed to fetch PR details. Make sure you're authenticated with 'gh auth login'"

    local pr_title pr_author pr_additions pr_deletions pr_body pr_branch_name pr_is_fork
    pr_title=$(echo "$pr_json" | jq -r '.title')
    pr_author=$(echo "$pr_json" | jq -r '.author.login')
    pr_additions=$(echo "$pr_json" | jq -r '.additions')
    pr_deletions=$(echo "$pr_json" | jq -r '.deletions')
    pr_body=$(echo "$pr_json" | jq -r '.body // ""')
    pr_branch_name=$(echo "$pr_json" | jq -r '.headRefName // ""')
    pr_is_fork=$(echo "$pr_json" | jq -r '.isCrossRepository // false')

    [[ -z "$pr_branch_name" || "$pr_branch_name" == "null" ]] &&
        die "Could not determine PR branch name from PR #${pr_number}"

    log_info "PR: #${pr_number} - ${pr_title}"
    log_info "Author: ${pr_author} (+${pr_additions}/-${pr_deletions} lines)"

    # Fetch PR diff (--color=never ensures clean text regardless of terminal environment)
    log_info "Fetching PR diff..."
    local pr_diff
    pr_diff=$(gh pr diff "$pr_number" --repo "$repo_path" --color=never 2>/dev/null) ||
        log_warn "Failed to fetch PR diff; agent will fetch it"

    # Format comments and reviews for context
    local comments_text reviews_text
    comments_text=$(echo "$pr_json" | jq -r '
        (.comments // []) |
        if length == 0 then "(none)"
        else map("**\(.author.login)**: \(.body)") | join("\n\n")
        end')
    reviews_text=$(echo "$pr_json" | jq -r '
        (.reviews // []) |
        map(select(.body != null and .body != "")) |
        if length == 0 then "(none)"
        else map("**\(.author.login)** [\(.state)]: \(.body)") | join("\n\n")
        end')

    # Build the enriched review prompt
    local review_prompt

    # --- Task context injection ---
    local task_context_block=""
    if [[ "${AID_NO_CONTEXT:-}" != "1" ]]; then
        local matched_task_id
        matched_task_id=$(find_task_by_pr "$pr_url" "$pr_branch_name" 2>/dev/null || echo "")
        if [[ -n "$matched_task_id" ]]; then
            task_context_block=$(build_task_context_block "$matched_task_id")
            log_info "Found existing task: $matched_task_id"
        else
            log_debug "No existing task found for this PR (review will proceed without task context)"
        fi
    fi

    if [[ -n "$task_context_block" ]]; then
        review_prompt="${task_context_block}
Review PR #${pr_number}: ${pr_url}

Title: ${pr_title}
Author: ${pr_author}
Changes: +${pr_additions}/-${pr_deletions} lines

## Description
${pr_body:-"(no description provided)"}

## Prior Comments
${comments_text}

## Prior Reviews
${reviews_text}

## Diff
\`\`\`diff
${pr_diff}
\`\`\`"
    else
        review_prompt="Review PR #${pr_number}: ${pr_url}

Title: ${pr_title}
Author: ${pr_author}
Changes: +${pr_additions}/-${pr_deletions} lines

## Description
${pr_body:-"(no description provided)"}

## Prior Comments
${comments_text}

## Prior Reviews
${reviews_text}

## Diff
\`\`\`diff
${pr_diff}
\`\`\`"
    fi

    # Dry run check
    if [[ "${AID_DRY_RUN:-}" == "1" ]]; then
        log_warn "Dry run mode - not executing"
        return 0
    fi

    # Create a temporary worktree checked out at the PR's head so the review agent
    # can use git grep / git show against the exact state of the code being reviewed.
    # For fork PRs the branch is not in origin, so fall back to running from the
    # source repo root (the embedded diff still provides full context).
    local session_id worktree_path
    session_id=$(generate_session_id)
    worktree_path="${WORKTREES_DIR}/review-${session_id}"

    if [[ "$pr_is_fork" == "true" ]]; then
        log_warn "Fork PR detected — skipping worktree; git grep/show will reflect your current branch"
        log_info "Starting code review..."
        cd "$source_repo"
        opencode --agent review --prompt "$review_prompt"
    else
        # Fetch the PR branch from origin
        log_info "Fetching PR branch '${pr_branch_name}'..."
        git fetch origin "${pr_branch_name}:refs/remotes/origin/${pr_branch_name}" 2>/dev/null ||
            die "Failed to fetch PR branch '${pr_branch_name}' from origin"

        # Create a detached-HEAD worktree at the PR's head — no local branch needed
        # since the review agent never commits
        log_info "Creating review worktree at PR head..."
        git worktree add --detach "$worktree_path" "origin/${pr_branch_name}" ||
            die "Failed to create review worktree"

        # Register worktree for cleanup (no branch to delete — detached HEAD)
        CLEANUP_WORKTREE_PATH="$worktree_path"
        CLEANUP_BRANCH_NAME=""
        CLEANUP_SOURCE_REPO="$source_repo"
        trap cleanup EXIT SIGTERM SIGHUP SIGINT

        log_success "Review worktree created at PR head"
        log_info "Starting code review..."

        cd "$worktree_path"
        opencode --agent review --prompt "$review_prompt"
    fi

    log_success "PR review completed"
}

# ==============================================================================
# Main Dispatch Logic
# ==============================================================================

dispatch() {
    local input="$1"
    local session_id branch_name worktree_path task_type task_source task_description
    local source_repo issue_json

    # Get current repo path
    source_repo=$(git rev-parse --show-toplevel 2>/dev/null) || die "Not in a git repository"

    # Get the default branch (main or master)
    local default_branch
    default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

    log_debug "Source repo: $source_repo"
    log_debug "Default branch: $default_branch"

    # Generate session ID first - used for branch naming
    session_id=$(generate_session_id)
    branch_name="aid/${session_id}"

    # Parse input - GitHub issue, PR, or plain text
    if is_github_issue_url "$input"; then
        task_type="github_issue"
        task_source="$input"

        # Validate repository match
        validate_github_url_repo "$input" || die "Repository validation failed"

        log_info "Fetching GitHub issue details..."
        issue_json=$(fetch_issue_details "$input")

        local issue_number issue_title
        issue_number=$(extract_issue_number "$input")
        issue_title=$(echo "$issue_json" | jq -r '.title')

        task_description="GitHub Issue #${issue_number}: ${issue_title}

$(echo "$issue_json" | jq -r '.body // "No description provided"')

Labels: $(echo "$issue_json" | jq -r '.labels | map(.name) | join(", ") // "none"')

Source: $input"

        log_info "Issue: #${issue_number} - ${issue_title}"
    elif is_github_pr_url "$input"; then
        task_type="github_pr"
        task_source="$input"

        # Validate repository match
        validate_github_url_repo "$input" || die "Repository validation failed"

        local repo_path pr_number
        repo_path=$(echo "$input" | sed -E 's|https?://github\.com/([^/]+/[^/]+)/pull/[0-9]+|\1|')
        pr_number=$(echo "$input" | grep -oE '[0-9]+$')

        log_info "Fetching PR #${pr_number} details..."

        local pr_json pr_title pr_branch_name pr_is_fork
        pr_json=$(gh pr view "$pr_number" --repo "$repo_path" \
            --json title,body,files,headRefName,isCrossRepository,comments,reviews 2>/dev/null) ||
            die "Failed to fetch PR details. Make sure you're authenticated with 'gh auth login'"
        pr_title=$(echo "$pr_json" | jq -r '.title')
        pr_branch_name=$(echo "$pr_json" | jq -r '.headRefName')
        [[ -z "$pr_branch_name" || "$pr_branch_name" == "null" ]] &&
            die "Could not determine PR branch name from PR #${pr_number}"
        pr_is_fork=$(echo "$pr_json" | jq '.isCrossRepository // false')
        if [[ "$pr_is_fork" == "true" ]]; then
            die "Fork PRs are not yet supported. Check out the branch manually and re-run."
        fi

        # Use the PR's actual branch instead of creating a new aid/ branch
        branch_name="$pr_branch_name"

        # Format comments and reviews for context
        local comments_text reviews_text
        comments_text=$(echo "$pr_json" | jq -r '
            (.comments // []) |
            if length == 0 then "(none)"
            else map("**\(.author.login)**: \(.body)") | join("\n\n")
            end')
        reviews_text=$(echo "$pr_json" | jq -r '
            (.reviews // []) |
            map(select(.body != null and .body != "")) |
            if length == 0 then "(none)"
            else map("**\(.author.login)** [\(.state)]: \(.body)") | join("\n\n")
            end')

        # Fetch inline review thread comments via REST API
        local inline_comments_json inline_text
        inline_comments_json=$(gh api "repos/${repo_path}/pulls/${pr_number}/comments" 2>/dev/null || echo "[]")
        inline_text=$(echo "$inline_comments_json" | jq -r '
            if length == 0 then "(none)"
            else map("**\(.user.login)** on `\(.path)` line \(.original_line // .line // "?"):\n\(.body)") | join("\n\n")
            end')

        task_description="GitHub PR #${pr_number}: ${pr_title}

$(echo "$pr_json" | jq -r '.body // "No description provided"')

Changed files:
$(echo "$pr_json" | jq -r '.files[].path' | head -20)

## Review Comments
${comments_text}

## Review Feedback
${reviews_text}

## Inline Review Comments
${inline_text}

Source: $input

Address the above review comments and requested changes."

        log_info "PR: #${pr_number} - ${pr_title}"
        log_info "PR branch: ${pr_branch_name}"
    else
        task_type="plain_text"
        task_source="cli"
        task_description="$input"

        log_info "Task: $input"
    fi

    worktree_path="${WORKTREES_DIR}/${session_id}"

    log_info "Session ID: $session_id"
    log_info "Branch: $branch_name"
    log_info "Worktree: $worktree_path"

    # Dry run check
    if [[ "${AID_DRY_RUN:-}" == "1" ]]; then
        log_warn "Dry run mode - not executing"
        return 0
    fi

    # Fetch latest changes
    log_info "Fetching latest changes..."
    if [[ "$task_type" == "github_pr" ]]; then
        # The default branch is only used as informational context in the task prompt;
        # the worktree is based entirely on the PR branch, so a stale default branch
        # cannot affect the work — failure here is intentionally non-fatal.
        git fetch origin "$default_branch" 2>/dev/null || log_warn "Failed to fetch default branch, continuing anyway"
        git fetch origin "${branch_name}:refs/remotes/origin/${branch_name}" 2>/dev/null || die "Failed to fetch PR branch '${branch_name}' from origin. Ensure the branch exists remotely."
    else
        git fetch origin "$default_branch" 2>/dev/null || log_warn "Failed to fetch, continuing anyway"
    fi

    # Create worktree - use existing PR branch or create new branch
    log_info "Creating worktree..."
    if [[ "$task_type" == "github_pr" ]]; then
        # For PR tasks: check out the existing PR branch so fixes go directly to the PR.
        # If a local branch already exists, validate it is safe to remove before recreating
        # it as a clean tracking branch from origin.
        if git show-ref --verify --quiet "refs/heads/${branch_name}" 2>/dev/null; then
            # Guard: refuse if the branch is checked out in any linked worktree
            local worktree_list
            worktree_list=$(git worktree list --porcelain) || die "Failed to list worktrees"
            # Skip the first block (main worktree) — we only care about linked worktrees
            local linked_worktrees
            linked_worktrees=$(echo "$worktree_list" | awk 'BEGIN{p=0} /^$/{p=1; next} p{print}')
            if echo "$linked_worktrees" | grep -qxF "branch refs/heads/${branch_name}"; then
                die "Branch '${branch_name}' is already checked out in another worktree. Remove it first."
            fi
            # Guard: refuse if local branch has commits not reachable from origin
            local local_tip merge_base
            local_tip=$(git rev-parse "refs/heads/${branch_name}") ||
                die "Could not resolve local branch '${branch_name}'"
            merge_base=$(git merge-base "refs/heads/${branch_name}" "origin/${branch_name}") ||
                die "Could not determine merge base for '${branch_name}'. Histories may be unrelated."
            if [[ "$local_tip" != "$merge_base" ]]; then
                die "Local branch '${branch_name}' has commits not in origin. Aborting to prevent data loss."
            fi
            # Safe to remove: local is a strict ancestor of (or equal to) origin
            git branch -D "$branch_name" ||
                die "Could not remove local branch '${branch_name}' before recreating it."
        fi
        # Create a fresh tracking branch from origin and add the worktree
        git worktree add --track -b "$branch_name" "$worktree_path" "origin/${branch_name}" ||
            die "Failed to create worktree for PR branch '${branch_name}'. Ensure 'origin/${branch_name}' exists."
    else
        # For issues/text tasks: create a new aid/ branch off the default branch
        git worktree add -b "$branch_name" "$worktree_path" "origin/${default_branch}" 2>/dev/null ||
            git worktree add -b "$branch_name" "$worktree_path" "$default_branch" ||
            die "Failed to create worktree"
    fi

    # Create state file
    local state_file
    state_file=$(create_state_file "$session_id" "$branch_name" "$worktree_path" "$task_type" "$task_source" "$task_description" "$source_repo")

    # Set cleanup variables
    CLEANUP_STATE_FILE="$state_file"
    CLEANUP_WORKTREE_PATH="$worktree_path"
    CLEANUP_BRANCH_NAME="$branch_name"
    CLEANUP_SOURCE_REPO="$source_repo"

    # Set up cleanup trap
    trap cleanup EXIT SIGTERM SIGHUP SIGINT

    log_success "Worktree created successfully"

    # --- Task context (persistent across sessions) ---
    local task_id repo_path_for_task
    task_id=$(derive_task_id "$branch_name")
    repo_path_for_task=$(get_current_repo_path 2>/dev/null || echo "")

    if [[ "${AID_NO_CONTEXT:-}" != "1" ]]; then
        local tdir
        tdir=$(create_task_context "$task_id" "$branch_name" "$repo_path_for_task")
        log_debug "Task context dir: $tdir"
    fi

    # Build context injection block (empty string if no prior context)
    local context_block=""
    if [[ "${AID_NO_CONTEXT:-}" != "1" ]]; then
        context_block=$(build_task_context_block "$task_id")
    fi

    # Prepare the task prompt - just the task and context, agent already knows the workflow
    local extra_context=""
    [[ "$task_type" == "github_pr" ]] && extra_context=$'\n'"- Branch: ${branch_name} (push directly to update the PR)"

    # Only tell the agent to write context files when context is enabled
    local context_dir_hint=""
    if [[ "${AID_NO_CONTEXT:-}" != "1" ]]; then
        context_dir_hint=$'\n'"- Task context dir: ${TASKS_DIR}/${task_id} (write research notes to context.md, implementation plan to plan.md)"
    fi

    local task_prompt
    if [[ -n "$context_block" ]]; then
        task_prompt="${context_block}
## Task

${task_description}

## Context

- Worktree: ${worktree_path}
- Target branch: ${default_branch}${extra_context}${context_dir_hint}"
    else
        task_prompt="## Task

${task_description}

## Context

- Worktree: ${worktree_path}
- Target branch: ${default_branch}${extra_context}${context_dir_hint}"
    fi

    # Change to worktree and run OpenCode
    log_info "Starting OpenCode in worktree..."
    echo ""

    cd "$worktree_path"

    # Run OpenCode with the dispatch agent (TUI mode)
    opencode --agent dispatch --prompt "$task_prompt"

    log_success "AI dispatch completed"
}

# ==============================================================================
# Resume Session
# ==============================================================================

resume_session() {
    local session_id="$1"
    local state_json

    state_json=$(read_state "$session_id") || die "Session not found: $session_id"

    local worktree_path status
    worktree_path=$(echo "$state_json" | jq -r '.worktree_path')
    status=$(echo "$state_json" | jq -r '.status')

    if [[ ! -d "$worktree_path" ]]; then
        die "Worktree no longer exists: $worktree_path"
    fi

    log_info "Resuming session: $session_id"
    log_info "Worktree: $worktree_path"

    cd "$worktree_path"
    # Continue the last OpenCode session in this worktree
    opencode -c
}

# ==============================================================================
# View Session
# ==============================================================================

view_session() {
    local session_id="$1"
    local state_json

    state_json=$(read_state "$session_id") || die "Session not found: $session_id"

    # Extract fields
    local branch_name worktree_path status created_at task_type task_source task_description source_repo pid
    branch_name=$(echo "$state_json" | jq -r '.branch_name')
    worktree_path=$(echo "$state_json" | jq -r '.worktree_path')
    status=$(echo "$state_json" | jq -r '.status')
    created_at=$(echo "$state_json" | jq -r '.created_at')
    task_type=$(echo "$state_json" | jq -r '.task_type')
    task_source=$(echo "$state_json" | jq -r '.task_source')
    task_description=$(echo "$state_json" | jq -r '.task_description')
    source_repo=$(echo "$state_json" | jq -r '.source_repo')
    pid=$(echo "$state_json" | jq -r '.pid')

    # Color status
    local status_colored
    case "$status" in
        running) status_colored="${GREEN}${status}${NC}" ;;
        completed) status_colored="${BLUE}${status}${NC}" ;;
        failed) status_colored="${RED}${status}${NC}" ;;
        *) status_colored="${YELLOW}${status}${NC}" ;;
    esac

    # --- Display metadata ---
    echo ""
    printf '%b\n' "${BOLD}Session: ${session_id}${NC}"
    printf '%s\n' "─────────────────────────────────────────────"
    printf "%-14s %b\n" "Status:" "$status_colored"
    printf "%-14s %s\n" "Created:" "$created_at"
    printf "%-14s %s\n" "Type:" "$task_type"
    printf "%-14s %s\n" "Branch:" "$branch_name"
    printf "%-14s %s\n" "Worktree:" "$worktree_path"
    echo ""
    printf '%b\n' "${BOLD}Task Description${NC}"
    printf '%s\n' "─────────────────────────────────────────────"
    echo "$task_description" | head -10
    echo ""

    # --- Git log (if worktree exists) ---
    if [[ -d "$worktree_path" ]]; then
        printf '%b\n' "${BOLD}Recent Commits${NC}"
        printf '%s\n' "─────────────────────────────────────────────"
        (
            cd "$worktree_path"
            local default_branch
            default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
            git log --oneline "origin/${default_branch}..HEAD" 2>/dev/null | head -10 || echo "  (no commits yet)"
        )
        echo ""
    else
        printf '%b\n' "${YELLOW}Worktree not found: ${worktree_path}${NC}"
        echo ""
    fi

    # --- PR status (check if branch has a PR) ---
    if [[ -n "$source_repo" && -d "$source_repo" ]]; then
        printf '%b\n' "${BOLD}Pull Request${NC}"
        printf '%s\n' "─────────────────────────────────────────────"
        local pr_info
        pr_info=$(cd "$source_repo" && gh pr list --head "$branch_name" --json number,title,state,url 2>/dev/null)

        if [[ -n "$pr_info" && "$pr_info" != "[]" ]]; then
            echo "$pr_info" | jq -r '.[] | "  #\(.number) - \(.title) (\(.state))\n  \(.url)"'
        else
            echo "  (no PR found for branch: $branch_name)"
        fi
        echo ""
    fi

    # --- Prompt to open in OpenCode ---
    if [[ -d "$worktree_path" ]]; then
        # Check if session is actively running
        local is_running=false
        if [[ "$status" == "running" && -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            is_running=true
            printf '%b\n' "${YELLOW}Warning: Session is still running (PID: $pid)${NC}"
            printf '%b' "Attach anyway? This may cause conflicts. [y/N] "
        else
            printf '%b' "Open session in OpenCode? [y/N] "
        fi
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            cd "$worktree_path"
            opencode -c
        fi
    fi
}

# ==============================================================================
# Tasks Command — list/view/edit/phase/cleanup task contexts
# ==============================================================================

tasks_list() {
    local count=0
    local merged_count=0

    local col_id=40
    local col_phase=12
    local col_status=12
    local col_branch=35
    local total_width=$((col_id + col_phase + col_status + col_branch))
    local separator
    separator=$(printf '%*s' "$total_width" '' | tr ' ' '─')

    echo ""
    printf '%b\n' "${BOLD}Aid Task Contexts${NC}"
    echo "$separator"
    printf "%-${col_id}s %-${col_phase}s %-${col_status}s %-${col_branch}s\n" \
        "TASK ID" "PHASE" "STATUS" "BRANCH"
    echo "$separator"

    [[ -d "$TASKS_DIR" ]] || { echo "No tasks found"; echo ""; return; }

    for tfile in "${TASKS_DIR}"/*/task.json; do
        [[ -f "$tfile" ]] || continue

        local task_id phase status branch_name task_repo pr_url
        task_id=$(jq -r '.id // "unknown"' "$tfile" 2>/dev/null)
        phase=$(jq -r '.phase // "unknown"' "$tfile" 2>/dev/null)
        status=$(jq -r '.status // "unknown"' "$tfile" 2>/dev/null)
        branch_name=$(jq -r '.branch // "unknown"' "$tfile" 2>/dev/null)
        task_repo=$(jq -r '.repo // ""' "$tfile" 2>/dev/null)
        pr_url=$(jq -r '.pr_url // ""' "$tfile" 2>/dev/null)

        # --- Live GitHub status check ---
        # If the task is not already marked done, query GitHub to get the real
        # state: branch gone means merged/closed; PR state provides more detail.
        if [[ "$status" != "done" && -n "$task_repo" && "$task_repo" != "null" ]]; then
            local http_status="" pr_state="" gh_raw=""
            # Capture gh api output into a variable first to avoid SIGPIPE when
            # piping directly into grep -m1 (gh api writes many lines; grep exits
            # after the first match and closes the pipe, sending SIGPIPE to gh api,
            # which — under set -o pipefail — kills the whole script).
            gh_raw=$(gh api --include \
                "repos/${task_repo}/branches/${branch_name}" 2>/dev/null || true)
            http_status=$(printf '%s\n' "$gh_raw" | grep -m1 '^HTTP/' | awk '{print $2}')

            if [[ "$http_status" == "404" ]]; then
                # Branch is gone — check if the PR was merged or just closed
                if [[ -n "$pr_url" && "$pr_url" != "null" ]]; then
                    local pr_number=""
                    pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$')
                    pr_state=$(gh api "repos/${task_repo}/pulls/${pr_number}" \
                        --jq '.state + (if .merged_at then "/merged" else "" end)' \
                        2>/dev/null || echo "")
                fi
                if [[ "$pr_state" == *"merged"* ]]; then
                    status="merged"
                    phase="done"
                elif [[ "$pr_state" == "closed"* ]]; then
                    status="closed"
                    phase="done"
                else
                    status="merged"
                    phase="done"
                fi
                merged_count=$((merged_count + 1))
            elif [[ "$http_status" == "200" && "$phase" != "done" ]]; then
                # Branch still exists — enrich with live PR state.
                # If pr_url is already stored use it directly; otherwise search
                # GitHub for an open PR against this branch (covers the case where
                # the agent created a PR but forgot to update task.json).
                local live_pr_number="" live_pr_url="" live_pr_state=""
                if [[ -n "$pr_url" && "$pr_url" != "null" ]]; then
                    live_pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$')
                else
                    # Search for any open PR whose head matches this branch
                    local found_pr
                    found_pr=$(gh api "repos/${task_repo}/pulls?state=open&head=${task_repo%%/*}:${branch_name}" \
                        --jq '.[0] | select(. != null) | "\(.number) \(.html_url)"' 2>/dev/null || echo "")
                    if [[ -n "$found_pr" ]]; then
                        live_pr_number=$(echo "$found_pr" | awk '{print $1}')
                        live_pr_url=$(echo "$found_pr" | awk '{print $2}')
                    fi
                fi
                if [[ -n "$live_pr_number" ]]; then
                    live_pr_state=$(gh api "repos/${task_repo}/pulls/${live_pr_number}" \
                        --jq '.state' 2>/dev/null || echo "")
                fi
                if [[ "$live_pr_state" == "open" && "$phase" == "research" ]]; then
                    # PR exists but phase wasn't advanced — fix it
                    phase="review"
                    status="active"
                    # Persist the correction silently (also store PR info if we discovered it)
                    update_task_phase "$task_id" "review" 2>/dev/null || true
                    if [[ -n "$live_pr_url" && -n "$live_pr_number" ]]; then
                        update_task_pr "$task_id" "$live_pr_number" "$live_pr_url" 2>/dev/null || true
                    fi
                fi
            fi
        fi

        # Truncate long task IDs
        if [[ ${#task_id} -gt $((col_id - 2)) ]]; then
            task_id="${task_id:0:$((col_id - 5))}..."
        fi
        # Truncate branch
        if [[ ${#branch_name} -gt $((col_branch - 2)) ]]; then
            branch_name="${branch_name:0:$((col_branch - 5))}..."
        fi

        # Color phase
        local phase_colored
        case "$phase" in
            research)  phase_colored="${CYAN}${phase}${NC}" ;;
            plan)      phase_colored="${YELLOW}${phase}${NC}" ;;
            implement) phase_colored="${BLUE}${phase}${NC}" ;;
            review)    phase_colored="${YELLOW}${phase}${NC}" ;;
            done)      phase_colored="${GREEN}${phase}${NC}" ;;
            *)         phase_colored="${NC}${phase}${NC}" ;;
        esac

        # Color status
        local status_colored
        case "$status" in
            active)  status_colored="${NC}${status}${NC}" ;;
            merged)  status_colored="${GREEN}${status}${NC}" ;;
            closed)  status_colored="${YELLOW}${status}${NC}" ;;
            done)    status_colored="${GREEN}${status}${NC}" ;;
            *)       status_colored="${NC}${status}${NC}" ;;
        esac

        printf "%-${col_id}s %-${col_phase}b %-${col_status}b %-${col_branch}s\n" \
            "$task_id" "$phase_colored" "$status_colored" "$branch_name"
        count=$((count + 1))
    done

    echo "$separator"
    if [[ $count -eq 0 ]]; then
        echo "No task contexts found"
    else
        echo "Total: $count task(s)"
        if [[ $merged_count -gt 0 ]]; then
            printf '%b\n' "${YELLOW}Tip: $merged_count merged/closed task(s) found. Run: ${BOLD}aid tasks cleanup --merged --force${NC}${YELLOW} to remove them.${NC}"
        fi
    fi
    echo ""
}

tasks_view() {
    local task_id="$1"
    local tdir
    tdir=$(task_dir "$task_id")

    if [[ ! -d "$tdir" ]]; then
        die "Task not found: $task_id  (looked in: $tdir)"
    fi

    echo ""
    printf '%b\n' "${BOLD}Task: ${task_id}${NC}"
    printf '%s\n' "─────────────────────────────────────────────"

    if [[ -f "${tdir}/task.json" ]]; then
        local phase status branch repo pr_url created
        phase=$(jq -r '.phase // "unknown"' "${tdir}/task.json")
        status=$(jq -r '.status // "unknown"' "${tdir}/task.json")
        branch=$(jq -r '.branch // "unknown"' "${tdir}/task.json")
        repo=$(jq -r '.repo // "unknown"' "${tdir}/task.json")
        pr_url=$(jq -r '.pr_url // ""' "${tdir}/task.json")
        created=$(jq -r '.created // "unknown"' "${tdir}/task.json")

        printf "%-12s %s\n" "Phase:" "$phase"
        printf "%-12s %s\n" "Status:" "$status"
        printf "%-12s %s\n" "Branch:" "$branch"
        printf "%-12s %s\n" "Repo:" "$repo"
        printf "%-12s %s\n" "Created:" "$created"
        [[ -n "$pr_url" && "$pr_url" != "null" ]] && printf "%-12s %s\n" "PR:" "$pr_url"
    fi

    echo ""

    if [[ -f "${tdir}/context.md" ]]; then
        local line_count
        line_count=$(wc -l < "${tdir}/context.md" | tr -d ' ')
        printf '%b\n' "${BOLD}context.md${NC} (${line_count} lines)"
        printf '%s\n' "─────────────────────────────────────────────"
        if (( line_count > 200 )); then
            printf '%b\n' "${YELLOW}⚠  context.md exceeds 200 lines — consider asking the agent to summarise it${NC}"
        fi
        cat "${tdir}/context.md"
        echo ""
    else
        printf '%b\n' "${YELLOW}context.md not yet written${NC}"
        echo ""
    fi

    if [[ -f "${tdir}/plan.md" ]]; then
        local plan_lines
        plan_lines=$(wc -l < "${tdir}/plan.md" | tr -d ' ')
        printf '%b\n' "${BOLD}plan.md${NC} (${plan_lines} lines)"
        printf '%s\n' "─────────────────────────────────────────────"
        cat "${tdir}/plan.md"
        echo ""
    else
        printf '%b\n' "${YELLOW}plan.md not yet written${NC}"
        echo ""
    fi
}

tasks_edit() {
    local task_id="$1"
    local file="${2:-plan.md}"   # default to plan.md
    local tdir
    tdir=$(task_dir "$task_id")

    if [[ ! -d "$tdir" ]]; then
        die "Task not found: $task_id"
    fi

    # Whitelist valid filenames to prevent path traversal
    case "$file" in
        context.md|plan.md) ;;
        *) die "Invalid file '${file}'. Valid options: context.md, plan.md" ;;
    esac

    local editor="${VISUAL:-${EDITOR:-vi}}"
    "$editor" "${tdir}/${file}"
}

tasks_phase() {
    local task_id="$1"
    local new_phase="${2:-}"

    local valid_phases="research plan implement review done"
    if [[ -z "$new_phase" ]]; then
        die "Usage: aid tasks phase <task-id> <phase>  (phases: ${valid_phases})"
    fi

    # Validate phase
    local valid=false
    for p in $valid_phases; do
        [[ "$new_phase" == "$p" ]] && valid=true && break
    done
    $valid || die "Invalid phase '${new_phase}'. Valid phases: ${valid_phases}"

    local tdir
    tdir=$(task_dir "$task_id")
    [[ -d "$tdir" ]] || die "Task not found: $task_id"

    update_task_phase "$task_id" "$new_phase"
    log_success "Phase updated: $task_id → $new_phase"
}

tasks_cleanup() {
    local mode="${1:-merged}"  # "merged" or "all"
    local force="${2:-false}"
    local cleaned=0
    local found=0

    [[ -d "$TASKS_DIR" ]] || { log_info "No tasks directory found"; return; }

    for tfile in "${TASKS_DIR}"/*/task.json; do
        [[ -f "$tfile" ]] || continue

        local task_id branch status task_repo
        task_id=$(jq -r '.id // ""' "$tfile" 2>/dev/null)
        branch=$(jq -r '.branch // ""' "$tfile" 2>/dev/null)
        status=$(jq -r '.status // ""' "$tfile" 2>/dev/null)
        task_repo=$(jq -r '.repo // ""' "$tfile" 2>/dev/null)

        [[ -z "$task_id" ]] && continue

        local should_clean=false
        local reason=""

        if [[ "$mode" == "all" ]]; then
            should_clean=true
            reason="all"
        elif [[ "$mode" == "merged" ]]; then
            # Check if the branch has been merged/deleted on the remote.
            # Use gh api routed to each task's own repo so that tasks from
            # multiple repos are checked against the correct remote — not just
            # the CWD repo's origin (which would falsely flag branches from
            # other repos as deleted).
            if [[ -n "$branch" ]]; then
                if [[ -n "$task_repo" ]]; then
                    # Use --include to get HTTP response headers so we can
                    # distinguish a definitive 404 (branch gone) from transient
                    # failures (network error, rate-limit, auth expiry) that
                    # should NOT cause a destructive removal.
                    # Capture into a variable first to avoid SIGPIPE: gh api
                    # outputs many lines; grep -m1 exits early and closes the
                    # pipe, which under set -o pipefail kills the script.
                    local gh_raw=""
                    gh_raw=$(gh api --include \
                        "repos/${task_repo}/branches/${branch}" 2>/dev/null || true)
                    local http_status=""
                    http_status=$(printf '%s\n' "$gh_raw" | grep -m1 '^HTTP/' | awk '{print $2}')
                    if [[ "$http_status" == "404" ]]; then
                        should_clean=true
                        reason="branch deleted/merged"
                    elif [[ -z "$http_status" ]]; then
                        log_warn "Skipping task ${task_id}: could not reach GitHub API (network/auth error)"
                    fi
                else
                    # Legacy tasks without a repo field: fall back to git ls-remote
                    # but only if we are inside a git repo to avoid false positives.
                    if git rev-parse --git-dir &>/dev/null; then
                        if ! git ls-remote --heads origin "$branch" 2>/dev/null | grep -q .; then
                            should_clean=true
                            reason="branch deleted/merged"
                        fi
                    else
                        log_warn "Skipping task ${task_id}: no repo field and not in a git repo"
                    fi
                fi
            fi
        fi

        if [[ "$should_clean" == "true" ]]; then
            found=$((found + 1))
            local tdir
            tdir=$(task_dir "$task_id")
            log_info "Found task to clean (${reason}): $task_id"

            if [[ "$force" == "true" ]]; then
                # Mark as done before removing so any concurrent reader sees a
                # terminal state rather than stale "active".
                complete_task "$task_id" 2>/dev/null || true
                rm -rf "$tdir"
                log_success "Removed: $tdir"
                cleaned=$((cleaned + 1))
            else
                echo "  Task: $task_id"
                echo "  Branch: $branch"
                echo "  Reason: $reason"
                echo ""
            fi
        fi
    done

    if [[ "$force" == "true" ]]; then
        log_success "Cleaned up $cleaned task context(s)"
    elif [[ $found -eq 0 ]]; then
        log_success "No task contexts to clean up"
    else
        log_info "Run with --force to remove these $found task context(s)"
    fi
}

tasks_cmd() {
    local subcmd="${1:-list}"
    shift || true

    case "$subcmd" in
        list|ls|"")
            tasks_list
            ;;
        view|show)
            [[ -z "${1:-}" ]] && die "Usage: aid tasks view <task-id>"
            tasks_view "$1"
            ;;
        edit)
            [[ -z "${1:-}" ]] && die "Usage: aid tasks edit <task-id> [context.md|plan.md]"
            tasks_edit "$1" "${2:-plan.md}"
            ;;
        phase)
            [[ -z "${1:-}" ]] && die "Usage: aid tasks phase <task-id> <phase>"
            tasks_phase "$1" "${2:-}"
            ;;
        cleanup|clean)
            local mode="merged"
            local force="false"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --merged) mode="merged" ;;
                    --all)    mode="all" ;;
                    --force|-f) force="true" ;;
                    *) die "Unknown tasks cleanup option: $1" ;;
                esac
                shift
            done
            tasks_cleanup "$mode" "$force"
            ;;
        *)
            die "Unknown tasks subcommand: $subcmd  (list|view|edit|phase|cleanup|sync)"
            ;;
    esac
}

# ==============================================================================
# Usage
# ==============================================================================

usage() {
    cat <<EOF
${BOLD}aid${NC} - Autonomous AI workflow for OpenCode

${BOLD}USAGE${NC}
    aid                              Open OpenCode TUI interactively for user to provide task
    aid <github-issue-url>           Work on a GitHub issue
    aid <github-pr-url>              Work on a GitHub PR (implement requested changes)
    aid "task description"           Work on a plain text task
    aid review <pr-url>              Review a PR and post feedback (read-only)
    aid list                         List active dispatch sessions
    aid view <session-id>            View session details and optionally resume
    aid cleanup [options]            Clean up sessions (see options below)
    aid resume <session-id>          Resume a previous session
    aid tasks [subcommand]           Manage persistent task contexts
    aid help                         Show this help message
    aid --version                    Show version information

${BOLD}TASKS SUBCOMMANDS${NC}
    aid tasks                        List all task contexts (queries GitHub for live status)
    aid tasks list                   List all task contexts (queries GitHub for live status)
    aid tasks view <task-id>         Show task metadata, context.md, and plan.md
    aid tasks edit <task-id> [file]  Open context.md or plan.md in \$EDITOR
    aid tasks phase <task-id> <p>    Set phase (research|plan|implement|review|done)
    aid tasks cleanup [options]      Remove task contexts for merged/deleted branches
      --merged                       (default) Remove tasks whose branch is gone from origin
      --all                          Remove all task contexts
      --force, -f                    Actually remove (without this, just lists them)

${BOLD}CLEANUP OPTIONS${NC}
    --force, -f                 Actually remove sessions (without this, just lists them)
    --failed                    Clean up failed sessions
    --all                       Clean up both orphaned and failed sessions
    (default)                   Clean up orphaned sessions (running but process died)

${BOLD}EXAMPLES${NC}
    # Interactive mode - opens OpenCode TUI with initial prompt
    aid

    # Work on a GitHub issue
    aid https://github.com/user/repo/issues/123

    # Work on a GitHub PR (fix requested changes)
    aid https://github.com/user/repo/pull/456

    # Review a PR
    aid review https://github.com/user/repo/pull/456

    # Work on a custom task
    aid "Add dark mode toggle to settings page"

    # List all sessions
    aid list

    # View session details
    aid view 20260313-143052-12345

    # Clean up orphaned sessions (process died)
    aid cleanup --force

    # Clean up failed sessions
    aid cleanup --failed --force

    # Clean up all (orphaned + failed)
    aid cleanup --all --force

    # List all task contexts
    aid tasks

    # View a task's research notes and plan
    aid tasks view aid-20260313-143052-12345

    # Edit the implementation plan before work starts
    aid tasks edit aid-20260313-143052-12345 plan.md

    # Advance phase manually
    aid tasks phase aid-20260313-143052-12345 implement

    # Clean up tasks for merged branches
    aid tasks cleanup --merged --force

${BOLD}WORKFLOW${NC}
    1. AI creates PR via dispatch    -> PR opened; task phase advances to "review"
    2. You run: aid review <pr-url>  -> AI posts review comment
    3. If issues found:              -> Run: aid <pr-url> to fix
    4. When satisfied:               -> gh pr merge --delete-branch
    5. aid tasks (list)              -> Shows merged tasks with status "merged"
    6. Clean task contexts:          -> aid tasks cleanup --merged --force

${BOLD}ENVIRONMENT${NC}
    AID_DEBUG=1          Enable debug output
    AID_DRY_RUN=1        Show what would be done without executing
    AID_NO_CONTEXT=1     Disable task context injection

${BOLD}REQUIREMENTS${NC}
    - git (with worktree support)
    - gh (GitHub CLI, for issue fetching)
    - opencode
    - jq


${BOLD}FILES${NC}
    ~/.config/opencode/dispatch/        Session state files
    ~/.config/opencode/worktrees/       Git worktrees for AI work
    ~/.config/opencode/tasks/<id>/      Persistent task context directories
      task.json                         Task metadata (phase, branch, PR info)
      context.md                        Agent-written research notes
      plan.md                           Implementation plan (editable)

EOF
}

# ==============================================================================
# Main Entry Point
# ==============================================================================

main() {
    # Check required commands
    require_cmd git
    require_cmd opencode
    require_cmd jq
    require_cmd gh

    # Ensure directories exist
    mkdir -p "$DISPATCH_DIR" "$WORKTREES_DIR" "$TASKS_DIR"

    # Parse command
    local cmd="${1:-}"

    case "$cmd" in
        "")
            # Interactive mode - open OpenCode with initial prompt
            interactive_dispatch
            ;;
        help|--help|-h)
            usage
            exit 0
            ;;
        version|--version|-v)
            echo "aid version ${VERSION}"
            exit 0
            ;;
        list|ls)
            list_sessions
            ;;
        cleanup|clean)
            local mode="orphaned"
            local force="false"
            
            # Parse cleanup flags
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --force|-f) force="true" ;;
                    --failed) mode="failed" ;;
                    --all) mode="all" ;;
                    *) die "Unknown cleanup option: $1" ;;
                esac
                shift
            done
            
            cleanup_sessions "$mode" "$force"
            ;;
        resume)
            if [[ -z "${2:-}" ]]; then
                die "Usage: aid resume <session-id>"
            fi
            resume_session "$2"
            ;;
        view|show)
            if [[ -z "${2:-}" ]]; then
                die "Usage: aid view <session-id>"
            fi
            view_session "$2"
            ;;
        review)
            if [[ -z "${2:-}" ]]; then
                die "Usage: aid review <pr-url>"
            fi
            
            review_pr "$2"
            ;;
        tasks|task)
            shift
            tasks_cmd "$@"
            ;;
        *)
            # Assume it's a task description or URL
            dispatch "$cmd"
            ;;
    esac
}

main "$@"
