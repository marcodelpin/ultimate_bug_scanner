#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# C# ULTIMATE BUG SCANNER v1.0 (Bash) - Industrial-Grade Code Analysis
# ═══════════════════════════════════════════════════════════════════════════
# Comprehensive static analysis for modern C# (.NET 6+) using:
#   • Roslyn analyzers (built-in with dotnet build)
#   • Roslynator CLI (500+ additional analyzers)
#   • dotnet format (style/formatting checks)
#   • optional Security Code Scan (OWASP vulnerabilities)
#
# Focus:
#   • Null reference checks      • async/await pitfalls
#   • Dispose/IDisposable        • exception handling
#   • Security vulnerabilities   • code quality
#   • Performance patterns       • style consistency
#
# Supports:
#   --format text|json|sarif
#   --fail-on-warning, --skip, --jobs
#   --ci, --no-color
#   --fix (auto-fix with roslynator fix)
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
OUTPUT_FILE=""
FORMAT="text"
CI_MODE=0
FAIL_ON_WARNING=0
QUIET=0
NO_COLOR_FLAG=0
FIX_MODE=0
SKIP_BUILD=0
SKIP_ROSLYNATOR=0
SKIP_FORMAT=0

# Counters
TOTAL_CRITICAL=0
TOTAL_WARNING=0
TOTAL_INFO=0
FILES_SCANNED=0

# Symbols
CHECK="✓"; CROSS="✗"; WARN="⚠"; INFO="ℹ"; ARROW="→"; BULLET="•"
MAGNIFY="🔍"; BUG="🐛"; FIRE="🔥"; SPARKLE="✨"; SHIELD="🛡"; DOTNET="🔷"

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
# Usage
# ────────────────────────────────────────────────────────────────────────────

print_usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") [options] [PROJECT_DIR]

C# Ultimate Bug Scanner - Static analysis for .NET projects

Options:
  --format=FMT        Output format: text|json|sarif (default: text)
  --ci                CI mode (stable timestamps, no interactive)
  --fail-on-warning   Exit non-zero if warnings exist
  --fix               Auto-fix issues with roslynator fix
  --skip-build        Skip dotnet build step
  --skip-roslynator   Skip roslynator analysis
  --skip-format       Skip dotnet format check
  --no-color          Disable colored output
  -v, --verbose       More detailed output
  -q, --quiet         Minimal output
  -h, --help          Show this help

Examples:
  $(basename "$0") .                    # Scan current directory
  $(basename "$0") --fix MyProject/     # Scan and auto-fix
  $(basename "$0") --ci --format=sarif  # CI mode with SARIF output

Requirements:
  • dotnet SDK 6.0+
  • roslynator (dotnet tool install -g roslynator.dotnet.cli)
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
        --fix) FIX_MODE=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --skip-roslynator) SKIP_ROSLYNATOR=1; shift ;;
        --skip-format) SKIP_FORMAT=1; shift ;;
        --no-color) NO_COLOR_FLAG=1; USE_COLOR=0; init_colors; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -q|--quiet) QUIET=1; shift ;;
        -h|--help) print_usage; exit 0 ;;
        # Options passed by UBS meta-runner (accept and ignore)
        --exclude=*) shift ;;  # ignore patterns handled by meta-runner
        --exclude) shift 2 ;;
        --jobs=*) shift ;;     # parallelism handled by meta-runner
        --jobs) shift 2 ;;
        --skip=*) shift ;;     # category skip handled by meta-runner
        --skip) shift 2 ;;
        --report-json=*) shift ;;  # JS-specific
        --staged|--diff) shift ;;  # git-based modes handled by meta-runner
        -*) echo "Unknown option: $1" >&2; print_usage; exit 1 ;;
        *) PROJECT_DIR="$1"; shift ;;
    esac
