#!/usr/bin/env bash
#
# aid - AI development workflow for OpenCode

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
    
    local ready_to_merge=()
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
        # Sanitize source: replace pipe/tab/newline with space, truncate to 50 chars
        source=$(jq -r '.source // ""' "$tfile" | tr $'\n\t|' '   ' | head -c 50)
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
                OPEN:APPROVED)
                    status="ready-to-merge"
                    ;;
                OPEN:*)
                    # Check for reviews/comments
                    local feedback_json
                    feedback_json=$(gh pr view "$pr_number" --repo "$repo" --json comments,reviews \
                        --jq '{
                            changes_requested: [.reviews[] | select(.state == "CHANGES_REQUESTED")],
                            lgtm_comments: [.comments[] | select(.body | test("^lgtm[.!]?$"; "i"))],
                            regular_comments: [.comments[] | select(.body | test("^lgtm[.!]?$"; "i") | not)]
                        }' 2>/dev/null) || feedback_json="{}"

                    local changes_count lgtm_count comments_count
                    changes_count=$(echo "$feedback_json" | jq '.changes_requested | length')
                    lgtm_count=$(echo "$feedback_json" | jq '.lgtm_comments | length')
                    comments_count=$(echo "$feedback_json" | jq '.regular_comments | length')
                    
                    if [[ "$changes_count" -gt 0 ]]; then
                        status="needs-changes"
                    elif [[ "$lgtm_count" -gt 0 ]]; then
                        status="ready-to-merge"
                    elif [[ "$comments_count" -gt 0 ]]; then
                        status="needs-changes"
                    else
                        status="awaiting-review"
                    fi
                    ;;
            esac
        fi
        
        local entry="${task_id}|${pr_url:-none}|${source}..."
        
        case "$status" in
            ready-to-merge) ready_to_merge+=("$entry") ;;
            awaiting-review) awaiting_review+=("$entry") ;;
            needs-changes) needs_changes+=("$entry") ;;
            working) working+=("$entry") ;;
        esac
    done
    
    # Print results
    if [[ ${#ready_to_merge[@]} -gt 0 ]]; then
        printf "\n${BOLD}READY TO MERGE${NC} ${DIM}(run 'aid <id>' to auto-merge)${NC}\n"
        for entry in "${ready_to_merge[@]}"; do
            IFS='|' read -r id url desc <<< "$entry"
            printf "  ${GREEN}%s${NC}  %s  ${DIM}%s${NC}\n" "$id" "$url" "$desc"
        done
    fi

    if [[ ${#awaiting_review[@]} -gt 0 ]]; then
        printf "\n${BOLD}AWAITING REVIEW${NC} ${DIM}(run 'aid view <id>' to open PR)${NC}\n"
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
        printf "\n${BOLD}WORKING${NC} ${DIM}(AI is still working on these)${NC}\n"
        for entry in "${working[@]}"; do
            IFS='|' read -r id url desc <<< "$entry"
            printf "  ${BLUE}%s${NC}  ${DIM}%s${NC}\n" "$id" "$desc"
        done
    fi
    
    if [[ ${#ready_to_merge[@]} -eq 0 && ${#awaiting_review[@]} -eq 0 && ${#needs_changes[@]} -eq 0 && ${#working[@]} -eq 0 ]]; then
        log_info "No active tasks"
    fi
    
    printf "\n"
}

cmd_resume() {
    local input="$1"
    local task_id
    
    require_cmd opencode
    require_cmd jq
    require_cmd gh
    
    # Find task by ID or PR URL
    if is_github_pr_url "$input"; then
        task_id=$(find_task_by_pr "$input") || die "No task found for PR: $input"
    elif [[ -d "${TASKS_DIR}/${input}" ]]; then
        task_id="$input"
    else
        die "Task not found: $input"
    fi
    
    local worktree pr_number repo status
    worktree=$(get_task_field "$task_id" "worktree")
    pr_number=$(get_task_field "$task_id" "pr_number")
    repo=$(get_task_field "$task_id" "repo")
    status=$(get_task_field "$task_id" "status")
    
    [[ -d "$worktree" ]] || die "Worktree not found: $worktree"
    
    # Block if task has no PR yet
    if [[ -z "$pr_number" ]]; then
        die "Task has no PR yet. Wait for the AI to finish, or check 'aid status'."
    fi
    
    # Ensure repo is set
    [[ -n "$repo" ]] || die "Task has no repo configured."
    
    # Check PR state on GitHub
    local pr_state review_decision
    pr_state=$(gh pr view "$pr_number" --repo "$repo" --json state,reviewDecision \
        --jq '.state + ":" + (.reviewDecision // "")' 2>/dev/null) || pr_state=""
    
    case "$pr_state" in
        MERGED:*)
            die "PR #${pr_number} is already merged. Run 'aid cleanup' to remove this task."
            ;;
        CLOSED:*)
            die "PR #${pr_number} is closed. Run 'aid cleanup' to remove this task."
            ;;
    esac
    
    # Extract review decision from pr_state
    review_decision="${pr_state#*:}"
    
    # Auto-merge if approved by GitHub Review
    if [[ "$review_decision" == "APPROVED" ]]; then
        log_info "PR has been approved. Merging..."
        if cmd_approve "$task_id"; then
            return
        fi
        log_warn "Auto-merge failed. Handing back to agent."
    fi
    
    # Check for "LGTM" comment (case-insensitive, optional punctuation)
    local lgtm_comment
    lgtm_comment=$(gh pr view "$pr_number" --repo "$repo" --json comments \
        --jq '.comments[] | select(.body | test("^lgtm[.!]?$"; "i")) | .body' 2>/dev/null | head -n 1) || lgtm_comment=""
        
    if [[ -n "$lgtm_comment" ]]; then
        log_info "Found LGTM comment. Merging..."
        if cmd_approve "$task_id"; then
            return
        fi
        log_warn "Auto-merge failed. Handing back to agent."
    fi
    
    # Fetch PR feedback (reviews with content + recent comments with content)
    log_info "Fetching PR feedback..."
    local feedback
    feedback=$(gh pr view "$pr_number" --repo "$repo" --json comments,reviews \
        --jq '
            ([.reviews[] | select(.state == "CHANGES_REQUESTED" and .body != "") | "Review (CHANGES_REQUESTED): " + .body] +
             [.comments[-5:][] | select(.body != "" and (.body | test("^lgtm[.!]?$"; "i") | not)) | "Comment: " + .body]) | join("\n\n")
        ' 2>/dev/null) || feedback=""

    # Check for merge conflicts
    local mergeable_state
    mergeable_state=$(gh pr view "$pr_number" --repo "$repo" --json mergeable --jq '.mergeable' 2>/dev/null) || mergeable_state=""
    
    if [[ "$mergeable_state" == "CONFLICTING" ]]; then
        if [[ -n "$feedback" ]]; then
            feedback="${feedback}"$'\n\n'
        fi
        feedback="${feedback}SYSTEM ALERT: The PR has merge conflicts. Please resolve them."
    fi
    
    # Check if feedback has actual content (not just whitespace)
    if [[ -z "${feedback//[[:space:]]/}" ]]; then
        die "No feedback to address. Use 'aid approve ${task_id}' to merge, or add comments on the PR."
    fi
    
    update_task_status "$task_id" "working"
    
    cd "$worktree"
    
    log_info "Found feedback to address"
    local prompt
    printf -v prompt "Address this PR feedback:\n\n%s\n\nAfter fixing, push the changes." "$feedback"
    opencode --agent dispatch --prompt "$prompt"
    
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

cmd_view() {
    local task_id="$1"
    
    require_cmd jq
    require_cmd gh
    
    [[ -d "${TASKS_DIR}/${task_id}" ]] || die "Task not found: $task_id"
    
    local pr_number pr_url repo source status created
    pr_number=$(get_task_field "$task_id" "pr_number")
    pr_url=$(get_task_field "$task_id" "pr_url")
    repo=$(get_task_field "$task_id" "repo")
    source=$(get_task_field "$task_id" "source")
    status=$(get_task_field "$task_id" "status")
    created=$(get_task_field "$task_id" "created")
    
    # If PR exists with valid data, open in browser
    if [[ -n "$pr_number" && -n "$repo" ]]; then
        log_info "Opening PR in browser..."
        gh pr view "$pr_number" --repo "$repo" --web
    else
        # No PR yet, show task info
        printf "\n${BOLD}Task:${NC} %s\n" "$task_id"
        printf "${BOLD}Status:${NC} %s\n" "$status"
        printf "${BOLD}Created:${NC} %s\n" "$created"
        printf "${BOLD}Description:${NC}\n%s\n\n" "$source"
        log_info "No PR created yet"
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
    
    # Check for conflicts
    local mergeable_state
    mergeable_state=$(gh pr view "$pr_number" --repo "$repo" --json mergeable --jq '.mergeable' 2>/dev/null) || mergeable_state=""
    
    if [[ "$mergeable_state" == "CONFLICTING" ]]; then
        log_warn "PR #${pr_number} has merge conflicts."
        return 1
    fi
    
    log_info "Merging PR #${pr_number}..."
    if ! gh pr merge "$pr_number" --repo "$repo" --squash --delete-branch; then
        log_warn "Failed to merge PR #${pr_number}."
        return 1
    fi
    
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
            # Check if branch still exists (robust check using HTTP status)
            local http_code
            http_code=$(gh api "repos/${repo}/branches/${branch}" --include --silent 2>/dev/null | grep "^HTTP/" | tail -n 1 | awk '{print $2}' | tr -d '\r')
            http_code="${http_code:-000}"
            
            if [[ "$http_code" == "404" ]]; then
                 should_clean=true
            elif [[ "$http_code" == "000" || "$http_code" == "5"* ]]; then
                 log_warn "Could not check branch status for ${task_id} (API error)"
            fi
        fi
        
        if [[ "$should_clean" == "true" ]]; then
            log_info "Cleaning: ${task_id}"
            
            # Remove worktree
            if [[ -d "$worktree" ]]; then
                git worktree remove "$worktree" --force 2>/dev/null || rm -rf "$worktree"
            fi
            
            # Remove local branch if set
            if [[ -n "$branch" ]]; then
                git branch -D "$branch" 2>/dev/null || true
            fi
            
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
  aid <task-id>                  Address PR feedback or conflicts (auto-merges if approved)
  aid <pr-url>                   Address PR feedback by PR URL
  aid view <task-id>             Open PR in browser or show task info
  aid approve <task-id>          Merge PR and cleanup
  aid cleanup                    Remove merged/closed tasks
  aid help                       Show this help

${BOLD}WORKFLOW${NC}
  1. ${CYAN}aid new "Add feature X"${NC}
     Creates worktree, starts OpenCode, AI works through:
     explore -> plan -> implement -> review -> PR

  2. ${CYAN}aid status${NC}
     Check which tasks need attention

  3. Review PR on GitHub, leave comments or approve

  4. ${CYAN}aid <task-id>${NC}
     - If approved: auto-merges and cleans up
     - If has comments: AI addresses feedback

  5. ${CYAN}aid approve <task-id>${NC}
     Manually merge when ready

${BOLD}STATUSES${NC}
  ${BLUE}working${NC}          AI is actively working
  ${CYAN}awaiting-review${NC}  PR created, waiting for human
  ${YELLOW}needs-changes${NC}    Human requested changes
  ${GREEN}approved${NC}         Merged and cleaned up

${BOLD}EXAMPLES${NC}
  aid new "Fix login timeout bug"
  aid new https://github.com/owner/repo/issues/42
  aid status
  aid view aid-20260313-143052
  aid aid-20260313-143052
  aid approve aid-20260313-143052
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
        view)
            [[ -n "${2:-}" ]] || die "Usage: aid view <task-id>"
            cmd_view "$2"
            ;;
        approve)
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
