#!/bin/bash
# =============================================================================
# Enterprise Operations Control Script
# Description: Modular Bash automation toolkit for enterprise system operations
#              including backup, database management, disk monitoring,
#              secure file transfer, and database migration.
# Author: Mayowa Babatola
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

# Colors for Output
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Helper Functions for Colored Outputs
print_green() { echo -e "${GREEN}$1${RESET}"; }
print_red() { echo -e "${RED}$1${RESET}"; }
print_cyan() { echo -e "${CYAN}$1${RESET}"; }

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
disk_utilization() {
	local MOUNT_POINT=$1

	print_cyan "\n[INFO] Performing Disk Check on ${MOUNT_POINT}\n"

	UTILIZATION=$(df -h 2>/dev/null | awk -v mount="$MOUNT_POINT" '$NF == mount {print $(NF-1)}' | sed 's/%//')

	if [[ -z "${UTILIZATION}" ]]; then
		print_red "\n[ERROR] Unable to retrieve disk utilization for ${MOUNT_POINT}. Check if the mount point exists."
		exit 1
	fi

	print_cyan "\n[STATUS] Current utilization for ${MOUNT_POINT} is ${UTILIZATION}%\n"

	if [[ ${UTILIZATION} -gt 82 ]]; then
		print_red "\n[WARNING] Disk usage on ${MOUNT_POINT} exceeded 80%! Current: ${UTILIZATION}%"
		SUBJECT="[WARNING] Disk usage on ${MOUNT_POINT} exceeded 80% threshold. Current usage: ${UTILIZATION}%"
		BODY="[WARNING]: Disk usage exceeded the 80% threshold on ${MOUNT_POINT}. Current usage: ${UTILIZATION}%."

		print_cyan "\n[ALERT] Sending email to the DevOps Engineers.\n"
		email "${SUBJECT}" "${BODY}"
		exit 1
	else
		print_green "\n[INFO] Disk space on ${MOUNT_POINT} is within safe limits.\n"
	fi
}

# ---------------------------------------------------------
# File/Directory Backup Function
# ---------------------------------------------------------
backup() {
	local MOUNT_POINT="/backup"
	local OP_ID=$RANDOM
	local OP_TYPE="BACKUP"

	print_cyan "\n[INFO] Starting backup process ....\n"

	# Check Disk Utilization Before Backup
	border="================================================================================================"
	echo "$border"
	echo -e "\n|| [INFO] -> Checking disk utilization for ${MOUNT_POINT} before starting the backup... ||\n"
	disk_utilization ${MOUNT_POINT}
	echo "$border"

	TS=$(date "+%m%d%Y%M%S")
	print_cyan "\n[INFO] Backing up SOURCE: ${SOURCE} TO DESTINATION: ${DESTINATION}\n"

	IFS=' ' read -r -a SOURCE_ARRAY <<< "${SOURCE}"

	database_logging "$OP_ID" "$OP_TYPE" "PROCESSING"

	for SOURCE in "${SOURCE_ARRAY[@]}"; do
		# Determine source type
		if [[ -f "${SOURCE}" ]]; then
			BACKUP_TYPE="file_backup"
			print_green "\n[INFO] ${SOURCE} is a file\n"
		elif [[ -d "${SOURCE}" ]]; then
			BACKUP_TYPE="directory_backup"
			print_green "\n[INFO] ${SOURCE} is a directory\n"
		else
			print_red "\n[ERROR] The source: ${SOURCE} is neither a file nor a directory. Backup aborted!\n"
			exit 1
		fi

		TS_SOURCE=$(basename "${SOURCE}")_${TS}

		# Create timestamped destination directory
		TIMESTAMPED_DESTINATION="${DESTINATION}/${BACKUP_TYPE}/${RUNNER^^}/${TS}"

		if [[ ! -d ${TIMESTAMPED_DESTINATION} ]]; then
			print_cyan "\n[INFO] Creating ${TIMESTAMPED_DESTINATION} directory...\n"
			mkdir -p "${TIMESTAMPED_DESTINATION}" || {
				print_red "\n[ERROR] Failed to create directory.\n"
				exit 1
			}
			print_green "\n[SUCCESS] ${TIMESTAMPED_DESTINATION} has been created!\n"
		fi

		# Copy source to timestamped destination
		print_cyan "\n[INFO] Copying ${SOURCE} to ${TIMESTAMPED_DESTINATION}\n"

		cp -r "${SOURCE}" "${TIMESTAMPED_DESTINATION}/${TS_SOURCE}" || {
			print_red "\n[ERROR] Failed to copy source\n"
			exit 1
		}
	done

	print_green "\n[SUCCESS] The source: ${SOURCE} has been backed up to => ${TIMESTAMPED_DESTINATION}.\n"

	print_cyan "\n **** CONTENTS OF ${TIMESTAMPED_DESTINATION} ****\n"
	ls -ltr "${TIMESTAMPED_DESTINATION}"

	# Check utilization after backup
	border="============================================================================="
	echo "$border"
	print_cyan "\n|| [INFO] -> Checking disk utilization after backup completion... ||\n"
	disk_utilization ${MOUNT_POINT}
	echo "$border"

	# Log completion in the database
	database_logging "$OP_ID" "$OP_TYPE" "COMPLETE"
}

