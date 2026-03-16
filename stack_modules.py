#!/bin/python
# =============================================================================
# Enterprise Operations Modules
# Description: Python module library for enterprise system operations including
#              backup, Oracle database management (Data Pump), disk monitoring,
#              compression/decompression, patching, and email notifications.
# Author: Mayowa Babatola
# =============================================================================

# Importing Modules
import sys
import time
import os
import shutil
import gzip
import tarfile
import glob
import datetime
import subprocess
import smtplib
import random
import cx_Oracle as c
import re
import logging
from email.mime.text import MIMEText
from tabulate import tabulate

# ---------------------------------------------------------
# Configuration - Loaded from environment variables
# ---------------------------------------------------------
DB_USER = os.environ.get("DB_USER", "")
DB_PASS = os.environ.get("DB_PASS", "")
DB_DSN = os.environ.get("DB_DSN", "localhost:1521/MYDB")
TO_EMAIL = os.environ.get("ALERT_EMAIL", "admin@example.com")
SMTP_FROM = os.environ.get("SMTP_FROM", "oracle@localhost")
BASE_DIR = os.environ.get("DATAPUMP_DIR", "/backup/datapump")
PAR_FILE_PATH = os.environ.get("PAR_FILE_PATH", os.getcwd())
SSH_SERVER_IP = os.environ.get("SSH_SERVER_IP", "")
SSH_USERNAME = os.environ.get("SSH_USERNAME", "")
SSH_KEY_PATH = os.environ.get("SSH_KEY_PATH", "")

# Get the present working directory
CURRENT_DIR = os.getcwd()

# Define log directory and log file path
LOG_DIR = os.path.join(CURRENT_DIR, "logs")
STACK_LOG = os.path.join(LOG_DIR, "stack_logs.log")

# Ensure the log directory exists
os.makedirs(LOG_DIR, exist_ok=True)


# =============================================================================
# DATABASE OPERATION LOGGING
# =============================================================================
def log_operation(**kwargs):
	"""Log operation lifecycle (PROCESSING/COMPLETE/FAILED) to Oracle database."""
	OP_ID = kwargs.get("OP_ID")
	OP_TYPE = kwargs.get("OP_TYPE")
	STATUS = kwargs.get("STATUS")
	LOGGER_NAME = kwargs.get("LOGGER_NAME", "PYTHON")

	try:
		# Establish database connection
		connection = c.connect(
			user=DB_USER,
			password=DB_PASS,
			dsn=DB_DSN
		)
		cursor = connection.cursor()

		TS = datetime.datetime.now()
		DB_TS = TS.strftime("%Y-%m-%d %H:%M:%S")

		if STATUS == "PROCESSING":
			# Generate OP_ID for new processing record
			OP_ID = random.randint(10000, 99999)

			# Insert new record into the operations table
			cursor.execute("""
				INSERT INTO operations (OP_ID, OP_TYPE, START_TIME, END_TIME, STATUS, LOGGER)
				VALUES (:op_id, :op_type, :start_time, '-', :status, :logger)
			""", op_id=OP_ID, op_type=OP_TYPE, start_time=DB_TS, status=STATUS, logger=LOGGER_NAME)
			connection.commit()

		elif STATUS in ["COMPLETE", "FAILED"]:
			# Ensure OP_ID is provided when updating status
			if OP_ID is None:
				raise ValueError("OP_ID is required to update operation status")
			# Update existing record for COMPLETE/FAILED status
			cursor.execute("""
				UPDATE operations
				SET END_TIME= :end_time, STATUS=:status
				WHERE OP_ID= :op_id
			""", end_time=DB_TS, status=STATUS, op_id=OP_ID)
			connection.commit()

		# Show last 5 operations (newest first)
		cursor.execute("SELECT * FROM (SELECT * FROM operations ORDER BY START_TIME DESC) WHERE ROWNUM <= 5 ")

		rows = cursor.fetchall()

		headers = ["OP_ID", "OP_TYPE", "START_TIME", "END_TIME", "STATUS", "LOGGER"]
		table = tabulate(rows, headers=headers, tablefmt="grid")
		print(table)

		cursor.close()
		connection.close()

		# Return OP_ID if the operation was newly created
		if STATUS == "PROCESSING":
			return OP_ID

	except Exception as e:
		print("[ERROR] log_operation failed: ", e)
		return None


# =============================================================================
# LOGGING SETUP
# =============================================================================

# Define custom success level
SUCCESS = 25
logging.addLevelName(SUCCESS, "SUCCESS")


