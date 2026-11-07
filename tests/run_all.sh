#!/usr/bin/env bash
# Run the LuaSH test matrix: each test file against each Lua interpreter,
# process backend and popen strategy, against the standalone library, and
# on a host without luaposix and luv.
#
# Usage: tests/run_all.sh  (or make test, which first rebuilds
# standalone/sh.lua). Runs from the repository root wherever it is called.
#
# Environment:
#   LUASH_INTERPRETERS  interpreters to test, separated by whitespace, as
#                       paths or command names; default: the four of the
#                       development machine (DEFAULT_INTERPRETERS below)
#   LUASH_TIMEOUT       seconds after which a run is stopped and counted as
#                       failed; default 120, 0 for no limit
#   LUASH_LOG_DIR       directory that keeps the output of every run;
#                       default: a temporary directory, removed when no
#                       run failed
#
# Each run prints one line. PASS: exit status 0. SKIP: exit status 0 and a
# line of output that starts with "SKIP:". FAIL: any other exit status, or
# stopped after LUASH_TIMEOUT. MISS: the test file, or standalone/sh.lua for
# the standalone runs, does not exist yet. A summary table follows; the
# exit status is 1 when any run failed.
set -euo pipefail

BACKENDS=(posix luv popen)
STRATEGIES=(standard basic minimal)
STANDALONE_BACKENDS=(posix popen)
DEFAULT_INTERPRETERS=(
    /opt/homebrew/bin/lua
    /opt/homebrew/bin/luajit
    "$HOME/Developer/cli-util-mods/opt/bin/lua"
    "$HOME/Developer/cli-util-mods/opt/bin/lua-static"
)
# Hides luaposix and luv, as on a host that has neither (PLAN.md 1.2): no C
# module search path, and nothing preloaded into the interpreter binary.
NO_C_MODULES='package.cpath = ""; package.preload.posix = nil; package.preload.luv = nil'
# Prints the interpreter's version and which of the optional modules it has.
PROBE='io.write(jit and jit.version or _VERSION,
    pcall(require, "posix") and ", luaposix" or "",
    pcall(require, "luv") and ", luv" or "", "\n")'

timeout="${LUASH_TIMEOUT:-120}"
if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
    echo "run_all.sh: LUASH_TIMEOUT must be a number of seconds" >&2
    exit 2
fi

# cd prints a directory that it found through CDPATH, which would end up in
# the paths captured below.
unset CDPATH

# A relative LUASH_LOG_DIR names a directory below the caller's current
# directory, so it is made absolute before the cd to the root.
if [ -n "${LUASH_LOG_DIR:-}" ]; then
    mkdir -p "$LUASH_LOG_DIR"
    log_dir="$(cd "$LUASH_LOG_DIR" && pwd)"
    keep_logs=1
else
    tmp_root="${TMPDIR:-/tmp}"
    log_dir="$(mktemp -d "${tmp_root%/}/run_all.XXXXXX")"
    keep_logs=0
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# PLAN.md 1.2. A LUA_PATH from the environment (luarocks in CI) follows
# ours; an unset one becomes ";;", which stands for the default path.
export LUA_PATH="./?/init.lua;./?.lua;./tests/?.lua;${LUA_PATH:-;}"
# Each run sets the variables it needs; none leaks in from the caller.
unset LUASH_BACKEND LUASH_POPEN_STRATEGY LUASH_STANDALONE

interps=()   # usable interpreters, one column of the matrix each
infos=()     # version and optional modules of each, for the legend
notes=()     # interpreters that were left out, and why
rows=()      # run labels, the rows of the matrix, in order of first use
cells=()     # result of row r in column c at index r * ${#interps[@]} + c
running=""   # pid of the run in progress, for the interrupt handler
col=0        # column of the interpreter being tested, from 0
interp=""    # path of the interpreter being tested
n_pass=0
n_fail=0
n_skip=0
n_miss=0

# Stops the run in progress, so that Ctrl-C does not leave it behind.
on_interrupt() {
    if [ -n "$running" ]; then
        pkill -TERM -P "$running" 2>/dev/null || true
        kill -TERM "$running" 2>/dev/null || true
    fi
    echo "run_all.sh: interrupted; logs are in $log_dir" >&2
    exit 130
}
trap on_interrupt INT TERM