# ---------------------------------------------------------
# Database Operation Logging (Oracle)
# ---------------------------------------------------------
database_logging() {
	local OP_ID="$1"
	local OP_TYPE="$2"
	local STATUS="$3"

	local TS=$(date "+%m-%d-%y %H:%M:%S")
	LOG_TS=$(date "+%m%d%y%H%S")

	local LOGDIR="${SCRIPT_HOME}/logs/${LOG_TS}"
	local LOG_FILE="${LOGDIR}/dblogin_${LOG_TS}.log"

	mkdir -p "${LOGDIR}"

	print_cyan "\n[INFO] Log file created at: ${LOG_FILE}\n"

	# Source database environment
	source "${SCRIPTS}/oracle_env_${DB_NAME}.sh"

	echo "[INFO] Logging Operation: OP_ID=${OP_ID}, OP_TYPE=${OP_TYPE}, STATUS=${STATUS}, TIMESTAMP=${TS}"

	if [[ "${STATUS}" == "PROCESSING" ]]; then
		sqlplus -s "/as sysdba" <<EOF

		set linesize 250
		select name from v\$database;

		INSERT INTO ${DB_SCHEMA_PREFIX}.operations VALUES (${OP_ID},'${OP_TYPE}','${TS}','-','PROCESSING');

		SELECT * FROM ${DB_SCHEMA_PREFIX}.operations ORDER BY START_TIME ASC;
EOF

	elif [[ "${STATUS}" == "COMPLETE" || "${STATUS}" == "FAILED" ]]; then
		local END_TS=$(date "+%Y-%m-%d %H:%M:%S")

		sleep 10

		echo "[INFO] Updating operation ID ${OP_ID} to STATUS=${STATUS} with END_TIME=${END_TS}"

		sqlplus -s "/as sysdba" <<EOF

		set linesize 250

		UPDATE ${DB_SCHEMA_PREFIX}.operations
		SET END_TIME='${END_TS}', STATUS='${STATUS}'
		WHERE OP_ID=${OP_ID};
		COMMIT;

		SELECT * FROM ${DB_SCHEMA_PREFIX}.operations ORDER BY END_TIME ASC;
EOF
	fi

	if (($? != 0)); then
		echo "[ERROR] Database logging failed!"
		exit
	fi

	print_cyan "\n[INFO] Database logging completed successfully."
}