def success(self, message, *args, **kws):
	if self.isEnabledFor(SUCCESS):
		self._log(SUCCESS, message, args, **kws)


logging.Logger.success = success

logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s', filename=STACK_LOG)
script_logger = logging.getLogger("script_logger")


def get_log_filename(**kwargs):
	"""Generate a unique log file name based on the command name and timestamp."""
	command_name = kwargs.get("command_name")
	timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
	return os.path.join(LOG_DIR, "{}_{}.log".format(command_name, timestamp))


def setup_logger(**kwargs):
	"""Set up a logger for each critical command execution."""
	try:
		command_name = kwargs.get("command_name")

		if not command_name:
			raise ValueError("command_name not provided to setup_logger()")

		log_file = get_log_filename(command_name=command_name)

		# Create a logger instance
		logger = logging.getLogger(command_name)
		logger.setLevel(logging.DEBUG)

		# Ensure log file is created
		file_handler = logging.FileHandler(log_file)
		file_handler.setLevel(logging.DEBUG)
		file_handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s - %(message)s"))

		# Add console logging
		console_handler = logging.StreamHandler()
		console_handler.setLevel(logging.DEBUG)
		console_handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s - %(message)s"))

		# Add handlers to logger
		logger.addHandler(file_handler)
		logger.addHandler(console_handler)

		return logger, log_file

	except Exception as e:
		print("[ERROR] Failed to set up logger: {}\n".format(e))


def logging_func(**kwargs):
	"""Write logs dynamically to log file."""
	try:
		logger = kwargs.get("logger")

		if not logger:
			raise ValueError("Logger not initialized.")

		log_str = kwargs.get("log_str")
		lt = kwargs.get("lt")
		TS = time.strftime("%d-%m-%y %H:%M:%S", time.localtime())

		if lt == "INFO":
			logger.info("{} - {}".format(TS, log_str))
		elif lt == "DEBUG":
			logger.debug("{} - {}".format(TS, log_str))
		elif lt == "CRITICAL":
			logger.critical("{} - {}".format(TS, log_str))
		elif lt == "WARNING":
			logger.warning("{} - {}".format(TS, log_str))
		elif lt == "ERROR":
			logger.error("{} - {}".format(TS, log_str))
		elif lt == "SUCCESS":
			logger.success("{} - {}".format(TS, log_str))
		else:
			logger.warning("{} - Invalid log type: {} - {}\n".format(TS, lt, log_str))

	except Exception as e:
		if logger:
			logger.error("[ERROR] Logging failed: {}\n".format(str(e)))
		else:
			print("[ERROR] logging failed before logger was initialized: {}\n".format(str(e)))


# =============================================================================
# EMAIL NOTIFICATIONS
# =============================================================================
def stack_emails(**kwargs):
	"""Send email notifications via SMTP."""
	try:
		logger = kwargs.get("logger")
		TO_EMAIL = kwargs.get("TO_EMAIL")
		SUBJECT = kwargs.get("SUBJECT")
		BODY = kwargs.get("BODY")

		TIME_RUN = time.localtime()
		TS = time.strftime("%m%d%y%H%S", TIME_RUN)
		logging_func(logger=logger, log_str="Stack emails module runtime is: {}\n".format(TS), lt="INFO")

		FROM = SMTP_FROM
		MSG = "From: {}\nTo: {}\nSubject: {}\n\n{}".format(FROM, TO_EMAIL, SUBJECT, BODY)

		with smtplib.SMTP('localhost') as my_email:
			my_email.sendmail(FROM, TO_EMAIL, MSG)
			logging_func(logger=logger, log_str="Email sent successfully to {}\n".format(TO_EMAIL), lt="INFO")

	except smtplib.SMTPException as e:
		logger.error("Failed to send email due to SMTP issue: {}\n".format(str(e)))
	except Exception as e:
		logger.error("Unexpected error while sending email: {}\n".format(str(e)))


