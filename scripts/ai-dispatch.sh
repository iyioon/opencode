#!/usr/bin/env bash
#
# ai-dispatch - Autonomous AI workflow for OpenCode
#
# Usage:
#   ai-dispatch <github-issue-url>      Work on a GitHub issue
#   ai-dispatch "task description"      Work on a plain text task
#   ai-dispatch list                    List active dispatch sessions
#   ai-dispatch cleanup [--force]       Clean up orphaned sessions
#   ai-dispatch resume <session-id>     Resume a previous session
#
# Environment:
#   AI_DISPATCH_DEBUG=1                 Enable debug output
#   AI_DISPATCH_DRY_RUN=1               Show what would be done without executing

set -euo pipefail

# ==============================================================================
# Version
# ==============================================================================

readonly VERSION="0.1.0"

# ==============================================================================
# Configuration
# ==============================================================================

readonly OPENCODE_CONFIG_DIR="${HOME}/.config/opencode"
readonly DISPATCH_DIR="${OPENCODE_CONFIG_DIR}/dispatch"
readonly WORKTREES_DIR="${OPENCODE_CONFIG_DIR}/worktrees"

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
    if [[ "${AI_DISPATCH_DEBUG:-}" == "1" ]]; then
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

# Sanitize string for use in branch names
sanitize_branch_name() {
    local input="$1"
    echo "$input" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-|-$//g' | cut -c1-50
}

# ==============================================================================
# GitHub Issue Parsing
# ==============================================================================

