#!/usr/bin/env bash
#
# =============================================================================
# Script:    hdd_poweroff_guard.sh
# Author:    Mikhail Deynekin <mid1977@gmail.com>
# Site:      https://deynekin.com
# Date:      15/03/2026
# Version:   2.4
# Purpose:   Power off SATA HDD if it is not mounted and is spinning.
#            Intended to be run from cron every 5 min as a safety guard,
#            ensuring the HDD is never left spinning when idle.
# Requires:  root, hdparm, coreutils (timeout, findmnt, stat), util-linux (flock)
# License:   MIT
# =============================================================================
#
# Changelog:
#   v2.4  • BUGFIX: added active/idle pattern to case statements in process_disk()
#                   and process_disk_wake() — hdparm -C returns "active/idle" as a
#                   single slash-separated token; previously matched "unexpected state"
#         • BUGFIX: wake_drive() returned EXIT_WARNING (treated as error) when drive
#                   reached active/idle after dd — fixed: active/idle is SUCCESS
#         • BUGFIX: process_disk_wake() did not propagate $? from wake_drive() on
#                   failure; now passes EXIT_WARNING/EXIT_ERROR correctly
#         • Added diagnose_and_force_poweroff(): detailed APM/PM/SMART capability
#                   log + udisksctl power-off fallback + sysfs SCSI offline/delete
#         • power_off_drive() now calls diagnose_and_force_poweroff() on hdparm fail
#         • wake_drive() — case-based state validation after spinup, with
#                   measured spinup time logged (seconds via $SECONDS builtin)
#         • process_disk_wake() — full case-based state handling before wake:
#                   active/idle/active|idle treated as already-awake (EXIT_OK),
#                   unknown state gets a best-effort wake attempt
#         • State check after sysfs/delete in process_disk() handles "removed"
#                   as a valid successful final state
#   v2.3  • Added -w/--wake flag: wake (spin up) drives from standby/sleep
#         • Added wake_drive() function — triggers read I/O to spin up the drive
#         • Added process_disk_wake() for the wake lifecycle
#         • Script mode is now MODE=poweroff (default) or MODE=wake
#   v2.2  • Added -s/--dev flag: auto-resolve disk ID by device name (sda)
#         • Added no-args mode: prints help + available ATA disk list
#         • list_ata_disks() shown on --help and on disk-not-found errors
#   v2.1  • Fixed: error() function was missing (CRITICAL)
#         • Fixed: double backslash in get_drive_state() pipe (CRITICAL)
#         • Fixed: rotate_log() moved out of log() — called once at startup
#         • Fixed: ((counter++)) || true replaced with arithmetic assignment
#         • Fixed: HDD_MOUNT wired into findmnt check as additional guard
#         • Added: IFS=$'\n\t' for correct word splitting in strict mode
#         • Replaced: unsafe (${HDD_IDS}) with read -ra for word splitting
#   v2.0  • flock-based locking, trap handlers, LC_ALL=C hdparm parsing
#         • Log rotation (max 10MB), --dry-run mode, exit codes for monitoring
#         • Multi-disk support via HDD_IDS, ShellCheck compliant
#
# Cron schedule (07:30 – 02:00, every 5 minutes, spanning midnight):
#   30-59/5  7     * * *  /usr/local/sbin/hdd_poweroff_guard.sh -s sda
#   */5      8-23  * * *  /usr/local/sbin/hdd_poweroff_guard.sh -s sda
#   */5      0-1   * * *  /usr/local/sbin/hdd_poweroff_guard.sh -s sda
# =============================================================================

set -euo pipefail
IFS=$'\n\t'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# =============================================================================
#  CONFIGURATION
# =============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.4"
readonly LOCK_FILE="/var/run/${SCRIPT_NAME%.sh}.lock"

: "${HDD_ID:=}"
: "${HDD_IDS:=}"
: "${HDD_MOUNT:=/mnt/backup}"
: "${LOG_FILE:=/var/log/hdd_poweroff_guard.log}"
: "${LOG_MAX_SIZE:=10485760}"
: "${TIMEOUT_SEC:=10}"
: "${DRY_RUN:=false}"

# Script operating mode: poweroff (default) | wake
MODE="poweroff"

readonly EXIT_OK=0
readonly EXIT_ERROR=1
readonly EXIT_WARNING=2
readonly EXIT_LOCKED=3

# =============================================================================
#  GLOBAL STATE
# =============================================================================

LOCK_FD=""
CLEANUP_REQUIRED=false

# =============================================================================
#  LOGGING
# =============================================================================