# =============================================================================
# FILE / DIRECTORY BACKUP
# =============================================================================
def backup(**kwargs):
	"""Copy files or directories from source to destination with operation logging."""
	try:
		logger = kwargs.get("logger")
		SOURCE = kwargs.get("SOURCE")
		DESTINATION = kwargs.get("DESTINATION")
		OP_TYPE = kwargs.get("OP_TYPE", "BACKUP")

		# Start DB logging and capture generated id
		OP_ID = log_operation(OP_TYPE=OP_TYPE, STATUS="PROCESSING")

		if os.path.isfile(SOURCE):
			shutil.copy2(SOURCE, DESTINATION)
			logging_func(logger=logger, log_str="The file: {} has been moved to destination: {} successfully\n".format(SOURCE, DESTINATION), lt="SUCCESS")
		elif os.path.isdir(SOURCE):
			shutil.copytree(SOURCE, DESTINATION)
			logging_func(logger=logger, log_str="The directory: {} has been moved to destination: {} successfully\n".format(SOURCE, DESTINATION), lt="SUCCESS")
		else:
			logging_func(logger=logger, log_str="You entered the wrong number of arguments or chose the wrong source", lt="ERROR")
			log_operation(OP_ID=OP_ID, OP_TYPE=OP_TYPE, STATUS="FAILED")
			return

		log_operation(OP_ID=OP_ID, OP_TYPE=OP_TYPE, STATUS="COMPLETE")
	except FileNotFoundError as e:
		logger.error("File not found {}\n".format(str(e)))
		log_operation(OP_ID=OP_ID, OP_TYPE=OP_TYPE, STATUS="FAILED")
	except PermissionError:
		logger.error("Permission denied while accessing source or destination.\n")
		log_operation(OP_ID=OP_ID, OP_TYPE=OP_TYPE, STATUS="FAILED")
	except Exception as e:
		logger.error("Backup operation failed: {}\n".format(str(e)))
		log_operation(OP_ID=OP_ID, OP_TYPE=OP_TYPE, STATUS="FAILED")


# =============================================================================
# ORACLE DATABASE BACKUP (DATA PUMP EXPORT)
# =============================================================================
def database_backup(**kwargs):
	"""Run Oracle Data Pump export for one or more schemas."""
	try:
		logger = kwargs.get("logger")
		RUNNER = kwargs.get("RUNNER")
		SCHEMAS = kwargs.get("SCHEMAS")
		DB_NAME = kwargs.get("DB_NAME")
		OP_TYPE = kwargs.get("OP_TYPE", "DATABASE BACKUP")

		logging_func(logger=logger, log_str="Backing up the database, please standby......\n", lt="INFO")

		OP_ID = log_operation(OP_TYPE=OP_TYPE, STATUS="PROCESSING")

		if isinstance(SCHEMAS, str):
			SCHEMAS = [SCHEMAS]
		elif isinstance(SCHEMAS, list):
			SCHEMAS = [schema.strip() for schema in SCHEMAS]

		TS = datetime.datetime.now().strftime("%m%d%H%M%S")

		# Loop through each schema
		for SCHEMA in SCHEMAS:
			logging_func(logger=logger, log_str="Processing backup for SCHEMA: {}\n".format(SCHEMA), lt="INFO")

			PAR_FILE = "{}/parfile_{}.par".format(PAR_FILE_PATH, SCHEMA)

			with open(PAR_FILE, "w+") as parfile:
				parfile.write("USERID=' / as sysdba'\n")
				parfile.write("SCHEMAS={}\n".format(SCHEMA))
				parfile.write("DUMPFILE=expdp_{}_dump_{}_{}.dmp\n".format(SCHEMA, RUNNER, TS))
				parfile.write("LOGFILE=expdp_{}_dump_{}_{}.log\n".format(SCHEMA, RUNNER, TS))
				parfile.write("DIRECTORY=DATA_PUMP_DIR\n")

			# Set ORACLE_SID environment variable
			os.environ['ORACLE_SID'] = DB_NAME

			expdp_command = "expdp parfile={}".format(PAR_FILE)

			logging_func(logger=logger, log_str="Running command: {}\n".format(expdp_command), lt="INFO")
			subprocess.run(expdp_command, shell=True, check=True)

			# Define dump and log path
			dump_file = "{}/expdp_{}_dump_{}_{}.dmp".format(BASE_DIR, SCHEMA, RUNNER, TS)
			dblog = "{}/expdp_{}_dump_{}_{}.log".format(BASE_DIR, SCHEMA, RUNNER, TS)

			# Wait for log file to be created
			timeout = 20
			elapsed_time = 0

			while not os.path.exists(dblog) and elapsed_time < timeout:
				logging_func(logger=logger, log_str="Waiting for log file to be created: {}\n".format(dblog), lt="INFO")
				time.sleep(3)
				elapsed_time += 3

			if os.path.exists(dblog):
				with open(dblog, "r") as dblogfile:
					log_contents = dblogfile.read()
				logging_func(logger=logger, log_str="Log file found and read successfully!\n", lt="SUCCESS")
			else:
				logging_func(logger=logger, log_str="Log file not found after {} seconds: {}\n".format(timeout, dblog), lt="ERROR")
				log_contents = "[ERROR] Log file not found!"

			# Compress dump and log files
			logging_func(logger=logger, log_str="Compressing dump and log files...\n", lt="INFO")
			archive_file = G_Zipp(logger=logger, FILES=[dump_file, dblog], RUNNER=RUNNER, DESTINATION=BASE_DIR)

			if archive_file:
				logging_func(logger=logger, log_str="Archive created successfully: {}\n".format(archive_file), lt="SUCCESS")

				# Remove original dump and log files after compression
				os.remove(dump_file)
				os.remove(dblog)
				logging_func(logger=logger, log_str="Removed original dump and log files: {}, {}\n".format(dump_file, dblog), lt="INFO")
			else:
				logging_func(logger=logger, log_str="Compression failed! Dump and log files not archived.\n", lt="ERROR")

			# Send email notification
			SUBJECT = "[SUCCESS] Database backup was successful for SCHEMA: {} - [{}]".format(SCHEMA, RUNNER)
			BODY = "\nThe database was backed up successfully.\nPlease check your logs."
			BODY += "\nLog Contents:\n\n{}\n".format(log_contents)

			logging_func(logger=logger, log_str="Sending backup notification to admin\n", lt="INFO")
			stack_emails(logger=logger, TO_EMAIL=TO_EMAIL, SUBJECT=SUBJECT, BODY=BODY)
			logging_func(logger=logger, log_str="Notification sent successfully!\n", lt="SUCCESS")

		# Log success after all schemas processed
		log_operation(OP_ID=OP_ID, OP_TYPE=OP_TYPE, STATUS="COMPLETE")
		return True

	except ValueError as e:
		logger.error(str(e))
		log_operation(OP_ID=OP_ID, OP_TYPE=OP_TYPE, STATUS="FAILED")
	except Exception as e:
		logger.error("Database backup encountered an issue: {}\n".format(str(e)))
		log_operation(OP_ID=OP_ID, OP_TYPE=OP_TYPE, STATUS="FAILED")


