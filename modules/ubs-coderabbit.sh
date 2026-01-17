#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# CODERABBIT ULTIMATE BUG SCANNER v1.0 (Bash) - AI Code Review Integration
# ═══════════════════════════════════════════════════════════════════════════
# AI-powered code review using CodeRabbit CLI
# https://docs.coderabbit.ai/cli/overview
#
# Features:
#   • AI-powered code analysis (logic errors, race conditions, null pointers)
#   • Cross-file dependency analysis
#   • 40+ integrated linters and SAST tools
#   • Pattern learning from team codebase
#
# Supports:
#   --format text|json|sarif
#   --fail-on-warning, --ci
#   --type uncommitted|staged|branch
#   --base BRANCH (comparison base)
# ═══════════════════════════════════════════════════════════════════════════

set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true
shopt -s extglob 2>/dev/null || true

# ────────────────────────────────────────────────────────────────────────────
# Globals & defaults
# ────────────────────────────────────────────────────────────────────────────

SCRIPT_VERSION="1.0.0"
VERBOSE=0
PROJECT_DIR="."
FORMAT="text"
CI_MODE=0
FAIL_ON_WARNING=0
QUIET=0
NO_COLOR_FLAG=0
REVIEW_TYPE="uncommitted"  # uncommitted, staged, branch
BASE_BRANCH=""
PROMPT_ONLY=0

# Counters
TOTAL_CRITICAL=0
TOTAL_WARNING=0
TOTAL_INFO=0
FILES_SCANNED=0

# Symbols
CHECK="✓"; CROSS="✗"; WARN="⚠"; INFO="ℹ"; ARROW="→"; BULLET="•"
MAGNIFY="🔍"; BUG="🐛"; FIRE="🔥"; SPARKLE="✨"; RABBIT="🐰"

# Color handling
USE_COLOR=1
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then USE_COLOR=0; fi

init_colors() {
    if [[ "$USE_COLOR" -eq 1 ]]; then
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
        MAGENTA='\033[0;35m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[0;90m'
        BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
    else
        RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; WHITE=''; GRAY=''
        BOLD=''; DIM=''; RESET=''
    fi
}
init_colors

# ────────────────────────────────────────────────────────────────────────────
# Error handling
# ────────────────────────────────────────────────────────────────────────────

on_err() {
    local ec=$?; local cmd=${BASH_COMMAND}; local line=${BASH_LINENO[0]}
    local src=${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}
    echo -e "\n${RED}${BOLD}Unexpected error (exit $ec)${RESET} ${DIM}at ${src}:${line}${RESET}" >&2
    echo -e "${DIM}Last command:${RESET} ${WHITE}$cmd${RESET}" >&2
    exit "$ec"
}
trap on_err ERR

# ────────────────────────────────────────────────────────────────────────────
# JSON/SARIF output helpers
# ────────────────────────────────────────────────────────────────────────────

now() {
    if [[ "$CI_MODE" -eq 1 ]]; then
        echo "CI-RUN"
    else
        date '+%Y-%m-%dT%H:%M:%S'
    fi
}

json_escape() {
    local s="${1-}"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

emit_json_summary() {
    printf '{"project":"%s","files":%s,"critical":%s,"warning":%s,"info":%s,"timestamp":"%s","format":"json"}\n' \
        "$(json_escape "$PROJECT_DIR")" "$FILES_SCANNED" "$TOTAL_CRITICAL" "$TOTAL_WARNING" "$TOTAL_INFO" "$(json_escape "$(now)")"
}

emit_sarif() {
    local results='[]'
    printf '{"version":"2.1.0","$schema":"https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json","runs":[{"tool":{"driver":{"name":"ubs-coderabbit","version":"%s","informationUri":"https://coderabbit.ai"}},"results":%s}]}\n' \
        "$SCRIPT_VERSION" "$results"
}

# ────────────────────────────────────────────────────────────────────────────
# Usage
# ────────────────────────────────────────────────────────────────────────────

print_usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") [options] [PROJECT_DIR]

CodeRabbit AI Code Review - Integration for UBS

Options:
  --format=FMT        Output format: text|json|sarif (default: text)
  --ci                CI mode (stable timestamps, no interactive)
  --fail-on-warning   Exit non-zero if warnings exist
  --type=TYPE         Review type: uncommitted|staged|branch (default: uncommitted)
  --base=BRANCH       Base branch for comparison (default: auto-detect)
  --prompt-only       Minimal output optimized for parsing
  --no-color          Disable colored output
  -v, --verbose       More detailed output
  -q, --quiet         Minimal output
  -h, --help          Show this help

Examples:
  $(basename "$0") .                       # Review uncommitted changes
  $(basename "$0") --type=staged .         # Review staged changes only
  $(basename "$0") --base=main --ci .      # Compare against main branch

Requirements:
  • CodeRabbit CLI (curl -fsSL https://cli.coderabbit.ai/install.sh | sh)
  • Authentication (coderabbit auth login)
USAGE
}

# ────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ────────────────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --format=*) FORMAT="${1#*=}"; shift ;;
        --format) FORMAT="$2"; shift 2 ;;
        --ci) CI_MODE=1; shift ;;
        --fail-on-warning) FAIL_ON_WARNING=1; shift ;;
        --type=*) REVIEW_TYPE="${1#*=}"; shift ;;
        --type) REVIEW_TYPE="$2"; shift 2 ;;
        --base=*) BASE_BRANCH="${1#*=}"; shift ;;
        --base) BASE_BRANCH="$2"; shift 2 ;;
        --prompt-only) PROMPT_ONLY=1; shift ;;
        --no-color) NO_COLOR_FLAG=1; USE_COLOR=0; init_colors; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -q|--quiet) QUIET=1; shift ;;
        -h|--help) print_usage; exit 0 ;;
        # Options passed by UBS meta-runner (accept and ignore)
        --exclude=*) shift ;;
        --exclude) shift 2 ;;
        --jobs=*) shift ;;
        --jobs) shift 2 ;;
        --skip=*) shift ;;
        --skip) shift 2 ;;
        --report-json=*) shift ;;
        --staged|--diff) REVIEW_TYPE="staged"; shift ;;
        -*) echo "Unknown option: $1" >&2; print_usage; exit 1 ;;
        *) PROJECT_DIR="$1"; shift ;;
    esac