log() {
    local level="${1:-INFO}"
    shift || true
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] [${SCRIPT_NAME}] $*"

    echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true

    if [[ -t 1 ]]; then
        case "${level}" in
            FATAL|ERROR) echo -e "\033[1;31m${msg}\033[0m" ;;
            WARNING)     echo -e "\033[1;33m${msg}\033[0m" ;;
            SUCCESS)     echo -e "\033[1;32m${msg}\033[0m" ;;
            *)           echo "${msg}" ;;
        esac
    fi
}

section() {
    log "INFO" "============================================================"
    log "INFO" "$*"
    log "INFO" "============================================================"
}

die()     { log "FATAL"   "$*"; cleanup; exit "${EXIT_ERROR}"; }
error()   { log "ERROR"   "$*"; }
warn()    { log "WARNING" "$*"; }
info()    { log "INFO"    "$*"; }
success() { log "SUCCESS" "$*"; }

# =============================================================================
#  LOG ROTATION
# =============================================================================

rotate_log() {
    [[ -f "${LOG_FILE}" ]] || return 0

    local size
    size=$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo 0)

    if (( size > LOG_MAX_SIZE )); then
        mv "${LOG_FILE}" "${LOG_FILE}.old"
        gzip -f "${LOG_FILE}.old" 2>/dev/null || true
        info "Log rotated: ${LOG_FILE}.old.gz"
    fi
}

# =============================================================================
#  CLEANUP & SIGNAL HANDLING
# =============================================================================

cleanup() {
    if [[ "${CLEANUP_REQUIRED}" == "true" && -n "${LOCK_FD}" ]]; then
        flock -u "${LOCK_FD}" 2>/dev/null || true
        rm -f "${LOCK_FILE}" 2>/dev/null || true
    fi
}

trap cleanup                                               EXIT
trap 'warn "Received SIGTERM — exiting gracefully"; exit "${EXIT_OK}"' TERM
trap 'warn "Received SIGINT  — exiting gracefully"; exit "${EXIT_OK}"' INT
trap 'warn "Received SIGHUP  — ignoring signal"'          HUP

# =============================================================================
#  LOCKING
# =============================================================================

acquire_lock() {
    exec {LOCK_FD}>"${LOCK_FILE}"
    if ! flock -n "${LOCK_FD}"; then
        log "ERROR" "Another instance is already running (lock: ${LOCK_FILE})"
        exit "${EXIT_LOCKED}"
    fi
    CLEANUP_REQUIRED=true
    info "Exclusive lock acquired: ${LOCK_FILE}"
}

# =============================================================================
#  PREREQUISITES
# =============================================================================