# =============================================================================
# DISK MONITORING
# =============================================================================
def Disk_Maintenance_Check_On_Prem(**kwargs):
	"""Check disk utilization against threshold and send alerts if exceeded."""
	try:
		logger = kwargs.get("logger")
		if not logger:
			print("[ERROR] logger not initialized")
			return

		DISK = kwargs.get("DISK")
		THRESHOLD = kwargs.get("THRESHOLD")
		OP_TYPE = kwargs.get("OP_TYPE", "DISK CHECK")

		logging_func(logger=logger, log_str="Checking disk utilization for {}.\n".format(DISK), lt="INFO")

		OP_ID = log_operation(OP_TYPE="DISK CHECK", STATUS="PROCESSING")

		# Get disk usage using df command
		usage_output = os.popen("df -h | grep ' {}' | awk '{{print $(NF-1)}}'".format(DISK)).read().strip()

		if not usage_output:
			logging_func(logger=logger, log_str="Could not retrieve disk usage for {}. Ensure it exists".format(DISK), lt="INFO")
			return

		# Extract the percentage from output
		usage_percentage = int(usage_output.replace("%", ""))

		logging_func(logger=logger, log_str="Current Disk Usage on {}: {}% (Threshold: {}%)\n".format(DISK, usage_percentage, THRESHOLD), lt="INFO")

		# Check if usage exceeds threshold
		if usage_percentage > int(THRESHOLD):
			logging_func(logger=logger, log_str="Disk utilization exceeded! {} is at {}%, above the threshold of {}%\n".format(DISK, usage_percentage, THRESHOLD), lt="WARNING")

			SUBJECT = "[ALERT] Disk Usage on: {} is above threshold: {}%".format(DISK, THRESHOLD)
			BODY = "\n[WARNING] Disk utilization exceeded on DISK: {} is at {}%, above the threshold of {}%\n".format(DISK, usage_percentage, THRESHOLD)

			stack_emails(logger=logger, TO_EMAIL=TO_EMAIL, SUBJECT=SUBJECT, BODY=BODY)
		else:
			logging_func(logger=logger, log_str="Disk utilization for {} is within limits ({}% used).\n".format(DISK, usage_percentage), lt="INFO")

		log_operation(OP_ID=OP_ID, OP_TYPE=OP_TYPE, STATUS="COMPLETE")

	except OSError as e:
		print(str(e))
		log_operation(OP_ID=OP_ID, OP_TYPE=OP_TYPE, STATUS="FAILED")
	except ValueError:
		logger.error("Invalid disk usage data format.\n")
		log_operation(OP_ID=OP_ID, OP_TYPE=OP_TYPE, STATUS="FAILED")
	except Exception as e:
		logger.error("Disk check failed: {}\n".format(str(e)))
		log_operation(OP_ID=OP_ID, OP_TYPE=OP_TYPE, STATUS="FAILED")