done

# ────────────────────────────────────────────────────────────────────────────
# Banner
# ────────────────────────────────────────────────────────────────────────────

print_banner() {
    [[ "$QUIET" -eq 1 ]] && return
    cat <<'BANNER'
╔═══════════════════════════════════════════════════════════════════════════╗
║  ██╗   ██╗██╗  ████████╗██╗███╗   ███╗ █████╗ ████████╗███████╗           ║
║  ██║   ██║██║  ╚══██╔══╝██║████╗ ████║██╔══██╗╚══██╔══╝██╔════╝           ║
║  ██║   ██║██║     ██║   ██║██╔████╔██║███████║   ██║   █████╗             ║
║  ██║   ██║██║     ██║   ██║██║╚██╔╝██║██╔══██║   ██║   ██╔══╝             ║
║  ╚██████╔╝███████╗██║   ██║██║ ╚═╝ ██║██║  ██║   ██║   ███████╗           ║
║   ╚═════╝ ╚══════╝╚═╝   ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝   ╚═╝   ╚══════╝           ║
║                                                                           ║
║   ██████╗ ██████╗ ██████╗ ███████╗██████╗  █████╗ ██████╗ ██████╗ ██╗████████╗║
║  ██╔════╝██╔═══██╗██╔══██╗██╔════╝██╔══██╗██╔══██╗██╔══██╗██╔══██╗██║╚══██╔══╝║
║  ██║     ██║   ██║██║  ██║█████╗  ██████╔╝███████║██████╔╝██████╔╝██║   ██║   ║
║  ██║     ██║   ██║██║  ██║██╔══╝  ██╔══██╗██╔══██║██╔══██╗██╔══██╗██║   ██║   ║
║  ╚██████╗╚██████╔╝██████╔╝███████╗██║  ██║██║  ██║██████╔╝██████╔╝██║   ██║   ║
║   ╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ ╚═════╝ ╚═╝   ╚═╝   ║
║                                                                           ║
║  AI-Powered Code Review • 40+ Linters • Pattern Learning                  ║
║  UBS: ULTIMATE BUG SCANNER • CODERABBIT MODULE 🐰                         ║
║                                                                           ║
║  Night Owl QA                                                             ║
║  "We see bugs before you do."                                             ║
╚═══════════════════════════════════════════════════════════════════════════╝
BANNER
    echo ""
}

# ────────────────────────────────────────────────────────────────────────────
# Tool checks
# ────────────────────────────────────────────────────────────────────────────

check_tools() {
    local missing=0

    echo -e "${INFO} Checking required tools..."

    if command -v coderabbit &>/dev/null; then
        echo -e "  ${CHECK} coderabbit CLI available"
    elif command -v cr &>/dev/null; then
        echo -e "  ${CHECK} coderabbit CLI available (as 'cr')"
    else
        echo -e "  ${CROSS} coderabbit CLI not found"
        echo -e "  ${DIM}Install: curl -fsSL https://cli.coderabbit.ai/install.sh | sh${RESET}"
        missing=1
    fi

    if command -v git &>/dev/null; then
        echo -e "  ${CHECK} git available"
    else
        echo -e "  ${CROSS} git not found (required for diff analysis)"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        echo -e "${RED}${CROSS} Missing required tools.${RESET}"
        return 1
    fi
    echo ""
    return 0
}

