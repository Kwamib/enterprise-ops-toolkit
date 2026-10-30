#!/bin/bash
# =============================================================================
# Enterprise Operations Control Script
# Description: Modular Bash automation toolkit for enterprise system operations
#              including backup, database management, disk monitoring,
#              secure file transfer, and database migration.
# Author: Mayowa Babatola
#
# NOTE ON `set -e`: not enabled. Each step checks its own result and records
# FAILED in the audit log before returning; `set -e` would exit first and leave
# the audit row at PROCESSING. `set -u` is off because several settings are
# optional and are checked where they are used.
# =============================================================================

# ---------------------------------------------------------
# Configuration - Set these via environment variables or .env
# ---------------------------------------------------------
SCRIPTS="${SCRIPTS_DIR:-/opt/scripts}"
DB_NAME="${DB_NAME:-MYDB}"
AVAIL=$(ps -ef | grep pmon | grep "${DB_NAME}" | awk '{print $8}' | cut -d "_" -f 3)
# Timestamps are YYYYMMDDHHMMSS: sortable, unique to the second, and digits
# only, because file names built from them are split on "_" later.
TS=$(date "+%Y%m%d%H%M%S")
SCRIPT_HOME="${SCRIPT_HOME:-/opt/scripts/bin}"
HOST="${REMOTE_HOST}"
USER="${REMOTE_USER:-oracle}"
PEM_FILE="${PEM_FILE_PATH}"
MAIL="${ALERT_EMAIL}"
LOG_DIR="${LOG_DIR:-/backup/datapump/${DB_NAME}}"
DB_SCHEMA_PREFIX="${DB_SCHEMA_PREFIX:-OPS}"

# Alert threshold, in percent. The check and every alert message use it.
DISK_THRESHOLD="${DISK_THRESHOLD:-80}"

# Colors for Output
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Helper Functions for Colored Outputs
print_green() { echo -e "${GREEN}$1${RESET}"; }
print_red() { echo -e "${RED}$1${RESET}"; }
print_cyan() { echo -e "${CYAN}$1${RESET}"; }

# Operation IDs: epoch seconds plus PID, unique for any realistic run rate.
# ($RANDOM only goes to 32767, so IDs collided.)
new_op_id() {
	echo "$(date +%s)$$"
}

# ---------------------------------------------------------
# Help / Usage Functions
# ---------------------------------------------------------
display_help_bk() {
	print_cyan "\nFor BACKUP ACTION"
	print_cyan "\nUsage: $0 <ACTION> <SOURCE> <RUNNER> <DESTINATION>\n"
	print_cyan "EXAMPLE: $0 backup /path/to/source RUNNER /path/to/destination."
}

display_help_db() {
	print_cyan "\nFor DATABASE BACKUP ACTION"
	print_cyan "\nUsage: $0 <ACTION> <SCHEMA> <RUNNER> <DESTINATION>\n"
	print_cyan "EXAMPLE: $0 database_backup SCHEMA RUNNER /path/to/destination"
}

display_help_sc() {
	print_cyan "\nFor Secure BACKUP ACTION"
	print_cyan "\nUsage: $0 <ACTION> <SOURCE> <RUNNER> <BACKUP DESTINATION>\n"
	print_cyan "EXAMPLE: $0 secure_copy SOURCE RUNNER /path/to/destination."
}

display_help_dk() {
	print_cyan "\nFor DISK UTILIZATION"
	print_cyan "\nUsage: $0 <ACTION> <MOUNT_POINT>\n"
	print_cyan "EXAMPLE: $0 disk_utilization MOUNT_POINT"
}

display_help_mg() {
	print_cyan "\nFor DATABASE MIGRATION"
	print_cyan "\nUsage: $0 <ACTION> <TARGET_DB> <RUNNER>\n"
	print_cyan "EXAMPLE: $0 database_migration TARGET_DB RUNNER"
}

# ---------------------------------------------------------
# Email Notification Function
# ---------------------------------------------------------
email() {
	if [[ -z "$MAIL" || -z "${SUBJECT}" || -z "${BODY}" ]]; then
		print_red "\n[ERROR] Missing variables. Cannot send email."
		return 1
	fi

	echo "${BODY}" | mailx -s "${SUBJECT}" "${MAIL}"
}

# ---------------------------------------------------------
# Disk Utilization Monitoring
# ---------------------------------------------------------
# Returns a status instead of exiting: callers are mid-operation and still
# need to record COMPLETE or FAILED for the audit row.
disk_utilization() {
	local MOUNT_POINT=$1

	print_cyan "\n[INFO] Performing Disk Check on ${MOUNT_POINT}\n"

	UTILIZATION=$(df -h 2>/dev/null | awk -v mount="$MOUNT_POINT" '$NF == mount {print $(NF-1)}' | sed 's/%//')

	if [[ -z "${UTILIZATION}" ]]; then
		print_red "\n[ERROR] Unable to retrieve disk utilization for ${MOUNT_POINT}. Check if the mount point exists."
		return 2
	fi

	print_cyan "\n[STATUS] Current utilization for ${MOUNT_POINT} is ${UTILIZATION}%\n"

	if [[ ${UTILIZATION} -gt ${DISK_THRESHOLD} ]]; then
		print_red "\n[WARNING] Disk usage on ${MOUNT_POINT} exceeded ${DISK_THRESHOLD}%! Current: ${UTILIZATION}%"
		SUBJECT="[WARNING] Disk usage on ${MOUNT_POINT} exceeded ${DISK_THRESHOLD}% threshold. Current usage: ${UTILIZATION}%"
		BODY="[WARNING]: Disk usage exceeded the ${DISK_THRESHOLD}% threshold on ${MOUNT_POINT}. Current usage: ${UTILIZATION}%."

		print_cyan "\n[ALERT] Sending email to the DevOps Engineers.\n"
		email "${SUBJECT}" "${BODY}"
		return 1
	fi

	print_green "\n[INFO] Disk space on ${MOUNT_POINT} is within safe limits.\n"
	return 0
}