# =============================================================================
# COMPRESSION / DECOMPRESSION
# =============================================================================
def G_Zipp(**kwargs):
	"""Compress files into .tar.gz (multiple) or .gz (single)."""
	try:
		logger = kwargs.get("logger")
		FILES = kwargs.get("FILES")
		RUNNER = kwargs.get("RUNNER")
		DESTINATION = kwargs.get("DESTINATION")

		if not isinstance(FILES, list):
			FILES = [FILES]

		# Validate that all files exist
		for file in FILES:
			if not os.path.exists(file):
				raise FileNotFoundError("[ERROR] The file '{}' does not exist.".format(file))

		TS = datetime.datetime.now().strftime("%m%d%H%M%S")

		# Case 1: Multiple files or directory → .tar.gz
		if len(FILES) > 1 or os.path.isdir(FILES[0]):
			archive_name = os.path.join(DESTINATION, "archive_{}_{}.tar.gz".format(RUNNER, TS))
			logging_func(logger=logger, log_str="Creating archive: {}\n".format(archive_name), lt="INFO")

			with tarfile.open(archive_name, "w:gz") as tar:
				for file in FILES:
					tar.add(file, arcname=os.path.basename(file))
					logging_func(logger=logger, log_str="Added {} to archive.\n".format(file), lt="INFO")

			logging_func(logger=logger, log_str="Archive created successfully: {}\n".format(archive_name), lt="INFO")
			return archive_name

		# Case 2: Single file → .gz
		else:
			file_path = FILES[0]
			gzipped_file = os.path.join(DESTINATION, "file_{}_{}.gz".format(os.path.basename(file_path), TS))

			with open(file_path, 'rb') as f_in, gzip.open(gzipped_file, 'wb') as f_out:
				shutil.copyfileobj(f_in, f_out)

			logging_func(logger=logger, log_str="File '{}' has been gzipped successfully to '{}'\n".format(file_path, gzipped_file), lt="INFO")
			return gzipped_file

	except Exception as e:
		logging.error("Compression failed: {}\n".format(str(e)))


def G_Unzipp(**kwargs):
	"""Extract .tar.gz or .gz compressed files."""
	try:
		logger = kwargs.get("logger")
		FILE_PATH = kwargs.get("FILE_PATH")
		RUNNER = kwargs.get("RUNNER")
		DESTINATION = kwargs.get("DESTINATION")

		if not os.path.exists(FILE_PATH):
			raise FileNotFoundError("\n[ERROR] The file '{}' does not exist.\n".format(FILE_PATH))

		if DESTINATION is None:
			DESTINATION = os.path.dirname(FILE_PATH)

		if FILE_PATH.endswith(".tar.gz"):
			logging_func(logger=logger, log_str="Extracting archive '{}' to '{}'\n".format(FILE_PATH, DESTINATION), lt="INFO")

			with tarfile.open(FILE_PATH, "r:gz") as tar:
				tar.extractall(path=DESTINATION)

			logging_func(logger=logger, log_str="Archive '{}' extracted successfully to '{}'\n".format(FILE_PATH, DESTINATION), lt="SUCCESS")
			return DESTINATION

		elif FILE_PATH.endswith(".gz"):
			extracted_file = os.path.join(DESTINATION, os.path.basename(FILE_PATH).replace(".gz", ""))
			logging_func(logger=logger, log_str="Decompressing file '{}' to '{}'\n".format(FILE_PATH, extracted_file), lt="INFO")
			return extracted_file

		else:
			raise ValueError("\n[ERROR] Unsupported file type: '{}'. Must be a .gz or .tar.gz file.\n".format(FILE_PATH))

	except Exception as e:
		logger.error("Extraction failed: {}\n".format(str(e)))