check_prerequisites() {
    local missing=()

    for cmd in hdparm timeout findmnt flock stat gzip dd; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done

    if (( ${#missing[@]} > 0 )); then
        die "Required utilities not found: ${missing[*]}. Install: apt install ${missing[*]}"
    fi

    local log_dir
    log_dir=$(dirname "${LOG_FILE}")
    [[ -d "${log_dir}" ]] || mkdir -p "${log_dir}" || die "Cannot create log directory: ${log_dir}"
    [[ -w "${log_dir}" ]]                           || die "Log directory is not writable: ${log_dir}"

    info "All prerequisites satisfied"
}

# =============================================================================
#  DISK DISCOVERY & VALIDATION
# =============================================================================

list_ata_disks() {
    echo ""
    echo "  Available ATA disks in /dev/disk/by-id/:"
    echo "  ------------------------------------------------------------"

    local found=false
    while IFS= read -r line; do
        echo "  ${line}"
        found=true
    done < <(ls -la /dev/disk/by-id/ 2>/dev/null \
             | grep 'ata-' \
             | grep -v -- '-part' \
             || true)

    if [[ "${found}" == "false" ]]; then
        echo "  (no ATA disks found)"
    fi

    echo "  ------------------------------------------------------------"
    echo "  Tip — use the ID portion before the arrow, for example:"
    echo "    ${SCRIPT_NAME} -i ata-WDC_WD10EZEX-00BBHA0_WD-WCC6Y0SLCEHT"
    echo "    ${SCRIPT_NAME} -s sda   (auto-resolve ID by device name)"
    echo ""
}

validate_disk_id() {
    local disk_id="$1"
    [[ -n "${disk_id}" ]] && [[ -L "/dev/disk/by-id/${disk_id}" ]]
}

resolve_disk_path() {
    local disk_id="$1"
    local disk_path

    disk_path=$(readlink -f "/dev/disk/by-id/${disk_id}" 2>/dev/null) || return 1
    [[ -b "${disk_path}" ]] || return 1
    echo "${disk_path}"
}

resolve_disk_id_by_dev() {
    local dev_input="$1"
    local dev_base
    dev_base=$(basename "${dev_input}")

    if [[ ! -b "/dev/${dev_base}" ]]; then
        error "Block device /dev/${dev_base} does not exist"
        list_ata_disks
        return 1
    fi

    local disk_id=""
    local link target

    while IFS= read -r -d '' link; do
        target=$(readlink -f "${link}" 2>/dev/null) || continue
        if [[ "$(basename "${target}")" == "${dev_base}" ]]; then
            disk_id=$(basename "${link}")
            break
        fi
    done < <(find /dev/disk/by-id/ -name 'ata-*' ! -name '*-part*' -print0 2>/dev/null)

    if [[ -z "${disk_id}" ]]; then
        error "Could not resolve an ATA disk ID for /dev/${dev_base}"
        list_ata_disks
        return 1
    fi

    info "Resolved /dev/${dev_base} → ${disk_id}"
    echo "${disk_id}"
}

verify_sata_disk() {
    local disk_path="$1"

    if ! timeout "${TIMEOUT_SEC}" hdparm -i "${disk_path}" >/dev/null 2>&1; then
        warn "Device ${disk_path} did not respond to hdparm -i (may not be ATA/SATA)"
        return 1
    fi
    info "Device identity verified: ${disk_path}"
    return 0
}

# =============================================================================
#  MOUNT CHECK
# =============================================================================

is_disk_mounted() {
    local disk_path="$1"
    local mount_target

    mount_target=$(findmnt -n -o TARGET --source "${disk_path}" 2>/dev/null || true)
    if [[ -n "${mount_target}" ]]; then
        echo "${mount_target}"
        return 0
    fi

    if mountpoint -q "${HDD_MOUNT}" 2>/dev/null; then
        echo "${HDD_MOUNT}"
        return 0
    fi

    return 1
}

# =============================================================================
#  DRIVE STATE MANAGEMENT
# =============================================================================

get_drive_state() {
    local disk_path="$1"
    local status_output
    local status

    status_output=$(LC_ALL=C timeout "${TIMEOUT_SEC}" hdparm -C "${disk_path}" 2>/dev/null || true)

    if [[ -z "${status_output}" ]]; then
        echo "unknown"
        return
    fi

    status=$(echo "${status_output}" \
             | LC_ALL=C grep -iE "drive state is:" \
             | sed -E 's/.*drive state is:[[:space:]]*//' \
             | tr -d '[:space:]' \
             | tr '[:upper:]' '[:lower:]' \
             | head -1 || true)

    echo "${status:-unknown}"
}

# =============================================================================
#  DIAGNOSTIC & FORCED POWER-OFF
#  Called when hdparm -Y and -y both fail for a drive.
#  1. Logs drive capabilities (APM, PM, SMART) from hdparm -I output
#  2. Attempts udisksctl power-off (graceful, parks heads via UDisks2 daemon)
#  3. Falls back to sysfs SCSI offline → delete (kernel parks heads natively)
#  4. Prints manual remediation steps if all methods fail
#  Returns: EXIT_OK on success, EXIT_ERROR on full failure
# =============================================================================

diagnose_and_force_poweroff() {
    local disk_path="$1"
    local dev_base
    dev_base=$(basename "${disk_path}")

    warn "------------------------------------------------------------"
    warn "  hdparm FAILED for ${disk_path} — running capability diagnostics"
    warn "------------------------------------------------------------"

    # --- 1. Read drive feature set via hdparm -I ---
    local hdparm_info=""
    hdparm_info=$(timeout "${TIMEOUT_SEC}" hdparm -I "${disk_path}" 2>&1 || true)

    if [[ -z "${hdparm_info}" ]]; then
        warn "  [DIAG] hdparm -I returned no output — drive may be unresponsive"
    else
        # APM (Advanced Power Management)
        if echo "${hdparm_info}" | grep -qi "Advanced power management"; then
            local apm_val
            apm_val=$(timeout "${TIMEOUT_SEC}" hdparm -B "${disk_path}" 2>/dev/null \
                      | grep -i "APM_level\|apm" | awk '{print $NF}' || echo "unknown")
            info "  [CAPABILITY] APM supported — current level: ${apm_val}"
            info "  [FIX-APM]   Force minimum APM: hdparm -B 1 ${disk_path}"
            info "  [FIX-APM]   Persistent (hdparm.conf): /dev/${dev_base} { apm = 1 }"
        else
            warn "  [CAPABILITY] APM NOT supported — hdparm -Y/-y unavailable on this drive"
            warn "  [REASON]    Drive firmware does not implement ATA Power Management feature set"
        fi

        # ATA Power Management feature set
        if echo "${hdparm_info}" | grep -qi "Power Management feature"; then
            info "  [CAPABILITY] ATA Power Management feature set: supported"
        else
            warn "  [CAPABILITY] ATA Power Management feature set: NOT supported"
        fi

        # SMART
        if echo "${hdparm_info}" | grep -qi "S.M.A.R.T"; then
            info "  [CAPABILITY] SMART: supported — check drive health: smartctl -a ${disk_path}"
        fi

        # Security (alternative sleep via ATA Security)
        if echo "${hdparm_info}" | grep -qi "Security Mode feature"; then
            info "  [CAPABILITY] ATA Security feature set: available (advanced use only)"
        fi
    fi

    # --- 2. sysfs SCSI runtime power management ---
    local scsi_dev="/sys/block/${dev_base}/device"
    if [[ -d "${scsi_dev}" ]]; then
        local pm_ctrl_file="${scsi_dev}/power/control"
        if [[ -f "${pm_ctrl_file}" ]]; then
            local pm_state
            pm_state=$(cat "${pm_ctrl_file}" 2>/dev/null || echo "unknown")
            info "  [SYSFS] Runtime PM control node: ${pm_ctrl_file} (current: ${pm_state})"
            info "  [FIX-PM] Enable runtime PM auto: echo auto > ${pm_ctrl_file}"
        fi
    fi

    warn "------------------------------------------------------------"
    warn "  Attempting forced SATA power-off (fallback chain)"
    warn "------------------------------------------------------------"

    # --- 3. udisksctl power-off (most graceful: UDisks2 parks heads) ---
    if command -v udisksctl >/dev/null 2>&1; then
        info "  [METHOD-1] udisksctl available — attempting: udisksctl power-off -b ${disk_path}"
        if [[ "${DRY_RUN}" == "true" ]]; then
            info "  [DRY-RUN] Skipping udisksctl power-off"
        else
            if timeout "${TIMEOUT_SEC}" udisksctl power-off -b "${disk_path}" 2>/dev/null; then
                success "  [METHOD-1] SATA power-off via udisksctl SUCCEEDED for ${disk_path}"
                return "${EXIT_OK}"
            else
                warn "  [METHOD-1] udisksctl power-off FAILED (may require polkit allow-rule for root)"
                warn "  [FIX]      apt install udisks2 && check /etc/polkit-1/rules.d/"
            fi
        fi
    else
        warn "  [METHOD-1] udisksctl not found — install: apt install udisks2"
    fi

    # --- 4. sysfs SCSI offline → delete (kernel handles head parking) ---
    local state_node="/sys/class/block/${dev_base}/device/state"
    local delete_node="/sys/block/${dev_base}/device/delete"

    if [[ -f "${state_node}" ]] && [[ -f "${delete_node}" ]]; then
        info "  [METHOD-2] sysfs SCSI offline+delete available"
        if [[ "${DRY_RUN}" == "true" ]]; then
            info "  [DRY-RUN] Would run:"
            info "            echo offline > ${state_node}"
            info "            echo 1       > ${delete_node}"
        else
            info "  [METHOD-2] Sending SCSI offline: ${state_node}"
            sync
            if echo offline > "${state_node}" 2>/dev/null; then
                sleep 1
                info "  [METHOD-2] Removing SCSI device: ${delete_node}"
                if echo 1 > "${delete_node}" 2>/dev/null; then
                    success "  [METHOD-2] Kernel SCSI offline+delete SUCCEEDED for /dev/${dev_base}"
                    success "             Kernel will park heads and stop spindle (see: dmesg | grep ${dev_base})"
                    # Print rescan instruction for future use
                    local host_id
                    host_id=$(ls -la "/sys/block/${dev_base}" 2>/dev/null \
                              | grep -oP 'host\K[0-9]+' | head -1 || echo "*")
                    info "  [RESCAN]  To bring drive back: echo '- - -' > /sys/class/scsi_host/host${host_id}/scan"
                    info "  [RESCAN]  Or all hosts:        echo '- - -' | tee /sys/class/scsi_host/host*/scan"
                    return "${EXIT_OK}"
                else
                    error "  [METHOD-2] sysfs delete FAILED"
                fi
            else
                error "  [METHOD-2] sysfs offline FAILED (node may be read-only)"
            fi
        fi
    else
        warn "  [METHOD-2] sysfs nodes not found:"
        [[ -f "${state_node}" ]]  || warn "              missing: ${state_node}"
        [[ -f "${delete_node}" ]] || warn "              missing: ${delete_node}"
    fi

    # --- 5. All methods failed — print manual remediation ---
    warn "------------------------------------------------------------"
    warn "  ALL automatic power-off methods FAILED for ${disk_path}"
    warn "  Manual remediation options:"
    warn "    A) Enable APM, then retry script:"
    warn "         hdparm -B 1 ${disk_path}"
    warn "         ${SCRIPT_NAME} -s ${dev_base}"
    warn "    B) Install UDisks2 and retry:"
    warn "         apt install udisks2"
    warn "         udisksctl power-off -b ${disk_path}"
    warn "    C) Force SCSI removal manually:"
    warn "         sync && echo offline > /sys/class/block/${dev_base}/device/state"
    warn "         echo 1 > /sys/block/${dev_base}/device/delete"
    warn "    D) Physical SATA power disconnection (last resort)"
    warn "    E) BIOS/UEFI AHCI port power management settings"
    warn "------------------------------------------------------------"

    return "${EXIT_ERROR}"
}

# =============================================================================
#  POWER OFF DRIVE
#  v2.4: calls diagnose_and_force_poweroff() when hdparm -Y and -y both fail
# =============================================================================

power_off_drive() {
    local disk_path="$1"
    local dry_run_flag="$2"

    if [[ "${dry_run_flag}" == "true" ]]; then
        info "[DRY-RUN] Would sync filesystems and send hdparm -Y to ${disk_path}"
        return 0
    fi

    info "Flushing filesystem write buffers (sync)..."
    sync

    info "Sending deep-sleep command: hdparm -Y ${disk_path}"
    if timeout "${TIMEOUT_SEC}" hdparm -Y "${disk_path}" >/dev/null 2>&1; then
        info "hdparm -Y accepted by drive"
        return 0
    fi

    warn "hdparm -Y was rejected — falling back to hdparm -y (standby mode)"
    if timeout "${TIMEOUT_SEC}" hdparm -y "${disk_path}" >/dev/null 2>&1; then
        info "hdparm -y accepted by drive"
        return 0
    fi

    warn "Both hdparm -Y and hdparm -y failed on ${disk_path}"
    warn "Drive does not support ATA power management commands — entering diagnostic mode"

    # Fallback: detailed diagnostics + forced power-off via udisksctl / sysfs
    diagnose_and_force_poweroff "${disk_path}"
    return $?
}

# =============================================================================
#  WAKE DRIVE
#  Sends a single-sector read via dd to spin up a sleeping/standby SATA drive.
#  Uses bash $SECONDS builtin to measure and log actual spinup time.
#  Returns: EXIT_OK  — drive confirmed active/idle after spinup
#           EXIT_WARNING — drive state uncertain after spinup (may need more time)
#           EXIT_ERROR   — dd I/O failed; drive did not respond at all
# =============================================================================

wake_drive() {
    local disk_path="$1"
    local dry_run_flag="$2"

    if [[ "${dry_run_flag}" == "true" ]]; then
        info "[DRY-RUN] Would send wake I/O: dd if=${disk_path} of=/dev/null count=1 bs=512"
        info "[DRY-RUN] Would wait for spindle and verify state via hdparm -C"
        return "${EXIT_OK}"
    fi

    info "Sending wake-up I/O to ${disk_path} (read sector 0 via dd)..."

    local t_start="${SECONDS}"

    if ! dd if="${disk_path}" of=/dev/null count=1 bs=512 2>/dev/null; then
        error "dd read failed on ${disk_path} — drive did not respond to I/O"
        error "Possible causes: drive removed, SATA link lost, or firmware error"
        error "Check: dmesg | grep -E '$(basename "${disk_path}")|ata[0-9]'"
        return "${EXIT_ERROR}"
    fi

    local t_io=$(( SECONDS - t_start ))
    info "I/O delivered in ${t_io}s — waiting for spindle to reach rated speed..."

    # Give the drive time to complete spinup (conservative: 4s after dd returns)
    sleep 4

    local t_total=$(( SECONDS - t_start ))
    local state_after
    state_after=$(get_drive_state "${disk_path}")

    case "${state_after}" in
        active|idle|active/idle)
            success "Drive is awake and spinning (state: ${state_after}, total spinup: ${t_total}s)"
            return "${EXIT_OK}"
            ;;

        standby|sleep)
            # Drive went back to sleep immediately — likely APM or kernel re-idle
            warn "Drive returned to ${state_after} immediately after wake (spinup: ${t_total}s)"
            warn "Possible cause: hdparm APM level too aggressive (hdparm -B 254 ${disk_path})"
            warn "Check: hdparm -I ${disk_path} | grep -i 'power management'"
            return "${EXIT_WARNING}"
            ;;

        unknown)
            warn "Drive state could not be determined after wake attempt (${t_total}s elapsed)"
            warn "Drive may still be spinning up — retry in a few seconds"
            warn "Manual check: hdparm -C ${disk_path}"
            return "${EXIT_WARNING}"
            ;;

        *)
            warn "Unexpected drive state '${state_after}' after wake (${t_total}s elapsed)"
            warn "Manual check: hdparm -C ${disk_path}"
            return "${EXIT_WARNING}"
            ;;
    esac
}