# ---------------------------------------------------------
# File/Directory Backup Function
# ---------------------------------------------------------
# Usage: backup SOURCE RUNNER DESTINATION
backup() {
	local SOURCE="${1:?source required}"
	local RUNNER="${2:?runner required}"
	local DESTINATION="${3:?destination required}"

	local MOUNT_POINT="/backup"
	local OP_ID
	OP_ID=$(new_op_id)
	local OP_TYPE="BACKUP"

	print_cyan "\n[INFO] Starting backup process ....\n"

	# Check Disk Utilization Before Backup
	border="================================================================================================"
	echo "$border"
	echo -e "\n|| [INFO] -> Checking disk utilization for ${MOUNT_POINT} before starting the backup... ||\n"

	disk_utilization "${MOUNT_POINT}" || {
		print_red "\n[ERROR] Disk check failed for ${MOUNT_POINT}. Backup aborted.\n"
		return 1
	}
	echo "$border"

	TS=$(date "+%Y%m%d%H%M%S")
	print_cyan "\n[INFO] Backing up SOURCE: ${SOURCE} TO DESTINATION: ${DESTINATION}\n"

	IFS=' ' read -r -a SOURCE_ARRAY <<< "${SOURCE}"

	database_logging "$OP_ID" "$OP_TYPE" "PROCESSING"

	# ITEM, not SOURCE, so the summary afterwards reports what was requested.
	for ITEM in "${SOURCE_ARRAY[@]}"; do
		if [[ -f "${ITEM}" ]]; then
			BACKUP_TYPE="file_backup"
			print_green "\n[INFO] ${ITEM} is a file\n"
		elif [[ -d "${ITEM}" ]]; then
			BACKUP_TYPE="directory_backup"
			print_green "\n[INFO] ${ITEM} is a directory\n"
		else
			print_red "\n[ERROR] The source: ${ITEM} is neither a file nor a directory. Backup aborted!\n"
			# Record FAILED before returning, so the audit row never stays PROCESSING.
			database_logging "$OP_ID" "$OP_TYPE" "FAILED"
			return 1
		fi

		TS_SOURCE=$(basename "${ITEM}")_${TS}

		TIMESTAMPED_DESTINATION="${DESTINATION}/${BACKUP_TYPE}/${RUNNER^^}/${TS}"

		if [[ ! -d "${TIMESTAMPED_DESTINATION}" ]]; then
			print_cyan "\n[INFO] Creating ${TIMESTAMPED_DESTINATION} directory...\n"
			mkdir -p "${TIMESTAMPED_DESTINATION}" || {
				print_red "\n[ERROR] Failed to create directory.\n"
				database_logging "$OP_ID" "$OP_TYPE" "FAILED"
				return 1
			}
			print_green "\n[SUCCESS] ${TIMESTAMPED_DESTINATION} has been created!\n"
		fi

		print_cyan "\n[INFO] Copying ${ITEM} to ${TIMESTAMPED_DESTINATION}\n"

		cp -r "${ITEM}" "${TIMESTAMPED_DESTINATION}/${TS_SOURCE}" || {
			print_red "\n[ERROR] Failed to copy source\n"
			database_logging "$OP_ID" "$OP_TYPE" "FAILED"
			return 1
		}
	done

	print_green "\n[SUCCESS] Backed up ${#SOURCE_ARRAY[@]} source(s) to => ${TIMESTAMPED_DESTINATION}.\n"

	print_cyan "\n **** CONTENTS OF ${TIMESTAMPED_DESTINATION} ****\n"
	ls -ltr "${TIMESTAMPED_DESTINATION}"

	border="============================================================================="
	echo "$border"
	print_cyan "\n|| [INFO] -> Checking disk utilization after backup completion... ||\n"
	# Post-backup check is informational - the data is already written, so a
	# high-water warning should not fail the operation.
	disk_utilization "${MOUNT_POINT}" || print_red "\n[WARNING] Disk above threshold after backup.\n"
	echo "$border"

	database_logging "$OP_ID" "$OP_TYPE" "COMPLETE"
}

