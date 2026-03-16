# Enterprise Operations Toolkit

Modular automation toolkit for enterprise system operations built with Bash and Python. Handles backup management, Oracle database administration (Data Pump export/import), disk monitoring with threshold-based alerting, automated patching, secure file transfer, and full database migration pipelines — with operation logging, email notifications, and colored terminal output.

## Features

- **File & Directory Backup** — Timestamped backups with pre/post disk utilization checks
- **Oracle Database Backup** — Automated Data Pump exports with parameter file generation and archive compression
- **Database Import** — Local and remote (cloud) import with schema remapping and validation
- **Database Migration** — End-to-end pipeline: backup → transfer → extract → import across environments
- **Disk Monitoring** — Threshold-based disk utilization checks with email alerting (supports automated continuous monitoring via the Python driver)
- **Automated Patching** — Time-window-based patch deployment (daytime/nighttime schedules) with local and remote SSH execution
- **Secure Copy** — SCP-based file transfer to remote servers with connection validation and directory provisioning
- **Operation Logging** — All operations tracked in an Oracle database with unique operation IDs, timestamps, and status updates (PROCESSING → COMPLETE/FAILED)
- **Email Notifications** — Success/failure alerts sent to administrators with log file contents
- **Interactive Help** — Guided prompts when incorrect arguments are provided

## Architecture

```
                        ┌──────────────────────┐
                        │   Control Scripts     │
                        │  (Bash / Python CLI)  │
                        └──────────┬───────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              │                    │                     │
     ┌────────▼────────┐ ┌────────▼────────┐  ┌────────▼────────┐
     │  Bash Modules   │ │ Python Modules  │  │  Notifications  │
     │  (ops_control)  │ │ (stack_modules) │  │  (Email/Slack)  │
     └────────┬────────┘ └────────┬────────┘  └────────┬────────┘
              │                    │                     │
    ┌─────────┼─────────┐         │                     │
    │         │         │         │                     │
┌───▼──┐ ┌───▼──┐ ┌────▼───┐ ┌──▼───┐          ┌──────▼──────┐
│Backup│ │ Disk │ │Secure  │ │Oracle│          │   mailx /   │
│(cp)  │ │(df)  │ │Copy    │ │Data  │          │   SMTP      │
│      │ │      │ │(scp)   │ │Pump  │          │             │
└──────┘ └──────┘ └────────┘ └──┬───┘          └─────────────┘
                                │
                    ┌───────────┼───────────┐
                    │           │           │
               ┌────▼───┐ ┌────▼───┐ ┌─────▼────┐
               │ Export  │ │ Import │ │Migration │
               │ (expdp) │ │(impdp) │ │(Full E2E)│
               └─────────┘ └────────┘ └──────────┘
```

## Project Structure

```
enterprise-ops-toolkit/
├── ops_control.sh                  # Bash control script (main entry point)
├── control_script_driver.py        # Python CLI driver
├── stack_modules.py                # Python module library
├── .env.example                    # Environment variable template
├── .gitignore                      # Excludes secrets, logs, dumps
└── README.md
```

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/Kwamib/enterprise-ops-toolkit.git
cd enterprise-ops-toolkit
```

### 2. Configure Environment

```bash
cp .env.example .env
# Edit .env with your actual values
```

### 3. Run Operations (Bash)

```bash
# File/Directory Backup
./ops_control.sh backup /path/to/source OPERATOR /path/to/destination

# Oracle Database Backup (Data Pump Export)
./ops_control.sh database_backup SCHEMA_NAME OPERATOR /backup/location

# Disk Utilization Check
./ops_control.sh disk_utilization /u01

# Secure Copy to Remote Server
./ops_control.sh secure_copy /path/to/source OPERATOR /remote/destination

# Database Migration (Backup + Transfer + Import)
./ops_control.sh database_migration LOCAL OPERATOR SCHEMA_NAME /backup/location
```

### 4. Run Operations (Python)

```bash
# File Backup
python control_script_driver.py backup /path/to/source /path/to/destination OPERATOR