# =============================================================================
# ORACLE DATABASE IMPORT (DATA PUMP IMPORT)
# =============================================================================
def database_import(**kwargs):
	"""Run Oracle Data Pump import with schema remapping and validation."""
	try:
		logger = kwargs.get("logger")
		DUMPFILE = kwargs.get("DUMPFILE")
		RUNNER = kwargs.get("RUNNER")
		DB_NAME = kwargs.get("DB_NAME")
		DIRECTORY = kwargs.get("DIRECTORY")

		logging_func(logger=logger, log_str="Searching for latest dump files for {}.\n".format(RUNNER), lt="INFO")

		archives = [DUMPFILE]

		if not archives:
			raise FileNotFoundError("[ERROR] No dump archive found for '{}'.\n".format(RUNNER))

		latest_archive = archives[0]
		logging_func(logger=logger, log_str="Found latest archive: '{}'\n".format(latest_archive), lt="INFO")

		# Unzip the latest dump file
		extracted_dir = G_Unzipp(logger=logger, FILE_PATH=latest_archive, RUNNER=RUNNER, DESTINATION=os.path.dirname(latest_archive))

		if not extracted_dir:
			raise FileNotFoundError("[ERROR] Failed to unzip archive '{}'.".format(latest_archive))

		logging_func(logger=logger, log_str="Archive extracted: '{}'\n".format(extracted_dir), lt="SUCCESS")

		# Find all dump files in extracted directory
		dump_files = sorted(glob.glob(os.path.join(extracted_dir, "*.dmp")))

		if not dump_files:
			raise FileNotFoundError("[ERROR] No valid dump files found in '{}'.\n".format(extracted_dir))

		# Filter dump files belonging to the RUNNER
		runner_dump_files = [dump for dump in dump_files if RUNNER.upper() in os.path.basename(dump)]

		if runner_dump_files:
			logging_func(logger=logger, log_str="Found dump files for '{}':\n".format(RUNNER), lt="SUCCESS")
			for dump in runner_dump_files:
				print(dump)
		else:
			logging_func(logger=logger, log_str="No dump files found for the runner '{}'.\n".format(RUNNER), lt="ERROR")

		logging_func(logger=logger, log_str="Found {} dump files for {}: \n{}\n".format(len(runner_dump_files), RUNNER, runner_dump_files), lt="SUCCESS")

		# Loop through dump files and run import
		for dump_file in runner_dump_files:
			dump_filename = os.path.basename(dump_file)

			if RUNNER.upper() not in dump_filename:
				continue

			# Extract schema name using RegEx
			match = re.search(r"expdp_(.*?)_dump_", dump_filename)

			if match:
				SCHEMA = match.group(1)
				logging_func(logger=logger, log_str="Extracted Schema Name: {}\n".format(SCHEMA), lt="SUCCESS")
			else:
				logging_func(logger=logger, log_str="Could not extract schema name from dump file: '{}'\n".format(dump_filename), lt="ERROR")
				continue

			# Generate import parameter file
			TS = datetime.datetime.now().strftime("%m%d%H%M%S")

			LOGFILE = "impdp_{}_{}_{}.log".format(SCHEMA, RUNNER, TS)
			LOGFILE_PATH = os.path.join(BASE_DIR, LOGFILE)

			log_contents = "[INFO] Log file has not been generated yet."

			PARFILE = "{}/impdp_{}_{}_{}.par".format(PAR_FILE_PATH, SCHEMA, RUNNER, TS)
			SCHEMA_RUNNER_NEW = "{}_{}_NEW".format(SCHEMA, RUNNER)
			DIRECTORY = "DATA_PUMP_DIR"

			with open(PARFILE, "w") as parfile:
				parfile.write("USERID='/ as sysdba'\n")
				parfile.write("DUMPFILE={}\n".format(dump_filename))
				parfile.write("LOGFILE=impdp_{}_{}_{}.log\n".format(SCHEMA, RUNNER, TS))
				parfile.write("SCHEMAS={}\n".format(SCHEMA))
				parfile.write("DIRECTORY={}\n".format(DIRECTORY))
				parfile.write("REMAP_SCHEMA={}:{}\n".format(SCHEMA, SCHEMA_RUNNER_NEW))
				parfile.write("TABLE_EXISTS_ACTION=REPLACE\n")

			logging_func(logger=logger, log_str="Import parfile created: {}\n".format(PARFILE), lt="INFO")

			# Run Oracle Data Pump import
			os.environ['ORACLE_SID'] = DB_NAME
			impdp_command = "impdp parfile={}".format(PARFILE)

			logging_func(logger=logger, log_str="Running command: {}\n".format(impdp_command), lt="INFO")
			result = subprocess.run(impdp_command, shell=True, check=True)

			# Wait for log file to be created
			timeout = 60
			elapsed_time = 0

			while not os.path.exists(LOGFILE_PATH) and elapsed_time < timeout:
				logging_func(logger=logger, log_str="Waiting for log file to be created: {}\n".format(LOGFILE_PATH), lt="INFO")
				time.sleep(5)
				elapsed_time += 5

				if os.path.exists(LOGFILE_PATH):
					with open(LOGFILE_PATH, "r") as log_file:
						log_contents = log_file.read()
					logging_func(logger=logger, log_str="Log file found and read successfully!\n", lt="INFO")
				else:
					logging_func(logger=logger, log_str="Log file not found after {} seconds: {}\n".format(timeout, LOGFILE_PATH), lt="ERROR")

			if result.returncode == 0:
				logging_func(logger=logger, log_str="Database import completed successfully for schema: {}\n".format(SCHEMA), lt="INFO")

				SUBJECT = "[SUCCESS] Database import completed for SCHEMA: {} - [{}]".format(SCHEMA, RUNNER)
				BODY = "\nDatabase import was successful.\n\nLog file is attached."
				BODY += "\n======= LOG FILE CONTENTS =======\n" + log_contents + "\n=================================\n"

				logging_func(logger=logger, log_str="Sending success notification to admin...\n", lt="INFO")
				stack_emails(logger=logger, TO_EMAIL=TO_EMAIL, SUBJECT=SUBJECT, BODY=BODY)
			else:
				logging_func(logger=logger, log_str="Database import failed: {}\n".format(result.stderr), lt="ERROR")

				SUBJECT = "[FAILED] Database import failed for SCHEMA: {}".format(SCHEMA)
				BODY = "\nDatabase import failed.\n\nError details in the attached log file."
				BODY += "\n======= LOG FILE CONTENTS =======\n" + log_contents + "\n=================================\n"

				logging_func(logger=logger, log_str="Sending failure notification to admin.\n", lt="INFO")
				stack_emails(logger=logger, TO_EMAIL=TO_EMAIL, SUBJECT=SUBJECT, BODY=BODY)

			logging_func(logger=logger, log_str="Database import completed for schema: {}\n".format(SCHEMA), lt="SUCCESS")

		return True

	except FileNotFoundError as e:
		logger.error("File not found: {}\n".format(str(e)))
	except ValueError as e:
		logger.error("Schema extraction failed: {}\n".format(str(e)))
	except subprocess.CalledProcessError as e:
		logger.error("Database import failed due to a subprocess error: {}\n".format(str(e)))
	except Exception as e:
		logger.error("Database import encountered an issue: {}\n".format(str(e)))