# =============================================================================
#  PER-DISK PROCESSING — WAKE MODE
#  Full lifecycle: validate → resolve → verify → read state → wake if needed.
#
#  State machine:
#    standby / sleep          → send wake I/O via wake_drive()
#    active / idle / active/idle → already running, no action needed (EXIT_OK)
#    unknown                  → best-effort wake attempt with explicit warning
#    anything else            → skip with EXIT_WARNING (defensive)
#
#  Returns: EXIT_OK      — drive confirmed awake, or was already running
#           EXIT_WARNING — state uncertain, best-effort wake attempted
#           EXIT_ERROR   — drive did not respond to I/O at all
# =============================================================================

process_disk_wake() {
    local disk_id="$1"
    local disk_path
    local state_before
    local result="${EXIT_OK}"

    info "--- Processing disk (wake): ${disk_id}"

    # Step 1 — Validate disk ID exists in /dev/disk/by-id/
    if ! validate_disk_id "${disk_id}"; then
        warn "Disk ID '${disk_id}' not found in /dev/disk/by-id/"
        list_ata_disks
        return "${EXIT_WARNING}"
    fi

    # Step 2 — Resolve to /dev/sdX
    disk_path=$(resolve_disk_path "${disk_id}") || {
        warn "Failed to resolve device path for '${disk_id}'"
        return "${EXIT_WARNING}"
    }
    info "Device path resolved: ${disk_path}"

    # Step 3 — Confirm ATA/SATA identity (drive must respond to hdparm -i)
    if ! verify_sata_disk "${disk_path}"; then
        warn "Skipping non-SATA device: ${disk_path}"
        return "${EXIT_WARNING}"
    fi

    # Step 4 — Read current power state before acting
    state_before=$(get_drive_state "${disk_path}")
    info "Drive state before wake: ${state_before}"

    case "${state_before}" in

        standby|sleep)
            # ── Normal wake path ──────────────────────────────────────────────
            info "Drive is ${state_before} — initiating spinup sequence"
            set +e
            wake_drive "${disk_path}" "${DRY_RUN}"
            result=$?
            set -e
            ;;

        active|idle|active/idle)
            # ── Already running — nothing to do ───────────────────────────────
            # active/idle is the standard hdparm -C response for a spinning drive.
            # It is NOT an error; the drive is ready for I/O.
            success "Drive is already awake (state: ${state_before}) — no action needed"
            result="${EXIT_OK}"
            ;;

        unknown)
            # ── State unreadable — attempt wake defensively ───────────────────
            warn "Drive state could not be determined — attempting best-effort wake"
            warn "If the drive is already running, this is harmless"
            set +e
            wake_drive "${disk_path}" "${DRY_RUN}"
            result=$?
            set -e
            # Downgrade error → warning for unknown-state drives
            # (we cannot be certain it failed)
            [[ "${result}" == "${EXIT_ERROR}" ]] && result="${EXIT_WARNING}"
            ;;

        *)
            warn "Unexpected drive state '${state_before}' — skipping wake"
            warn "Manual check: hdparm -C ${disk_path}"
            result="${EXIT_WARNING}"
            ;;

    esac

    return "${result}"
}

