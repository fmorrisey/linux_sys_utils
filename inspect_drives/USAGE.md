# 🧠 inspect_rosewill_drives.sh

Automated inspection, SMART testing, and surface verification of legacy drives connected via a dual-bay **JMicron USB enclosure** (such as a Rosewill DAS).

---

## 🧩 Overview

`inspect_rosewill_drives.sh` is a Bash utility that validates the health and integrity of old hard drives before transferring their data into a modern RAID or ZFS array (for example, `/mnt/helicon` on TrueNAS).

The script performs **non-destructive diagnostics** on drives connected through JMicron-based USB enclosures, running SMART long tests and optional surface scans. It is part of the **Rainier Workstation** archival workflow but can be used on any Linux system.

---

## ⚙️ Features

- 🔍 Detects both JMicron bays (`usbjmicron,0` and `usbjmicron,1`)
- 🧪 Runs extended SMART self-tests and polls progress via JSON
- 💾 Optional **non-destructive** read-only surface scan with `badblocks`
- 🧱 Automatically maps drives to `/dev/sdX` by capacity
- 🧠 Produces structured logs for every step in `~/logs/rosewill_drives/`
- 🛡️ Never writes to drives or alters data

---

## 🧰 Requirements

Install dependencies:

```bash
sudo apt install smartmontools jq e2fsprogs
````

---

## 🗂️ Log Output

All reports are saved to:

```
~/logs/rosewill_drives/
```

| File                 | Description                              |
| -------------------- | ---------------------------------------- |
| `*_smart_before.txt` | Initial SMART report and self-test start |
| `*_smart_after.txt`  | Final SMART report after test completion |
| `*_badblocks.log`    | Optional read-only surface scan output   |

---

## 🧑‍💻 Usage

### Basic SMART inspection

```bash
chmod +x inspect_rosewill_drives.sh
./inspect_rosewill_drives.sh
```

### SMART + surface scan

```bash
RUN_BADBLOCKS=1 ./inspect_rosewill_drives.sh
```

### Adjust SMART polling interval

```bash
POLL_SECS=120 ./inspect_rosewill_drives.sh
```

---

## 🧾 Example Output

```
 -> Found: Serial=6QG3J74E  Model=ST3500630AS  Capacity=500107862016 bytes via /dev/sdf (bay 0)
 -> Found: Serial=9VP2NZL6  Model=ST31000528AS  Capacity=1000204886016 bytes via /dev/sdf (bay 1)

==> Polling SMART test progress for 6QG3J74E ...
    6QG3J74E: still running (40% remaining). Next check in 60s
```

Final SMART results:

```
SMART overall-health self-assessment test result: PASSED
Reallocated_Sector_Ct: 0
Current_Pending_Sector: 0
Offline_Uncorrectable: 0
```

---

## 🧮 Post-Test Verification

After completion, summarize all results:

```bash
grep -E "overall|Reallocated|Pending|Offline_Uncorrectable" ~/logs/rosewill_drives/*_smart_after.txt
```

Drives showing **PASSED** with zero reallocated or pending sectors are safe to migrate.

---

## ⚙️ Configuration Variables

| Variable        | Default    | Description                                 |
| --------------- | ---------- | ------------------------------------------- |
| `RUN_BADBLOCKS` | `0`        | Enables read-only surface scan              |
| `POLL_SECS`     | `60`       | SMART progress polling interval (seconds)   |
| `MAP_TOL_BYTES` | `52428800` | Size tolerance (~50 MiB) for device mapping |

---

## 🧩 Implementation Details

* Uses `smartctl --json` for structured parsing and progress tracking
* Maps drives by reported user capacity to the correct block device
* Handles dual-bay JMicron bridges exposing two disks through one node
* Organizes logs by drive serial number for traceability
* Performs all operations read-only and safe for mounted volumes

---

## 🛡️ Safety Notes

* The script **never writes** to drives
* The `badblocks` step runs in **read-only** mode (`-sv`)
* System disks are skipped automatically
* SMART long tests can take hours; avoid disconnecting drives mid-test

---

## 🧮 Useful Manual Commands

List connected drives:

```bash
sudo smartctl --scan
```

Check SMART manually:

```bash
sudo smartctl -a -d usbjmicron,0 /dev/sdf
sudo smartctl -a -d usbjmicron,1 /dev/sdf
```

Watch progress:

```bash
watch -n 60 'sudo smartctl -a -d usbjmicron,0 /dev/sdf | grep -A 5 "Self-test"'
```

---

## 📜 Example Repository Layout

```
/scripts/
  └── inspect_rosewill_drives.sh
/docs/
  └── inspect_rosewill_drives.md
/logs/
  └── rosewill_drives/
       ├── 6QG3J74E_smart_before.txt
       ├── 6QG3J74E_smart_after.txt
       ├── 9VP2NZL6_smart_before.txt
       ├── 9VP2NZL6_smart_after.txt
       └── *_badblocks.log
```

---

## 🧠 Project Context

This script is part of the **Rainier Workstation (HP Z440)** archival workflow for migrating legacy data from a **Rosewill USB 2.0 DAS** into the **Helicon RAIDZ1 ZFS pool** on TrueNAS SCALE. It ensures data integrity before archival transfer.

---

## ✍️ Author Notes

Developed by **Forrest Morrisey** — 2025

> “Measure twice, copy once — especially when your drives remember Windows XP.”

---