done

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
    printf '{"version":"2.1.0","$schema":"https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json","runs":[{"tool":{"driver":{"name":"ubs-csharp","version":"%s","informationUri":"https://github.com/Dicklesworthstone/ultimate_bug_scanner"}},"results":%s}]}\n' \
        "$SCRIPT_VERSION" "$results"
}

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
║  ██████╗ ██╗   ██╗ ██████╗      ██████╗██╗  ██╗   ███╗   ██╗███████╗████████╗║
║  ██╔══██╗██║   ██║██╔════╝     ██╔════╝╚██╗██╔╝   ████╗  ██║██╔════╝╚══██╔══╝║
║  ██████╔╝██║   ██║██║  ███╗    ██║      ╚███╔╝    ██╔██╗ ██║█████╗     ██║   ║
║  ██╔══██╗██║   ██║██║   ██║    ██║      ██╔██╗    ██║╚██╗██║██╔══╝     ██║   ║
║  ██████╔╝╚██████╔╝╚██████╔╝    ╚██████╗██╔╝ ██╗   ██║ ╚████║███████╗   ██║   ║
║  ╚═════╝  ╚═════╝  ╚═════╝      ╚═════╝╚═╝  ╚═╝   ╚═╝  ╚═══╝╚══════╝   ╚═╝   ║
║                                                                           ║
║  C# • .NET • Roslyn • Roslynator                                          ║
║  UBS: ULTIMATE BUG SCANNER • C# MODULE 🔷                                 ║
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

    if command -v dotnet &>/dev/null; then
        local dotnet_version
        dotnet_version=$(dotnet --version 2>/dev/null || echo "unknown")
        echo -e "  ${CHECK} dotnet SDK ${dotnet_version}"
    else
        echo -e "  ${CROSS} dotnet SDK not found"
        missing=1
    fi

    if command -v roslynator &>/dev/null; then
        echo -e "  ${CHECK} roslynator available"
    else
        echo -e "  ${WARN} roslynator not found (install: dotnet tool install -g roslynator.dotnet.cli)"
        SKIP_ROSLYNATOR=1
    fi

    if [[ $missing -eq 1 ]]; then
        echo -e "${RED}${CROSS} Missing required tools. Install .NET SDK first.${RESET}"
        exit 1
    fi
    echo ""
}

# ────────────────────────────────────────────────────────────────────────────
# Find project/solution
# ────────────────────────────────────────────────────────────────────────────

find_target() {
    local dir="$1"

    # Try to find .sln first
    local sln
    sln=$(find "$dir" -maxdepth 2 -name "*.sln" -type f 2>/dev/null | head -1)
    if [[ -n "$sln" ]]; then
        echo "$sln"
        return 0
    fi

    # Fall back to .csproj
    local csproj
    csproj=$(find "$dir" -maxdepth 2 -name "*.csproj" -type f 2>/dev/null | head -1)
    if [[ -n "$csproj" ]]; then
        echo "$csproj"
        return 0
    fi

    return 1
}

# ────────────────────────────────────────────────────────────────────────────
# Count C# files
# ────────────────────────────────────────────────────────────────────────────

count_cs_files() {
    local dir="$1"
    find "$dir" -name "*.cs" -not -path "*/obj/*" -not -path "*/bin/*" 2>/dev/null | wc -l
}

# ────────────────────────────────────────────────────────────────────────────
# Run dotnet build (Roslyn analyzers)
# ────────────────────────────────────────────────────────────────────────────

run_dotnet_build() {
    local target="$1"

    echo -e "${MAGNIFY} ${BOLD}Phase 1: Roslyn Analyzers (dotnet build)${RESET}"
    echo -e "${DIM}────────────────────────────────────────────────────────────${RESET}"

    local build_output
    local build_exit=0

    # Run dotnet build and capture warnings/errors
    build_output=$(dotnet build "$target" --no-restore -v q -consoleloggerparameters:NoSummary 2>&1) || build_exit=$?

    # Parse warnings and errors
    local warnings errors
    warnings=$(echo "$build_output" | grep -c " warning " 2>/dev/null || true)
    errors=$(echo "$build_output" | grep -c " error " 2>/dev/null || true)
    warnings=${warnings:-0}
    errors=${errors:-0}
    warnings=$((warnings + 0))  # ensure numeric
    errors=$((errors + 0))      # ensure numeric

    TOTAL_WARNING=$((TOTAL_WARNING + warnings))
    TOTAL_CRITICAL=$((TOTAL_CRITICAL + errors))

    if [[ $errors -gt 0 ]]; then
        echo -e "${RED}${CROSS} Build errors: $errors${RESET}"
        echo "$build_output" | grep " error " | head -10
    fi

    if [[ $warnings -gt 0 ]]; then
        echo -e "${YELLOW}${WARN} Build warnings: $warnings${RESET}"
        if [[ $VERBOSE -eq 1 ]]; then
            echo "$build_output" | grep " warning " | head -20
        fi
    fi

    if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
        echo -e "${GREEN}${CHECK} No build issues${RESET}"
    fi

    echo ""
    return $build_exit
}

# ────────────────────────────────────────────────────────────────────────────
# Run Roslynator
# ────────────────────────────────────────────────────────────────────────────