# =============================================================================
# PATCHING
# =============================================================================
def get_yum_package_info(**kwargs):
	"""Retrieve information about a yum package."""
	try:
		package_name = kwargs.get("package_name")
		output = os.popen("yum info {}".format(package_name)).read()
		return output
	except Exception as e:
		print("Error getting package info for {}: {}".format(package_name, e))
		return None


def Patch_Function_A(**kwargs):
	"""Apply patch A to the given server (7am - 7pm, local execution)."""
	logger = kwargs.get("logger")
	SERVER = kwargs.get("SERVER")
	RUNNER = kwargs.get("RUNNER")

	logger.info("Applying Patching to SERVER: {}, by RUNNER: {}\n".format(SERVER, RUNNER))
	try:
		package_name = os.environ.get("PATCH_A_PACKAGE", "mysql-community-client-plugins.x86_64")
		package_version = os.environ.get("PATCH_A_VERSION", "0:8.0.40-1.el6")
		command = "sudo yum install {} {} -y".format(package_name, package_version)

		process = os.popen(command, 'r')
		output = process.read()
		return_code = process.close()

		if return_code:
			logger.error("Error applying Patch A: {}".format(output))
			raise Exception(output)

		logger.success("Patch A applied successfully to: {}\n".format(SERVER))
		package_info = get_yum_package_info(package_name=package_name)

		SUBJECT = "[SUCCESS] Patch A Applied on: {} - [{}]".format(SERVER, RUNNER)
		BODY = "\n[INFO] Patch A applied successfully to SERVER: {} by RUNNER: {}\n".format(SERVER, RUNNER)
		stack_emails(logger=logger, TO_EMAIL=TO_EMAIL, SUBJECT=SUBJECT, BODY=BODY)
	except Exception as e:
		logger.error("Error applying Patch A to: {}. Error: {}".format(SERVER, e))


