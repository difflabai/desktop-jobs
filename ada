#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════╗
# ║  ada — dead-simple service manager for ~/projects/desktop-jobs      ║
# ║  Dependencies: bash ≥4, jq, standard unix tools                     ║
# ╚══════════════════════════════════════════════════════════════════════╝
set -uo pipefail

readonly ADA_VERSION="1.0.0"

# ── Paths ────────────────────────────────────────────────────────────────
readonly ADA_HOME="${HOME}/.ada"
readonly ADA_PIDS="${ADA_HOME}/pids"
readonly ADA_LOGS="${ADA_HOME}/logs"
readonly ADA_STATE="${ADA_HOME}/state"
readonly ADA_LOCK="${ADA_HOME}/watch.lock"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVICES_JSON="${SCRIPT_DIR}/services.json"

# ── Tunables ─────────────────────────────────────────────────────────────
readonly MAX_LOG_BYTES=$(( 2 * 1024 * 1024 ))   # 2 MB per service
readonly CRASH_LOOP_THRESHOLD=5                   # max restarts in window
readonly CRASH_LOOP_WINDOW=120                    # seconds
readonly STOP_GRACE=5                             # seconds before SIGKILL
readonly WATCH_INTERVAL=10                        # supervisor check interval

# ── Colors (disabled when stdout is not a tty) ──────────────────────────
if [[ -t 1 ]]; then
    readonly RST=$'\033[0m'  BOLD=$'\033[1m'  DIM=$'\033[2m'
    readonly RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' CYAN=$'\033[36m'
    readonly BG_RED=$'\033[41m' WHITE=$'\033[97m'
else
    readonly RST="" BOLD="" DIM="" RED="" GREEN="" YELLOW="" CYAN="" BG_RED="" WHITE=""
fi

# ── Bootstrap ────────────────────────────────────────────────────────────
mkdir -p "${ADA_PIDS}" "${ADA_LOGS}" "${ADA_STATE}"

# ── Helpers ──────────────────────────────────────────────────────────────
die()  { printf '%b\n' "${RED}error:${RST} $*" >&2; exit 1; }
info() { printf '%b\n' "${CYAN}▸${RST} $*"; }
warn() { printf '%b\n' "${YELLOW}▸${RST} $*"; }

expand_tilde() { printf '%s' "${1/#\~/$HOME}"; }

# ── Config readers ───────────────────────────────────────────────────────
require_config() {
    [[ -f "${SERVICES_JSON}" ]] || die "config not found: ${SERVICES_JSON}"
}

service_names() {
    require_config
    jq -r '.[].name' "${SERVICES_JSON}"
}

enabled_names() {
    require_config
    jq -r '.[] | select(.enabled == true) | .name' "${SERVICES_JSON}"
}

service_exists() {
    require_config
    jq -e --arg n "$1" '.[] | select(.name == $n)' "${SERVICES_JSON}" >/dev/null 2>&1
}

service_field() {
    jq -r --arg n "$1" --arg f "$2" \
        '.[] | select(.name == $n) | .[$f] // empty' "${SERVICES_JSON}"
}

require_service() {
    service_exists "$1" || die "unknown service: $1"
}

# ── PID / file helpers ──────────────────────────────────────────────────
pid_file()   { printf '%s' "${ADA_PIDS}/${1}.pid"; }
log_file()   { printf '%s' "${ADA_LOGS}/${1}.log"; }
state_file() { printf '%s' "${ADA_STATE}/${1}.json"; }

read_pid() {
    local pf
    pf="$(pid_file "$1")"
    [[ -f "${pf}" ]] && cat "${pf}" || printf ''
}

is_running() {
    local pid
    pid="$(read_pid "$1")"
    [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

# ── Log rotation ─────────────────────────────────────────────────────────
rotate_log() {
    local lf
    lf="$(log_file "$1")"
    [[ -f "${lf}" ]] || return 0
    local sz
    sz=$(stat -c%s "${lf}" 2>/dev/null || stat -f%z "${lf}" 2>/dev/null || echo 0)
    if (( sz > MAX_LOG_BYTES )); then
        tail -c "${MAX_LOG_BYTES}" "${lf}" > "${lf}.tmp" && mv "${lf}.tmp" "${lf}"
    fi
}

# ── State management ────────────────────────────────────────────────────
init_state() {
    local sf
    sf="$(state_file "$1")"
    [[ -f "${sf}" ]] && return 0
    printf '%s\n' '{"restart_count":0,"restart_times":[],"crash_loop":false,"started_at":null}' > "${sf}"
}

get_state() {
    init_state "$1"
    cat "$(state_file "$1")"
}

set_state() {
    printf '%s\n' "$2" > "$(state_file "$1")"
}

record_restart() {
    local name="$1" now cutoff state recent
    now=$(date +%s)
    cutoff=$(( now - CRASH_LOOP_WINDOW ))
    state="$(get_state "${name}")"

    state=$(printf '%s' "${state}" | jq \
        --argjson now "${now}" --argjson cutoff "${cutoff}" '
        .restart_times = ([.restart_times[] | select(. > $cutoff)] + [$now])
        | .restart_count += 1
    ')

    recent=$(printf '%s' "${state}" | jq '[.restart_times[]] | length')
    if (( recent > CRASH_LOOP_THRESHOLD )); then
        state=$(printf '%s' "${state}" | jq '.crash_loop = true')
    fi

    set_state "${name}" "${state}"
}

clear_crash_loop() {
    local state
    state="$(get_state "$1")"
    state=$(printf '%s' "${state}" | jq '.crash_loop = false | .restart_times = [] | .restart_count = 0')
    set_state "$1" "${state}"
}

is_crash_loop() {
    [[ "$(get_state "$1" | jq -r '.crash_loop')" == "true" ]]
}

get_restart_count() {
    get_state "$1" | jq -r '.restart_count'
}

get_started_at() {
    get_state "$1" | jq -r '.started_at // empty'
}

set_started_at() {
    local now state
    now=$(date +%s)
    state="$(get_state "$1")"
    state=$(printf '%s' "${state}" | jq --argjson t "${now}" '.started_at = $t')
    set_state "$1" "${state}"
}

clear_started_at() {
    local state
    state="$(get_state "$1")"
    state=$(printf '%s' "${state}" | jq '.started_at = null')
    set_state "$1" "${state}"
}

# ── Resolve "all" → list of names ───────────────────────────────────────
resolve_targets() {
    if [[ "$1" == "all" ]]; then
        service_names
    else
        printf '%s\n' "$1"
    fi
}

resolve_enabled_targets() {
    if [[ "$1" == "all" ]]; then
        enabled_names
    else
        printf '%s\n' "$1"
    fi
}

# ── Display helpers ──────────────────────────────────────────────────────
last_log_line() {
    local lf
    lf="$(log_file "$1")"
    [[ -f "${lf}" ]] || return 0
    # Strip ANSI escapes for clean display
    tail -1 "${lf}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-80
}

human_uptime() {
    local s="$1"
    if   (( s < 60 ));    then printf '%ds' "${s}"
    elif (( s < 3600 ));  then printf '%dm %ds'  $(( s/60 )) $(( s%60 ))
    elif (( s < 86400 )); then printf '%dh %dm'  $(( s/3600 )) $(( (s%3600)/60 ))
    else                       printf '%dd %dh'  $(( s/86400 )) $(( (s%86400)/3600 ))
    fi
}

repeat_char() {
    local i
    for (( i=0; i<$2; i++ )); do printf '%s' "$1"; done
}

# ═══════════════════════════════════════════════════════════════════════
#  COMMANDS
# ═══════════════════════════════════════════════════════════════════════

# ── start ────────────────────────────────────────────────────────────────
cmd_start() {
    local name="$1"
    require_service "${name}"

    if is_running "${name}"; then
        info "${name} already running (PID $(read_pid "${name}"))"
        return 0
    fi

    local cmd dir env_file lf full_cmd
    cmd="$(service_field "${name}" cmd)"
    dir="$(expand_tilde "$(service_field "${name}" dir)")"
    env_file="$(service_field "${name}" env_file)"
    lf="$(log_file "${name}")"

    [[ -d "${dir}" ]] || die "directory does not exist: ${dir}"

    rotate_log "${name}"

    # Build launch command with optional env_file
    full_cmd=""
    if [[ -n "${env_file}" ]]; then
        env_file="$(expand_tilde "${env_file}")"
        if [[ -f "${env_file}" ]]; then
            full_cmd="set -a; source $(printf '%q' "${env_file}"); set +a; "
        else
            warn "env_file not found: ${env_file} — starting without it"
        fi
    fi
    full_cmd+="${cmd}"

    # Launch in its own session so SIGTERM propagates to child processes.
    # setsid detaches from our terminal; the process won't die when ada exits.
    setsid bash -c "cd $(printf '%q' "${dir}") && exec bash -c $(printf '%q' "${full_cmd}")" \
        >>"${lf}" 2>&1 &
    local pid=$!

    # Brief grace period to detect immediate crashes
    sleep 0.4
    if kill -0 "${pid}" 2>/dev/null; then
        printf '%d' "${pid}" > "$(pid_file "${name}")"
        set_started_at "${name}"
        info "${name} started (PID ${pid})"
    else
        warn "${name} exited immediately — check: ada logs ${name}"
        rm -f "$(pid_file "${name}")"
        clear_started_at "${name}"
        return 1
    fi
}

# ── stop ─────────────────────────────────────────────────────────────────
cmd_stop() {
    local name="$1"
    require_service "${name}"

    local pid
    pid="$(read_pid "${name}")"

    if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
        info "${name} is not running"
        rm -f "$(pid_file "${name}")"
        clear_started_at "${name}"
        return 0
    fi

    info "stopping ${name} (PID ${pid})…"

    # Try SIGTERM to the process group first, fall back to just the PID
    kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true

    local waited=0
    while (( waited < STOP_GRACE )); do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 1
        (( waited++ )) || true
    done

    if kill -0 "${pid}" 2>/dev/null; then
        warn "PID ${pid} did not exit — sending SIGKILL"
        kill -KILL -- "-${pid}" 2>/dev/null || kill -KILL "${pid}" 2>/dev/null || true
        sleep 0.5
    fi

    rm -f "$(pid_file "${name}")"
    clear_started_at "${name}"
    info "${name} stopped"
}

# ── restart ──────────────────────────────────────────────────────────────
cmd_restart() {
    local name="$1"
    require_service "${name}"
    clear_crash_loop "${name}"
    cmd_stop "${name}"
    cmd_start "${name}"
}

# ── status ───────────────────────────────────────────────────────────────
cmd_status() {
    require_config
    local now
    now=$(date +%s)

    # Column widths
    local wN=20 wP=7 wS=12 wU=10 wR=8 wL=42

    # Horizontal rules for each column
    local rN rP rS rU rR rL
    rN="$(repeat_char '─' $(( wN + 2 )))"
    rP="$(repeat_char '─' $(( wP + 2 )))"
    rS="$(repeat_char '─' $(( wS + 2 )))"
    rU="$(repeat_char '─' $(( wU + 2 )))"
    rR="$(repeat_char '─' $(( wR + 2 )))"
    rL="$(repeat_char '─' $(( wL + 2 )))"

    printf '\n'
    # ┌ top border
    printf '  ┌%s┬%s┬%s┬%s┬%s┬%s┐\n' "${rN}" "${rP}" "${rS}" "${rU}" "${rR}" "${rL}"

    # Header
    printf "  │ ${BOLD}%-${wN}s${RST} │ ${BOLD}%-${wP}s${RST} │ ${BOLD}%-${wS}s${RST} │ ${BOLD}%-${wU}s${RST} │ ${BOLD}%-${wR}s${RST} │ ${BOLD}%-${wL}s${RST} │\n" \
        "SERVICE" "PID" "STATE" "UPTIME" "RESTARTS" "LAST LOG"

    # ├ separator
    printf '  ├%s┼%s┼%s┼%s┼%s┼%s┤\n' "${rN}" "${rP}" "${rS}" "${rU}" "${rR}" "${rL}"

    local names
    names="$(service_names 2>/dev/null)"
    if [[ -z "${names}" ]]; then
        local total_w=$(( wN + wP + wS + wU + wR + wL + 12 ))
        printf "  │ ${DIM}%-${total_w}s${RST}│\n" "(no services configured)"
        printf '  └%s┴%s┴%s┴%s┴%s┴%s┘\n' "${rN}" "${rP}" "${rS}" "${rU}" "${rR}" "${rL}"
        printf '\n'
        return
    fi

    while IFS= read -r name; do
        local pid state sc uptime_str restarts last enabled rc=""

        enabled="$(service_field "${name}" enabled)"
        pid="$(read_pid "${name}")"
        restarts="$(get_restart_count "${name}")"
        last="$(last_log_line "${name}")"
        [[ ${#last} -gt ${wL} ]] && last="${last:0:$(( wL - 1 ))}…"

        if is_crash_loop "${name}"; then
            state="CRASH-LOOP"
            sc="${BG_RED}${WHITE}${BOLD}"
            rc="${RED}"
            pid="-"
            uptime_str="-"
        elif [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            state="running"
            sc="${GREEN}"
            local sa
            sa="$(get_started_at "${name}")"
            if [[ -n "${sa}" && "${sa}" != "null" ]]; then
                uptime_str="$(human_uptime $(( now - sa )))"
            else
                uptime_str="?"
            fi
        else
            pid="-"
            if [[ "${enabled}" == "true" ]]; then
                state="stopped"
                sc="${YELLOW}"
            else
                state="disabled"
                sc="${DIM}"
            fi
            uptime_str="-"
            rm -f "$(pid_file "${name}")" 2>/dev/null
        fi

        printf "  │ ${rc}%-${wN}s${RST} │ ${rc}%-${wP}s${RST} │ ${sc}%-${wS}s${RST} │ ${rc}%-${wU}s${RST} │ ${rc}%-${wR}s${RST} │ ${DIM}%-${wL}s${RST} │\n" \
            "${name}" "${pid}" "${state}" "${uptime_str}" "${restarts}" "${last}"
    done <<< "${names}"

    # └ bottom border
    printf '  └%s┴%s┴%s┴%s┴%s┴%s┘\n' "${rN}" "${rP}" "${rS}" "${rU}" "${rR}" "${rL}"
    printf '\n'

    # Supervisor indicator
    if [[ -f "${ADA_LOCK}" ]]; then
        local wpid
        wpid="$(cat "${ADA_LOCK}" 2>/dev/null)"
        if [[ -n "${wpid}" ]] && kill -0 "${wpid}" 2>/dev/null; then
            printf '  %b◉%b %bsupervisor active (PID %s)%b\n' "${GREEN}" "${RST}" "${DIM}" "${wpid}" "${RST}"
        else
            printf '  %b◌%b %bsupervisor not running (stale lock)%b\n' "${YELLOW}" "${RST}" "${DIM}" "${RST}"
            rm -f "${ADA_LOCK}"
        fi
    else
        printf '  %b◌%b %bsupervisor not running%b\n' "${YELLOW}" "${RST}" "${DIM}" "${RST}"
    fi
    printf '\n'
}

# ── logs ─────────────────────────────────────────────────────────────────
cmd_logs() {
    local name="$1"; shift
    require_service "${name}"

    local lf
    lf="$(log_file "${name}")"
    [[ -f "${lf}" ]] || die "no log file yet for ${name}"

    local lines="" follow=true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n)  lines="${2:?'-n' requires a number}"; follow=false; shift 2 ;;
            -f)  follow=true; shift ;;
            *)   die "unknown flag: $1" ;;
        esac
    done

    if [[ -n "${lines}" ]]; then
        tail -n "${lines}" "${lf}"
    elif ${follow}; then
        printf '%b── %s ── ctrl-c to exit ──%b\n' "${DIM}" "${name}" "${RST}"
        tail -f "${lf}"
    else
        tail -n 50 "${lf}"
    fi
}

# ── add ──────────────────────────────────────────────────────────────────
cmd_add() {
    local name="$1" cmd="$2" dir="$3"
    local env_file="${4:-}"

    require_config
    if service_exists "${name}"; then
        die "service '${name}' already exists"
    fi

    local entry
    if [[ -n "${env_file}" ]]; then
        entry=$(jq -n \
            --arg n "${name}" --arg c "${cmd}" --arg d "${dir}" --arg e "${env_file}" \
            '{name:$n, cmd:$c, dir:$d, env_file:$e, enabled:true}')
    else
        entry=$(jq -n \
            --arg n "${name}" --arg c "${cmd}" --arg d "${dir}" \
            '{name:$n, cmd:$c, dir:$d, env_file:null, enabled:true}')
    fi

    # Atomic write via temp file
    jq --argjson e "${entry}" '. + [$e]' "${SERVICES_JSON}" > "${SERVICES_JSON}.tmp" \
        && mv "${SERVICES_JSON}.tmp" "${SERVICES_JSON}"

    info "added service: ${name}"
}

# ── remove ───────────────────────────────────────────────────────────────
cmd_remove() {
    local name="$1"
    require_service "${name}"

    if is_running "${name}"; then
        info "stopping ${name} first…"
        cmd_stop "${name}"
    fi

    jq --arg n "${name}" '[.[] | select(.name != $n)]' "${SERVICES_JSON}" \
        > "${SERVICES_JSON}.tmp" && mv "${SERVICES_JSON}.tmp" "${SERVICES_JSON}"

    rm -f "$(pid_file "${name}")" "$(state_file "${name}")"
    info "removed service: ${name}"
}

# ── enable / disable ────────────────────────────────────────────────────
cmd_enable() {
    local name="$1"
    require_service "${name}"
    jq --arg n "${name}" \
        '[.[] | if .name == $n then .enabled = true else . end]' "${SERVICES_JSON}" \
        > "${SERVICES_JSON}.tmp" && mv "${SERVICES_JSON}.tmp" "${SERVICES_JSON}"
    info "enabled: ${name}"
}

cmd_disable() {
    local name="$1"
    require_service "${name}"
    jq --arg n "${name}" \
        '[.[] | if .name == $n then .enabled = false else . end]' "${SERVICES_JSON}" \
        > "${SERVICES_JSON}.tmp" && mv "${SERVICES_JSON}.tmp" "${SERVICES_JSON}"
    info "disabled: ${name}"
}

# ── watch (supervisor) ──────────────────────────────────────────────────
cmd_watch() {
    # Prevent double supervisors via lock file
    if [[ -f "${ADA_LOCK}" ]]; then
        local existing
        existing="$(cat "${ADA_LOCK}" 2>/dev/null)"
        if [[ -n "${existing}" ]] && kill -0 "${existing}" 2>/dev/null; then
            die "supervisor already running (PID ${existing}). Kill it or remove ${ADA_LOCK}"
        fi
        rm -f "${ADA_LOCK}"
    fi

    printf '%d' $$ > "${ADA_LOCK}"
    trap 'rm -f "${ADA_LOCK}"; exit 0' INT TERM EXIT

    local watch_log="${ADA_LOGS}/watch.log"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    info "supervisor started (PID $$)"
    printf '[%s] supervisor started (PID %d)\n' "${ts}" $$ >> "${watch_log}"

    while true; do
        if [[ ! -f "${SERVICES_JSON}" ]]; then
            sleep "${WATCH_INTERVAL}"
            continue
        fi

        local names
        names="$(enabled_names 2>/dev/null)" || true

        if [[ -n "${names}" ]]; then
            while IFS= read -r svc; do
                [[ -z "${svc}" ]] && continue

                # Skip crash-looped services
                if is_crash_loop "${svc}"; then
                    continue
                fi

                if ! is_running "${svc}"; then
                    ts="$(date '+%Y-%m-%d %H:%M:%S')"
                    warn "[watch] ${svc} is down — restarting…"
                    printf '[%s] auto-restart: %s\n' "${ts}" "${svc}" >> "${watch_log}"

                    record_restart "${svc}"

                    if is_crash_loop "${svc}"; then
                        printf '[%s] CRASH-LOOP: %s (>%d restarts in %ds)\n' \
                            "${ts}" "${svc}" "${CRASH_LOOP_THRESHOLD}" "${CRASH_LOOP_WINDOW}" \
                            >> "${watch_log}"
                        local ll
                        ll="$(last_log_line "${svc}")"
                        [[ -n "${ll}" ]] && \
                            printf '[%s]   last log: %s\n' "${ts}" "${ll}" >> "${watch_log}"
                        warn "[watch] ${RED}${svc} entered CRASH-LOOP — giving up${RST}"
                        continue
                    fi

                    cmd_start "${svc}" 2>&1 | while IFS= read -r line; do
                        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${line}" >> "${watch_log}"
                    done
                fi
            done <<< "${names}"
        fi

        sleep "${WATCH_INTERVAL}"
    done
}

# ── help ─────────────────────────────────────────────────────────────────
cmd_help() {
    cat <<EOF

  ${BOLD}ada${RST} v${ADA_VERSION} — service manager for desktop-jobs

  ${BOLD}USAGE${RST}
    ada status                       Show all services
    ada start  <name|all>            Start a service (skips if already running)
    ada stop   <name|all>            Graceful stop (SIGTERM → SIGKILL after ${STOP_GRACE}s)
    ada restart <name|all>           Restart (clears crash-loop flag)
    ada logs   <name> [-n N] [-f]    Tail service log (-f is default)
    ada add    <name> <cmd> <dir> [env_file]
                                     Register a new service
    ada remove <name>                Unregister (stops first if running)
    ada enable  <name>               Enable a service
    ada disable <name>               Disable a service
    ada watch                        Start supervisor (auto-restarts crashed services)

  ${BOLD}EXAMPLES${RST}
    ada start all                    Start every enabled service
    ada logs ace-step -n 100         Last 100 lines of ace-step log
    nohup ada watch &                Run supervisor in background

  ${BOLD}FILES${RST}
    ${DIM}~/.ada/pids/<name>.pid${RST}         PID tracking
    ${DIM}~/.ada/logs/<name>.log${RST}         Per-service logs (${MAX_LOG_BYTES} byte rotation)
    ${DIM}~/.ada/logs/watch.log${RST}          Supervisor log
    ${DIM}~/.ada/state/<name>.json${RST}       Restart counters & crash-loop state

EOF
}

# ═══════════════════════════════════════════════════════════════════════
#  DISPATCH
# ═══════════════════════════════════════════════════════════════════════
main() {
    local cmd="${1:-status}"
    shift 2>/dev/null || true

    case "${cmd}" in
        status|st|s)
            cmd_status
            ;;
        start)
            [[ $# -lt 1 ]] && die "usage: ada start <name|all>"
            while IFS= read -r t; do
                cmd_start "${t}"
            done <<< "$(resolve_enabled_targets "$1")"
            ;;
        stop)
            [[ $# -lt 1 ]] && die "usage: ada stop <name|all>"
            while IFS= read -r t; do
                cmd_stop "${t}"
            done <<< "$(resolve_targets "$1")"
            ;;
        restart)
            [[ $# -lt 1 ]] && die "usage: ada restart <name|all>"
            while IFS= read -r t; do
                cmd_restart "${t}"
            done <<< "$(resolve_enabled_targets "$1")"
            ;;
        logs|log|l)
            [[ $# -lt 1 ]] && die "usage: ada logs <name> [-n N]"
            cmd_logs "$@"
            ;;
        add)
            [[ $# -lt 3 ]] && die "usage: ada add <name> <cmd> <dir> [env_file]"
            cmd_add "$@"
            ;;
        remove|rm)
            [[ $# -lt 1 ]] && die "usage: ada remove <name>"
            cmd_remove "$1"
            ;;
        enable)
            [[ $# -lt 1 ]] && die "usage: ada enable <name>"
            cmd_enable "$1"
            ;;
        disable)
            [[ $# -lt 1 ]] && die "usage: ada disable <name>"
            cmd_disable "$1"
            ;;
        watch|w)
            cmd_watch
            ;;
        help|--help|-h|h)
            cmd_help
            ;;
        version|--version|-v)
            printf 'ada %s\n' "${ADA_VERSION}"
            ;;
        *)
            die "unknown command: ${cmd}  (try: ada help)"
            ;;
    esac
}

main "$@"
