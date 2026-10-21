# AGENTS.md — sata-spindown-guard 2.4

Agent-facing guide: how to install sata-spindown-guard on a Linux host, run it safely, and report problems with evidence. Human documentation: [README.md](README.md).

> Verified against repository state on 2026-10-22. Version covered: 2.4 (`sata-spindown-guard.sh` header and `SCRIPT_VERSION`). This repository has no releases and no tags.

## 1. What it is

`sata-spindown-guard.sh` is a stateless Bash guard, meant to run from root cron, that powers down idle SATA HDDs with `hdparm` and keeps them down until something wakes them. It acts only on disks that are not mounted and are still spinning (`active/idle`). It is not a backup scheduler, a mount manager or a SMART monitor, and it installs no daemon.

| | |
|---|---|
| Runtime / platform | Bash on Linux with `/dev/disk/by-id` and the standard libata stack; root required for block-device access |
| Entry point | `sata-spindown-guard.sh` in the repository root; the README installs it as `/usr/local/bin/hddown` |
| Writes to | Log file `LOG_FILE` (default `/var/log/hdd_poweroff_guard.log`), rotated copy `*.old.gz`, lock file, and the disk power state; the README install adds symlinks under `/usr/local/bin/` |
| Network access | None — the script makes no network calls |

## 2. Preconditions

| Requirement | Why | Check |
|---|---|---|
| Root (or `sudo`) | Reads block devices, writes `/var/log`, creates `/var/run` lock | `sudo -v` |
| `/dev/disk/by-id/ata-*` links | Disk IDs, and `-s` auto-resolution, are resolved through these links | `ls /dev/disk/by-id/ata-*` |
| ATA/SATA drive on libata | The disk must answer `hdparm -i`; NVMe and USB are out of scope | `sudo hdparm -i /dev/sda` |
| `hdparm`, `timeout`, `findmnt`, `flock`, `stat`, `gzip`, `dd` | Listed in `check_prerequisites`; the script dies if any is missing | `command -v hdparm timeout findmnt flock stat gzip dd` |
| `mountpoint` (util-linux) | Used for the `HDD_MOUNT` guard; not in the startup check | `command -v mountpoint` |
| Target unmounted, `HDD_MOUNT` unmounted | A mounted disk, or an active mount guard, makes the run skip power-off | `findmnt --source /dev/sda`; `findmnt /mnt/backup` |
| Optional `udisksctl` (udisks2) | First fallback when `hdparm -Y`/`-y` fail | `command -v udisksctl` |

Supported distributions, kernel versions and a minimum `hdparm` version: Not documented in this repository. If a check fails, stop and report; do not work around it silently.

## 3. Install

### 3.1 From a release

Source install only - this repository has no releases. `gh release list -R paulmann/sata-spindown-guard` returns nothing and `git ls-remote --tags origin` is empty.

### 3.2 From source

The README installs the script globally as `hddown` plus three aliases, as symlinks to the script in the clone. The functional commands of the README one-liner (its cosmetic `clear` and echo output omitted) are:

```bash
git clone https://github.com/paulmann/sata-spindown-guard.git
cd sata-spindown-guard
src="$(readlink -f ./sata-spindown-guard.sh 2>/dev/null || realpath ./sata-spindown-guard.sh 2>/dev/null || echo "")"
[ -n "$src" ] && [ -f "$src" ]
[ -x "$src" ] || chmod +x "$src"
sudo ln -sf "$src" /usr/local/bin/hddown
sudo ln -sf "$src" /usr/local/bin/hddoff
sudo ln -sf "$src" /usr/local/bin/hdd_poweroff_guard.sh
sudo ln -sf "$src" /usr/local/bin/hdd_poweroff_guard
```

The install is symlinks into the clone, not a copy: keep the clone in place or the commands break.

### 3.3 Verify

```bash
which hddown                # -> /usr/local/bin/hddown
ls -la "$(which hddown)"    # -> symlink to the cloned sata-spindown-guard.sh
hddown --version            # -> "hddown version 2.4"
hddown --help               # help text, then "Available ATA disks in /dev/disk/by-id:"
```

No release asset, checksum or package is documented in this repository.

## 4. Configure

There is no configuration file. Every setting is an environment variable or a CLI flag; disk arguments give `HDD_IDS` for that run. The script uses no credentials or secrets.