def Patch_Function_B(**kwargs):
	"""Apply patch B to the given server (7pm - 7am, remote SSH execution)."""
	logger = kwargs.get("logger")
	SERVER = kwargs.get("SERVER")
	RUNNER = kwargs.get("RUNNER")

	logger.info("Applying Patching to SERVER: {}, by RUNNER: {}\n".format(SERVER, RUNNER))

	try:
		server_ip = SSH_SERVER_IP
		username = SSH_USERNAME
		key_path = SSH_KEY_PATH

		package_name = os.environ.get("PATCH_B_PACKAGE", "mysql-community-client-plugins.x86_64")
		package_version = os.environ.get("PATCH_B_VERSION", "0:8.0.40-1.el6")

		if not server_ip or not username or not key_path:
			logger.error("Error: SSH credentials not found in environment variables.")
			return

		# Construct the SSH command
		ssh_command = [
			"ssh",
			"-i", key_path,
			"{}@{}".format(username, server_ip),
			"sudo yum install {} {} -y".format(package_name, package_version)
		]

		# Execute SSH command with subprocess
		result = subprocess.run(
			ssh_command,
			stdout=subprocess.PIPE,
			stderr=subprocess.PIPE,
			universal_newlines=True,
			check=True
		)

		output = result.stdout
		error = result.stderr

		if error:
			logger.error("Error applying Patch B: {}".format(error))
			raise Exception(error)

		logger.success("Patch B applied successfully to: {}\n".format(SERVER))

		package_info = get_yum_package_info(package_name=package_name)

		SUBJECT = "[SUCCESS] Patch B Applied on: {} - [{}]".format(SERVER, RUNNER)
		BODY = """
		[INFO] Patch B applied successfully to SERVER: {} by RUNNER: {}

		Patch Details:{}
		""".format(SERVER, RUNNER, package_info).strip()

		stack_emails(logger=logger, TO_EMAIL=TO_EMAIL, SUBJECT=SUBJECT, BODY=BODY)
	except Exception as e:
		logger.error("Error applying Patch B to: {}. Error: {}".format(SERVER, e))


def patch_server(**kwargs):
	"""Patch servers based on time window, server name, and patch type."""
	logger = kwargs.get("logger")
	server_list = kwargs.get("server_list")
	RUNNER = kwargs.get("RUNNER")
	OP_TYPE = kwargs.get("OP_TYPE", "PATCHING")

	now = datetime.datetime.now().time()
	day_start = datetime.time(7, 0)
	day_end = datetime.time(19, 0)

	# Log operation start
	OP_ID = log_operation(OP_TYPE=OP_TYPE, STATUS="PROCESSING")

	try:
		for i in range(0, len(server_list), 2):
			SERVER = server_list[i]
			PATCH_TYPE = server_list[i + 1].upper()

			if PATCH_TYPE == "PATCH_A":
				if day_start <= now < day_end:
					Patch_Function_A(SERVER=SERVER, RUNNER=RUNNER, logger=logger)
				else:
					logging_func(logger=logger, log_str="Skipping Server: {} outside of Patch A time window\n".format(SERVER), lt="INFO")
			elif PATCH_TYPE == "PATCH_B":
				if day_end <= now or now < day_start:
					Patch_Function_B(SERVER=SERVER, RUNNER=RUNNER, logger=logger)
				else:
					logging_func(logger=logger, log_str="Skipping Server: {} outside of Patch B time window\n".format(SERVER), lt="INFO")
			else:
				logging_func(logger=logger, log_str="[WARNING] Unknown patch type: {}\n".format(PATCH_TYPE), lt="WARNING")

		# Log success
		log_operation(OP_ID=OP_ID, OP_TYPE=OP_TYPE, STATUS="COMPLETE")
	except IndexError:
		logger.error("Invalid servers and patches list. Ensure it has SERVER, PATCH_TYPE in pairs\n")
		log_operation(OP_ID=OP_ID, OP_TYPE=OP_TYPE, STATUS="FAILED")
	except Exception as e:
		logger.error("An unexpected error occurred in patch_server: {}".format(e))
		log_operation(OP_ID=OP_ID, OP_TYPE=OP_TYPE, STATUS="FAILED")


# =============================================================================
# PLACEHOLDER FUNCTIONS
# =============================================================================
def scp(**kwargs):
	"""Secure copy placeholder."""
	print("This is the SCP function")


def aws_func(**kwargs):
	"""AWS operations placeholder."""
	print("This is the AWS function")


def config_mgmt(**kwargs):
	"""Configuration management placeholder."""
	RUNNER = kwargs.get("RUNNER")
	SCHEMA = kwargs.get("SCHEMA")
	DB_NAME = kwargs.get("DB_NAME")
	DIRECTORY = kwargs.get("DIRECTORY", "N/A")

	print("\n[INFO] {} is executing operations for {} to {}".format(RUNNER, SCHEMA, DIRECTORY))
	print("\n[INFO] {} is performing configuration management for {} to {}".format(RUNNER, SCHEMA, DIRECTORY))
	print("\n[INFO] Directory: {}\n".format(DIRECTORY))