# ---------------------------------------------------------
# Database Operation Logging (Oracle)
# ---------------------------------------------------------
database_logging() {
	local OP_ID="$1"
	local OP_TYPE="$2"
	local STATUS="$3"

	local TS
	TS=$(date "+%Y-%m-%d %H:%M:%S")
	LOG_TS=$(date "+%Y%m%d%H%M%S")

	local LOGDIR="${SCRIPT_HOME}/logs/${LOG_TS}"
	local LOG_FILE="${LOGDIR}/dblogin_${LOG_TS}.log"

	mkdir -p "${LOGDIR}"

	print_cyan "\n[INFO] Log file created at: ${LOG_FILE}\n"

	# shellcheck source=/dev/null  # per-database environment file, path set at run time
	source "${SCRIPTS}/oracle_env_${DB_NAME}.sh"

	echo "[INFO] Logging Operation: OP_ID=${OP_ID}, OP_TYPE=${OP_TYPE}, STATUS=${STATUS}, TIMESTAMP=${TS}"

	# Check sqlplus's status straight away: any command in between replaces $?.
	local rc=0

	if [[ "${STATUS}" == "PROCESSING" ]]; then
		# Named columns, so adding a column to the table can't break this INSERT.
		sqlplus -s "/as sysdba" <<EOF
		set linesize 250
		WHENEVER SQLERROR EXIT FAILURE
		INSERT INTO ${DB_SCHEMA_PREFIX}.operations
		    (OP_ID, OP_TYPE, START_TIME, END_TIME, STATUS)
		VALUES (${OP_ID}, '${OP_TYPE}', '${TS}', '-', 'PROCESSING');
		COMMIT;
		EXIT;
EOF
		rc=$?

	elif [[ "${STATUS}" == "COMPLETE" || "${STATUS}" == "FAILED" ]]; then
		local END_TS
		END_TS=$(date "+%Y-%m-%d %H:%M:%S")

		echo "[INFO] Updating operation ID ${OP_ID} to STATUS=${STATUS} with END_TIME=${END_TS}"

		sqlplus -s "/as sysdba" <<EOF
		set linesize 250
		WHENEVER SQLERROR EXIT FAILURE
		UPDATE ${DB_SCHEMA_PREFIX}.operations
		SET END_TIME='${END_TS}', STATUS='${STATUS}'
		WHERE OP_ID=${OP_ID};
		COMMIT;
		EXIT;
EOF
		rc=$?
	fi

	# A logging failure warns but doesn't stop the caller: the backup matters
	# more than its audit row.
	if (( rc != 0 )); then
		print_red "\n[ERROR] Database logging failed for OP_ID=${OP_ID} (status ${STATUS})."
		return 1
	fi

	print_cyan "\n[INFO] Database logging completed successfully."
	return 0
}

# ---------------------------------------------------------
# Oracle Database Backup (Data Pump Export)
# ---------------------------------------------------------
database_backup() {
	local SCHEMA="${1:?schema required}"
	local RUNNER="${2:?runner required}"
	local DESTINATION="${3:?destination required}"

	local MOUNT_POINT="/backup"
	local OP_ID
	OP_ID=$(new_op_id)
	local OP_TYPE="DATABASE_BACKUP"
	local LOG_FILE
	local TS
	TS=$(date "+%Y%m%d%H%M%S")

	print_cyan "\n[INFO] Backing up SCHEMA: ${SCHEMA}\n"

	border="================================================================================================"
	echo "$border"
	print_cyan "\n|| [INFO] -> Checking disk utilization for ${MOUNT_POINT} before backup... ||\n"
	disk_utilization "${MOUNT_POINT}" || {
		print_red "\n[ERROR] Disk check failed. Backup aborted.\n"
		return 1
	}
	echo "$border"

	export ORACLE_SID="${DB_NAME}"

	local AVAIL
	AVAIL=$(ps -ef | grep pmon | grep "${DB_NAME}" | awk '{print $8}' | cut -d "_" -f 3)

	if [[ "${AVAIL}" != "${DB_NAME}" ]]; then
		print_red "\n[ERROR] Database ${DB_NAME} is not running.\n"
		database_logging "$OP_ID" "$OP_TYPE" "FAILED"
		return 1
	fi

	print_cyan "\n[INFO] Pointing to ${AVAIL} database\n"
	# shellcheck source=/dev/null  # per-database environment file, path set at run time
	source "${SCRIPTS}/oracle_env_${DB_NAME}.sh"

	print_cyan "\n[INFO] The ${AVAIL} Database is up and running, checking for DB status."

	# Written and read at the same absolute path, wherever the script runs from.
	local STATUS_LOG="${SCRIPT_HOME}/check_db_status.log"

	sqlplus -s "${DB_CONNECT_STRING}" > "${STATUS_LOG}" <<EOF
SELECT status FROM v\$instance;
EXIT;
EOF

	if ! grep -q "OPEN" "${STATUS_LOG}"; then
		print_red "\n[ERROR] The ${AVAIL} instance is not OPEN!"
		database_logging "$OP_ID" "$OP_TYPE" "FAILED"
		return 1
	fi

	print_green "\n[SUCCESS] The ${AVAIL} database is OPEN.\n"

	source /usr/local/bin/oraenv <<<"$ORACLE_SID"

	database_logging "$OP_ID" "$OP_TYPE" "PROCESSING"

	# Names are built once and reused below.
	local BASENAME="expdp_${SCHEMA}_${RUNNER}_${TS}"
	local PAR_FILE="${BASENAME}.par"
	local DUMP_FILE="${BASENAME}.dmp"
	LOG_FILE="${LOG_DIR}/${BASENAME}.log"

	cat <<EOF > "${PAR_FILE}"
userid=${DB_CONNECT_STRING}
schemas=${SCHEMA}
dumpfile=${DUMP_FILE}
logfile=${BASENAME}.log
directory=DATA_PUMP_DIR
EOF

	print_cyan "\n[INFO] Running database backup ... please standby!\n"

	expdp parfile="${PAR_FILE}" | tee -a "${LOG_FILE}"

	if ! grep -q "successfully completed" "${LOG_FILE}"; then
		print_red "\n[ERROR] The ${SCHEMA} failed to backup.\n"
		database_logging "$OP_ID" "$OP_TYPE" "FAILED"

		SUBJECT="[ALERT] Backup failure for ${SCHEMA}"
		if [[ ! -s "${LOG_FILE}" ]]; then
			BODY="[ERROR] Backup of ${SCHEMA} failed and no log file was produced."
		else
			BODY=$(cat "${LOG_FILE}")
		fi
		email "${SUBJECT}" "${BODY}"
		return 1
	fi

	print_green "\n[SUCCESS] The ${SCHEMA} was backed up successfully\n"

	BACKUP_ARCHIVE="${LOG_DIR}/expdp_backup_${RUNNER}_${TS}.tar.gz"

	print_cyan "\n[INFO] Compressing dump and log files to ${BACKUP_ARCHIVE}...\n"

	# -z makes a real gzip archive, which later steps open with tar -xzf.
	# The dump and its log are archived by name.
	if tar -czf "${BACKUP_ARCHIVE}" -C "${LOG_DIR}" "${DUMP_FILE}" "${BASENAME}.log"; then
		print_green "\n[INFO] Backup archive created successfully: ${BACKUP_ARCHIVE}\n"
		# Remove the originals only after the archive is written, and only those.
		rm -f "${LOG_DIR}/${DUMP_FILE}" "${LOG_DIR}/${BASENAME}.log"
	else
		print_red "\n[ERROR] Failed to create archive. Dump files left in place.\n"
		database_logging "$OP_ID" "$OP_TYPE" "FAILED"
		return 1
	fi

	database_logging "$OP_ID" "$OP_TYPE" "COMPLETE"

	print_cyan "\n[INFO] Sending email notification ....\n"
	SUBJECT="[SUCCESS] ${SCHEMA} has been backed up successfully by ${RUNNER}"
	BODY=$(cat "${LOG_FILE}" 2>/dev/null || echo "Backup of ${SCHEMA} completed.")
	email "${SUBJECT}" "${BODY}"

	return 0
}