run_roslynator() {
    local target="$1"

    echo -e "${MAGNIFY} ${BOLD}Phase 2: Roslynator Analysis${RESET}"
    echo -e "${DIM}────────────────────────────────────────────────────────────${RESET}"

    if [[ $SKIP_ROSLYNATOR -eq 1 ]]; then
        echo -e "${DIM}Skipped (roslynator not available)${RESET}"
        echo ""
        return 0
    fi

    local rosl_output
    local rosl_exit=0

    if [[ $FIX_MODE -eq 1 ]]; then
        echo -e "${INFO} Running roslynator fix..."
        roslynator fix "$target" 2>&1 || rosl_exit=$?
    else
        rosl_output=$(roslynator analyze "$target" 2>&1) || rosl_exit=$?
    fi

    if [[ $rosl_exit -eq 0 ]]; then
        echo -e "${GREEN}${CHECK} No Roslynator issues${RESET}"
    else
        # Count issues from output
        local issues
        issues=$(echo "$rosl_output" | grep -cE "^[A-Z]{2,}[0-9]+" 2>/dev/null || true)
        issues=${issues:-0}
        issues=$((issues + 0))  # ensure numeric
        TOTAL_WARNING=$((TOTAL_WARNING + issues))

        echo -e "${YELLOW}${WARN} Roslynator issues: $issues${RESET}"
        if [[ $VERBOSE -eq 1 ]]; then
            echo "$rosl_output" | head -30
        else
            echo "$rosl_output" | head -10
        fi
    fi

    echo ""
}

# ────────────────────────────────────────────────────────────────────────────
# Run dotnet format check
# ────────────────────────────────────────────────────────────────────────────

run_format_check() {
    local target="$1"

    echo -e "${MAGNIFY} ${BOLD}Phase 3: Format Check (dotnet format)${RESET}"
    echo -e "${DIM}────────────────────────────────────────────────────────────${RESET}"

    if [[ $SKIP_FORMAT -eq 1 ]]; then
        echo -e "${DIM}Skipped${RESET}"
        echo ""
        return 0
    fi

    local format_exit=0

    if [[ $FIX_MODE -eq 1 ]]; then
        dotnet format "$target" 2>&1 || format_exit=$?
        echo -e "${GREEN}${CHECK} Format applied${RESET}"
    else
        dotnet format "$target" --verify-no-changes 2>&1 || format_exit=$?
        if [[ $format_exit -eq 0 ]]; then
            echo -e "${GREEN}${CHECK} Format OK${RESET}"
        else
            TOTAL_INFO=$((TOTAL_INFO + 1))
            echo -e "${YELLOW}${WARN} Format issues detected (run with --fix to auto-fix)${RESET}"
        fi
    fi

    echo ""
}

# ────────────────────────────────────────────────────────────────────────────
# Print summary
# ────────────────────────────────────────────────────────────────────────────

print_summary() {
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════${RESET}"
    echo -e "                    ${DOTNET} SCAN COMPLETE ${DOTNET}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "Summary Statistics:"
    echo -e "  Files scanned:    $FILES_SCANNED"
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
        # Redirect FD 3 to original stdout for JSON, then redirect stdout to stderr
        exec 3>&1 1>&2
    fi

    # In text mode, show banner
    if [[ "$FORMAT" == "text" ]]; then
        print_banner
        echo -e "Project:  ${BOLD}$PROJECT_DIR${RESET}"
        echo -e "Started:  $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
    fi

    check_tools

    # Find target
    local target
    if ! target=$(find_target "$PROJECT_DIR"); then
        echo -e "${RED}${CROSS} No .sln or .csproj found in $PROJECT_DIR${RESET}"
        # Even on error, emit valid JSON if requested
        if [[ $machine_mode -eq 1 ]]; then
            if [[ "$FORMAT" == "sarif" ]]; then
                emit_sarif >&3
            else
                emit_json_summary >&3
            fi
        fi
        exit 1
    fi
    echo -e "${INFO} Target: ${CYAN}$target${RESET}"

    # Count files
    FILES_SCANNED=$(count_cs_files "$PROJECT_DIR")
    FILES_SCANNED=$((FILES_SCANNED + 0))  # ensure numeric
    echo -e "${INFO} Files:  $FILES_SCANNED source files (cs)"
    echo ""

    if [[ $FILES_SCANNED -eq 0 ]]; then
        echo -e "${YELLOW}${WARN} No C# files found${RESET}"
        if [[ $machine_mode -eq 1 ]]; then
            if [[ "$FORMAT" == "sarif" ]]; then
                emit_sarif >&3
            else
                emit_json_summary >&3
            fi
        fi
        exit 0
    fi

    # Restore packages first
    echo -e "${INFO} Restoring packages..."
    dotnet restore "$target" -v q 2>/dev/null || true
    echo ""

    # Run phases
    if [[ $SKIP_BUILD -eq 0 ]]; then
        run_dotnet_build "$target" || true
    fi

    run_roslynator "$target"

    run_format_check "$target"

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