# ────────────────────────────────────────────────────────────────────────────
# Count files to review
# ────────────────────────────────────────────────────────────────────────────

count_files_to_review() {
    local dir="$1"
    local type="$2"

    cd "$dir" || return 0

    case "$type" in
        staged)
            git diff --cached --name-only 2>/dev/null | wc -l
            ;;
        uncommitted)
            git diff --name-only 2>/dev/null | wc -l
            ;;
        branch)
            if [[ -n "$BASE_BRANCH" ]]; then
                git diff --name-only "$BASE_BRANCH"...HEAD 2>/dev/null | wc -l
            else
                git diff --name-only origin/main...HEAD 2>/dev/null | wc -l || \
                git diff --name-only origin/master...HEAD 2>/dev/null | wc -l || echo 0
            fi
            ;;
        *)
            find "$dir" -type f \( -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.go" -o -name "*.rs" -o -name "*.java" -o -name "*.cs" -o -name "*.rb" \) 2>/dev/null | wc -l
            ;;
    esac
}

# ────────────────────────────────────────────────────────────────────────────
# Run CodeRabbit review
# ────────────────────────────────────────────────────────────────────────────

run_coderabbit_review() {
    local dir="$1"

    echo -e "${MAGNIFY} ${BOLD}Running CodeRabbit AI Review${RESET}"
    echo -e "${DIM}────────────────────────────────────────────────────────────${RESET}"

    local cr_cmd="coderabbit"
    if ! command -v coderabbit &>/dev/null; then
        cr_cmd="cr"
    fi

    local -a cr_args=()

    # Use plain output for parsing
    cr_args+=("--plain")

    # Set review type
    cr_args+=("--type" "$REVIEW_TYPE")

    # Set base branch if specified
    if [[ -n "$BASE_BRANCH" ]]; then
        cr_args+=("--base" "$BASE_BRANCH")
    fi

    # Set working directory
    cr_args+=("--cwd" "$dir")

    # Disable color for parsing
    cr_args+=("--no-color")

    local cr_output
    local cr_exit=0

    if [[ $VERBOSE -eq 1 ]]; then
        echo -e "${DIM}Running: $cr_cmd ${cr_args[*]}${RESET}"
    fi

    cr_output=$("$cr_cmd" "${cr_args[@]}" 2>&1) || cr_exit=$?

    # Parse output for issues
    # CodeRabbit output format varies, we'll look for common patterns
    local critical_count=0
    local warning_count=0
    local info_count=0

    # Look for severity indicators in output
    critical_count=$(echo "$cr_output" | grep -ciE "(critical|error|severe|security vulnerability|race condition)" 2>/dev/null || true)
    warning_count=$(echo "$cr_output" | grep -ciE "(warning|potential issue|should|consider|might)" 2>/dev/null || true)
    info_count=$(echo "$cr_output" | grep -ciE "(info|suggestion|note|improvement|style)" 2>/dev/null || true)

    # Ensure numeric
    critical_count=${critical_count:-0}
    warning_count=${warning_count:-0}
    info_count=${info_count:-0}
    critical_count=$((critical_count + 0))
    warning_count=$((warning_count + 0))
    info_count=$((info_count + 0))

    TOTAL_CRITICAL=$((TOTAL_CRITICAL + critical_count))
    TOTAL_WARNING=$((TOTAL_WARNING + warning_count))
    TOTAL_INFO=$((TOTAL_INFO + info_count))

    if [[ $cr_exit -eq 0 ]]; then
        if [[ -z "$cr_output" || "$cr_output" == *"No changes"* || "$cr_output" == *"nothing to review"* ]]; then
            echo -e "${GREEN}${CHECK} No issues found (or no changes to review)${RESET}"
        else
            echo -e "${YELLOW}${WARN} CodeRabbit found potential issues${RESET}"
            if [[ $VERBOSE -eq 1 ]]; then
                echo "$cr_output"
            else
                echo "$cr_output" | head -20
                local total_lines
                total_lines=$(echo "$cr_output" | wc -l)
                if [[ $total_lines -gt 20 ]]; then
                    echo -e "${DIM}... ($((total_lines - 20)) more lines, use -v to see all)${RESET}"
                fi
            fi
        fi
    else
        if [[ "$cr_output" == *"not authenticated"* || "$cr_output" == *"auth"* ]]; then
            echo -e "${YELLOW}${WARN} CodeRabbit not authenticated${RESET}"
            echo -e "${DIM}Run: coderabbit auth login${RESET}"
            TOTAL_INFO=$((TOTAL_INFO + 1))
        elif [[ "$cr_output" == *"rate limit"* ]]; then
            echo -e "${YELLOW}${WARN} Rate limit reached (free tier: 2 reviews/hour)${RESET}"
            TOTAL_INFO=$((TOTAL_INFO + 1))
        else
            echo -e "${YELLOW}${WARN} CodeRabbit review returned warnings${RESET}"
            echo "$cr_output" | head -10
        fi
    fi

    echo ""
}

