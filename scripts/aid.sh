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

# Build the initial dispatch prompt using commands/work.md as the source of truth.
# Falls back to the embedded template if the command file is unavailable.
build_work_prompt() {
    local task_text="$1"
    local cmd_file="${OPENCODE_CONFIG_DIR}/commands/work.md"
    local template=""

    if [[ -f "$cmd_file" ]]; then
        # Strip YAML frontmatter from command markdown and use the body template.
        template=$(awk '
            BEGIN { in_frontmatter = 0; frontmatter_seen = 0 }
            NR == 1 && $0 == "---" { in_frontmatter = 1; frontmatter_seen = 1; next }
            in_frontmatter && $0 == "---" { in_frontmatter = 0; next }
            !in_frontmatter { print }
        ' "$cmd_file")
    fi

    if [[ -z "$template" ]]; then
        template=$(cat <<'EOF'
<task>
$ARGUMENTS
</task>

<instructions>
Complete this task autonomously through to a pull request.

1. Understand the task by reading relevant code
2. Implement the solution, committing as you go
3. Get a code review from @reviewer (fix issues, max 3 cycles)
4. Push and create the PR

Output the PR URL when done. Only stop if genuinely blocked.
</instructions>
EOF
)
    fi

    # Replace placeholder used by OpenCode custom commands.
    template="${template//\$ARGUMENTS/$task_text}"
    printf '%s' "$template"
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
    [[ "$1" =~ ^https?://github\.com/[^/]+/[^/]+/pull/[0-9]+([/?#].*)?$ ]]
}

parse_github_pr_url() {
    local url="$1"
    if [[ "$url" =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)([/?#].*)?$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}/${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
        return 0
    fi
    return 1
}

normalize_github_pr_url() {
    local parsed repo number
    parsed=$(parse_github_pr_url "$1") || return 1
    repo="${parsed% *}"
    number="${parsed#* }"
    printf 'https://github.com/%s/pull/%s\n' "$repo" "$number"
}

extract_repo_path() {
    echo "$1" | sed -E 's|https?://github\.com/([^/]+/[^/]+)/[^/]+/[0-9]+.*|\1|'
}

extract_number() {
    if [[ "$1" =~ /([0-9]+)([/?#].*)?$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
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
    local normalized_input
    normalized_input=$(normalize_github_pr_url "$pr_url") || normalized_input="$pr_url"

    for tfile in "${TASKS_DIR}"/*/task.json; do
        [[ -f "$tfile" ]] || continue
        local url normalized_url
        url=$(jq -r '.pr_url // ""' "$tfile")
        normalized_url=$(normalize_github_pr_url "$url" 2>/dev/null || printf '%s' "$url")
        if [[ "$normalized_url" == "$normalized_input" ]]; then
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

line_in_pr_diff() {
    local worktree="$1"
    local base_ref="$2"
    local path="$3"
    local line_no="$4"

    local diff
    diff=$(git -C "$worktree" diff --unified=0 "origin/${base_ref}...HEAD" -- "$path" 2>/dev/null || true)
    [[ -n "$diff" ]] || return 1

    local header start count end
    while IFS= read -r header; do
        [[ "$header" =~ ^@@[[:space:]]-[0-9]+(,[0-9]+)?[[:space:]]\+([0-9]+)(,([0-9]+))?[[:space:]]@@ ]] || continue
        start="${BASH_REMATCH[2]}"
        count="${BASH_REMATCH[4]:-1}"
        [[ "$count" -gt 0 ]] || continue
        end=$((start + count - 1))
        if [[ "$line_no" -ge "$start" && "$line_no" -le "$end" ]]; then
            return 0
        fi
    done <<< "$diff"

    return 1
}

extract_reviewer_verdict() {
    local review_text="$1"
    local verdict=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^(PASS|NEEDS_FIXES)$ ]]; then
            verdict="$line"
            break
        fi
    done <<< "$review_text"

    printf '%s' "$verdict"
}

extract_reviewer_issues() {
    local review_text="$1"

    while IFS= read -r line; do
        [[ "$line" =~ ^-[[:space:]]\[([^]]+)\][[:space:]](.+)$ ]] || continue
        local location description path line_no
        location="${BASH_REMATCH[1]}"
        description="${BASH_REMATCH[2]}"
        [[ "$location" =~ ^(.+):([0-9]+)$ ]] || continue
        path="${BASH_REMATCH[1]}"
        line_no="${BASH_REMATCH[2]}"
        printf '%s\t%s\t%s\n' "$path" "$line_no" "$description"
    done <<< "$review_text"
}

build_review_summary() {
    local verdict="$1"
    local pr_url="$2"
    local inline_count="$3"
    local issue_count="$4"
    local fallback_notes="$5"
    local review_text="$6"

    local headline
    if [[ "$verdict" == "PASS" ]]; then
        headline="AI review verdict: PASS"
    else
        headline="AI review verdict: NEEDS_FIXES"
    fi

    local summary
    summary=$(cat <<EOF
${headline}

Reviewed PR: ${pr_url}
- Inline comments posted: ${inline_count}
- Findings detected: ${issue_count}

## Key Findings
EOF
)

    if [[ "$issue_count" -eq 0 ]]; then
        summary+=$'\n- None.\n'
    else
        local issues
        issues=$(extract_reviewer_issues "$review_text")
        if [[ -n "$issues" ]]; then
            while IFS=$'\t' read -r path line_no description; do
                summary+="- [${path}:${line_no}] ${description}"$'\n'
            done <<< "$issues"
        fi
    fi

    if [[ -n "$fallback_notes" ]]; then
        summary+=$'\n## Summary-Only Notes\n'
        summary+="$fallback_notes"
    fi

    printf '%s' "$summary"
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
    local is_pr_input=false
    local pr_number_input=""
    if is_github_issue_url "$input"; then
        require_cmd gh
        source_url="$input"
        local issue_repo issue_number
        issue_repo=$(extract_repo_path "$input")
        issue_number=$(extract_number "$input")

        log_info "Fetching issue #${issue_number} from ${issue_repo}..."
        issue_body=$(gh issue view "$issue_number" --repo "$issue_repo" --json title,body,number,comments \
            --jq '
                "Issue #" + (.number|tostring) + ": " + .title + "\n\n" + (.body // "") +
                ([.comments[] | select((.body // "") != "") |
                    "Comment by " + (.author.login // "unknown") + ":\n" + .body
                ] | if length > 0 then
                    "\n\n--- Issue Comments ---\n\n" + join("\n\n---\n\n")
                else "" end)
            ') || \
            die "Failed to fetch issue"
        source=$(cat <<EOF
IMPORTANT: This task came from GitHub issue ${issue_repo}#${issue_number}.
When you create or update the pull request description, include this exact line so GitHub auto-closes the issue on merge:

Closes ${issue_repo}#${issue_number}

Issue details:

${issue_body}
EOF
)
        repo="$issue_repo"
    elif is_github_pr_url "$input"; then
        require_cmd gh
        is_pr_input=true
        source_url=$(normalize_github_pr_url "$input") || source_url="$input"
        local pr_repo
        pr_repo=$(extract_repo_path "$source_url")
        pr_number_input=$(extract_number "$source_url")
        repo="$pr_repo"

        # Check if a task already tracks this PR
        local existing_task
        existing_task=$(find_task_by_pr "$source_url" 2>/dev/null) || true
        if [[ -n "$existing_task" ]]; then
            die "A task already tracks this PR: $existing_task. Use 'aid $existing_task' to resume."
        fi

        # Check PR state
        local pr_state
        pr_state=$(gh pr view "$pr_number_input" --repo "$pr_repo" --json state --jq '.state' 2>/dev/null) || \
            die "Failed to fetch PR #${pr_number_input}"
        case "$pr_state" in
            MERGED) die "PR #${pr_number_input} is already merged." ;;
            CLOSED) die "PR #${pr_number_input} is closed." ;;
        esac

        # Fetch PR description
        log_info "Fetching PR #${pr_number_input} from ${pr_repo}..."
        local pr_body
        pr_body=$(gh pr view "$pr_number_input" --repo "$pr_repo" --json title,body,number \
            --jq '"PR #" + (.number|tostring) + ": " + .title + "\n\n" + (.body // "")') || \
            die "Failed to fetch PR"

        # Fetch PR feedback (comments, reviews, review threads) — same as cmd_resume
        local pr_feedback=""
        pr_feedback=$(gh pr view "$pr_number_input" --repo "$pr_repo" \
            --json comments,reviews,reviewThreads \
            --jq '
                ([.reviews[] | select(.state != "APPROVED" and (.body // "") != "") |
                    "Review (" + .state + "): " + .body] +
                [.comments[] | select((.body // "") != "") |
                    "Comment: " + .body] +
                [.reviewThreads[] |
                    (if .isResolved then "Resolved thread" else "Unresolved thread" end) +
                    " on " + (.path // "unknown") + ":" + (.line // 0 | tostring) + "\n" +
                    (.comments[0].body // "")]
                ) | join("\n\n---\n\n")
            ' 2>/dev/null) || pr_feedback=""

        # Check for merge conflicts
        local mergeable_state
        mergeable_state=$(gh pr view "$pr_number_input" --repo "$pr_repo" --json mergeable --jq '.mergeable' 2>/dev/null) || mergeable_state=""
        if [[ "$mergeable_state" == "CONFLICTING" ]]; then
            if [[ -n "$pr_feedback" ]]; then
                pr_feedback="${pr_feedback}"$'\n\n'
            fi
            pr_feedback="${pr_feedback}SYSTEM ALERT: The PR has merge conflicts. Please resolve them."
        fi

        # Assemble full source
        source="$pr_body"
        if [[ -n "$pr_feedback" ]]; then
            source="${source}"$'\n\n--- PR Feedback ---\n\n'"${pr_feedback}"
        fi
    else
        source="$input"
        source_url=""
    fi

    # Create directories
    mkdir -p "$WORKTREES_DIR" "$TASKS_DIR"

    # Fetch latest
    log_info "Fetching latest from origin..."
    git fetch origin 2>/dev/null || die "Failed to fetch from origin"

    # Create worktree
    local worktree="${WORKTREES_DIR}/${task_id}"
    if [[ "$is_pr_input" == true ]]; then
        # Fetch PR head branch info (after git fetch so refs are current)
        local pr_head_branch pr_head_repo_owner
        pr_head_branch=$(gh pr view "$pr_number_input" --repo "$repo" \
            --json headRefName --jq '.headRefName' 2>/dev/null) || \
            die "Failed to get PR head branch"
        pr_head_repo_owner=$(gh pr view "$pr_number_input" --repo "$repo" \
            --json headRepositoryOwner --jq '.headRepositoryOwner.login' 2>/dev/null) || pr_head_repo_owner=""
        local base_repo_owner
        base_repo_owner=$(echo "$repo" | cut -d/ -f1)

        # Detect fork PRs: head repo owner differs from base repo owner
        if [[ -n "$pr_head_repo_owner" && "$pr_head_repo_owner" != "$base_repo_owner" ]]; then
            log_info "PR is from a fork (${pr_head_repo_owner}). Fetching fork ref..."
            git fetch "https://github.com/${pr_head_repo_owner}/$(echo "$repo" | cut -d/ -f2).git" \
                "${pr_head_branch}:refs/remotes/origin/${pr_head_branch}" 2>/dev/null || \
                die "Failed to fetch fork branch '${pr_head_branch}' from ${pr_head_repo_owner}"
        fi

        branch="$pr_head_branch"

        log_info "Creating worktree on PR branch: ${branch}"
        # Remove any stale local branch of the same name to avoid collisions.
        git branch -D "$branch" 2>/dev/null || true
        git worktree add -b "$branch" "$worktree" "origin/${branch}" || \
            die "Failed to create worktree for PR branch"
    else
        # Determine base branch and create a new branch
        local base_branch
        base_branch=$(get_base_branch)

        log_info "Creating worktree: ${worktree}"
        git worktree add "$worktree" -b "$branch" "origin/${base_branch}" || \
            die "Failed to create worktree"
    fi

    # Create task record
    create_task "$task_id" "$branch" "$source" "$source_url" "$repo"
    log_success "Created task: ${task_id}"

    # If created from a PR, record PR link while keeping status as "working"
    if [[ "$is_pr_input" == true && -n "$pr_number_input" ]]; then
        local tdir
        tdir=$(task_dir "$task_id")
        _atomic_task_update "${tdir}/task.json" \
            '.pr_url = $url | .pr_number = $num' \
            --arg     url "$source_url" \
            --argjson num "$pr_number_input"
    fi

    # Warn if source was too long
    local source_len=${#source}
    if [[ $source_len -gt $MAX_SOURCE_LEN ]]; then
        log_warn "Source is ${source_len} chars; only the first ${MAX_SOURCE_LEN} will be passed to the prompt."
    fi

    # Truncate source for the prompt
    local prompt_source
    prompt_source=$(truncate_str "$source" "$MAX_SOURCE_LEN")

    # Launch OpenCode in the worktree.
    # NOTE: `--prompt "/work ..."` is treated as a plain message on startup,
    # not as an interactive slash-command invocation. Build an equivalent
    # prompt from commands/work.md so startup behavior matches manual `/work`.
    local initial_prompt
    initial_prompt=$(build_work_prompt "$prompt_source")

    log_info "Starting OpenCode..."
    (cd "$worktree" && opencode --agent dispatch --prompt "$initial_prompt")

    # After OpenCode exits, update task status
    if [[ "$is_pr_input" == true ]]; then
        # Verify actual PR state before setting status
        local post_pr_state
        post_pr_state=$(gh pr view "$pr_number_input" --repo "$repo" --json state --jq '.state' 2>/dev/null) || post_pr_state=""
        case "$post_pr_state" in
            MERGED|CLOSED)
                log_info "PR #${pr_number_input} is ${post_pr_state,,}. Run 'aid cleanup' to remove this task."
                ;;
            OPEN)
                update_task_status "$task_id" "awaiting-review"
                log_success "Task ${task_id} has PR: ${source_url}"
                ;;
            *)
                # Network failure or unknown state — keep as working
                log_warn "Could not verify PR state. Task remains as 'working'. Resume with: aid ${task_id}"
                ;;
        esac
    else
        local pr_url pr_number
        pr_url=$(cd "$worktree" && gh pr view --json url -q '.url' 2>/dev/null) || true

        if [[ -n "$pr_url" ]]; then
            pr_number=$(extract_number "$pr_url")
            update_task_pr "$task_id" "$pr_url" "$pr_number"
            log_success "Task ${task_id} has PR: ${pr_url}"
        else
            log_info "No PR created yet. Resume with: aid ${task_id}"
        fi
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
        printf "\n${BOLD}AWAITING REVIEW${NC} ${DIM}(run 'aid view <id>' to inspect task details)${NC}\n"
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
        local normalized_input
        normalized_input=$(normalize_github_pr_url "$input") || normalized_input="$input"
        task_id=$(find_task_by_pr "$normalized_input") || die "No task found for PR: $input"
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
    
    [[ -d "${TASKS_DIR}/${task_id}" ]] || die "Task not found: $task_id"
    
    local pr_number pr_url repo source status created branch worktree source_url
    pr_number=$(get_task_field "$task_id" "pr_number")
    pr_url=$(get_task_field "$task_id" "pr_url")
    repo=$(get_task_field "$task_id" "repo")
    source=$(get_task_field "$task_id" "source")
    status=$(get_task_field "$task_id" "status")
    created=$(get_task_field "$task_id" "created")
    branch=$(get_task_field "$task_id" "branch")
    worktree=$(get_task_field "$task_id" "worktree")
    source_url=$(get_task_field "$task_id" "source_url")

    local source_max=1200
    local source_preview source_length
    source_preview=$(truncate_str "$source" "$source_max")
    source_length=${#source}

    local pr_display="(none)"
    if [[ -n "$pr_url" && -n "$pr_number" ]]; then
        pr_display="#${pr_number} (${pr_url})"
    elif [[ -n "$pr_url" ]]; then
        pr_display="$pr_url"
    elif [[ -n "$pr_number" ]]; then
        pr_display="#${pr_number}"
    fi

    printf "\n${BOLD}Task Details${NC}\n"
    printf "${BOLD}Task ID:${NC} %s\n" "$task_id"
    printf "${BOLD}Status:${NC} %s\n" "${status:-unknown}"
    printf "${BOLD}Created:${NC} %s\n" "${created:-unknown}"
    printf "${BOLD}Repo:${NC} %s\n" "${repo:-unknown}"
    printf "${BOLD}Branch:${NC} %s\n" "${branch:-unknown}"
    printf "${BOLD}Worktree:${NC} %s\n" "${worktree:-unknown}"
    printf "${BOLD}Source URL:${NC} %s\n" "${source_url:-none}"
    printf "${BOLD}PR:${NC} %s\n" "$pr_display"
    printf "\n${BOLD}Source${NC}\n"
    printf "%s\n" "$source_preview"

    if [[ "$source_length" -gt "$source_max" ]]; then
        printf "${DIM}... truncated (%s total chars)${NC}\n" "$source_length"
    fi
    printf "\n"
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
        local normalized_input
        normalized_input=$(normalize_github_pr_url "$input") || normalized_input="$input"
        task_id=$(find_task_by_pr "$normalized_input") || die "No task found for PR: $input"
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

cmd_review() {
    local pr_url="$1"

    require_cmd gh
    require_cmd git
    require_cmd jq
    require_cmd opencode

    is_github_pr_url "$pr_url" || die "Usage: aid review <github-pr-url>"

    local parsed repo pr_number
    parsed=$(parse_github_pr_url "$pr_url") || die "Invalid GitHub PR URL: $pr_url"
    repo="${parsed% *}"
    pr_number="${parsed#* }"

    local pr_json
    pr_json=$(gh pr view "$pr_number" --repo "$repo" \
        --json url,state,number,title,baseRefName,headRefName,headRefOid,headRepositoryOwner,isCrossRepository 2>/dev/null) || \
        die "Failed to access PR #${pr_number} in ${repo}. Check URL and GitHub access."

    local base_ref head_ref head_sha pr_state
    base_ref=$(echo "$pr_json" | jq -r '.baseRefName')
    head_ref=$(echo "$pr_json" | jq -r '.headRefName')
    head_sha=$(echo "$pr_json" | jq -r '.headRefOid')
    pr_state=$(echo "$pr_json" | jq -r '.state')

    [[ -n "$base_ref" && "$base_ref" != "null" ]] || die "PR metadata missing base ref"
    [[ -n "$head_ref" && "$head_ref" != "null" ]] || die "PR metadata missing head ref"
    [[ -n "$head_sha" && "$head_sha" != "null" ]] || die "PR metadata missing head SHA"

    if [[ "$pr_state" != "OPEN" ]]; then
        log_warn "PR is ${pr_state}. Posting review comments anyway."
    fi

    local changed_files
    changed_files=$(gh api "repos/${repo}/pulls/${pr_number}/files" --paginate --jq '.[].filename' 2>/dev/null) || \
        die "Failed to fetch changed files for PR #${pr_number}"

    local tmp_root repo_dir worktree
    tmp_root=$(mktemp -d)
    repo_dir="${tmp_root}/repo"
    worktree="${tmp_root}/worktree"

    cleanup_review_workspace() {
        if [[ -n "${repo_dir:-}" && -d "$repo_dir" && -n "${worktree:-}" && -d "$worktree" ]]; then
            git -C "$repo_dir" worktree remove "$worktree" --force >/dev/null 2>&1 || true
        fi
        [[ -n "${tmp_root:-}" && -d "$tmp_root" ]] && rm -rf "$tmp_root"
    }
    trap cleanup_review_workspace EXIT

    log_info "Cloning ${repo} into temporary workspace..."
    gh repo clone "$repo" "$repo_dir" -- --no-checkout >/dev/null 2>&1 || \
        die "Failed to clone ${repo}"

    log_info "Fetching PR refs..."
    git -C "$repo_dir" fetch --quiet origin \
        "+refs/heads/${base_ref}:refs/remotes/origin/${base_ref}" \
        "+refs/pull/${pr_number}/head:refs/remotes/origin/pr-${pr_number}-head" || \
        die "Failed to fetch PR refs for #${pr_number}"

    log_info "Creating temporary worktree for PR head branch..."
    git -C "$repo_dir" worktree add --detach "$worktree" "refs/remotes/origin/pr-${pr_number}-head" >/dev/null || \
        die "Failed to create temporary worktree"

    local changed_list
    if [[ -n "$changed_files" ]]; then
        changed_list=$(printf '%s\n' "$changed_files" | sed 's/^/- /')
    else
        changed_list="- (No changed files returned by GitHub API)"
    fi

    local review_prompt
    review_prompt=$(cat <<EOF
Review this GitHub pull request and return output exactly in your configured format.

PR URL: ${pr_url}
Repository: ${repo}
PR Number: ${pr_number}
Base branch: ${base_ref}
Head branch: ${head_ref}
Head SHA: ${head_sha}

Prioritize review coverage for changed files listed below, but read any other repository files as needed to verify indirect impacts, regressions, and standards.

Changed files:
${changed_list}

For each concrete finding, include an issue bullet with location in this exact shape:
- [path/to/file.ext:123] description

If no issues are found, output "None" in the Issues section and verdict PASS.
EOF
)

    log_info "Running AI review..."
    local review_text
    review_text=$(opencode run --agent reviewer --format json --dir "$worktree" "$review_prompt" \
        | jq -r 'select(.type == "text") | .part.text' 2>/dev/null) || \
        die "AI review failed"

    [[ -n "$review_text" ]] || die "AI review returned empty output"

    local verdict
    verdict=$(extract_reviewer_verdict "$review_text")
    if [[ "$verdict" != "PASS" && "$verdict" != "NEEDS_FIXES" ]]; then
        if extract_reviewer_issues "$review_text" | grep -q .; then
            verdict="NEEDS_FIXES"
        else
            verdict="PASS"
        fi
    fi

    local inline_count=0
    local issue_count=0
    local fallback_notes=""
    local issue_lines
    issue_lines=$(extract_reviewer_issues "$review_text")

    local changed_set_file
    changed_set_file="${tmp_root}/changed_files.txt"
    printf '%s\n' "$changed_files" > "$changed_set_file"

    if [[ -n "$issue_lines" ]]; then
        while IFS=$'\t' read -r path line_no description; do
            [[ -n "$path" && -n "$line_no" && -n "$description" ]] || continue
            issue_count=$((issue_count + 1))

            if ! grep -Fxq "$path" "$changed_set_file"; then
                fallback_notes+="- [${path}:${line_no}] ${description} (outside changed files; posted in summary only)"$'\n'
                continue
            fi

            if ! line_in_pr_diff "$worktree" "$base_ref" "$path" "$line_no"; then
                fallback_notes+="- [${path}:${line_no}] ${description} (line not mappable to PR diff; posted in summary only)"$'\n'
                continue
            fi

            if gh api -X POST "repos/${repo}/pulls/${pr_number}/comments" \
                -f body="AI review: ${description}" \
                -f commit_id="$head_sha" \
                -f path="$path" \
                -F line="$line_no" \
                -f side="RIGHT" >/dev/null 2>&1; then
                inline_count=$((inline_count + 1))
            else
                fallback_notes+="- [${path}:${line_no}] ${description} (GitHub rejected inline mapping; posted in summary only)"$'\n'
            fi
        done <<< "$issue_lines"
    fi

    local summary_body
    summary_body=$(build_review_summary "$verdict" "$pr_url" "$inline_count" "$issue_count" "$fallback_notes" "$review_text")

    log_info "Posting summary PR review comment..."
    gh api -X POST "repos/${repo}/pulls/${pr_number}/reviews" \
        -f event="COMMENT" \
        -f body="$summary_body" >/dev/null || \
        die "Failed to post summary review comment"

    log_success "Review submitted (${verdict}). Inline comments: ${inline_count}, findings: ${issue_count}"
    cleanup_review_workspace
    trap - EXIT
}

cmd_help() {
    cat <<EOF
${BOLD}aid${NC} - AI Development Workflow v${VERSION}

${BOLD}USAGE${NC}
  aid new "task description"     Create new task and start working
  aid new <issue-url>            Create task from GitHub issue
  aid new <pr-url>               Create task from GitHub PR (fetches feedback)
  aid status                     List tasks by status
  aid <task-id>                  Address PR feedback or conflicts (auto-merges if approved)
  aid <pr-url>                   Resume a locally tracked PR by its URL
  aid view <task-id>             Show task details in terminal
  aid review <pr-url>            Run AI review and post feedback on any PR URL
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
  aid new https://github.com/owner/repo/pull/15
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
            [[ -n "${2:-}" ]] || die "Usage: aid new <task-description|issue-url|pr-url>"
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
        review)
            [[ -n "${2:-}" ]] || die "Usage: aid review <github-pr-url>"
            cmd_review "$2"
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