# ---------------------------------------------------------
# Oracle Database Backup (Data Pump Export)
# ---------------------------------------------------------
database_backup() {
	local MOUNT_POINT="/backup"
	local OP_ID=$RANDOM
	local OP_TYPE="DATABASE_BACKUP"
	local LOG_FILE
	local TS=$(date "+%m%d%Y%M%S")

	print_cyan "\n[INFO] Backing up the following SCHEMA(S): ${SCHEMAS}\n"

	# Pre-backup disk check
	border="================================================================================================"
	echo "$border"
	print_cyan "\n|| [INFO] -> Checking disk utilization for ${MOUNT_POINT} before backup... ||\n"
	disk_utilization ${MOUNT_POINT}
	echo "$border"

	print_cyan "\n[INFO] Pointing to ${AVAIL} database\n"

	export ORACLE_SID=${DB_NAME}

	local AVAIL=$(ps -ef | grep pmon | grep "${DB_NAME}" | awk '{print $8}' | cut -d "_" -f 3)

	if [[ ${AVAIL} == "${DB_NAME}" ]]; then
		print_cyan "\n[INFO] Pointing to ${AVAIL} database\n"

		source "${SCRIPTS}/oracle_env_${DB_NAME}.sh"

		print_cyan "\n[INFO] The ${AVAIL} Database is up and running, checking for DB status."

		sqlplus -s "${DB_CONNECT_STRING}" >./check_db_status.log <<EOF
SELECT status FROM v\$instance;
EOF

		if (grep "OPEN" "${SCRIPT_HOME}/check_db_status.log"); then
			print_green "\n[INFO] Backing up SCHEMA: ${SCHEMA}\n"
			print_green "\n[SUCCESS] The ${AVAIL} database is OPEN.\n"

			export ORACLE_SID=${DB_NAME}
			source /usr/local/bin/oraenv <<<$ORACLE_SID

			print_cyan "\nCreating backup configuration file"

			database_logging "$OP_ID" "$OP_TYPE" "PROCESSING"

			if [[ -z "${SCHEMA}" ]]; then
				print_red "[ERROR] Schema is empty!"
				return
			fi

			# Create Data Pump export parameter file
			cat <<EOF >expdp_"${SCHEMA}"_"${RUNNER}"_"${TS}".par
userid=${DB_CONNECT_STRING}
schemas=${SCHEMA}
dumpfile=expdp_${SCHEMA}_${RUNNER}_${TS}.dmp
logfile=expdp_${SCHEMA}_${RUNNER}_${TS}.log
directory=DATA_PUMP_DIR
EOF

			print_cyan "\n[INFO] Running database backup ... please standby!\n"

			LOG_FILE="${LOG_DIR}/expdp_${SCHEMA}_${RUNNER}_${TS}.log"

			expdp parfile=expdp_"${SCHEMA}"_"${RUNNER}"_"${TS}".par | tee -a "${LOG_FILE}"
			wait

			if grep -q "successfully completed" "$LOG_FILE"; then
				print_green "\n[SUCCESS] The ${SCHEMA} was backed up successfully\n"

				database_logging "$OP_ID" "$OP_TYPE" "COMPLETE"

				print_cyan "\n[INFO] Sending email notification ....\n"

				SUBJECT="[SUCCESS] ${SCHEMA} has been backed up successfully by ${RUNNER}"
				BODY=$(cat "${LOG_FILE}")

				# Compress dump and log files
				BACKUP_ARCHIVE="${LOG_DIR}/expdp_backup_${RUNNER}_${TS}.tar.gz"

				print_cyan "\n[INFO] Compressing dump and log files to ${BACKUP_ARCHIVE}...\n"

				tar -cvf "${BACKUP_ARCHIVE}" -C "${LOG_DIR}" "${DUMPFILE_NAME}" && \
					find "${LOG_DIR}" -type f \( -name "*_${RUNNER}_*.dmp" -o -name "*_${RUNNER}_*.log" \) -exec rm -f {} \;

				print_green "\n[INFO] Backup archive created successfully: ${BACKUP_ARCHIVE}\n"
			else
				print_red "\n[ERROR] The ${SCHEMA} failed to backup.\n"

				database_logging "$OP_ID" "$OP_TYPE" "FAILED"

				sleep 5

				if [[ ! -s "${LOG_FILE}" ]]; then
					print_cyan "\n[ALERT] Sending email notification....."
					SUBJECT="[ALERT] Log File not found"
					BODY="[ERROR] Log file not found!"
				fi

				email "${SUBJECT}" "${BODY}"
				exit 1
			fi
		else
			print_red "\n[ERROR] The ${AVAIL} is shutdown!"
			database_logging "$OP_ID" "$OP_TYPE" "FAILED"
			exit 1
		fi
	else
		print_red "\n[ERROR] Database backup failed!\n"
		database_logging "$OP_ID" "$OP_TYPE" "FAILED"
		exit 1
	fi

	database_logging "$OP_ID" "$OP_TYPE" "COMPLETE"
}