# ---------------------------------------------------------
# Check and Drop Schema If Exists
# ---------------------------------------------------------
# Takes the schema name as its argument.
drop_schema_if_exists() {
	local TARGET_SCHEMA="${1:?target schema required}"

	print_cyan "\n[INFO] Check if ${TARGET_SCHEMA} exists in Database...\n"

	sqlplus -s / as sysdba > "${SCRIPT_HOME}/schema_check.log" <<EOF
set heading off feedback off
SELECT COUNT(*) FROM dba_users WHERE username = UPPER('${TARGET_SCHEMA}');
EXIT;
EOF

	SCHEMA_EXISTS=$(tr -d '[:space:]' < "${SCRIPT_HOME}/schema_check.log")

	# sqlplus may print an error instead of a number; treat that as a failure.
	if ! [[ "${SCHEMA_EXISTS}" =~ ^[0-9]+$ ]]; then
		print_red "\n[ERROR] Could not determine whether ${TARGET_SCHEMA} exists. Aborting."
		return 1
	fi

	if [[ "${SCHEMA_EXISTS}" -gt 0 ]]; then
		print_cyan "\n[INFO] Dropping existing ${TARGET_SCHEMA} before importing..."

		sqlplus -s / as sysdba <<EOF
set echo off heading off feedback off;
WHENEVER SQLERROR EXIT FAILURE;
DROP USER ${TARGET_SCHEMA} CASCADE;
EXIT;
EOF

		if [[ $? -ne 0 ]]; then
			print_red "\n[ERROR] Failed to drop ${TARGET_SCHEMA}"
			return 1
		fi

		print_green "\n[SUCCESS] Schema: ${TARGET_SCHEMA} has been dropped successfully\n"
	else
		print_cyan "\n[INFO] Schema: ${TARGET_SCHEMA} does not exist, proceeding with import\n"
	fi

	return 0
}

# ---------------------------------------------------------
# Archive and Cleanup
# ---------------------------------------------------------
# NOTE: retained but currently unreferenced - database_backup now removes its
# own dump and log files after the archive is verified. Kept for manual use
# when a run is interrupted partway and leaves files behind.
cleanup() {
	local RUNNER="${1:?runner required}"

	print_cyan "\n[INFO] Removing dump and log files for ${RUNNER}\n"

	# Works on full paths rather than cd, so the caller's directory is unchanged.
	rm -f "${LOG_DIR}"/expdp_*_"${RUNNER}"_*.dmp "${LOG_DIR}"/expdp_*_"${RUNNER}"_*.log

	print_green "\n[SUCCESS] Removed all dmp and logs for ${RUNNER} from ${LOG_DIR}.\n"
}

