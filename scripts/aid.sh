#!/usr/bin/env bash
#
# aid - AI development workflow for OpenCode
#

set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

readonly VERSION="1.0.0"
readonly OPENCODE_CONFIG_DIR="${HOME}/.config/opencode"
readonly WORKTREES_DIR="${OPENCODE_CONFIG_DIR}/worktrees"
readonly TASKS_DIR="${OPENCODE_CONFIG_DIR}/tasks"

# Max source length (characters) passed to the OpenCode prompt.
readonly MAX_SOURCE_LEN=4000

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

log_info()    { printf '%b\n' "${BLUE}[info]${NC} $*"; }
log_success() { printf '%b\n' "${GREEN}[done]${NC} $*"; }
log_warn()    { printf '%b\n' "${YELLOW}[warn]${NC} $*"; }
log_error()   { printf '%b\n' "${RED}[error]${NC} $*" >&2; }
die()         { log_error "$@"; exit 1; }

require_cmd() {
    command -v "$1" &>/dev/null || die "Required command not found: $1"
}

generate_task_id() {
    # Include nanoseconds (or PID as fallback) to prevent same-second collisions.
    local ns
    ns=$(date +%N 2>/dev/null) || ns="$$"
    echo "aid-$(date +%Y%m%d-%H%M%S)-${ns:0:6}"
}

# Safely truncate a string to at most $max characters without splitting multibyte
# chars.  $max is passed via --argjson to avoid filter-injection.
truncate_str() {
    local str="$1"
    local max="$2"
    printf '%s' "$str" | jq -Rrs --argjson max "$max" '.[0:$max]'
}