# ---------------------------------------------------------
# Check and Drop Schema If Exists
# ---------------------------------------------------------
drop_schema_if_exists() {
	local SCHEMA_RUNNER_NEW=$1

	print_cyan "\n[INFO] Check if ${SCHEMA}_${RUNNER}_NEW exists in Database...\n"

	sqlplus -s / as sysdba <<EOF > "${SCRIPT_HOME}/schema_check.log"

set heading off feedback off
SELECT COUNT(*) from dba_users WHERE username = UPPER('${SCHEMA}_${RUNNER}_NEW');
EXIT;
EOF

	SCHEMA_EXISTS=$(cat "${SCRIPT_HOME}/schema_check.log" | tr -d '[:space:]')

	if [[ "${SCHEMA_EXISTS}" -gt 0 ]]; then
		print_cyan "\n[INFO] Dropping existing ${SCHEMA} before importing..."

		sqlplus -s / as sysdba <<EOF
set echo off heading off feedback off;
WHENEVER SQLERROR EXIT FAILURE;
DROP USER ${SCHEMA}_${RUNNER}_NEW CASCADE;
EXIT;
EOF

		if [[ $? -ne 0 ]]; then
			print_red "\n[ERROR] Failed to drop the ${SCHEMA}"
			exit 1
		else
			print_green "\n[SUCCESS] Schema: ${SCHEMA}_${RUNNER}_NEW has been dropped successfully\n"
		fi
	else
		print_cyan "\n[INFO] Schema: ${SCHEMA}_${RUNNER}_NEW does not exist, proceeding with import\n"
	fi
}

# ---------------------------------------------------------
# Archive and Cleanup
# ---------------------------------------------------------
cleanup() {
	local RUNNER=$1

	print_cyan "\n[INFO] Removing dump and log files for ${RUNNER}\n"

	cd "${LOG_DIR}" || { print_red "\n[ERROR] Failed to change directory to ${LOG_DIR}\n"; exit 1; }

	rm -f expdp_*_"${RUNNER}"_*.dmp expdp_*_"${RUNNER}"_*.log

	print_green "\n[SUCCESS] Removed all dmp and logs for ${RUNNER} from ${LOG_DIR}.\n"
}

# ---------------------------------------------------------
# Database Import (Local and Remote/Cloud)
# ---------------------------------------------------------
database_import() {
	local IMPORT_TYPE=$1
	local RUNNER=$2
	local TS=$(date "+%m%d%Y%H%M%S")
	local OP_ID=$RANDOM
	local OP_TYPE="DATABASE_IMPORT"
	local SOURCE="${LOG_DIR}/expdp_backup_${RUNNER}_${TS}.tar.gz"
	local DESTINATION="${REMOTE_IMPORT_DIR:-/backup/datapump/import}"

	print_cyan "\n[INFO] Starting Database Import for ${IMPORT_TYPE^^}...\n"

	# Ensure LOG_DIR exists
	if [[ ! -d "${LOG_DIR}" ]]; then
		print_red "\n[ERROR] LOG_DIR does not exist: ${LOG_DIR}\n"
		exit 1
	fi

	# Ensure dump files exist before archiving
	if ! find "${LOG_DIR}" -type f -name "*.dmp" | grep -q .; then
		print_red "\n[ERROR] No .dmp files found in ${LOG_DIR}. Import aborted!\n"
		exit 1
	fi

	print_cyan "\n[INFO] Creating a tar archive of dump files...\n"
	SOURCE=$(ls -t ${LOG_DIR}/expdp_*_${RUNNER}_*.tar.gz 2>/dev/null | head -n 1)

	# Cloud Import - Transfer and execute on remote server
	if [[ "${IMPORT_TYPE^^}" == "CLOUD" ]]; then
		print_cyan "\n[INFO] Transferring tar file to Cloud Server...\n"
		secure_copy "${SOURCE}" "${DESTINATION}" || {
			print_red "[ERROR] File transfer failed! Exiting..."
			exit 1
		}

		# Extract tar file on remote server
		print_cyan "\n[INFO] Extracting tar file on Cloud Server...\n"
		ssh -i "${PEM_FILE}" "${USER}"@"${HOST}" "
			cd ${DESTINATION} || exit 1
			tar -xzf $(basename ${SOURCE}) || exit 1
		" || {
			print_red "[ERROR] Extraction failed on the Cloud Server!"
			exit 1
		}

		database_logging "$OP_ID" "$OP_TYPE" "PROCESSING"

		# Loop through and import dump files on remote server
		print_cyan "\n[INFO] Running impdp for all extracted dump files on the Cloud Server...\n"

		ssh -i "${PEM_FILE}" "${USER}"@"${HOST}" bash <<EOF
			DESTINATION="${DESTINATION}"
			RUNNER="${RUNNER}"
			TS="${TS}"
			cd ${DESTINATION} || exit 1

			> ${DESTINATION}/cloud_list.txt
			ls expdp_*_${RUNNER}_*.dmp > ${DESTINATION}/cloud_list.txt

			total_files=\$(wc -l < cloud_list.txt)
			echo "[DEBUG] Total dump files found: \$total_files"

			line_num=0

			echo "[INFO] Running impdp on extracted files..."
			while IFS= read -r DUMPFILE; do
				((line_num++))
				[[ -z "\$DUMPFILE" ]] && continue

				DUMPFILE_NAME=\$(basename "\$DUMPFILE")
				SCHEMA="\$(echo "\$DUMPFILE_NAME" | awk -F'_' '{print \$2"_"\$3"_"\$4}')"

				if [[ -z "\$SCHEMA" ]]; then
					echo "[ERROR] Failed to extract schema from: \$DUMPFILE_NAME. Skipping..."
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

				sleep 5

				if grep -q "successfully completed" "\${LOG_FILE}" && ! grep -q "ORA-" "\${LOG_FILE}"; then
					echo "[SUCCESS] Schema: \${SCHEMA} imported successfully!"
				else
					echo "[ERROR] Schema: \${SCHEMA} failed to import!"
				fi
			done < cloud_list.txt

			echo "[INFO] Cleaning up log and dump files on CLOUD SERVER"
			rm -f ${DESTINATION}/cloud_list.txt
			echo "[SUCCESS] Cleanup complete!"