# ---------------------------------------------------------
# Database Import (Local and Remote/Cloud)
# ---------------------------------------------------------
database_import() {
	local IMPORT_TYPE="${1:?import type required}"
	local RUNNER="${2:?runner required}"
	# SCHEMA is a parameter, not a global left over from the caller's loop.
	local SCHEMA="${3:-}"

	local TS
	TS=$(date "+%Y%m%d%H%M%S")
	local OP_ID
	OP_ID=$(new_op_id)
	local OP_TYPE="DATABASE_IMPORT"
	local DESTINATION="${REMOTE_IMPORT_DIR:-/backup/datapump/import}"

	print_cyan "\n[INFO] Starting Database Import for ${IMPORT_TYPE^^}...\n"

	if [[ ! -d "${LOG_DIR}" ]]; then
		print_red "\n[ERROR] LOG_DIR does not exist: ${LOG_DIR}\n"
		return 1
	fi

	local SOURCE
	SOURCE=$(ls -t "${LOG_DIR}"/expdp_backup_"${RUNNER}"_*.tar.gz 2>/dev/null | head -n 1)

	if [[ -z "${SOURCE}" ]]; then
		print_red "\n[ERROR] No backup archive found for ${RUNNER} in ${LOG_DIR}. Import aborted!\n"
		return 1
	fi

	if [[ "${IMPORT_TYPE^^}" == "CLOUD" ]]; then
		print_cyan "\n[INFO] Transferring tar file to Cloud Server...\n"
		secure_copy "${SOURCE}" "${DESTINATION}" || {
			print_red "[ERROR] File transfer failed! Exiting..."
			return 1
		}

		print_cyan "\n[INFO] Extracting tar file on Cloud Server...\n"

		local ARCHIVE_BASENAME
		ARCHIVE_BASENAME=$(basename "${SOURCE}")

		ssh -i "${PEM_FILE}" "${USER}"@"${HOST}" "
			cd ${DESTINATION} || exit 1
			tar -xzf ${ARCHIVE_BASENAME} || exit 1
		" || {
			print_red "[ERROR] Extraction failed on the Cloud Server!"
			return 1
		}

		database_logging "$OP_ID" "$OP_TYPE" "PROCESSING"

		print_cyan "\n[INFO] Running impdp for all extracted dump files on the Cloud Server...\n"

		# The remote block counts failed schemas and exits non-zero if any failed,
		# so the local side logs FAILED rather than COMPLETE.
		# shellcheck disable=SC2087  # unquoted on purpose: local values fill in, remote ones are escaped with \$
		ssh -i "${PEM_FILE}" "${USER}"@"${HOST}" bash <<EOF
			set -o pipefail
			DESTINATION="${DESTINATION}"
			RUNNER="${RUNNER}"
			TS="${TS}"
			cd \${DESTINATION} || exit 1

			ls expdp_*_\${RUNNER}_*.dmp > \${DESTINATION}/cloud_list.txt 2>/dev/null

			total_files=\$(wc -l < cloud_list.txt)
			echo "[INFO] Total dump files found: \$total_files"

			if [[ "\$total_files" -eq 0 ]]; then
				echo "[ERROR] No dump files extracted."
				exit 1
			fi

			failures=0

			while IFS= read -r DUMPFILE; do
				[[ -z "\$DUMPFILE" ]] && continue

				DUMPFILE_NAME=\$(basename "\$DUMPFILE")
				SCHEMA="\$(echo "\$DUMPFILE_NAME" | awk -F'_' '{print \$2"_"\$3"_"\$4}')"

				if [[ -z "\$SCHEMA" ]]; then
					echo "[ERROR] Failed to extract schema from: \$DUMPFILE_NAME. Skipping..."
					failures=\$((failures + 1))
					continue
				fi

				PARAM_FILE="impdp_\${SCHEMA}_\${RUNNER}_\${TS}.par"
				LOG_FILE="\${DESTINATION}/impdp_\${SCHEMA}_\${RUNNER}_\${TS}.log"

				echo "[INFO] Processing Schema: \${SCHEMA}"

				cat <<EOP > "\$PARAM_FILE"
USERID='/ as sysdba'
SCHEMAS=\${SCHEMA}
REMAP_SCHEMA=\${SCHEMA}:\${SCHEMA}_${RUNNER}_NEW
DUMPFILE=\${DUMPFILE_NAME}
LOGFILE=impdp_\${SCHEMA}_\${RUNNER}_\${TS}.log
DIRECTORY=DATA_PUMP_DIR
TABLE_EXISTS_ACTION=REPLACE
EOP

				export ORACLE_SID=${REMOTE_DB_NAME:-REMOTEDB}
				export ORAENV_ASK=NO
				. oraenv

				impdp parfile=\${PARAM_FILE}

				if grep -q "successfully completed" "\${LOG_FILE}" && ! grep -q "ORA-" "\${LOG_FILE}"; then
					echo "[SUCCESS] Schema: \${SCHEMA} imported successfully!"
				else
					echo "[ERROR] Schema: \${SCHEMA} failed to import!"
					failures=\$((failures + 1))
				fi
			done < cloud_list.txt

			rm -f \${DESTINATION}/cloud_list.txt

			if [[ \$failures -gt 0 ]]; then
				echo "[ERROR] \$failures schema(s) failed to import."
				exit 1
			fi

			echo "[SUCCESS] All schemas imported."
