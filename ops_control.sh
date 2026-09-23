#!/bin/bash
# =============================================================================
# Enterprise Operations Control Script
# Description: Modular Bash automation toolkit for enterprise system operations
#              including backup, database management, disk monitoring,
#              secure file transfer, and database migration.
# Author: Mayowa Babatola
#
# NOTE ON `set -e`: deliberately NOT enabled. This script relies on commands
# failing and being handled inline (the grep conditionals in particular), so
# `set -e` would abort runs that are working as designed. `set -u` is likewise
# left off because several variables are intentionally optional. Correctness
# here comes from explicit checks, not from shell options.
# =============================================================================

# ---------------------------------------------------------
# Configuration - Set these via environment variables or .env
# ---------------------------------------------------------
SCRIPTS="${SCRIPTS_DIR:-/opt/scripts}"
DB_NAME="${DB_NAME:-MYDB}"
AVAIL=$(ps -ef | grep pmon | grep "${DB_NAME}" | awk '{print $8}' | cut -d "_" -f 3)
TS=$(date "+%m%d%Y%M%S")
SCRIPT_HOME="${SCRIPT_HOME:-/opt/scripts/bin}"
HOST="${REMOTE_HOST}"
USER="${REMOTE_USER:-oracle}"
PEM_FILE="${PEM_FILE_PATH}"
MAIL="${ALERT_EMAIL}"
LOG_DIR="${LOG_DIR:-/backup/datapump/${DB_NAME}}"
DB_SCHEMA_PREFIX="${DB_SCHEMA_PREFIX:-OPS}"

# CHANGED: disk threshold is now one configurable value instead of a literal
# buried in a comparison. The old code compared against 82 while every message
# said 80%, so alerts described a threshold the script did not actually use.
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