EOF

		print_green "\n[SUCCESS] Database Import Completed for all schemas on Cloud Server!\n"
		database_logging "$OP_ID" "$OP_TYPE" "COMPLETE"

	else
		# Local Import Execution
		print_cyan "\n[INFO] Running impdp locally for schema: ${SCHEMA}"

		source "${SCRIPTS}/oracle_env_${DB_NAME}.sh"

		# Drop schema before import
		drop_schema_if_exists "${SCHEMA}_${RUNNER}_NEW"

		database_logging "$OP_ID" "$OP_TYPE" "PROCESSING"

		DUMP_FILE=$(ls -t ${LOG_DIR}/expdp_${SCHEMA}_${RUNNER}_*.dmp 2>/dev/null | head -n 1)

		if [[ -z "${DUMP_FILE}" ]]; then
			echo "[ERROR] No dump file found matching pattern: expdp_${SCHEMA}_${RUNNER}_*.dmp"
			exit 1
		fi

		DUMP_FILE=$(basename "${DUMP_FILE}")
		PARAM_FILE="impdp_${SCHEMA}_${RUNNER}_${TS}.par"
		LOG_FILE="impdp_${SCHEMA}_${RUNNER}_${TS}.log"

		cat <<EOP > "${PARAM_FILE}"
USERID='${DB_CONNECT_STRING}'
SCHEMAS="${SCHEMA}"
REMAP_SCHEMA="${SCHEMA}:${SCHEMA}_${RUNNER}_NEW"
DUMPFILE="${DUMP_FILE}"
LOGFILE="${LOG_FILE}"
DIRECTORY=DATA_PUMP_DIR
TABLE_EXISTS_ACTION=REPLACE
EOP

		source "${SCRIPTS}/oracle_env_${DB_NAME}.sh"

		LOG_FILE="${LOG_DIR}/impdp_${SCHEMA}_${RUNNER}_${TS}.log"
		touch "${LOG_FILE}"

		impdp parfile="${PARAM_FILE}" | tee -a "${LOG_FILE}"

		if grep -q "successfully completed" "${LOG_FILE}" && ! grep -q "ORA-" "${LOG_FILE}"; then
			print_green "\n[SUCCESS] The ${SCHEMA} was imported successfully\n"
			database_logging "$OP_ID" "$OP_TYPE" "COMPLETE"

			print_cyan "\n[INFO] Sending email notification..."
			SUBJECT="[SUCCESS] ${SCHEMA} imported successfully to ${IMPORT_TYPE}"
			BODY=$(cat "${LOG_FILE}")
			email "${SUBJECT}" "${BODY}"
		else
			print_red "\n[ERROR] The ${SCHEMA} failed to import locally.\n"

			SUBJECT="[ALERT] Import Failure for ${SCHEMA}"
			BODY="[ERROR] Import of ${SCHEMA} failed. Check logs at ${LOG_FILE}"
			email "${SUBJECT}" "${BODY}"

			database_logging "$OP_ID" "$OP_TYPE" "FAILED"
			exit 1
		fi
	fi

	print_green "\n[SUCCESS] Database Import Completed!\n"
}