EOF

		# The remote exit status decides what gets logged.
		if [[ $? -ne 0 ]]; then
			print_red "\n[ERROR] One or more schemas failed to import on the Cloud Server.\n"
			database_logging "$OP_ID" "$OP_TYPE" "FAILED"
			return 1
		fi

		print_green "\n[SUCCESS] Database Import Completed for all schemas on Cloud Server!\n"
		database_logging "$OP_ID" "$OP_TYPE" "COMPLETE"
		return 0
	fi

	# ----- Local Import Execution -----
	if [[ -z "${SCHEMA}" ]]; then
		print_red "\n[ERROR] Local import requires a schema name.\n"
		return 1
	fi

	print_cyan "\n[INFO] Running impdp locally for schema: ${SCHEMA}"

	# database_backup removes the loose dump files once they're archived, so
	# extract before importing. The CLOUD branch does this on the remote side.
	print_cyan "\n[INFO] Extracting ${SOURCE} for local import...\n"
	tar -xzf "${SOURCE}" -C "${LOG_DIR}" || {
		print_red "\n[ERROR] Failed to extract ${SOURCE}\n"
		return 1
	}

	# shellcheck source=/dev/null  # per-database environment file, path set at run time
	source "${SCRIPTS}/oracle_env_${DB_NAME}.sh"

	drop_schema_if_exists "${SCHEMA}_${RUNNER}_NEW" || {
		print_red "\n[ERROR] Could not prepare target schema. Import aborted.\n"
		return 1
	}

	database_logging "$OP_ID" "$OP_TYPE" "PROCESSING"

	local DUMP_FILE
	DUMP_FILE=$(ls -t "${LOG_DIR}"/expdp_"${SCHEMA}"_"${RUNNER}"_*.dmp 2>/dev/null | head -n 1)

	if [[ -z "${DUMP_FILE}" ]]; then
		print_red "\n[ERROR] No dump file found matching: expdp_${SCHEMA}_${RUNNER}_*.dmp"
		database_logging "$OP_ID" "$OP_TYPE" "FAILED"
		return 1
	fi

	DUMP_FILE=$(basename "${DUMP_FILE}")

	local PARAM_FILE="impdp_${SCHEMA}_${RUNNER}_${TS}.par"
	local LOG_FILE="${LOG_DIR}/impdp_${SCHEMA}_${RUNNER}_${TS}.log"

	# Set once, as a full path, so impdp logs where the script looks afterwards.
	cat <<EOP > "${PARAM_FILE}"
USERID='${DB_CONNECT_STRING}'
SCHEMAS=${SCHEMA}
REMAP_SCHEMA=${SCHEMA}:${SCHEMA}_${RUNNER}_NEW
DUMPFILE=${DUMP_FILE}
LOGFILE=impdp_${SCHEMA}_${RUNNER}_${TS}.log
DIRECTORY=DATA_PUMP_DIR
TABLE_EXISTS_ACTION=REPLACE
EOP

	touch "${LOG_FILE}"
	impdp parfile="${PARAM_FILE}" | tee -a "${LOG_FILE}"

	if grep -q "successfully completed" "${LOG_FILE}" && ! grep -q "ORA-" "${LOG_FILE}"; then
		print_green "\n[SUCCESS] The ${SCHEMA} was imported successfully\n"
		database_logging "$OP_ID" "$OP_TYPE" "COMPLETE"

		SUBJECT="[SUCCESS] ${SCHEMA} imported successfully to ${IMPORT_TYPE}"
		BODY=$(cat "${LOG_FILE}")
		email "${SUBJECT}" "${BODY}"
		return 0
	fi

	print_red "\n[ERROR] The ${SCHEMA} failed to import locally.\n"
	SUBJECT="[ALERT] Import Failure for ${SCHEMA}"
	BODY="[ERROR] Import of ${SCHEMA} failed. Check logs at ${LOG_FILE}"
	email "${SUBJECT}" "${BODY}"

	database_logging "$OP_ID" "$OP_TYPE" "FAILED"
	return 1
}

# ---------------------------------------------------------
# Secure Copy (SCP to Remote Server)
# ---------------------------------------------------------
secure_copy() {
	local SOURCE="${1:?source required}"
	local DESTINATION="${2:?destination required}"

	print_cyan "\n[INFO] You are in the Secure Copy Function....."

	if [[ ! -e "${SOURCE}" ]]; then
		print_red "\n[ERROR] The ${SOURCE} is neither a file nor a directory. Backup Aborted!"
		return 1
	fi

	CLOUD_DIR="${DESTINATION}"

	if [[ ! -f "${PEM_FILE}" ]]; then
		print_red "\n[ERROR] PEM file not found!"
		return 1
	fi

	chmod 400 "${PEM_FILE}"

	print_cyan "\n[INFO] Testing connection to the cloud server..."

	if ssh -i "${PEM_FILE}" -o BatchMode=yes -o ConnectTimeout=10 "${USER}"@"${HOST}" "exit"; then
		print_green "\n[SUCCESS] Connection to the cloud server established successfully."
	else
		print_red "\n[ERROR] Unable to connect to the cloud server! Check credentials or server status."
		return 1
	fi

	print_cyan "\n[INFO] Checking if the directory exists on the cloud server..."

	# A failed remote mkdir fails the function, so scp never runs against a
	# missing directory.
	ssh -i "${PEM_FILE}" "${USER}"@"${HOST}" "mkdir -p '${CLOUD_DIR}'" || {
		print_red "\n[ERROR] Failed to create ${CLOUD_DIR} on the cloud server!"
		return 1
	}

	print_cyan "\n[INFO] Copying ${SOURCE} to ${CLOUD_DIR} on the cloud server..."
	if scp -i "${PEM_FILE}" -r "${SOURCE}" "${USER}@${HOST}:${CLOUD_DIR}"; then
		print_green "\n[SUCCESS] ${SOURCE} copied to ${CLOUD_DIR} successfully."
		return 0
	fi

	print_red "\n[ERROR] Failed to copy ${SOURCE} to the cloud server!"
	return 1
}