## =============================================================================
#  PER-DISK PROCESSING — POWER-OFF MODE
#  v2.4: BUGFIX — added active/idle to case (hdparm -C returns it as one token)
# =============================================================================

process_disk() {
    local disk_id="$1"
    local disk_path
    local mount_target
    local state_before
    local state_after
    local result="${EXIT_OK}"

    info "--- Processing disk (power-off): ${disk_id}"

    if ! validate_disk_id "${disk_id}"; then
        warn "Disk ID '${disk_id}' not found in /dev/disk/by-id/"
        list_ata_disks
        return "${EXIT_WARNING}"
    fi

    disk_path=$(resolve_disk_path "${disk_id}") || {
        warn "Failed to resolve device path for '${disk_id}'"
        return "${EXIT_WARNING}"
    }
    info "Device path resolved: ${disk_path}"

    if ! verify_sata_disk "${disk_path}"; then
        warn "Skipping non-SATA device: ${disk_path}"
        return "${EXIT_WARNING}"
    fi

    if mount_target=$(is_disk_mounted "${disk_path}"); then
        info "Disk is mounted at '${mount_target}' — skipping power-off (backup may be running)"
        return "${EXIT_OK}"
    fi
    info "Disk is not mounted — safe to proceed"

    state_before=$(get_drive_state "${disk_path}")
    info "Drive state: ${state_before}"

    case "${state_before}" in
        # BUGFIX v2.4: hdparm -C reports "active/idle" as a single slash-separated
        # token. Previously only "active" or "idle" were matched, causing this
        # valid operational state to fall through to the unexpected-state branch.
        active|idle|active/idle)
            info "Drive is ${state_before} — initiating power-off sequence"

            if power_off_drive "${disk_path}" "${DRY_RUN}"; then
                sleep 2
                # After sysfs delete the device may be gone — state check may fail
                state_after=$(get_drive_state "${disk_path}" 2>/dev/null || echo "removed")
                info "Drive state after command: ${state_after}"

                if [[ "${state_after}" =~ ^(standby|sleep|removed)$ ]]; then
                    success "Drive powered down successfully (state: ${state_after})"
                    result="${EXIT_OK}"
                else
                    warn "Drive state is '${state_after}' after command (expected standby/sleep/removed)"
                    result="${EXIT_WARNING}"
                fi
            else
                error "Power-off sequence failed for ${disk_path}"
                result="${EXIT_ERROR}"
            fi
            ;;

        standby|sleep)
            info "Drive is already ${state_before} — no action required"
            result="${EXIT_OK}"
            ;;

        unknown)
            warn "Drive state could not be determined — skipping"
            result="${EXIT_WARNING}"
            ;;

        *)
            warn "Unexpected drive state '${state_before}' — skipping"
            result="${EXIT_WARNING}"
            ;;
    esac

    return "${result}"
}