# Oracle Database Backup
python control_script_driver.py database_backup SCHEMA1,SCHEMA2 OPERATOR DBNAME

# Disk Check (Single)
python control_script_driver.py Disk_Maintenance_Check_On_Prem /u01 85

# Automated Disk Monitoring (Continuous)
python control_script_driver.py Auto_Disk_Monitoring

# Compress Files
python control_script_driver.py compress /path/to/file OPERATOR /destination

# Uncompress Files
python control_script_driver.py uncompress /path/to/archive OPERATOR /destination

# Database Import
python control_script_driver.py database_import /path/to/dumpfile OPERATOR DBNAME DIRECTORY

# Automated Patching
python control_script_driver.py patching "SERVER1,PATCH_A,SERVER2,PATCH_B" OPERATOR
```

## Operation Logging

All operations are tracked in an Oracle database table with full lifecycle status:

| OP_ID | OP_TYPE         | START_TIME          | END_TIME            | STATUS     |
|-------|-----------------|---------------------|---------------------|------------|
| 48271 | BACKUP          | 2025-03-15 09:00:01 | 2025-03-15 09:05:32 | COMPLETE   |
| 63892 | DATABASE_BACKUP | 2025-03-15 10:15:00 | 2025-03-15 10:22:18 | COMPLETE   |
| 91034 | DATABASE_IMPORT | 2025-03-15 11:30:00 | -                   | PROCESSING |
| 22156 | PATCHING        | 2025-03-15 14:00:00 | 2025-03-15 14:01:45 | FAILED     |

## Automated Disk Monitoring

The Python driver supports continuous disk monitoring with configurable thresholds and alert intervals:

```python
# Alert thresholds and intervals
ALERT_THRESHOLDS = {
    "85": 5,   # Alert every 5 minutes when usage > 85%
    "95": 1,   # Alert every 1 minute when usage > 95%
}
```

Run in the background or via cron:

```bash
# Continuous monitoring (foreground)
python control_script_driver.py Auto_Disk_Monitoring

# Via cron (every 5 minutes)
*/5 * * * * cd /opt/scripts && python control_script_driver.py Disk_Maintenance_Check_On_Prem /u01 85
```

## Patching

Time-window-based patch deployment with support for local and remote (SSH) execution:

| Patch Type | Time Window         | Execution Method |
|------------|---------------------|------------------|
| PATCH_A    | 7:00 AM – 7:00 PM  | Local (yum)      |
| PATCH_B    | 7:00 PM – 7:00 AM  | Remote (SSH)     |

```bash
# Apply patches to multiple servers
python control_script_driver.py patching "webserver01,PATCH_A,dbserver01,PATCH_B" OPERATOR
```

## Prerequisites

- **OS:** Linux (RHEL/CentOS/Oracle Linux)
- **Database:** Oracle 12c+ with Data Pump utilities (expdp/impdp)
- **Python:** 3.6+ with `cx_Oracle`, `tabulate`
- **Tools:** `mailx`, `scp`, `ssh`, `sqlplus`, `tar`, `gzip`, `df`
- **Permissions:** Oracle DBA privileges, SSH key access for remote operations

## Security

- No hardcoded credentials — all secrets loaded via environment variables or external config
- PEM key permissions enforced (`chmod 400`)
- SSH connection validation before file transfers
- Database credentials managed through Oracle wallet or environment variables
- `.env` and credential files excluded via `.gitignore`

## Tech Stack

| Category       | Tools                                                |
|----------------|------------------------------------------------------|
| Languages      | Bash, Python                                         |
| Database       | Oracle (Data Pump, SQL*Plus)                         |
| Monitoring     | Disk utilization (df), threshold-based alerting       |
| Automation     | Cron, continuous monitoring loops, patching pipelines |
| File Transfer  | SCP, SSH                                             |
| Notifications  | mailx (Bash), smtplib (Python)                       |
| Logging        | Oracle DB operation tracking, file-based logging      |