# CHANGED: new helper. $RANDOM is 0-32767, so operation IDs collided often
# enough to corrupt the audit trail - a rerun could overwrite an earlier run's
# row. Epoch seconds plus PID is unique for any realistic run rate.
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
# CHANGED: this function no longer calls `exit`. It is invoked from inside
# backup() and database_backup(), so an exit here killed the entire script
# mid-operation - leaving the audit row stuck in PROCESSING forever, because
# the COMPLETE/FAILED update never ran. It now returns a status and each
# caller decides what to do, which is how a check should behave.
disk_utilization() {
	local MOUNT_POINT=$1

	print_cyan "\n[INFO] Performing Disk Check on ${MOUNT_POINT}\n"

	UTILIZATION=$(df -h 2>/dev/null | awk -v mount="$MOUNT_POINT" '$NF == mount {print $(NF-1)}' | sed 's/%//')

	if [[ -z "${UTILIZATION}" ]]; then
		print_red "\n[ERROR] Unable to retrieve disk utilization for ${MOUNT_POINT}. Check if the mount point exists."
		return 2
	fi

	print_cyan "\n[STATUS] Current utilization for ${MOUNT_POINT} is ${UTILIZATION}%\n"

	# CHANGED: threshold and message now reference the same value, so the alert
	# text can never drift from the condition that produced it.
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
# CHANGED: reads its own arguments. It was called as
# `backup "$SOURCE" "$RUNNER" "$DESTINATION"` but ignored all three and used
# globals instead - it worked only because the globals happened to hold the
# same values. That is a coincidence, not a contract.
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

	# CHANGED: the caller now handles a failed disk check explicitly.
	disk_utilization "${MOUNT_POINT}" || {
		print_red "\n[ERROR] Disk check failed for ${MOUNT_POINT}. Backup aborted.\n"
		return 1
	}
	echo "$border"

	TS=$(date "+%m%d%Y%M%S")
	print_cyan "\n[INFO] Backing up SOURCE: ${SOURCE} TO DESTINATION: ${DESTINATION}\n"

	IFS=' ' read -r -a SOURCE_ARRAY <<< "${SOURCE}"

	database_logging "$OP_ID" "$OP_TYPE" "PROCESSING"

	# CHANGED: loop variable renamed from SOURCE to ITEM. The old loop reassigned
	# SOURCE on every pass, so the success message afterwards reported only the
	# last path processed, not what was actually requested.
	for ITEM in "${SOURCE_ARRAY[@]}"; do
		if [[ -f "${ITEM}" ]]; then
			BACKUP_TYPE="file_backup"
			print_green "\n[INFO] ${ITEM} is a file\n"
		elif [[ -d "${ITEM}" ]]; then
			BACKUP_TYPE="directory_backup"
			print_green "\n[INFO] ${ITEM} is a directory\n"
		else
			print_red "\n[ERROR] The source: ${ITEM} is neither a file nor a directory. Backup aborted!\n"
			# CHANGED: mark the operation FAILED before leaving. The old code
			# exited here with the row still reading PROCESSING.
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
	TS=$(date "+%m-%d-%y %H:%M:%S")
	LOG_TS=$(date "+%m%d%y%H%S")

	local LOGDIR="${SCRIPT_HOME}/logs/${LOG_TS}"
	local LOG_FILE="${LOGDIR}/dblogin_${LOG_TS}.log"

	mkdir -p "${LOGDIR}"

	print_cyan "\n[INFO] Log file created at: ${LOG_FILE}\n"

	source "${SCRIPTS}/oracle_env_${DB_NAME}.sh"

	echo "[INFO] Logging Operation: OP_ID=${OP_ID}, OP_TYPE=${OP_TYPE}, STATUS=${STATUS}, TIMESTAMP=${TS}"

	# CHANGED: capture sqlplus's exit status directly. The old code ran a
	# `print_cyan` between the heredoc and its `if (($? != 0))` check, so $?
	# reported the echo's status, not sqlplus's - the check never fired.
	local rc=0

	if [[ "${STATUS}" == "PROCESSING" ]]; then
		# CHANGED: named columns instead of positional VALUES. An unqualified
		# INSERT breaks silently the moment a column is added to the table.
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

		# CHANGED: removed `sleep 10`. It delayed every status update by ten
		# seconds with no stated reason and no condition being waited on.

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

	# CHANGED: a logging failure warns but does not kill the caller. The old
	# bare `exit` aborted an in-flight backup because the audit write failed,
	# which is the wrong trade - losing the data matters more than losing the row.
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
# CHANGED: reads its own arguments. It was called with three and used none.
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
	TS=$(date "+%m%d%Y%M%S")

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
	source "${SCRIPTS}/oracle_env_${DB_NAME}.sh"

	print_cyan "\n[INFO] The ${AVAIL} Database is up and running, checking for DB status."

	# CHANGED: status file is written to and read from the same path. The old
	# code wrote to ./check_db_status.log (current directory, whatever that
	# happened to be) and grepped ${SCRIPT_HOME}/check_db_status.log - so the
	# check either read a stale file or found nothing.
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

	# CHANGED: filenames computed once and reused. The old code rebuilt the
	# same expdp_SCHEMA_RUNNER_TS string in five places, which is how the tar
	# ended up referencing a variable that was never set.
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

	# CHANGED: dropped the bare `wait`. expdp runs in the foreground here, so
	# there was no background job to wait on.
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

	# CHANGED, two bugs in one line:
	#   1. `tar -cvf` produced an UNCOMPRESSED archive named .tar.gz. Every
	#      downstream `tar -xzf` on it would fail. Now -czf.
	#   2. It archived "${DUMPFILE_NAME}", a variable never assigned anywhere
	#      in this function - so the tar contained nothing, and the `find ... rm`
	#      chained after it then deleted the real dump files. That combination
	#      destroyed the backup it had just taken.
	if tar -czf "${BACKUP_ARCHIVE}" -C "${LOG_DIR}" "${DUMP_FILE}" "${BASENAME}.log"; then
		print_green "\n[INFO] Backup archive created successfully: ${BACKUP_ARCHIVE}\n"
		# CHANGED: originals are removed only after the archive is confirmed
		# written, and only the files that were archived.
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
# CHANGED: takes the schema name as a real argument instead of rebuilding it
# from globals. The old version accepted $1, never used it, and referenced
# ${SCHEMA}_${RUNNER}_NEW from the enclosing scope.
drop_schema_if_exists() {
	local TARGET_SCHEMA="${1:?target schema required}"

	print_cyan "\n[INFO] Check if ${TARGET_SCHEMA} exists in Database...\n"

	# CHANGED: redirection moved before the heredoc. `<<EOF > file` is valid but
	# reads as though the heredoc is being redirected; `> file <<EOF` is the
	# conventional order and less likely to be misread during maintenance.
	sqlplus -s / as sysdba > "${SCRIPT_HOME}/schema_check.log" <<EOF
set heading off feedback off
SELECT COUNT(*) FROM dba_users WHERE username = UPPER('${TARGET_SCHEMA}');
EXIT;
EOF

	# CHANGED: dropped a useless-use-of-cat.
	SCHEMA_EXISTS=$(tr -d '[:space:]' < "${SCRIPT_HOME}/schema_check.log")

	# CHANGED: guard against a non-numeric result. If sqlplus errored, the old
	# `-gt` comparison against arbitrary text produced a shell error and the
	# function carried on as though the schema did not exist.
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

		# CHANGED: $? is now checked immediately after sqlplus rather than after
		# an intervening command.
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

	# CHANGED: operates on paths instead of cd'ing. A `cd` inside a function
	# changes the working directory for everything that follows it in the same
	# shell, which had already caused the check_db_status.log path mismatch.
	rm -f "${LOG_DIR}"/expdp_*_"${RUNNER}"_*.dmp "${LOG_DIR}"/expdp_*_"${RUNNER}"_*.log

	print_green "\n[SUCCESS] Removed all dmp and logs for ${RUNNER} from ${LOG_DIR}.\n"
}

# ---------------------------------------------------------
# Database Import (Local and Remote/Cloud)
# ---------------------------------------------------------
database_import() {
	local IMPORT_TYPE="${1:?import type required}"
	local RUNNER="${2:?runner required}"
	# CHANGED: SCHEMA is now a parameter. The local-import branch referenced a
	# global SCHEMA that the caller happened to set, so the function's behaviour
	# depended on whatever the last loop iteration left behind.
	local SCHEMA="${3:-}"

	local TS
	TS=$(date "+%m%d%Y%H%M%S")
	local OP_ID
	OP_ID=$(new_op_id)
	local OP_TYPE="DATABASE_IMPORT"
	local DESTINATION="${REMOTE_IMPORT_DIR:-/backup/datapump/import}"

	print_cyan "\n[INFO] Starting Database Import for ${IMPORT_TYPE^^}...\n"

	if [[ ! -d "${LOG_DIR}" ]]; then
		print_red "\n[ERROR] LOG_DIR does not exist: ${LOG_DIR}\n"
		return 1
	fi

	# CHANGED: removed a dead assignment. SOURCE was built from a timestamp
	# generated moments earlier - which could never match a file on disk - and
	# then immediately overwritten by the `ls -t` below.
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

		# CHANGED: the remote block now tracks failures and exits non-zero if any
		# schema fails. Previously it printed "[ERROR] failed to import" per
		# schema and still returned success, so the local side logged COMPLETE
		# for an import that had partially or entirely failed.
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

		# CHANGED: the remote exit status now determines what gets logged.
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

	# CHANGED: extract the archive before importing. database_backup now removes
	# the loose .dmp and .log files once the tar is verified, so the dump this
	# import needs only exists inside ${SOURCE} until it is unpacked. The CLOUD
	# branch above already extracts on the remote side; the local branch did not.
	print_cyan "\n[INFO] Extracting ${SOURCE} for local import...\n"
	tar -xzf "${SOURCE}" -C "${LOG_DIR}" || {
		print_red "\n[ERROR] Failed to extract ${SOURCE}\n"
		return 1
	}

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

	# CHANGED: LOG_FILE is set once. The old code assigned a bare filename, used
	# it in the parameter file, then reassigned it to a full path afterwards -
	# so impdp wrote its log somewhere other than where the script later looked.
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

	# CHANGED: the remote mkdir now fails the function if it fails. The old
	# `mkdir ... && echo SUCCESS || echo ERROR` printed an error and returned
	# zero, so the scp that followed ran against a directory that did not exist.
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

	# CHANGED: capture the return status directly instead of testing $? after
	# the call. Also passes SCHEMA through rather than relying on a global.
	if ! database_import "${IMPORT_TYPE^^}" "${RUNNER^^}" "${SCHEMA}"; then
		print_red "\n[ERROR] Database Migration failed for SCHEMA: ${SCHEMA}!"
		return 1
	fi

	print_cyan "\n[INFO] Database migration for ${SCHEMA} completed successfully"
	return 0
}

# CHANGED: removed aws_function() and its AWS) case branch entirely. It printed
# a string and did nothing else - an unfinished placeholder in a toolkit that
# otherwise does real work.

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

	# CHANGED: schemas are read from the argument directly. The old code piped
	# ${SCHEMAS} into sqlplus as a SQL statement and spooled the result - meaning
	# whatever the user typed at the prompt was executed as SQL against the
	# database as sysdba. That is arbitrary SQL execution from an interactive
	# prompt, and it is the most serious problem in the original file.
	read -r -a SCHEMA_ARRAY <<< "${SCHEMAS}"

	failed=0
	for SCHEMA in "${SCHEMA_ARRAY[@]}"; do
		[[ -z "${SCHEMA}" ]] && continue
		database_backup "${SCHEMA^^}" "${RUNNER^^}" "${DESTINATION^^}" || failed=$((failed + 1))
	done

	# CHANGED: removed the trailing `cd "${LOG_DIR}"` and second tar. It
	# referenced ${BACKUP_ARCHIVE}, a variable set inside database_backup's
	# scope, and re-archived files that function had already archived and
	# deleted - so it either failed or produced an empty archive.

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

	# CHANGED: comparison is now case-insensitive. The old check tested the raw
	# input against uppercase literals, so a user entering "cloud" was rejected
	# while the error message displayed it uppercased - confusing and wrong.
	if [[ "${IMPORT_TYPE^^}" != "LOCAL" && "${IMPORT_TYPE^^}" != "CLOUD" ]]; then
		print_red "\n[ERROR] Invalid import type: ${IMPORT_TYPE}. Choose LOCAL or CLOUD."
		exit 1
	fi

	print_cyan "Import Type: ${IMPORT_TYPE^^}"
	print_cyan "Runner: ${RUNNER^^}"
	print_cyan "Schemas: ${SCHEMAS^^}"

	# CHANGED: calls the function directly instead of re-invoking the script via
	# `$0 database_backup ...`. Spawning a subprocess meant the parent could not
	# see any of the child's variables and had to guess at filenames afterwards.
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

	# CHANGED, two problems here:
	#   1. secure_copy takes (SOURCE, DESTINATION), but was called with
	#      (SOURCE, RUNNER, DESTINATION) - so RUNNER was used as the remote
	#      path and files landed in a directory named after the operator.
	#   2. The call sat INSIDE the else branch, so the interactive path
	#      collected all three values and then did nothing with them.
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

	# CHANGED: the function's return status now becomes the script's exit status,
	# so this action is usable from cron or a monitoring wrapper that checks it.
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