# Check if input looks like a GitHub issue URL
is_github_url() {
    local input="$1"
    [[ "$input" =~ ^https?://github\.com/[^/]+/[^/]+/issues/[0-9]+$ ]]
}

# Extract issue number from GitHub URL
extract_issue_number() {
    local url="$1"
    echo "$url" | grep -oE '[0-9]+$'
}

# Extract owner/repo from GitHub URL
extract_repo_path() {
    local url="$1"
    echo "$url" | sed -E 's|https?://github\.com/([^/]+/[^/]+)/issues/[0-9]+|\1|'
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

# Check if a branch is already being worked on
check_existing_session() {
    local branch_name="$1"

    for state_file in "${DISPATCH_DIR}"/*.json; do
        [[ -f "$state_file" ]] || continue

        local existing_branch existing_status
        existing_branch=$(jq -r '.branch_name' "$state_file" 2>/dev/null || echo "")
        existing_status=$(jq -r '.status' "$state_file" 2>/dev/null || echo "")

        if [[ "$existing_branch" == "$branch_name" && "$existing_status" == "running" ]]; then
            local session_id
            session_id=$(jq -r '.session_id' "$state_file")
            log_warn "Branch '$branch_name' is already being worked on (session: $session_id)"
            return 0
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
cleanup_orphans() {
    local force="${1:-false}"
    local cleaned=0
    local found=0

    log_info "Scanning for orphaned sessions..."

    for state_file in "${DISPATCH_DIR}"/*.json; do
        [[ -f "$state_file" ]] || continue

        local session_id status pid worktree_path branch_name source_repo
        session_id=$(jq -r '.session_id' "$state_file" 2>/dev/null || echo "")
        status=$(jq -r '.status' "$state_file" 2>/dev/null || echo "")
        pid=$(jq -r '.pid' "$state_file" 2>/dev/null || echo "")
        worktree_path=$(jq -r '.worktree_path' "$state_file" 2>/dev/null || echo "")
        branch_name=$(jq -r '.branch_name' "$state_file" 2>/dev/null || echo "")
        source_repo=$(jq -r '.source_repo' "$state_file" 2>/dev/null || echo "")

        # Skip completed/failed sessions
        if [[ "$status" != "running" ]]; then
            continue
        fi

        # Check if process is still running
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_debug "Session $session_id (PID $pid) is still running"
            continue
        fi

        found=$((found + 1))
        log_info "Found orphaned session: $session_id"

        if [[ "$force" == "true" ]]; then
            # Set cleanup variables and run cleanup
            CLEANUP_STATE_FILE="$state_file"
            CLEANUP_WORKTREE_PATH="$worktree_path"
            CLEANUP_BRANCH_NAME="$branch_name"
            CLEANUP_SOURCE_REPO="$source_repo"

            update_state_status "$state_file" "orphaned"
            cleanup
            cleaned=$((cleaned + 1))

            # Reset cleanup variables
            CLEANUP_STATE_FILE=""
            CLEANUP_WORKTREE_PATH=""
            CLEANUP_BRANCH_NAME=""
            CLEANUP_SOURCE_REPO=""
        else
            echo "  Session: $session_id"
            echo "  Branch: $branch_name"
            echo "  Worktree: $worktree_path"
            echo ""
        fi
    done

    if [[ "$force" == "true" ]]; then
        log_success "Cleaned up $cleaned orphaned session(s)"
    elif [[ $found -eq 0 ]]; then
        log_success "No orphaned sessions found"
    else
        log_info "Run 'ai-dispatch cleanup --force' to remove these $found session(s)"
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

    # Parse input - GitHub issue or plain text
    if is_github_url "$input"; then
        task_type="github_issue"
        task_source="$input"

        log_info "Fetching GitHub issue details..."
        issue_json=$(fetch_issue_details "$input")

        local issue_number issue_title
        issue_number=$(extract_issue_number "$input")
        issue_title=$(echo "$issue_json" | jq -r '.title')

        branch_name="ai/issue-${issue_number}"
        task_description="GitHub Issue #${issue_number}: ${issue_title}

$(echo "$issue_json" | jq -r '.body // "No description provided"')

Labels: $(echo "$issue_json" | jq -r '.labels | map(.name) | join(", ") // "none"')

Source: $input"

        log_info "Issue: #${issue_number} - ${issue_title}"
    else
        task_type="plain_text"
        task_source="cli"

        local sanitized
        sanitized=$(sanitize_branch_name "$input")
        branch_name="ai/task-${sanitized}-$(date +%H%M%S)"
        task_description="$input"

        log_info "Task: $input"
    fi

    # Check for existing session with same branch
    if check_existing_session "$branch_name"; then
        die "A session is already working on this branch. Use 'ai-dispatch list' to see active sessions."
    fi

    # Generate session ID
    session_id=$(generate_session_id)
    worktree_path="${WORKTREES_DIR}/${branch_name//\//-}"

    log_info "Session ID: $session_id"
    log_info "Branch: $branch_name"
    log_info "Worktree: $worktree_path"

    # Dry run check
    if [[ "${AI_DISPATCH_DRY_RUN:-}" == "1" ]]; then
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
    state_file=$(create_state_file "$session_id" "$branch_name" "$worktree_path" "$task_type" "$task_source" "$task_description" "$source_repo")

    # Set cleanup variables
    CLEANUP_STATE_FILE="$state_file"
    CLEANUP_WORKTREE_PATH="$worktree_path"
    CLEANUP_BRANCH_NAME="$branch_name"
    CLEANUP_SOURCE_REPO="$source_repo"

    # Set up cleanup trap
    trap cleanup EXIT SIGTERM SIGHUP SIGINT

    log_success "Worktree created successfully"

    # Prepare the task prompt
    local task_prompt
    task_prompt="You are working on the following task in an isolated git worktree.

## Task Description

${task_description}

## Instructions

1. Analyze the task requirements carefully
2. Plan your implementation approach
3. Implement the changes systematically
4. Write/update tests if applicable
5. Commit your changes with clear, conventional commit messages (feat:, fix:, docs:, etc.)
6. Self-review your work for quality and completeness
7. Create a pull request against the '${default_branch}' branch

## Important

- You are in worktree: ${worktree_path}
- Target branch for PR: ${default_branch}
- Make atomic commits as you progress
- If you encounter blockers, document them in the PR description

Begin working on this task now."

    # Change to worktree and run OpenCode
    log_info "Starting OpenCode in worktree..."
    echo ""

    cd "$worktree_path"

    # Run OpenCode with the dispatch agent
    opencode run --agent dispatch "$task_prompt"

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
# Usage
# ==============================================================================

usage() {
    cat <<EOF
${BOLD}ai-dispatch${NC} - Autonomous AI workflow for OpenCode

${BOLD}USAGE${NC}
    ai-dispatch <github-issue-url>      Work on a GitHub issue
    ai-dispatch "task description"      Work on a plain text task
    ai-dispatch list                    List active dispatch sessions
    ai-dispatch cleanup [--force]       Clean up orphaned sessions
    ai-dispatch resume <session-id>     Resume a previous session
    ai-dispatch help                    Show this help message
    ai-dispatch --version               Show version information

${BOLD}EXAMPLES${NC}
    # Work on a GitHub issue
    ai-dispatch https://github.com/user/repo/issues/123

    # Work on a custom task
    ai-dispatch "Add dark mode toggle to settings page"

    # List all sessions
    ai-dispatch list

    # Clean up orphaned worktrees
    ai-dispatch cleanup --force

${BOLD}ENVIRONMENT${NC}
    AI_DISPATCH_DEBUG=1       Enable debug output
    AI_DISPATCH_DRY_RUN=1     Show what would be done without executing

${BOLD}REQUIREMENTS${NC}
    - git (with worktree support)
    - gh (GitHub CLI, for issue fetching)
    - opencode
    - jq


${BOLD}FILES${NC}
    ~/.config/opencode/dispatch/    Session state files
    ~/.config/opencode/worktrees/   Git worktrees for AI work

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
    mkdir -p "$DISPATCH_DIR" "$WORKTREES_DIR"

    # Parse command
    local cmd="${1:-}"

    case "$cmd" in
        "")
            usage
            exit 0
            ;;
        help|--help|-h)
            usage
            exit 0
            ;;
        version|--version|-v)
            echo "ai-dispatch version ${VERSION}"
            exit 0
            ;;
        list|ls)
            list_sessions
            ;;
        cleanup|clean)
            local force="false"
            if [[ "${2:-}" == "--force" || "${2:-}" == "-f" ]]; then
                force="true"
            fi
            cleanup_orphans "$force"
            ;;
        resume)
            if [[ -z "${2:-}" ]]; then
                die "Usage: ai-dispatch resume <session-id>"
            fi
            resume_session "$2"
            ;;
        *)
            # Assume it's a task description or URL
            dispatch "$cmd"
            ;;
    esac
}

main "$@"