# URL-encode a string (percent-encode everything except unreserved chars).
urlencode() {
    local string="$1"
    local encoded=""
    local i c
    for (( i = 0; i < ${#string}; i++ )); do
        c="${string:$i:1}"
        case "$c" in
            [A-Za-z0-9\-._~]) encoded+="$c" ;;
            *) encoded+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    echo "$encoded"
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

# Detect the default remote branch (main or master).
get_base_branch() {
    if git show-ref --verify --quiet refs/remotes/origin/main; then
        echo "main"
    elif git show-ref --verify --quiet refs/remotes/origin/master; then
        echo "master"
    else
        # Fallback: parse the symbolic-ref of the remote HEAD via ls-remote
        local ref
        ref=$(git ls-remote --symref origin HEAD 2>/dev/null \
              | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}')
        echo "${ref:-main}"
    fi
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

    # Use jq to build the JSON so special characters are properly escaped.
    jq -n \
        --arg id         "$task_id" \
        --arg branch     "$branch" \
        --arg worktree   "${WORKTREES_DIR}/${task_id}" \
        --arg repo       "$repo" \
        --arg source     "$source" \
        --arg source_url "$source_url" \
        --arg created    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            id:         $id,
            branch:     $branch,
            worktree:   $worktree,
            repo:       $repo,
            source:     $source,
            source_url: $source_url,
            status:     "working",
            pr_number:  null,
            pr_url:     null,
            created:    $created
        }' > "${tdir}/task.json"
}

# Atomically update task.json via a temp file, cleaning up on failure.
# Runs in a subshell so the trap does not clobber the caller's trap state.
_atomic_task_update() {
    local task_file="$1"
    local jq_expr="$2"
    shift 2
    # remaining args are extra --arg / --argjson flags for jq

    (
        local tmp
        tmp=$(mktemp)
        trap 'rm -f "$tmp"' EXIT

        jq "$@" "$jq_expr" "$task_file" > "$tmp" && mv "$tmp" "$task_file"
    )
}

update_task_status() {
    local task_id="$1"
    local status="$2"
    local tdir
    tdir=$(task_dir "$task_id")

    [[ -f "${tdir}/task.json" ]] || return 1
    _atomic_task_update "${tdir}/task.json" '.status = $s' --arg s "$status"
}

update_task_pr() {
    local task_id="$1"
    local pr_url="$2"
    local pr_number="$3"
    local tdir
    tdir=$(task_dir "$task_id")

    [[ -f "${tdir}/task.json" ]] || return 1
    _atomic_task_update "${tdir}/task.json" \
        '.pr_url = $url | .pr_number = $num | .status = "awaiting-review"' \
        --arg    url "$pr_url" \
        --argjson num "$pr_number"
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

_cleanup_task_artifacts() {
    local task_id="$1"
    local worktree="$2"
    local branch="$3"

    # Remove worktree
    if [[ -d "$worktree" ]]; then
        git worktree remove "$worktree" --force 2>/dev/null || rm -rf "$worktree"
    fi

    # Remove local branch
    if [[ -n "$branch" ]]; then
        git branch -D "$branch" 2>/dev/null || true
    fi

    # Remove task record
    rm -rf "${TASKS_DIR}/${task_id}"
}

# ==============================================================================
# Commands
# ==============================================================================

cmd_new() {
    local input="$*"   # join all args — caller passed "$@" after shifting 'new'
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
        issue_body=$(gh issue view "$issue_number" --repo "$issue_repo" --json title,body,number \
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
    git fetch origin 2>/dev/null || die "Failed to fetch from origin"

    # Determine base branch
    local base_branch
    base_branch=$(get_base_branch)

    # Create worktree
    local worktree="${WORKTREES_DIR}/${task_id}"
    log_info "Creating worktree: ${worktree}"
    git worktree add "$worktree" -b "$branch" "origin/${base_branch}" || \
        die "Failed to create worktree"

    # Create task record
    create_task "$task_id" "$branch" "$source" "$source_url" "$repo"
    log_success "Created task: ${task_id}"

    # Warn if source was too long
    local source_len=${#source}
    if [[ $source_len -gt $MAX_SOURCE_LEN ]]; then
        log_warn "Source is ${source_len} chars; only the first ${MAX_SOURCE_LEN} will be passed to the prompt."
    fi

    # Truncate source for the prompt
    local prompt_source
    prompt_source=$(truncate_str "$source" "$MAX_SOURCE_LEN")

    # Launch OpenCode in the worktree.
    log_info "Starting OpenCode..."
    (cd "$worktree" && opencode --agent dispatch --prompt "/work ${prompt_source}")

    # After OpenCode exits, check if a PR was created
    local pr_url pr_number
    pr_url=$(cd "$worktree" && gh pr view --json url -q '.url' 2>/dev/null) || true

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

    # Collect all task files first
    local task_files=()
    for tfile in "${TASKS_DIR}"/*/task.json; do
        [[ -f "$tfile" ]] || continue
        task_files+=("$tfile")
    done

    [[ ${#task_files[@]} -gt 0 ]] || { log_info "No active tasks"; printf "\n"; return; }

    # Fetch live PR state for each task in parallel into a shared temp dir.
    local tmpdir
    tmpdir=$(mktemp -d)

    local pids=()
    for tfile in "${task_files[@]}"; do
        local task_id pr_number repo
        task_id=$(jq -r '.id' "$tfile")
        pr_number=$(jq -r '.pr_number // empty' "$tfile")
        repo=$(jq -r '.repo // empty' "$tfile")

        if [[ -n "$pr_number" && -n "$repo" ]]; then
            # Fetch PR state in background; write result to a temp file.
            (
                gh pr view "$pr_number" --repo "$repo" \
                    --json state,reviewDecision,reviewThreads \
                    --jq '{
                        state:           .state,
                        reviewDecision:  (.reviewDecision // ""),
                        hasUnresolved:   ([.reviewThreads[] | select(.isResolved == false)] | length > 0)
                    }' 2>/dev/null > "${tmpdir}/${task_id}.json" || true
            ) &
            pids+=($!)
        fi
    done

    # Wait for all background fetches (guard against empty array under set -u on bash 3.2)
    for pid in "${pids[@]+"${pids[@]}"}"; do
        wait "$pid" || true
    done

    # Process results
    for tfile in "${task_files[@]}"; do
        local task_id status pr_number pr_url source repo
        task_id=$(jq -r '.id' "$tfile")
        status=$(jq -r '.status // "working"' "$tfile")
        pr_number=$(jq -r '.pr_number // empty' "$tfile")
        pr_url=$(jq -r '.pr_url // empty' "$tfile")
        # Safe truncation via jq — avoids splitting multibyte chars; collapse newlines for display.
        source=$(jq -r '.source // "" | gsub("\n"; " ") | .[0:60]' "$tfile")
        repo=$(jq -r '.repo // ""' "$tfile")

        if [[ -n "$pr_number" && -n "$repo" && -f "${tmpdir}/${task_id}.json" ]]; then
            local pr_state review_decision has_unresolved
            pr_state=$(jq -r '.state // ""' "${tmpdir}/${task_id}.json")
            review_decision=$(jq -r '.reviewDecision // ""' "${tmpdir}/${task_id}.json")
            has_unresolved=$(jq -r '.hasUnresolved' "${tmpdir}/${task_id}.json")

            case "$pr_state" in
                MERGED|CLOSED)
                    continue  # Skip merged/closed
                    ;;
                OPEN)
                    # Use detailed status logic from origin/main
                    if [[ "$review_decision" == "CHANGES_REQUESTED" ]]; then
                        status="needs-changes"
                    elif [[ "$review_decision" == "APPROVED" ]]; then
                        status="ready-to-merge"
                    else
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
                        elif [[ "$comments_count" -gt 0 || "$has_unresolved" == "true" ]]; then
                            status="needs-changes"
                        else
                            status="awaiting-review"
                        fi
                    fi
                    ;;
            esac
        fi

        local entry="${task_id}|${pr_url:-none}|${source}..."

        case "$status" in
            ready-to-merge) ready_to_merge+=("$entry") ;;
            awaiting-review) awaiting_review+=("$entry") ;;
            needs-changes)   needs_changes+=("$entry") ;;
            working)         working+=("$entry") ;;
        esac
    done

    rm -rf "$tmpdir"

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

    # Block if task has no PR yet (only if status is not working? No, wait.)
    # If PR number is empty, we might be in early "working" stage.
    # But if we called resume explicitly, we might want to just resume opencode.
    if [[ -z "$pr_number" ]]; then
         # If no PR, just resume working
         log_info "No PR yet. Resuming task..."
         (cd "$worktree" && opencode --agent dispatch)
         return
    fi
    
    # Ensure repo is set if PR is set
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
    
    # Check for "LGTM" comment
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

    # Fetch PR feedback (combining HEAD's detailed feedback with conflict checking)
    log_info "Fetching PR feedback..."
    local feedback=""
    feedback=$(gh pr view "$pr_number" --repo "$repo" \
        --json comments,reviews,reviewThreads \
        --jq '
            # Non-approved reviews with a body
            ([.reviews[] | select(.state != "APPROVED" and (.body // "") != "") |
                "Review (" + .state + "): " + .body] +
            # Top-level PR comments (all of them)
            [.comments[] | select((.body // "") != "") |
                "Comment: " + .body] +
            # Inline review thread comments (unresolved highlighted)
            [.reviewThreads[] |
                (if .isResolved then "Resolved thread" else "Unresolved thread" end) +
                " on " + (.path // "unknown") + ":" + (.line // 0 | tostring) + "\n" +
                (.comments[0].body // "")]
            ) | join("\n\n---\n\n")
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

    update_task_status "$task_id" "working"

    if [[ -n "$feedback" ]]; then
        log_info "Found feedback to address"
        # Use printf to correctly expand \n into newlines in the prompt string.
        local prompt_text
        prompt_text=$(printf 'Address this PR feedback and push the changes when done:\n\n%s' "$feedback")
        (cd "$worktree" && opencode --agent dispatch --prompt "$prompt_text")
    else
        log_info "Resuming task..."
        (cd "$worktree" && opencode --agent dispatch)
    fi

    # Check if PR exists (or was newly created) after session
    local pr_url
    pr_url=$(cd "$worktree" && gh pr view --json url -q '.url' 2>/dev/null) || true
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
    [[ -n "$repo" ]]      || die "No repo associated with task: $task_id"

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

    log_info "Removing artifacts..."
    _cleanup_task_artifacts "$task_id" "$worktree" "$branch"

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
        task_id=$(jq -r '.id'                   "$tfile")
        pr_number=$(jq -r '.pr_number // empty' "$tfile")
        repo=$(jq -r '.repo // empty'           "$tfile")
        worktree=$(jq -r '.worktree // empty'   "$tfile")
        branch=$(jq -r '.branch // empty'       "$tfile")

        local should_clean=false

        if [[ -n "$pr_number" && -n "$repo" ]]; then
            local pr_state
            pr_state=$(gh pr view "$pr_number" --repo "$repo" --json state -q '.state' 2>/dev/null) || pr_state=""

            if [[ "$pr_state" == "MERGED" || "$pr_state" == "CLOSED" ]]; then
                should_clean=true
            fi
        elif [[ -n "$branch" && -n "$repo" ]]; then
            # URL-encode the branch name so slashes (e.g. aid/20260313-...) are
            # passed as a single path segment rather than multiple segments.
            local encoded_branch
            encoded_branch=$(urlencode "$branch")
            if ! gh api "repos/${repo}/branches/${encoded_branch}" &>/dev/null; then
                should_clean=true
            fi
        fi

        if [[ "$should_clean" == "true" ]]; then
            log_info "Cleaning: ${task_id}"
            _cleanup_task_artifacts "$task_id" "$worktree" "$branch"
            cleaned=$((cleaned + 1))
        fi
    done

    if [[ $cleaned -gt 0 ]]; then
        log_success "Cleaned ${cleaned} task(s)"
    else
        log_info "No tasks to clean"
    fi
}

cmd_remove() {
    local input="$1"
    local force="${2:-}"
    local task_id

    require_cmd jq
    require_cmd gh
    require_cmd git

    # Resolve task ID
    if is_github_pr_url "$input"; then
        task_id=$(find_task_by_pr "$input") || die "No task found for PR: $input"
    elif [[ -d "${TASKS_DIR}/${input}" ]]; then
        task_id="$input"
    else
        die "Task not found: $input"
    fi

    local pr_number pr_url repo worktree branch
    pr_number=$(get_task_field "$task_id" "pr_number")
    pr_url=$(get_task_field "$task_id" "pr_url")
    repo=$(get_task_field "$task_id" "repo")
    worktree=$(get_task_field "$task_id" "worktree")
    branch=$(get_task_field "$task_id" "branch")

    # Check for open PR
    if [[ -n "$pr_number" && -n "$repo" ]]; then
        local pr_state
        pr_state=$(gh pr view "$pr_number" --repo "$repo" --json state -q '.state' 2>/dev/null) || pr_state=""
        
        if [[ "$pr_state" == "OPEN" ]]; then
            if [[ "$force" != "--force" && "$force" != "-f" ]]; then
                log_warn "Task has an open PR: ${pr_url:-#$pr_number}"
                log_warn "Use 'aid remove ${task_id} --force' to delete local task anyway."
                log_info "To close the PR first, run: gh pr close ${pr_url:-$pr_number}"
                return 1
            fi
        fi
    fi

    log_info "Removing task ${task_id}..."
    _cleanup_task_artifacts "$task_id" "$worktree" "$branch"
    log_success "Task ${task_id} removed"
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
  aid remove <task-id>           Remove a task (use --force to delete open PRs)
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
  ${CYAN}awaiting-review${NC}  PR created, waiting for human review
  ${YELLOW}needs-changes${NC}    Human requested changes or left unresolved threads
  ${GREEN}ready-to-merge${NC}   PR approved or LGTM

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
            cmd_new "$@"
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
        remove|rm|delete)
            [[ -n "${2:-}" ]] || die "Usage: aid remove <task-id>"
            cmd_remove "$2" "${3:-}"
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