# ---------------------------------------------------------
# Database Migration (Backup + Import Pipeline)
# ---------------------------------------------------------
database_migration() {
	local IMPORT_TYPE="${1:?import type required}"
	local RUNNER="${2:?runner required}"
	local SCHEMA="${3:-}"

	print_cyan "\n[INFO] Starting database migration for ${IMPORT_TYPE^^}\n"

	if [[ "${IMPORT_TYPE^^}" != "LOCAL" && "${IMPORT_TYPE^^}" != "CLOUD" ]]; then
		print_red "\n[ERROR] Invalid import type: ${IMPORT_TYPE^^}. Allowed: LOCAL or CLOUD\n"
		return 1
	fi

	# Uses the call's own status, and passes SCHEMA through.
	if ! database_import "${IMPORT_TYPE^^}" "${RUNNER^^}" "${SCHEMA}"; then
		print_red "\n[ERROR] Database Migration failed for SCHEMA: ${SCHEMA}!"
		return 1
	fi

	print_cyan "\n[INFO] Database migration for ${SCHEMA} completed successfully"
	return 0
}

# =========================================================
# MAIN - Case Statement Router
# =========================================================
ACTION=$1

case ${ACTION^^} in
BACKUP)
	print_cyan "\nCalling the BACKUP function!!\n"
	if [[ $# -ne 4 ]]; then
		print_red "\nYou entered ${#} arguments, but 4 are required.\n"
		read -rp "Do you need help running the script? (Y/N) " HELP
		if [[ ${HELP^^} == "Y" ]]; then
			echo ""
			read -rp "Enter SOURCE(s) or DIRECTORY(ies) to backup (use quotes for multiple paths): " SOURCE
			read -rp "Enter your name: " RUNNER
			read -rp "Enter the DESTINATION for backup: " DESTINATION

			print_cyan "\nYou entered SOURCE: ${SOURCE}, RUNNER: ${RUNNER}, DESTINATION: ${DESTINATION}"
			if [[ -z "${SOURCE}" || -z "${RUNNER}" || -z "${DESTINATION}" ]]; then
				print_red "\nError! One or more values are missing!\n"
				exit 1
			fi
		else
			display_help_bk
			print_green "\n*** Goodbye! ***\n"
			exit 1
		fi
	else
		SOURCE=$2
		RUNNER=$3
		DESTINATION=$4
		print_green "\n[INFO] You entered the correct number of command line arguments\n"
	fi

	print_green "\n[INFO] Initiating backup.......\n"
	backup "${SOURCE}" "${RUNNER}" "${DESTINATION}" || exit 1
	;;

DATABASE_BACKUP)
	print_cyan "\n[INFO] Calling DATABASE BACKUP\n"

	if [[ $# -ne 4 ]]; then
		print_red "\n[ERROR] You entered ${#} arguments, but 4 are required.\n"

		read -rp "Do you need help running the script? (Y/N) " HELP
		if [[ ${HELP^^} == "Y" ]]; then
			print_green "[SUCCESS] Here to help!"

			IFS= read -rp "Enter SCHEMA(S), space separated: " SCHEMAS
			read -rp "Enter your NAME: " RUNNER
			read -rp "Enter Backup Location: " DESTINATION

			if [[ -z "${SCHEMAS}" || -z "${RUNNER}" || -z "${DESTINATION}" ]]; then
				print_red "\n[ERROR] One or more values are missing!\n"
				exit 1
			fi
		else
			display_help_db
			exit 1
		fi
	else
		SCHEMAS=$2
		RUNNER=$3
		DESTINATION=$4
	fi

	# Schema names come from the argument and are never sent to sqlplus as SQL.
	read -r -a SCHEMA_ARRAY <<< "${SCHEMAS}"

	failed=0
	for SCHEMA in "${SCHEMA_ARRAY[@]}"; do
		[[ -z "${SCHEMA}" ]] && continue
		database_backup "${SCHEMA^^}" "${RUNNER^^}" "${DESTINATION^^}" || failed=$((failed + 1))
	done

	if [[ ${failed} -gt 0 ]]; then
		print_red "\n[ERROR] ${failed} schema(s) failed to back up.\n"
		exit 1
	fi

	print_green "\n[SUCCESS] All schemas backed up.\n"
	;;

DATABASE_MIGRATION)
	print_cyan "[INFO] Welcome to DATABASE MIGRATION"

	if [[ $# -ne 5 ]]; then
		print_red "\nYou entered ${#} arguments, but 5 are required.\n"

		read -rp "Do you need help running the script? (Y/N): " HELP
		if [[ ${HELP^^} == "Y" ]]; then
			read -rp "Select import type (LOCAL or CLOUD) => " IMPORT_TYPE
			read -rp "What is your name: " RUNNER
			read -rp "What SCHEMA would you like to migrate: " SCHEMAS
			read -rp "Enter Backup Destination: " DESTINATION

			if [[ -z "${IMPORT_TYPE}" || -z "${RUNNER}" || -z "${SCHEMAS}" || -z "${DESTINATION}" ]]; then
				print_red "\n[ERROR] One or more values are missing!\n"
				exit 1
			fi
		else
			display_help_mg
			print_cyan "\n*** Goodbye! ***\n"
			exit 1
		fi
	else
		IMPORT_TYPE=$2
		RUNNER=$3
		SCHEMAS=$4
		DESTINATION=$5
	fi

	# Case-insensitive, so "cloud" and "CLOUD" both work.
	if [[ "${IMPORT_TYPE^^}" != "LOCAL" && "${IMPORT_TYPE^^}" != "CLOUD" ]]; then
		print_red "\n[ERROR] Invalid import type: ${IMPORT_TYPE}. Choose LOCAL or CLOUD."
		exit 1
	fi

	print_cyan "Import Type: ${IMPORT_TYPE^^}"
	print_cyan "Runner: ${RUNNER^^}"
	print_cyan "Schemas: ${SCHEMAS^^}"

	# Called directly, not via $0, so this run's variables stay available.
	read -r -a SCHEMA_ARRAY <<< "${SCHEMAS}"

	for SCHEMA in "${SCHEMA_ARRAY[@]}"; do
		[[ -z "${SCHEMA}" ]] && continue

		database_backup "${SCHEMA^^}" "${RUNNER^^}" "${DESTINATION^^}" || {
			print_red "\n[ERROR] Backup failed for ${SCHEMA}. Migration aborted."
			exit 1
		}

		database_migration "${IMPORT_TYPE^^}" "${RUNNER^^}" "${SCHEMA^^}" || {
			print_red "\n[ERROR] Migration failed for ${SCHEMA}."
			exit 1
		}
	done

	print_green "\n[SUCCESS] Migration complete.\n"
	;;

SECURE_COPY)
	print_cyan "\nCalling the Secure Copy Function!!"

	if [[ $# -ne 4 ]]; then
		print_red "\nYou entered ${#} arguments, but 4 are required.\n"

		read -rp "Do you need help running the script? (Y/N): " HELP
		if [[ ${HELP^^} == "Y" ]]; then
			echo ""
			read -rp "Enter SOURCE or DIRECTORY to secure copy: " SOURCE
			read -rp "Enter your name: " RUNNER
			read -rp "Enter the DESTINATION for Cloud Server: " DESTINATION

			if [[ -z "${SOURCE}" || -z "${RUNNER}" || -z "${DESTINATION}" ]]; then
				print_red "\n[ERROR] One or more values are missing!\n"
				exit 1
			fi
		else
			display_help_sc
			print_cyan "\n*** Goodbye! ***\n"
			exit 1
		fi
	else
		SOURCE=$2
		RUNNER=$3
		DESTINATION=$4
	fi

	print_cyan "\n[INFO] Initializing secure copy......"

	# secure_copy takes SOURCE and DESTINATION only.
	secure_copy "${SOURCE}" "${DESTINATION}" || exit 1
	;;

DISK_UTILIZATION)
	print_cyan "Calling the disk_utilization function!"

	if [[ $# -ne 2 ]]; then
		print_red "\nYou entered the wrong number of arguments!\n"

		read -rp "Do you need help running the script? (Y/N) " HELP
		if [[ ${HELP^^} == "Y" ]]; then
			echo ""
			print_green "\n---------------------------------------------------------------\n"
			print_green "\n[INFO]             DISK USAGE REPORT\n"
			echo ""
			df -h 2>/dev/null | awk 'BEGIN {
				width = 20;
				printf "%" width "s\n", "Mounted On";
				print "-----------------------------------------------------------------";
			}
			NR>1 && $NF ~ /^\// && $NF !~ /^\/dev/ {
				printf "%" width "s\n", $NF;
			}'

			print_green "\n-----------------------------------------------------------------\n"

			read -rp "Enter the MOUNT POINT e.g /backup, /u01: " MOUNT_POINT

			if [[ -z ${MOUNT_POINT} ]]; then
				print_red "\n[ERROR] Mount Point value is missing."
				exit 1
			fi
		else
			display_help_dk
			print_green "\n*** Goodbye! ***\n"
			exit 1
		fi
	else
		MOUNT_POINT=$2
	fi

	# The action's status becomes the script's exit status, for cron and monitoring.
	disk_utilization "${MOUNT_POINT}"
	exit $?
	;;

*)
	print_red "\n[ERROR] You made an invalid action: ${ACTION}."
	echo ""
	display_help_bk
	echo ""
	display_help_db
	echo ""
	display_help_sc
	echo ""
	display_help_dk
	echo ""
	display_help_mg
	echo ""
	print_green "\n***** Goodbye! *****\n"
	exit 1
	;;
esac