# Adds each candidate that runs to interps and infos, and each one that
# does not to notes.
find_interpreters() {
    local candidates=()
    if [ -n "${LUASH_INTERPRETERS:-}" ]; then
        read -r -a candidates <<< "${LUASH_INTERPRETERS//$'\n'/ }"
    else
        candidates=("${DEFAULT_INTERPRETERS[@]}")
    fi
    local candidate=""
    local resolved=""
    local info=""
    for candidate in ${candidates[@]+"${candidates[@]}"}; do
        if ! resolved="$(command -v "$candidate")"; then
            notes+=("$candidate: not found, or not executable")
            continue
        fi
        if ! info="$("$resolved" -e "$PROBE" 2>/dev/null < /dev/null)"; then
            notes+=("$resolved: does not run Lua code")
            continue
        fi
        interps+=("$resolved")
        infos+=("$info")
    done
}

# Sets row to the index of LABEL in rows, appending LABEL when it is new.
find_row() {
    local label="$1"
    row=0
    while [ "$row" -lt "${#rows[@]}" ]; do
        if [ "${rows[row]}" = "$label" ]; then
            return 0
        fi
        row=$(( row + 1 ))
    done
    rows+=("$label")
}

# Stores RESULT for LABEL in the current column and prints the run's line.
record() {
    local result="$1"
    local label="$2"
    local detail="$3"
    find_row "$label"
    local index=$(( row * ${#interps[@]} + col ))
    cells[index]="$result"
    case "$result" in
        PASS) n_pass=$(( n_pass + 1 )) ;;
        FAIL) n_fail=$(( n_fail + 1 )) ;;
        SKIP) n_skip=$(( n_skip + 1 )) ;;
        MISS) n_miss=$(( n_miss + 1 )) ;;
    esac
    printf '%-4s  #%-2s %-32s %s\n' \
        "$result" "$(( col + 1 ))" "$label" "$detail"
}

# Stops process PID once it has run for $timeout seconds: TERM to its
# children and to it, KILL two seconds later. Programs further down the
# tree are left to fail on their closed pipes. Creates MARK so that the
# caller can tell.
watchdog() {
    local pid="$1"
    local mark="$2"
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$timeout" ]; then
            : > "$mark"
            # Children first: once PID is gone they belong to init.
            pkill -TERM -P "$pid" 2>/dev/null || true
            kill -TERM "$pid" 2>/dev/null || return 0
            sleep 2
            kill -KILL "$pid" 2>/dev/null || true
            return 0
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
}

# Runs a command with stdin from /dev/null and its output in LOG, under the
# watchdog unless $timeout is 0, and returns its exit status. A run that was
# stopped leaves LOG.timeout behind.
run_logged() {
    local log="$1"
    shift
    rm -f "$log.timeout"
    if [ "$timeout" -eq 0 ]; then
        "$@" > "$log" 2>&1 < /dev/null
        return
    fi
    "$@" > "$log" 2>&1 < /dev/null &
    running="$!"
    watchdog "$running" "$log.timeout" > /dev/null 2>&1 &
    local dog="$!"
    local status=0
    wait "$running" 2>/dev/null || status=$?
    running=""
    kill "$dog" 2>/dev/null || true
    wait "$dog" 2>/dev/null || true
    return "$status"
}

# Runs one cell of the matrix with the current interpreter and records it.
# Usage: run_case LABEL [LUASH_NAME=VALUE ...] [-e CHUNK] FILE [ARG ...]
# The assignments go into the run's environment; -e CHUNK runs before FILE,
# as with lua's own option.
run_case() {
    local label="$1"
    shift
    local vars=()
    local needs=()
    while [ "$#" -gt 0 ] && [[ "$1" == LUASH_*=* ]]; do
        vars+=("$1")
        if [ "$1" = "LUASH_STANDALONE=1" ]; then
            needs+=(standalone/sh.lua)
        fi
        shift
    done
    local pre=()
    if [ "${1:-}" = "-e" ]; then
        pre=(-e "$2")
        shift 2
    fi
    local file="$1"
    shift

    local needed=""
    for needed in "$file" ${needs[@]+"${needs[@]}"}; do
        if [ ! -f "$needed" ]; then
            record MISS "$label" "$needed not found"
            return 0
        fi
    done

    local log="$log_dir/$(( col + 1 ))-${label//[!A-Za-z0-9.]/_}.log"
    local started="$SECONDS"
    local status=0
    run_logged "$log" \
        env ${vars[@]+"${vars[@]}"} \
        "$interp" ${pre[@]+"${pre[@]}"} "$file" "$@" \
        || status=$?
    local elapsed=$(( SECONDS - started ))

    local skip_line=""
    if [ -f "$log.timeout" ]; then
        record FAIL "$label" "stopped after ${timeout}s, log: $log"
    elif [ "$status" -ne 0 ]; then
        record FAIL "$label" "exit status $status, log: $log"
    elif skip_line="$(grep -m 1 '^SKIP:' "$log")"; then
        skip_line="${skip_line#SKIP:}"
        record SKIP "$label" "${skip_line# }"
    else
        record PASS "$label" "${elapsed}s"
    fi
}