# ---------------------------------------------------------
# Secure Copy (SCP to Remote Server)
# ---------------------------------------------------------
secure_copy() {
	TS=$(date "+%m%d%Y%M%S")
	local SOURCE=$1
	local DESTINATION=$2

	print_cyan "\n[INFO] You are in the Secure Copy Function....."

	if [[ -f "${SOURCE}" ]]; then
		BACKUP_TYPE="file_backup"
		print_cyan "\n${SOURCE} is a file!"
	elif [[ -d "${SOURCE}" ]]; then
		BACKUP_TYPE="directory_backup"
	else
		print_red "\n[ERROR] The ${SOURCE} is neither a file or a directory. Backup Aborted!"
		exit 1
	fi

	CLOUD_DIR="${DESTINATION}"

	# Validate PEM key
	if [[ ! -f "${PEM_FILE}" ]]; then
		print_red "\n[ERROR] PEM file not found!"
		exit 1
	fi

	chmod 400 "${PEM_FILE}"

	# Test server connection
	print_cyan "\n[INFO] Testing connection to the cloud server..."

	if ssh -i "${PEM_FILE}" -o BatchMode=yes -o ConnectTimeout=10 "${USER}"@"${HOST}" "exit"; then
		print_green "\n[SUCCESS] Connection to the cloud server established successfully."
	else
		print_red "\n[ERROR] Unable to connect to the cloud server! Check credentials or server status."
		exit 1
	fi

	# Check and create remote directory
	print_cyan "\n[INFO] Checking if the directory exists on the cloud server..."
	ssh -i "$PEM_FILE" "$USER"@"$HOST" bash <<EOF
	if [[ -d ${CLOUD_DIR} ]]; then
		echo -e "\n[INFO] Directory ${CLOUD_DIR} already exists on the cloud server."
	else
		echo -e "\n[INFO] Directory ${CLOUD_DIR} does not exist. Creating now..."
		mkdir -p "${CLOUD_DIR}" && echo -e "\n[SUCCESS] Directory created." || echo -e "\n[ERROR] Failed to create directory!"
	fi
EOF

	# Transfer files
	print_cyan "\n[INFO] Copying ${SOURCE} to ${CLOUD_DIR} on the cloud server..."
	if scp -i "${PEM_FILE}" -r "${SOURCE}" "${USER}@${HOST}:${CLOUD_DIR}"; then
		print_green "\n[SUCCESS] ${SOURCE} copied to ${CLOUD_DIR} successfully."
	else
		print_red "\n[ERROR] Failed to copy ${SOURCE} to the cloud server!"
		exit 1
	fi
}

# ---------------------------------------------------------
# Database Migration (Backup + Import Pipeline)
# ---------------------------------------------------------
database_migration() {
	local IMPORT_TYPE=$1
	local RUNNER=$2
	local TS=$(date "+%m%d%Y%M%S")
	local OP_ID=$RANDOM
	local OP_TYPE="DATABASE_MIGRATION"

	print_cyan "\n[INFO] Starting database migration for ${IMPORT_TYPE^^}\n"

	if [[ "${IMPORT_TYPE^^}" != "LOCAL" && "${IMPORT_TYPE^^}" != "CLOUD" ]]; then
		print_red "\n[ERROR] Invalid import type: ${IMPORT_TYPE^^}. Allowed: LOCAL or CLOUD\n"
		exit 1
	fi

	database_import "${IMPORT_TYPE^^}" "${RUNNER^^}"

	if [[ $? -ne 0 ]]; then
		print_red "\n[ERROR] Database Migration failed for SCHEMA: ${SCHEMAS^^}!"
		exit 1
	fi

	print_cyan "\n[INFO] Database migration for ${SCHEMAS^^} completed successfully"
}