# =============================================================================
#  HELP & VERSION
# =============================================================================

show_version() {
    echo "${SCRIPT_NAME} version ${SCRIPT_VERSION}"
    echo "Author : Mikhail Deynekin <mid1977@gmail.com>"
    echo "Site   : https://deynekin.com"
    echo "Date   : 15/03/2026"
}

show_usage() {
    cat << EOF

${SCRIPT_NAME} v${SCRIPT_VERSION} — SATA HDD power-off / wake-up guard
Author: Mikhail Deynekin <mid1977@gmail.com> | https://deynekin.com

USAGE:
    ${SCRIPT_NAME} [OPTIONS]

OPTIONS:
    -h, --help            Show this help message and list available ATA disks
    -v, --version         Show version information
    -d, --dry-run         Simulate without making any changes to the drive
    -w, --wake            Wake mode: spin up drives from standby/sleep
    -s, --dev DEV         Device name (e.g. sda) — disk ID resolved automatically
    -i, --disk ID         Disk ID from /dev/disk/by-id/ (can be repeated)

ENVIRONMENT VARIABLES:
    HDD_ID                Single disk ID (used if no -i/-s flag is given)
    HDD_IDS               Multiple disk IDs, space-separated
    HDD_MOUNT             Mount point safety guard   (default: ${HDD_MOUNT})
    LOG_FILE              Log file path              (default: ${LOG_FILE})
    LOG_MAX_SIZE          Log rotation threshold     (default: 10 MB)
    TIMEOUT_SEC           hdparm command timeout     (default: ${TIMEOUT_SEC}s)
    DRY_RUN               Simulate mode              (default: ${DRY_RUN})

EXIT CODES:
    0  Success / No action needed
    1  Error occurred
    2  Warning (disk state uncertain or unresolvable)
    3  Another instance is already running

POWER-OFF EXAMPLES:
    ${SCRIPT_NAME} -s sda                          # auto-resolve and power off sda
    ${SCRIPT_NAME} -s sda --dry-run                # simulate power-off for sda
    ${SCRIPT_NAME} -i ata-WDC_WD10EZEX-00BBHA0_WD-WCC6Y0SLCEHT
    ${SCRIPT_NAME} -i ata-DISK1_XXX -i ata-DISK2_YYY

WAKE-UP EXAMPLES:
    ${SCRIPT_NAME} -w -s sda                       # wake sda from standby/sleep
    ${SCRIPT_NAME} -w -s sda --dry-run             # simulate wake-up for sda
    ${SCRIPT_NAME} -w -i ata-DISK1_XXX -i ata-DISK2_YYY   # wake multiple disks

CRON SETUP (every 5 min, 07:30 – 02:00):
    30-59/5  7     * * *  ${SCRIPT_NAME} -s sda
    */5      8-23  * * *  ${SCRIPT_NAME} -s sda
    */5      0-1   * * *  ${SCRIPT_NAME} -s sda

EOF
    list_ata_disks
}