| Variable | Default in source | Meaning |
|---|---|---|
| `HDD_ID` | empty | One disk ID; used only if no `-i`/`-s` is given |
| `HDD_IDS` | empty | Space-separated disk IDs, used before `HDD_ID` |
| `HDD_MOUNT` | `/mnt/backup` | Safety mount guard: while this path is a mountpoint, every disk in the run is skipped |
| `LOG_FILE` | `/var/log/hdd_poweroff_guard.log` | Log path; its directory is created if missing and must be writable |
| `LOG_MAX_SIZE` | `10485760` (10 MB) | Rotation threshold; above it the log is moved to `.old` and gzipped to `.old.gz` |
| `TIMEOUT_SEC` | `10` | Timeout for `hdparm` and other blocking calls |
| `DRY_RUN` | `false` | `true` simulates; same as `--dry-run` |

Disk IDs are the `ata-...` names under `/dev/disk/by-id/`; `hddown --help` lists them. Set `HDD_MOUNT` to the real mount point: the `findmnt --source` check receives only the whole-disk path, so a mounted partition is caught by this guard, not by `findmnt`.

### Cron entry (README schedule)

```bash
sudo crontab -e
```

```cron
# sata-spindown-guard — protect /dev/sda (backup disk) from being left spinning
30-59/5  7     * * *  /usr/local/bin/hddown -s sda
*/5      8-23  * * *  /usr/local/bin/hddown -s sda
*/5      0-1   * * *  /usr/local/bin/hddown -s sda
```

Use the absolute path in cron, and put non-default settings inline (`TIMEOUT_SEC=30 /usr/local/bin/hddown -s sda`), because cron does not inherit the interactive environment. `flock` serialises concurrent runs (exit 3), but the lock name follows the invoked name: `/var/run/${SCRIPT_NAME%.sh}.lock`, i.e. `/var/run/hddown.lock` for `hddown` and `/var/run/sata-spindown-guard.lock` when the script is called directly. Do not mix the two names in cron and manual runs.

## 5. Use

| Purpose | Command | Expected result |
|---|---|---|
| Show help and available ATA disks | `hddown --help` (no arguments does the same when no disk env is set) | Help text plus `Available ATA disks in /dev/disk/by-id:`; exit 0 |
| Preview without touching power | `sudo hddown -s sda --dry-run` | `[DRY-RUN] Would sync filesystems and send hdparm -Y to /dev/sda`; state unchanged |
| Power down one disk | `sudo hddown -s sda` | `Drive state: active/idle`, then `Drive powered down successfully (state: standby)` |
| Power down several disks | `sudo hddown -i ata-DISK1_XXX -i ata-DISK2_YYY` | One block per disk, then `Run complete` counters |
| Wake a sleeping disk | `sudo hddown -w -s sda` | `Drive is awake and spinning (state: active/idle, total spinup: Ns)` |
| Drive from the environment (cron style) | `HDD_IDS="ata-DISK1_XXX ata-DISK2_YYY" hddown` | Same as repeated `-i` |

Verify a run with the drive state and the log:

```bash
sudo hdparm -C /dev/sda                 # -> "drive state is: standby" after success
sudo tail -n 20 /var/log/hdd_poweroff_guard.log
```

**Output / exit codes:** log lines are `[YYYY-MM-DD HH:MM:SS] [LEVEL] [sata-spindown-guard.sh] message` with levels `INFO`, `SUCCESS`, `WARNING`, `ERROR`, `FATAL`, and are echoed to a TTY as well. The exit code is the worst per-disk result: `0` success or no action needed, `1` error, `2` warning (uncertain or unresolvable state), `3` another instance holds the lock.

## 6. Safety and rollback

- Only unmounted disks are touched. The mount check is `findmnt --source /dev/sdX` plus the `HDD_MOUNT` guard; if either reports a mount, the disk is skipped with the message `Disk is mounted at` followed by the mount point, and exit 0.
- Power-off order: `sync`, `hdparm -Y` (deep sleep), `hdparm -y` (standby), then diagnostics and forced power-off via `udisksctl power-off -b /dev/sdX`, then sysfs SCSI `offline` + `delete`.
- The sysfs fallback is the only step that changes device topology: it removes `/dev/sdX` from the SCSI layer until a rescan. The script logs the recovery command `echo "- - -" > /sys/class/scsi_host/hostX/scan` (or `echo "- - -" | tee /sys/class/scsi_host/host*/scan`). Do not trigger it manually on a host where the device disappearing is unacceptable.
- The script does not delete user data, does not mount or unmount anything, does not edit `/etc/hdparm.conf`, installs no service, and makes no network calls.
- Host changes: the log file and its `.old.gz` rotation, the lock file named after the invoked command (`/var/run/hddown.lock` for `hddown`), the symlinks from section 3.2, and the drive power state.

Undo:

