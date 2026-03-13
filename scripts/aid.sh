#!/usr/bin/env bash
#
# aid - Simplified AI workflow for OpenCode
#
# Usage:
#   aid new "task description"       Create task and start working
#   aid new <github-issue-url>       Create task from GitHub issue
#   aid status                       List tasks by status
#   aid <task-id>                    Resume a task (address PR feedback)
#   aid <pr-url>                     Resume task from PR URL
#   aid approve <task-id>            Merge PR and cleanup (alias: lgtm)
#   aid lgtm <task-id>               Alias for approve
#   aid cleanup                      Remove merged/closed tasks
#   aid help                         Show help message
#
# Statuses:
#   working          - AI is actively working
#   awaiting-review  - PR created, waiting for human review
#   needs-changes    - Human requested changes
#   approved         - Merged and cleaned up

set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

readonly VERSION="1.0.0"
readonly OPENCODE_CONFIG_DIR="${HOME}/.config/opencode"
readonly WORKTREES_DIR="${OPENCODE_CONFIG_DIR}/worktrees"
readonly TASKS_DIR="${OPENCODE_CONFIG_DIR}/tasks"

# Colors
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[0;33m')
BLUE=$(printf '\033[0;34m')
CYAN=$(printf '\033[0;36m')
BOLD=$(printf '\033[1m')
DIM=$(printf '\033[2m')
NC=$(printf '\033[0m')

# ==============================================================================
# Utility Functions
# ==============================================================================

log_info() { printf '%b\n' "${BLUE}[info]${NC} $*"; }
log_success() { printf '%b\n' "${GREEN}[done]${NC} $*"; }
log_warn() { printf '%b\n' "${YELLOW}[warn]${NC} $*"; }
log_error() { printf '%b\n' "${RED}[error]${NC} $*" >&2; }
die() { log_error "$@"; exit 1; }

require_cmd() {
    command -v "$1" &>/dev/null || die "Required command not found: $1"
}

generate_task_id() {
    echo "aid-$(date +%Y%m%d-%H%M%S)"
}

# ==============================================================================
# GitHub URL Parsing
# ==============================================================================

is_github_issue_url() {
    [[ "$1" =~ ^https?://github\.com/[^/]+/[^/]+/issues/[0-9]+$ ]]
}

is_github_pr_url() {
    [[ "$1" =~ ^https?://github\.com/[^/]+/[^/]+/pull/[0-9]+$ ]]
}

extract_repo_path() {
    echo "$1" | sed -E 's|https?://github\.com/([^/]+/[^/]+)/[^/]+/[0-9]+.*|\1|'
}

extract_number() {
    echo "$1" | grep -oE '[0-9]+$'
}

get_current_repo_path() {
    local remote_url
    remote_url=$(git config --get remote.origin.url 2>/dev/null) || return 1
    if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/]+)(\.git)?$ ]]; then
        echo "${BASH_REMATCH[1]%.git}"
        return 0
    fi
    return 1
}

# ==============================================================================
# Task Management
# ==============================================================================

task_dir() {
    echo "${TASKS_DIR}/$1"
}

create_task() {
    local task_id="$1"
    local branch="$2"
    local source="$3"
    local source_url="${4:-}"
    local repo="${5:-}"
    
    local tdir
    tdir=$(task_dir "$task_id")
    mkdir -p "$tdir"
    
    cat > "${tdir}/task.json" <<EOF
{
  "id": "${task_id}",
  "branch": "${branch}",
  "worktree": "${WORKTREES_DIR}/${task_id}",
  "repo": "${repo}",
  "source": "${source}",
  "source_url": "${source_url}",
  "status": "working",
  "pr_number": null,
  "pr_url": null,
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

update_task_status() {
    local task_id="$1"
    local status="$2"
    local tdir
    tdir=$(task_dir "$task_id")
    
    [[ -f "${tdir}/task.json" ]] || return 1
    
    local tmp
    tmp=$(mktemp)
    jq --arg s "$status" '.status = $s' "${tdir}/task.json" > "$tmp" && mv "$tmp" "${tdir}/task.json"
}

update_task_pr() {
    local task_id="$1"
    local pr_url="$2"
    local pr_number="$3"
    local tdir
    tdir=$(task_dir "$task_id")
    
    [[ -f "${tdir}/task.json" ]] || return 1
    
    local tmp
    tmp=$(mktemp)
    jq --arg url "$pr_url" --argjson num "$pr_number" \
        '.pr_url = $url | .pr_number = $num | .status = "awaiting-review"' \
        "${tdir}/task.json" > "$tmp" && mv "$tmp" "${tdir}/task.json"
}

get_task_field() {
    local task_id="$1"
    local field="$2"
    local tdir
    tdir=$(task_dir "$task_id")
    
    [[ -f "${tdir}/task.json" ]] || return 1
    jq -r ".${field} // empty" "${tdir}/task.json"
}

find_task_by_pr() {
    local pr_url="$1"
    
    for tfile in "${TASKS_DIR}"/*/task.json; do
        [[ -f "$tfile" ]] || continue
        local url
        url=$(jq -r '.pr_url // ""' "$tfile")
        if [[ "$url" == "$pr_url" ]]; then
            jq -r '.id' "$tfile"
            return 0
        fi
    done
    return 1
}

find_task_by_branch() {
    local branch="$1"
    
    for tfile in "${TASKS_DIR}"/*/task.json; do
        [[ -f "$tfile" ]] || continue
        local b
        b=$(jq -r '.branch // ""' "$tfile")
        if [[ "$b" == "$branch" ]]; then
            jq -r '.id' "$tfile"
            return 0
        fi
    done
    return 1
}

# ==============================================================================
# Commands
# ==============================================================================

cmd_new() {
    local input="$1"
    local task_id source source_url repo issue_body
    
    task_id=$(generate_task_id)
    local branch="aid/${task_id#aid-}"
    
    require_cmd git
    require_cmd opencode
    require_cmd jq
    
    # Ensure we're in a git repo
    git rev-parse --git-dir &>/dev/null || die "Not in a git repository"
    
    # Get current repo path
    repo=$(get_current_repo_path) || repo=""
    
    # Parse input
    if is_github_issue_url "$input"; then
        require_cmd gh
        source_url="$input"
        local issue_repo issue_number
        issue_repo=$(extract_repo_path "$input")
        issue_number=$(extract_number "$input")
        
        log_info "Fetching issue #${issue_number} from ${issue_repo}..."
        issue_body=$(gh issue view "$issue_number" --repo "$issue_repo" --json title,body \
            --jq '"Issue #" + (.number|tostring) + ": " + .title + "\n\n" + .body') || \
            die "Failed to fetch issue"
        source="$issue_body"
        repo="$issue_repo"
    else
        source="$input"
        source_url=""
    fi
    
    # Create directories
    mkdir -p "$WORKTREES_DIR" "$TASKS_DIR"
    
    # Fetch latest
    log_info "Fetching latest from origin..."
    git fetch origin main 2>/dev/null || git fetch origin master 2>/dev/null || \
        die "Failed to fetch from origin"
    
    # Determine base branch
    local base_branch="main"
    git show-ref --verify --quiet refs/remotes/origin/main || base_branch="master"
    
    # Create worktree
    local worktree="${WORKTREES_DIR}/${task_id}"
    log_info "Creating worktree: ${worktree}"
    git worktree add "$worktree" -b "$branch" "origin/${base_branch}" || \
        die "Failed to create worktree"
    
    # Create task
    create_task "$task_id" "$branch" "$source" "$source_url" "$repo"
    log_success "Created task: ${task_id}"
    
    # Launch OpenCode
    log_info "Starting OpenCode..."
    cd "$worktree"
    
    # Escape source for prompt
    local escaped_source
    escaped_source=$(printf '%s' "$source" | head -c 2000)  # Limit length
    
    opencode --agent dispatch --prompt "/work ${escaped_source}"
    
    # After OpenCode exits, check if PR was created
    local pr_url pr_number
    pr_url=$(gh pr view --json url -q '.url' 2>/dev/null) || true
    
    if [[ -n "$pr_url" ]]; then
        pr_number=$(extract_number "$pr_url")
        update_task_pr "$task_id" "$pr_url" "$pr_number"
        log_success "Task ${task_id} has PR: ${pr_url}"
    else
        log_info "No PR created yet. Resume with: aid ${task_id}"
    fi
}

cmd_status() {
    require_cmd jq
    require_cmd gh
    
    [[ -d "$TASKS_DIR" ]] || { log_info "No tasks found"; return; }
    
    local awaiting_review=()
    local needs_changes=()
    local working=()
    
    for tfile in "${TASKS_DIR}"/*/task.json; do
        [[ -f "$tfile" ]] || continue
        
        local task_id status pr_number pr_url source repo
        task_id=$(jq -r '.id' "$tfile")
        status=$(jq -r '.status // "working"' "$tfile")
        pr_number=$(jq -r '.pr_number // empty' "$tfile")
        pr_url=$(jq -r '.pr_url // empty' "$tfile")
        source=$(jq -r '.source // ""' "$tfile" | head -c 50)
        repo=$(jq -r '.repo // ""' "$tfile")
        
        # Check live PR state if we have a PR
        if [[ -n "$pr_number" && -n "$repo" ]]; then
            local pr_state
            pr_state=$(gh pr view "$pr_number" --repo "$repo" --json state,reviewDecision \
                --jq '.state + ":" + (.reviewDecision // "")' 2>/dev/null) || pr_state=""
            
            case "$pr_state" in
                MERGED:*|CLOSED:*)
                    continue  # Skip merged/closed
                    ;;
                OPEN:CHANGES_REQUESTED)
                    status="needs-changes"
                    ;;
                OPEN:*)
                    # Check for unaddressed comments
                    local comment_count
                    comment_count=$(gh pr view "$pr_number" --repo "$repo" --json comments \
                        --jq '.comments | length' 2>/dev/null) || comment_count=0
                    if [[ "$comment_count" -gt 0 ]]; then
                        status="needs-changes"
                    else
                        status="awaiting-review"
                    fi
                    ;;
            esac
        fi
        
        local entry="${task_id}|${pr_url:-none}|${source}..."
        
        case "$status" in
            awaiting-review) awaiting_review+=("$entry") ;;
            needs-changes) needs_changes+=("$entry") ;;
            working) working+=("$entry") ;;
        esac
    done
    
    # Print results
    if [[ ${#awaiting_review[@]} -gt 0 ]]; then
        printf "\n${BOLD}AWAITING REVIEW${NC} ${DIM}(run 'aid lgtm <id>' to merge)${NC}\n"
        for entry in "${awaiting_review[@]}"; do
            IFS='|' read -r id url desc <<< "$entry"
            printf "  ${CYAN}%s${NC}  %s  ${DIM}%s${NC}\n" "$id" "$url" "$desc"
        done
    fi
    
    if [[ ${#needs_changes[@]} -gt 0 ]]; then
        printf "\n${BOLD}NEEDS CHANGES${NC} ${DIM}(run 'aid <id>' to address feedback)${NC}\n"
        for entry in "${needs_changes[@]}"; do
            IFS='|' read -r id url desc <<< "$entry"
            printf "  ${YELLOW}%s${NC}  %s  ${DIM}%s${NC}\n" "$id" "$url" "$desc"
        done
    fi
    
    if [[ ${#working[@]} -gt 0 ]]; then
        printf "\n${BOLD}WORKING${NC} ${DIM}(run 'aid <id>' to continue)${NC}\n"
        for entry in "${working[@]}"; do
            IFS='|' read -r id url desc <<< "$entry"
            printf "  ${BLUE}%s${NC}  ${DIM}%s${NC}\n" "$id" "$desc"
        done
    fi
    
    if [[ ${#awaiting_review[@]} -eq 0 && ${#needs_changes[@]} -eq 0 && ${#working[@]} -eq 0 ]]; then
        log_info "No active tasks"
    fi
    
    printf "\n"
}

cmd_resume() {
    local input="$1"
    local task_id
    
    require_cmd opencode
    require_cmd jq
    
    # Find task by ID or PR URL
    if is_github_pr_url "$input"; then
        task_id=$(find_task_by_pr "$input") || die "No task found for PR: $input"
    elif [[ -d "${TASKS_DIR}/${input}" ]]; then
        task_id="$input"
    else
        die "Task not found: $input"
    fi
    
    local worktree pr_number repo
    worktree=$(get_task_field "$task_id" "worktree")
    pr_number=$(get_task_field "$task_id" "pr_number")
    repo=$(get_task_field "$task_id" "repo")
    
    [[ -d "$worktree" ]] || die "Worktree not found: $worktree"
    
    # Fetch PR comments if we have a PR
    local feedback=""
    if [[ -n "$pr_number" && -n "$repo" ]]; then
        log_info "Fetching PR comments..."
        feedback=$(gh pr view "$pr_number" --repo "$repo" --json comments,reviews \
            --jq '
                ([.reviews[] | select(.state != "APPROVED") | "Review (" + .state + "): " + .body] +
                 [.comments[-5:][] | "Comment: " + .body]) | join("\n\n")
            ' 2>/dev/null) || feedback=""
    fi
    
    update_task_status "$task_id" "working"
    
    cd "$worktree"
    
    if [[ -n "$feedback" ]]; then
        log_info "Found feedback to address"
        opencode --agent dispatch --prompt "Address this PR feedback:\n\n${feedback}\n\nAfter fixing, push the changes."
    else
        log_info "Resuming task..."
        opencode --agent dispatch
    fi
    
    # Check if PR exists after session
    local pr_url
    pr_url=$(gh pr view --json url -q '.url' 2>/dev/null) || true
    if [[ -n "$pr_url" ]]; then
        local new_pr_number
        new_pr_number=$(extract_number "$pr_url")
        update_task_pr "$task_id" "$pr_url" "$new_pr_number"
        log_success "Task ${task_id} has PR: ${pr_url}"
    fi
}

cmd_approve() {
    local task_id="$1"
    
    require_cmd gh
    require_cmd jq
    require_cmd git
    
    [[ -d "${TASKS_DIR}/${task_id}" ]] || die "Task not found: $task_id"
    
    local pr_number repo worktree branch
    pr_number=$(get_task_field "$task_id" "pr_number")
    repo=$(get_task_field "$task_id" "repo")
    worktree=$(get_task_field "$task_id" "worktree")
    branch=$(get_task_field "$task_id" "branch")
    
    [[ -n "$pr_number" ]] || die "No PR associated with task: $task_id"
    [[ -n "$repo" ]] || die "No repo associated with task: $task_id"
    
    log_info "Merging PR #${pr_number}..."
    gh pr merge "$pr_number" --repo "$repo" --squash --delete-branch || \
        die "Failed to merge PR"
    
    log_success "PR #${pr_number} merged"
    
    # Cleanup worktree
    if [[ -d "$worktree" ]]; then
        log_info "Removing worktree..."
        git worktree remove "$worktree" --force 2>/dev/null || rm -rf "$worktree"
    fi
    
    # Cleanup local branch if exists
    git branch -D "$branch" 2>/dev/null || true
    
    # Remove task
    rm -rf "${TASKS_DIR}/${task_id}"
    
    log_success "Task ${task_id} completed and cleaned up"
}

cmd_cleanup() {
    require_cmd gh
    require_cmd jq
    require_cmd git
    
    [[ -d "$TASKS_DIR" ]] || { log_info "No tasks directory"; return; }
    
    local cleaned=0
    
    for tfile in "${TASKS_DIR}"/*/task.json; do
        [[ -f "$tfile" ]] || continue
        
        local task_id pr_number repo worktree branch
        task_id=$(jq -r '.id' "$tfile")
        pr_number=$(jq -r '.pr_number // empty' "$tfile")
        repo=$(jq -r '.repo // empty' "$tfile")
        worktree=$(jq -r '.worktree // empty' "$tfile")
        branch=$(jq -r '.branch // empty' "$tfile")
        
        local should_clean=false
        
        if [[ -n "$pr_number" && -n "$repo" ]]; then
            local pr_state
            pr_state=$(gh pr view "$pr_number" --repo "$repo" --json state -q '.state' 2>/dev/null) || pr_state=""
            
            if [[ "$pr_state" == "MERGED" || "$pr_state" == "CLOSED" ]]; then
                should_clean=true
            fi
        elif [[ -n "$branch" && -n "$repo" ]]; then
            # Check if branch still exists
            local http_status
            http_status=$(gh api "repos/${repo}/branches/${branch}" --silent 2>&1 | head -1) || http_status="404"
            if [[ "$http_status" == *"404"* ]]; then
                should_clean=true
            fi
        fi
        
        if [[ "$should_clean" == "true" ]]; then
            log_info "Cleaning: ${task_id}"
            
            # Remove worktree
            if [[ -d "$worktree" ]]; then
                git worktree remove "$worktree" --force 2>/dev/null || rm -rf "$worktree"
            fi
            
            # Remove local branch
            git branch -D "$branch" 2>/dev/null || true
            
            # Remove task
            rm -rf "${TASKS_DIR}/${task_id}"
            
            cleaned=$((cleaned + 1))
        fi
    done
    
    if [[ $cleaned -gt 0 ]]; then
        log_success "Cleaned ${cleaned} task(s)"
    else
        log_info "No tasks to clean"
    fi
}

cmd_help() {
    cat <<EOF
${BOLD}aid${NC} - AI Development Workflow v${VERSION}

${BOLD}USAGE${NC}
  aid new "task description"     Create new task and start working
  aid new <issue-url>            Create task from GitHub issue
  aid status                     List tasks by status
  aid <task-id>                  Resume a task
  aid <pr-url>                   Resume task by PR URL
  aid approve <task-id>          Merge PR and cleanup
  aid lgtm <task-id>             Alias for approve
  aid cleanup                    Remove merged/closed tasks
  aid help                       Show this help

${BOLD}WORKFLOW${NC}
  1. ${CYAN}aid new "Add feature X"${NC}
     Creates worktree, starts OpenCode, AI works through:
     explore -> plan -> implement -> review -> PR

  2. ${CYAN}aid status${NC}
     Check which tasks need attention

  3. Review PR on GitHub, leave comments if needed

  4. ${CYAN}aid <task-id>${NC}
     Resume to address feedback (if any)

  5. ${CYAN}aid lgtm <task-id>${NC}
     Approve and merge when ready

${BOLD}STATUSES${NC}
  ${BLUE}working${NC}          AI is actively working
  ${CYAN}awaiting-review${NC}  PR created, waiting for human
  ${YELLOW}needs-changes${NC}    Human requested changes
  ${GREEN}approved${NC}         Merged and cleaned up

${BOLD}EXAMPLES${NC}
  aid new "Fix login timeout bug"
  aid new https://github.com/owner/repo/issues/42
  aid status
  aid aid-20260313-143052
  aid lgtm aid-20260313-143052
  aid cleanup
EOF
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    local cmd="${1:-}"
    
    case "$cmd" in
        new)
            [[ -n "${2:-}" ]] || die "Usage: aid new <task-description|issue-url>"
            shift
            cmd_new "$*"
            ;;
        status|list|ls)
            cmd_status
            ;;
        approve|lgtm)
            [[ -n "${2:-}" ]] || die "Usage: aid approve <task-id>"
            cmd_approve "$2"
            ;;
        cleanup|clean)
            cmd_cleanup
            ;;
        help|--help|-h)
            cmd_help
            ;;
        --version|-v)
            echo "aid version ${VERSION}"
            ;;
        "")
            cmd_help
            ;;
        *)
            # Check if it's a task ID or PR URL to resume
            if is_github_pr_url "$cmd" || [[ -d "${TASKS_DIR}/${cmd}" ]]; then
                cmd_resume "$cmd"
            else
                die "Unknown command: $cmd. Run 'aid help' for usage."
            fi
            ;;
    esac
}

main "$@"
