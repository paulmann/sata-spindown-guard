# sata-spindown-guard 🌓🛡️
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE) [![Shell](https://img.shields.io/badge/shell-bash-orange.svg)](https://www.gnu.org/software/bash/) ![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg) ![Scope](https://img.shields.io/badge/scope-SATA%20HDD%20only-blue.svg)


> **A safe, cron-friendly guard script that automatically spins down idle SATA HDDs and prevents them from being left spinning when not in use.**

`sata-spindown-guard.sh` is a robust, production-ready Bash utility that monitors one or more SATA hard drives and powers them down when they are not mounted and remain in the `active/idle` state for too long.  
It is designed to run periodically from `cron` as a *safety layer* on top of your backup or archive workflows, ensuring that cold-storage disks are not wasting power or wearing out their mechanics.

---

## ⚡ Quick Start

**Yes, both will be executable.**  
The install chain handles it automatically:

- `sata-spindown-guard.sh` — gets `chmod +x` applied if missing  
- `hddown` — symlink inherits the executable bit from its target; no separate `chmod` is needed

---

## Installation

```bash
# Clone the repository
git clone https://github.com/paulmann/sata-spindown-guard.git
cd sata-spindown-guard

# Install globally as `hddown` — resolves absolute path, ensures executable bit, creates symlink
src="$(readlink -f ./sata-spindown-guard.sh 2>/dev/null || realpath ./sata-spindown-guard.sh 2>/dev/null)" \
  && [ -f "$src" ] \
  && { [ -x "$src" ] || chmod +x "$src"; } \
  && sudo ln -sf "$src" /usr/local/bin/hddown \
  && sudo ln -sf "$src" /usr/local/bin/hddoff \
  && sudo ln -sf "$src" /usr/local/bin/hdd_poweroff_guard.sh \
  && echo "✅ Installed: $(which hddown) → $src"
```

> The install command automatically resolves the absolute path, grants the executable  
> bit to the source script if missing, and creates the `/usr/local/bin/hddown` symlink.  
> Since a symlink inherits permissions from its target, both `sata-spindown-guard.sh`  
> and `hddown` will be executable upon completion.

---

## Verify Installation

```bash
which hddown
# → /usr/local/bin/hddown

ls -la "$(which hddown)"
# → lrwxrwxrwx ... /usr/local/bin/hddown -> /path/to/sata-spindown-guard.sh
```

---

## Usage

Below are typical usage patterns for a single backup disk `/dev/sda` that is mounted at `/mnt/backup` only during actual backups.

```bash
# Show help and list all ATA disks discovered in /dev/disk/by-id/
hddown --help

# Power off a single SATA HDD by device name (auto-resolves /dev/disk/by-id/)
hddown -s sda

# Power off multiple disks explicitly by by-id names
hddown -i ata-WDC_WD10EZEX-00BBHA0_WD-WCC6Y0SLCEHT \
       -i ata-ST4000DM004-2CV104_ZFNXXXXXX

# Dry run — simulate actions without touching drive power state
hddown -s sda --dry-run

# Wake up a sleeping/standby drive (spin it up via minimal read I/O)
hddown -w -s sda

# Process disks from environment variables instead of CLI arguments
HDD_ID=ata-WDC_WD10EZEX-00BBHA0_WD-WCC6Y0SLCEHT hddown
HDD_IDS="ata-DISK1_XXX ata-DISK2_YYY" hddown
```

### Typical cron integration

The script is designed for *guard-style* cron execution – it checks drive state and powers off only when it is safe to do so.

```bash
# Edit root's crontab
sudo crontab -e
```

Example schedule (every 5 minutes, from 07:30 to 02:00, spanning midnight):

```cron
# sata-spindown-guard — protect /dev/sda (backup disk) from being left spinning
30-59/5  7     * * *  /usr/local/bin/hddown -s sda
*/5      8-23  * * *  /usr/local/bin/hddown -s sda
*/5      0-1   * * *  /usr/local/bin/hddown -s sda
```

---

## Uninstall

```bash
sudo rm /usr/local/bin/hddown && echo "✅ hddown removed from PATH"
```

---

## 📋 Table of Contents

- [🚨 Why sata-spindown-guard?](#-why-sata-spindown-guard)
- [How It Works](#how-it-works)
- [✨ Key Features](#-key-features)
- [🛡️ Safety Guarantees](#️-safety-guarantees)
- [🔧 Installation & Configuration](#-installation--configuration)
  - [System Requirements](#system-requirements)
  - [Configuration Options](#configuration-options)
  - [Command Line Options](#command-line-options)
  - [Usage Examples](#usage-examples)
- [📊 Logging & Monitoring](#-logging--monitoring)
- [🔍 Troubleshooting](#-troubleshooting)
- [🤝 Contributing](#-contributing)
- [📄 License](#-license)
- [👨‍💻 Author & Support](#-author--support)

---

## 🚨 Why sata-spindown-guard?

SATA HDDs used for cold storage, backups, or archives often get mounted periodically, used briefly, and then unintentionally left spinning for hours.  
This wastes power, generates unnecessary heat, and accelerates wear on mechanical components.

`sata-spindown-guard.sh` acts as a **stateless safety supervisor**: it does not manage your backup jobs, but it ensures that any unmounted drive will be cleanly powered down once it is no longer needed.

---

## How It Works

At a high level, each run of the script:

1. Resolves the target disk(s) either from:
   - `-s / --dev` (e.g. `sda`) → looks up matching `/dev/disk/by-id/ata-*`
   - `-i / --disk` (full by-id name)
   - `HDD_ID` / `HDD_IDS` environment variables
2. Verifies that the disk is an ATA/SATA device (`hdparm -i`).
3. Checks that the disk is **not mounted**, using both:
   - `findmnt --source /dev/sdX`
   - A configurable safety mount point `HDD_MOUNT` (e.g. `/mnt/backup`)
4. Queries the drive power state via `hdparm -C`:
   - Handles `active`, `idle`, `active/idle`, `standby`, `sleep`, `unknown`.
5. If the drive is spinning (`active/idle`), it:
   - Attempts `hdparm -Y` (deep sleep), falling back to `hdparm -y` (standby).
   - If hdparm fails or the firmware does not support ATA power management:
     - Runs a **diagnostic path** that logs capabilities and
       attempts a **forced power-off** via:
       - `udisksctl power-off -b /dev/sdX` (if available), or
       - sysfs SCSI `offline` + `delete` as a last resort.
6. Emits a detailed, timestamped log with **safe exit codes** suitable for monitoring.

When run with `-w / --wake`, the script instead issues a minimal `dd` read to spin the disk up and confirm that it is in `active/idle` state again.

---

## ✨ Key Features

- **SATA-focused**: Designed explicitly for ATA/SATA HDDs (not NVMe/USB).
- **Cron-friendly**: Stateless, idempotent, and safe to run every 5 minutes.
- **Multi-disk support**: Process one or many drives per run.
- **Auto-resolve by device name**: Just pass `-s sda` — no need to remember long by-id strings.
- **Detailed diagnostics**:
  - Logs APM and Power Management capabilities via `hdparm -I`.
  - Emits clear *why* a drive could not be powered down.
- **Fallback power-off methods**:
  - `udisksctl power-off` when UDisks2 is present.
  - SCSI `offline` + `delete` via `/sys` for stubborn drives.
- **Safe wake-up mode**:
  - Spins up sleeping drives via minimal read I/O.
- **Robust logging**:
  - Log rotation by size, colored interactive output, Nagios-compatible exit codes.

---

## 🛡️ Safety Guarantees

`sata-spindown-guard.sh` is built with safety as the first-class concern:

- **No power-off if mounted**  
  The script *never* attempts to power down a drive that is currently mounted or whose mount guard (`HDD_MOUNT`) is active.

- **Graceful failure**  
  When `hdparm` or other methods are not available, the script logs a warning and exits with a non-zero status instead of doing anything destructive.

- **Locking against concurrent runs**  
  A lightweight `flock` lock file (`/var/run/sata-spindown-guard.lock`) prevents overlapping cron runs.

- **Dry-run mode**  
  With `--dry-run`, no power or sleep commands are executed; all actions are simulated and logged.

---

## 🔧 Installation & Configuration

### System Requirements

- Linux with:
  - `/dev/disk/by-id` populated (standard on modern distros)
  - SATA controller using standard libata stack
- `bash` (POSIX-ish, but tuned for Bash)
- Required utilities:
  - `hdparm`, `timeout`, `findmnt`, `flock`, `stat`, `gzip`
  - Optionally: `udisksctl` (from `udisks2`) for graceful power-off

### Configuration Options

All options can be set via environment variables or CLI flags.

- `HDD_ID` — Single `/dev/disk/by-id` entry (used when no `-i/-s` provided).
- `HDD_IDS` — Space-separated list of disk IDs (`ata-...`).
- `HDD_MOUNT` — Safety mount path (default: `/mnt/backup`).
- `LOG_FILE` — Log file path (default: `/var/log/hdd_poweroff_guard.log` or similar).
- `LOG_MAX_SIZE` — Max log size in bytes before rotation (default: 10 MB).
- `TIMEOUT_SEC` — Timeout for `hdparm` and other blocking operations (default: `10`).
- `DRY_RUN` — `"true"` to simulate actions without affecting drive state.

### Command Line Options

```text
Usage: hddown [OPTIONS]

  -h, --help            Show help and list available ATA disks
  -v, --version         Show version information
  -d, --dry-run         Simulate without making any changes to the drive
  -w, --wake            Wake mode: spin up drives from standby/sleep
  -s, --dev DEV         Device name (e.g. sda) — disk ID resolved automatically
  -i, --disk ID         Disk ID from /dev/disk/by-id/ (can be repeated)
```

### Usage Examples

```bash
# Simple: guard a single backup disk
hddown -s sda

# Guard multiple named disks from cron
hddown -i ata-DISK1_XXX -i ata-DISK2_YYY

# Increase hdparm timeout for slow/large disks
TIMEOUT_SEC=30 hddown -s sda

# Use a custom log file location
LOG_FILE=/var/log/sata-spindown-guard.log hddown -s sda

# Fully simulated run with verbose logging (run manually)
DRY_RUN=true hddown -s sda
```

---

## 📊 Logging & Monitoring

The script writes a structured log with timestamps and levels:

```text
[2026-03-15 19:13:42] [INFO]    [sata-spindown-guard.sh] Disk is not mounted — safe to proceed
[2026-03-15 19:13:42] [INFO]    [sata-spindown-guard.sh] Drive state: active/idle
[2026-03-15 19:13:42] [SUCCESS] [sata-spindown-guard.sh] Drive powered down successfully (state: standby)
```

- Log rotation keeps size under control (`LOG_MAX_SIZE`).
- Exit codes are designed for monitoring tools:
  - `0` — Success / no action needed.
  - `1` — Error occurred.
  - `2` — Warning (uncertain state, could not fully process).
  - `3` — Another instance is already running (lock held).

You can hook this into Prometheus exporters, Nagios, Zabbix, or any log-based alerting system.

---

## 🔍 Troubleshooting

### Drive always reported as `active/idle`

- Check for background services polling SMART or disk stats:
  - `smartd`, `mdadm`, RAID controllers, monitoring daemons.
- Verify `hdparm -C /dev/sdX` manually:
  ```bash
  sudo hdparm -C /dev/sda
  ```
- If it never transitions to `standby`:
  - Inspect `hdparm -I /dev/sda` for APM and Power Management support.
  - Consider enabling APM:
    ```bash
    sudo hdparm -B 1 /dev/sda
    ```

### Power-off not supported by firmware

When `hdparm -Y/-y` fail, the script:

- Logs drive capabilities (`hdparm -I`).
- Tries `udisksctl power-off -b /dev/sdX` if available.
- Falls back to:
  ```bash
  echo offline > /sys/class/block/sdX/device/state
  echo 1       > /sys/block/sdX/device/delete
  ```
- Prints manual recovery commands to rescan:
  ```bash
  echo "- - -" > /sys/class/scsi_host/hostX/scan
  ```

### Permission errors

Always run from root or via `sudo` when touching block devices:

```bash
sudo hddown -s sda
```

---

## 🤝 Contributing

Contributions, feature requests, and bug reports are very welcome.

### Development Setup

```bash
git clone https://github.com/paulmann/sata-spindown-guard.git
cd sata-spindown-guard

# Basic syntax check
bash -n sata-spindown-guard.sh

# Dry-run on a test system
DRY_RUN=true ./sata-spindown-guard.sh -s sda
```

### Contribution Guidelines

1. **Fork** the repository.
2. **Create** a feature branch: `git checkout -b feature/your-feature`.
3. **Test** your changes thoroughly on a non-production system.
4. **Commit** with a clear message: `git commit -m 'Add XYZ feature'`.
5. **Push** to your fork: `git push origin feature/your-feature`.
6. **Open** a Pull Request describing your changes and rationale.

### Code Standards

- ✅ **Safe by default** — never power off a mounted disk.  
- ✅ **Clear logging** — every decision should be traceable in the log.  
- ✅ **No silent failures** — warnings or errors must be explicit.  
- ✅ **ShellCheck-friendly** — keep the script clean and maintainable.  
- ✅ **Backward-compatible** — do not break existing CLI usage patterns.

---

## 📄 License

This project is licensed under the **MIT License** – see the [`LICENSE`](LICENSE) file for details.

---

## 👨‍💻 Author & Support

**Mikhail Deynekin**

- 🌐 Website: [deynekin.com](https://deynekin.com)  
- 📧 Email: mid1977@gmail.com  
- 🐙 GitHub: [@paulmann](https://github.com/paulmann)

### Getting Help

- 📖 **Documentation**: This README.  
- 🐛 **Bug Reports**: Open an issue in the repository.  
- 💡 **Feature Requests**: Use issues with the `feature` label.  
- 💬 **Questions**: Start a GitHub Discussions thread if enabled.

---

### ⭐ Star this repository if it helps you!

**sata-spindown-guard** – *Keeping your backup drives truly cold when they should rest.* 🌓🛡️