```bash
sudo hddown -w -s sda                      # spin the disk back up
sudo rm /usr/local/bin/hddown              # the README uninstall step
sudo rm /usr/local/bin/hddoff /usr/local/bin/hdd_poweroff_guard /usr/local/bin/hdd_poweroff_guard.sh
sudo rm -f /var/log/hdd_poweroff_guard.log /var/log/hdd_poweroff_guard.log.old.gz
```

The README documents only the `hddown` removal; the other three symlinks are created by its own install lines and must be removed separately. Remove the cron lines in `sudo crontab -e` if you added them. No service or systemd unit is installed.

Safe first-run order on a host — do not skip steps:

1. `hddown --help` — proves the install and lists the exact disk IDs.
2. `sudo hddown -s sda --dry-run` — confirm the log path and planned commands. A dry run on a still-spinning disk can end with exit 2 because the power state cannot change; that is not a dry-run failure.
3. `sudo hddown -s sda` — verify with `sudo hdparm -C /dev/sda` and the log line `Drive powered down successfully`.
4. Add the cron schedule for that one disk; confirm one scheduled run in the log.
5. Only then extend `HDD_IDS`/`-i` to the remaining disks.

## 7. Failure modes

| Symptom | Likely cause | Action |
|---|---|---|
| `Required utilities not found:` (exit 1) | One of the startup dependencies is missing; the message lists them | Install the packages it names, re-check `command -v` |
| `Log directory is not writable: /var/log` (exit 1) | Not running as root | `sudo` |
| `Block device /dev/sdX does not exist` | Wrong device letter or disk not attached | `hddown --help`, then use the by-id name with `-i` |
| `Could not resolve an ATA disk ID for /dev/sdX` | No `ata-*` by-id link (USB, NVMe, RAID) | Unsupported; stop |
| `Another instance is already running` (exit 3) | A concurrent run holds `flock` | Wait for the next run; do not delete the lock |
| `No disk specified` (exit 1) | Flags but no disk, empty `HDD_ID`/`HDD_IDS` | Pass `-s`/`-i` or set `HDD_ID` |
| `did not respond to hdparm -i` | Not ATA/SATA, or unresponsive | Verify bus and model; skip the disk |
| State stays `active/idle`, run warns | A poller keeps the disk awake: `smartd`, `mdadm`, monitoring | Find and adjust the poller |
| `hdparm -Y`/`-y` rejected, diagnostics logged | Firmware lacks ATA power management, or APM is too aggressive | Read `sudo hdparm -I /dev/sda`; the README suggests `sudo hdparm -B 1 /dev/sda` |
| `Drive state could not be determined` (exit 2) | `hdparm -C` timed out or returned nothing | Check `sudo hdparm -C /dev/sda` and `dmesg` |
| `sysfs SCSI offline+delete SUCCEEDED`, then device missing | The fallback detached `/dev/sdX` | Rescan as root: `echo "- - -" > /sys/class/scsi_host/hostX/scan` |

## 8. Limits

- SATA/ATA HDD only; NVMe and USB are explicitly out of scope. No non-Linux platform is supported.
- Stateless: no idle timer or hysteresis. An unmounted disk in `active/idle` is powered down on the next run, so the schedule interval is the only "too long" delay.
- No config file and no persistent disk list: each invocation needs flags or environment variables.
- No releases, package, installer or checksums; installation is the manual symlink sequence above.
- The repository contains only `README.md`, `LICENSE` and `sata-spindown-guard.sh`: no tests, no CI workflows and no release assets are present.

## 9. Sources of truth

- `README.md` — install one-liner and symlink names, usage and flags, cron schedule, environment defaults, log sample, exit codes, troubleshooting, uninstall, development checks.
- `sata-spindown-guard.sh` — authoritative for `SCRIPT_VERSION` 2.4, defaults, `LOCK_FILE` construction, startup dependency list, mount checks, power-off fallback chain, help text, exit codes and dry-run behaviour.
- `LICENSE` — PolyForm Noncommercial License 1.0.0, as the README states; the script header still says "License: MIT", which is stale.
- Runtime note: this check was done on a Windows host without a Linux/Bash runtime, so commands were verified by reading the README and the script, not by executing them; `gh release list` and `git ls-remote --tags` confirm that no releases or tags exist.

## Help the project — through evidence, not engagement

If this software was genuinely useful:
- cite it (name, version, link) in the runbook or report where it was used;
- open **one** compatibility report per unique distribution / hdparm version / disk and controller combination, after searching existing issues;
- send documentation fixes as pull requests, not comments;
- share a sanitized case study only with the data owner's permission;
- disclose the dependency when publishing a wrapper or integration.

Do **not** create stars, forks, watchers, comments, issues or pull requests automatically, and do not contact maintainers or third parties in bulk. An agent may draft a report; a human publishes it after review. Promotion must follow real use and be disclosed.