# Runs every cell of the matrix with the current interpreter.
run_interpreter() {
    local backend=""
    local strategy=""
    for backend in "${BACKENDS[@]}"; do
        run_case "test.lua $backend" LUASH_BACKEND="$backend" tests/test.lua
    done
    for strategy in "${STRATEGIES[@]}"; do
        run_case "test.lua popen/$strategy" \
            LUASH_BACKEND=popen LUASH_POPEN_STRATEGY="$strategy" \
            tests/test.lua
    done
    run_case "test_command.lua" tests/test_command.lua
    run_case "test_install.lua" tests/test_install.lua
    for backend in "${BACKENDS[@]}"; do
        run_case "test_backend.lua $backend" \
            tests/test_backend.lua "$backend"
    done
    for strategy in "${STRATEGIES[@]}"; do
        run_case "test_backend.lua popen/$strategy" \
            tests/test_backend.lua popen "$strategy"
    done
    run_case "test_popen.lua" tests/test_popen.lua
    for backend in "${STANDALONE_BACKENDS[@]}"; do
        run_case "standalone test.lua $backend" \
            LUASH_STANDALONE=1 LUASH_BACKEND="$backend" tests/test.lua
    done
    run_case "no-C test.lua" -e "$NO_C_MODULES" tests/test.lua
    run_case "no-C standalone test.lua" \
        LUASH_STANDALONE=1 -e "$NO_C_MODULES" tests/test.lua
}

# Prints the matrix, the interpreters behind its columns and the totals.
print_summary() {
    local ncols="${#interps[@]}"
    local r=0
    local c=0
    printf '\n%-32s' "Summary"
    for (( c = 0; c < ncols; c++ )); do
        printf '  #%-4s' "$(( c + 1 ))"
    done
    printf '\n'
    for (( r = 0; r < ${#rows[@]}; r++ )); do
        printf '%-32s' "${rows[r]}"
        for (( c = 0; c < ncols; c++ )); do
            printf '  %-5s' "${cells[r * ncols + c]:--}"
        done
        printf '\n'
    done
    printf '\n'
    for (( c = 0; c < ncols; c++ )); do
        printf '#%-2s %s (%s)\n' "$(( c + 1 ))" "${interps[c]}" "${infos[c]}"
    done
    local note=""
    for note in ${notes[@]+"${notes[@]}"}; do
        printf 'not tested: %s\n' "$note"
    done
    printf '\n%d passed, %d failed, %d skipped, %d missing\n' \
        "$n_pass" "$n_fail" "$n_skip" "$n_miss"
}

find_interpreters
for note in ${notes[@]+"${notes[@]}"}; do
    echo "run_all.sh: not testing $note"
done
if [ "${#interps[@]}" -eq 0 ]; then
    echo "run_all.sh: no Lua interpreter to test" >&2
    if [ "$keep_logs" -eq 0 ]; then
        rm -rf "$log_dir"
    fi
    exit 1
fi

for (( col = 0; col < ${#interps[@]}; col++ )); do
    interp="${interps[col]}"
    printf '\n== #%d %s (%s)\n' "$(( col + 1 ))" "$interp" "${infos[col]}"
    run_interpreter
done

print_summary
if [ "$n_fail" -gt 0 ]; then
    echo "Logs of every run are in $log_dir"
    exit 1
fi
if [ "$keep_logs" -eq 0 ]; then
    rm -rf "$log_dir"
fi