# ────────────────────────────────────────────────────────────────────────────
# Print summary
# ────────────────────────────────────────────────────────────────────────────

print_summary() {
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════${RESET}"
    echo -e "                    ${RABBIT} SCAN COMPLETE ${RABBIT}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "Summary Statistics:"
    echo -e "  Files reviewed:   $FILES_SCANNED"
    echo -e "  Critical issues:  $TOTAL_CRITICAL"
    echo -e "  Warning issues:   $TOTAL_WARNING"
    echo -e "  Info items:       $TOTAL_INFO"
    echo ""

    if [[ $TOTAL_CRITICAL -gt 0 ]]; then
        echo -e "${RED}${FIRE} FIX CRITICAL ISSUES IMMEDIATELY${RESET}"
    elif [[ $TOTAL_WARNING -gt 0 ]]; then
        echo -e "${YELLOW}${WARN} Review warnings when possible${RESET}"
    else
        echo -e "${GREEN}${SPARKLE} No issues found!${RESET}"
    fi
    echo ""
}

# ────────────────────────────────────────────────────────────────────────────
# Main
# ────────────────────────────────────────────────────────────────────────────

main() {
    # For JSON/SARIF mode: redirect stdout to stderr for human output, keep JSON for stdout
    local machine_mode=0
    if [[ "$FORMAT" == "json" || "$FORMAT" == "jsonl" || "$FORMAT" == "sarif" ]]; then
        machine_mode=1
        exec 3>&1 1>&2
    fi

    # Use source project dir for git operations (may differ from shadow workspace)
    local GIT_PROJECT_DIR="${UBS_SOURCE_PROJECT_DIR:-$PROJECT_DIR}"

    # In text mode, show banner
    if [[ "$FORMAT" == "text" ]]; then
        print_banner
        echo -e "Project:  ${BOLD}$GIT_PROJECT_DIR${RESET}"
        echo -e "Review:   ${BOLD}$REVIEW_TYPE${RESET}"
        echo -e "Started:  $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
    fi

    # Check if it's a git repo (use GIT_PROJECT_DIR, not shadow workspace)
    if [[ ! -d "$GIT_PROJECT_DIR/.git" ]]; then
        # Try to find git root
        local git_root
        git_root=$(cd "$GIT_PROJECT_DIR" && git rev-parse --show-toplevel 2>/dev/null) || true
        if [[ -z "$git_root" ]]; then
            echo -e "${YELLOW}${WARN} Not a git repository - CodeRabbit requires git${RESET}"
            if [[ $machine_mode -eq 1 ]]; then
                if [[ "$FORMAT" == "sarif" ]]; then
                    emit_sarif >&3
                else
                    emit_json_summary >&3
                fi
            fi
            exit 0
        fi
        GIT_PROJECT_DIR="$git_root"
    fi

    # Update PROJECT_DIR to use the git repo for all operations
    PROJECT_DIR="$GIT_PROJECT_DIR"

    if ! check_tools; then
        if [[ $machine_mode -eq 1 ]]; then
            if [[ "$FORMAT" == "sarif" ]]; then
                emit_sarif >&3
            else
                emit_json_summary >&3
            fi
        fi
        exit 1
    fi

    # Count files
    FILES_SCANNED=$(count_files_to_review "$PROJECT_DIR" "$REVIEW_TYPE")
    FILES_SCANNED=$((FILES_SCANNED + 0))
    echo -e "${INFO} Files to review: $FILES_SCANNED"
    echo ""

    if [[ $FILES_SCANNED -eq 0 ]]; then
        echo -e "${GREEN}${CHECK} No changes to review${RESET}"
        if [[ $machine_mode -eq 1 ]]; then
            if [[ "$FORMAT" == "sarif" ]]; then
                emit_sarif >&3
            else
                emit_json_summary >&3
            fi
        fi
        exit 0
    fi

    # Run CodeRabbit
    run_coderabbit_review "$PROJECT_DIR"

    # Output based on format
    if [[ $machine_mode -eq 1 ]]; then
        if [[ "$FORMAT" == "sarif" ]]; then
            emit_sarif >&3
        else
            emit_json_summary >&3
        fi
    else
        print_summary
    fi

    # Exit code
    if [[ $FAIL_ON_WARNING -eq 1 && ($TOTAL_CRITICAL -gt 0 || $TOTAL_WARNING -gt 0) ]]; then
        exit 1
    elif [[ $TOTAL_CRITICAL -gt 0 ]]; then
        exit 1
    fi

    exit 0
}

main "$@"