# ---------------------------------------------------------
# AWS Function (Placeholder)
# ---------------------------------------------------------
aws_function() {
	print_cyan "\n[INFO] Calling the AWS function!\n"
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
		read -p "Do you need help running the script? (Y/N) " HELP
		if [[ ${HELP^^} == "Y" ]]; then
			echo ""
			read -p "Enter SOURCE(s) or DIRECTORY(ies) to backup (use quotes for multiple paths): " SOURCE
			read -p "Enter your name: " RUNNER
			read -p "Enter the DESTINATION for backup: " DESTINATION

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
	backup "${SOURCE}" "${RUNNER}" "${DESTINATION}"
	;;

DATABASE_BACKUP)
	print_cyan "\n[INFO] Calling DATABASE BACKUP\n"

	if [[ $# -ne 4 ]]; then
		print_red "\n[ERROR] You entered ${#} arguments, but 4 are required.\n"

		read -p "Do you need help running the script? (Y/N) " HELP
		if [[ ${HELP^^} == "Y" ]]; then
			print_green "[SUCCESS] Here to help!"

			IFS= read -r -p "Enter SCHEMA(S): " SCHEMAS
			read -p "Enter your NAME: " RUNNER
			read -p "Enter Backup Location: " DESTINATION

			print_cyan "\n[INFO] You entered SCHEMA: ${SCHEMAS^^}, RUNNER: ${RUNNER^^}, DESTINATION: ${DESTINATION}"

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
		print_cyan "\n[INFO] You entered the correct number of arguments\n"
	fi

	source "${SCRIPTS}/oracle_env_${DB_NAME}.sh"

	sqlplus -s "${DB_CONNECT_STRING}" <<EOF
set pagesize 0 heading off term off feedback off
SPOOL ${SCRIPT_HOME}/schemas.txt
${SCHEMAS}
SPOOL OFF
EXIT;
EOF

	# Loop through schemas
	while read -r SCHEMA; do
		[[ -z "${SCHEMA}" ]] && continue
		database_backup "${SCHEMA}" "${RUNNER^^}" "${DESTINATION^^}"
	done < "${SCRIPT_HOME}/schemas.txt"

	cd "${LOG_DIR}" || exit
	tar -czf "${BACKUP_ARCHIVE}" expdp_*_"${RUNNER}"_*.log expdp_*_"${RUNNER}"_*.dmp --remove-files || {
		print_red "\n[ERROR] Failed to create tar archive"
	}

	print_green "\n[INFO] Backup archive created successfully: ${BACKUP_ARCHIVE}\n"
	;;

DATABASE_MIGRATION)
	print_cyan "[INFO] Welcome to DATABASE MIGRATION"

	if [[ $# -ne 5 ]]; then
		print_red "\nYou entered ${#} arguments, but 5 are required.\n"

		read -p "Do you need help running the script? (Y/N): " HELP
		if [[ ${HELP^^} == "Y" ]]; then
			read -p "Select import type (LOCAL or CLOUD) => " IMPORT_TYPE
			read -p "What is your name: " RUNNER
			read -p "What SCHEMA would you like to backup: " SCHEMAS
			read -p "Enter Backup Destination: " DESTINATION

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
		print_cyan "\n[INFO] You have entered the correct number of arguments.\n"
	fi

	# Validate import type
	if [[ "${IMPORT_TYPE}" != "LOCAL" && "${IMPORT_TYPE}" != "CLOUD" ]]; then
		print_red "\n[ERROR] Invalid import type: ${IMPORT_TYPE^^}. Choose LOCAL or CLOUD."
		exit 1
	fi

	print_cyan "Import Type: ${IMPORT_TYPE^^}"
	print_cyan "Runner: ${RUNNER^^}"
	print_cyan "Schemas: ${SCHEMAS^^}"

	# Run database backup first
	$0 database_backup "${SCHEMAS^^}" "${RUNNER^^}" "${DESTINATION^^}"

	if [[ $? -ne 0 ]]; then
		print_red "\n[ERROR] Database failed to backup!"
		exit 1
	fi

	# Extract latest backup
	BACKUP_FILE=$(ls -t "${LOG_DIR}/expdp_backup_${RUNNER^^}"_*.tar.gz 2>/dev/null | head -n 1)

	if [[ -z "${BACKUP_FILE}" ]]; then
		print_red "\n[ERROR] No backup file for ${RUNNER^^}. Exiting..."
		exit 1
	fi

	print_cyan "\n[INFO] Extracting latest backup file: ${BACKUP_FILE}"

	tar -xzvf "${BACKUP_FILE}" -C "${LOG_DIR}" || {
		echo "[ERROR] Failed to extract dump files from ${BACKUP_FILE}"
		exit 1
	}

	# Create dump list
	print_cyan "\n[INFO] Creating fresh dump_list.txt"

	> "${SCRIPT_HOME}/dump_list.txt"
	find "${LOG_DIR}" -type f -name "*_${RUNNER}_*.dmp" > "${SCRIPT_HOME}/dump_list.txt"

	if [[ ! -s "${SCRIPT_HOME}/dump_list.txt" ]]; then
		print_red "\n[ERROR] No dump files found for migration. Exiting..."
		exit 1
	fi

	# Process each dump file
	while IFS= read -r DUMPFILE || [[ -n "$DUMPFILE" ]]; do
		DUMPFILE_NAME=$(basename "${DUMPFILE}")
		SCHEMA=$(echo "${DUMPFILE}" | awk -F'_' '{print $2"_"$3"_"$4}')

		if [[ -z "${SCHEMA}" ]]; then
			print_red "\n[ERROR] Schema extraction failed for DUMPFILE=${DUMPFILE_NAME}. Skipping"
			continue
		fi

		database_migration "${IMPORT_TYPE^^}" "${RUNNER^^}" "${SCHEMA^^}" "${DUMPFILE_NAME}"
	done < "${SCRIPT_HOME}/dump_list.txt"
	;;

SECURE_COPY)
	print_cyan "\nCalling the Secure Copy Function!!"

	if [[ $# -ne 4 ]]; then
		print_red "\nYou entered ${#} arguments, but 4 are required.\n"

		read -p "Do you need help running the script? (Y/N): " HELP
		if [[ ${HELP^^} == "Y" ]]; then
			echo ""
			read -p "Enter SOURCE or DIRECTORY to secure copy: " SOURCE
			read -p "Enter your name: " RUNNER
			read -p "Enter the DESTINATION for Cloud Server: " DESTINATION

			if [[ -z "${SOURCE}" || -z "${RUNNER}" || -z "${DESTINATION}" ]]; then
				print_red "\n[ERROR] One or more values are missing!\n"
				exit 1
			fi

			print_green "\n[INFO] Initializing secure copy..."
		else
			display_help_sc
			print_cyan "\n*** Goodbye! ***\n"
			exit 1
		fi
	else
		SOURCE=$2
		RUNNER=$3
		DESTINATION=$4
		print_cyan "\n[INFO] You have entered the correct number of arguments.\n"
		print_cyan "\n[INFO] Initializing secure copy......"

		secure_copy "${SOURCE}" "${RUNNER}" "${DESTINATION}"
	fi
	;;

DISK_UTILIZATION)
	echo "Calling the disk_utilization function!"

	if [[ $# -ne 2 ]]; then
		print_red "\nYou entered the wrong number of arguments!\n"

		read -p "Do you need help running the script? (Y/N) " HELP
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

			read -p "Enter the MOUNT POINT e.g /backup, /u01: " MOUNT_POINT

			if [[ -z ${MOUNT_POINT} ]]; then
				print_red "\n[ERROR] Mount Point value is missing."
				exit 1
			fi

			print_cyan "\n[INFO] Initiating Disk Utilization Check......"
		else
			display_help_dk
			print_green "\n*** Goodbye! ***\n"
			exit 1
		fi
	else
		MOUNT_POINT=$2
		print_cyan "\n[INFO] You have entered the correct number of arguments.\n"
		print_cyan "\n[INFO] Initializing disk utilization......"
	fi

	disk_utilization "${MOUNT_POINT}"
	;;

AWS)
	print_cyan "Calling the AWS function!"
	aws_function
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