# =============================================================================
#  ARGUMENT PARSING
# =============================================================================

parse_arguments() {
    if [[ $# -eq 0 && -z "${HDD_ID}" && -z "${HDD_IDS}" ]]; then
        show_usage
        exit "${EXIT_OK}"
    fi

    local disk_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit "${EXIT_OK}"
                ;;
            -v|--version)
                show_version
                exit "${EXIT_OK}"
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -w|--wake)
                MODE="wake"
                shift
                ;;
            -i|--disk)
                [[ -n "${2:-}" ]] || die "Option '$1' requires a disk ID argument"
                disk_args+=("$2")
                shift 2
                ;;
            -s|--dev)
                [[ -n "${2:-}" ]] || die "Option '$1' requires a device name (e.g. sda)"
                local resolved_id
                resolved_id=$(resolve_disk_id_by_dev "$2") || exit "${EXIT_ERROR}"
                disk_args+=("${resolved_id}")
                shift 2
                ;;
            -*)
                die "Unknown option: '$1'. Run '${SCRIPT_NAME} --help' for usage."
                ;;
            *)
                die "Unexpected argument: '$1'. Run '${SCRIPT_NAME} --help' for usage."
                ;;
        esac
    done

    if (( ${#disk_args[@]} > 0 )); then
        HDD_IDS="${disk_args[*]}"
    fi
}

# =============================================================================
#  MAIN
# =============================================================================

main() {
    parse_arguments "$@"

    rotate_log

    [[ "${DRY_RUN}" == "true" ]] && \
        echo -e "\033[1;33m  *** DRY-RUN MODE — no changes will be made ***\033[0m"

    [[ "${MODE}" == "wake" ]] && \
        echo -e "\033[1;36m  *** WAKE MODE — spinning up drives ***\033[0m"

    section "HDD Power-Off Guard v${SCRIPT_VERSION} started (PID: $$, mode: ${MODE})"

    check_prerequisites
    acquire_lock

    info "Mode         : ${MODE}"
    info "Mount guard  : ${HDD_MOUNT}"
    info "Log file     : ${LOG_FILE}"
    info "hdparm tmout : ${TIMEOUT_SEC}s"
    info "Dry-run mode : ${DRY_RUN}"

    local all_disks=()
    if [[ -n "${HDD_IDS}" ]]; then
        read -ra all_disks <<< "${HDD_IDS}"
    elif [[ -n "${HDD_ID}" ]]; then
        all_disks=("${HDD_ID}")
    else
        die "No disk specified. Use -s sda, -i <disk-id>, or set HDD_ID. Run --help for details."
    fi

    info "Disks to process: ${all_disks[*]}"

    local overall_result="${EXIT_OK}"
    local disks_processed=0
    local disks_ok=0
    local disks_warning=0
    local disks_error=0

    for disk_id in "${all_disks[@]}"; do
        disks_processed=$(( disks_processed + 1 ))

        set +e
        if [[ "${MODE}" == "wake" ]]; then
            process_disk_wake "${disk_id}"
        else
            process_disk "${disk_id}"
        fi
        local disk_result=$?
        set -e

        case "${disk_result}" in
            "${EXIT_OK}")      disks_ok=$(( disks_ok + 1 ))           ;;
            "${EXIT_WARNING}") disks_warning=$(( disks_warning + 1 ))  ;;
            "${EXIT_ERROR}")   disks_error=$(( disks_error + 1 ))      ;;
        esac

        (( disk_result > overall_result )) && overall_result="${disk_result}" || true
    done

    section "Run complete"
    info "Mode            : ${MODE}"
    info "Disks processed : ${disks_processed}"
    info "OK              : ${disks_ok}"
    info "Warnings        : ${disks_warning}"
    info "Errors          : ${disks_error}"

    case "${overall_result}" in
        "${EXIT_OK}")      success "All disks processed successfully" ;;
        "${EXIT_WARNING}") warn    "Completed with warnings — review the log" ;;
        *)                 error   "Completed with errors — review the log: ${LOG_FILE}" ;;
    esac

    exit "${overall_result}"
}

main "$@"
