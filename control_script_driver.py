#!/bin/python
# =============================================================================
# Enterprise Operations Control Script - Python Driver
# Description: CLI driver for enterprise operations including backup,
#              database management, disk monitoring, compression, patching,
#              and automated disk monitoring with threshold-based alerting.
# Author: Mayowa Babatola
# Usage: python control_script_driver.py <ACTION> [args...]
# =============================================================================

import sys
import os
import time
from datetime import datetime, timedelta
import stack_modules as m

# List of disks to monitor
MOUNT_POINTS = ["/u01", "/u02", "/u03", "/u04", "/u05", "/backup"]

# Alert thresholds and their respective alert intervals (minutes)
ALERT_THRESHOLDS = {
	"85": 5,  # every 5 minutes
	"95": 1,  # every 1 minute
}

# Tracks last time an alert was sent for each mount point and threshold
last_alert_time = {
	disk: {"85": None, "95": None} for disk in MOUNT_POINTS
}


# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
def should_alert(last_time, minutes):
	"""Determine if enough time has passed to send a new alert."""
	return (not last_time) or (datetime.now() - last_time >= timedelta(minutes=minutes))


def run_disk_monitoring(logger, **kwargs):
	"""
	Run disk check for all mount points and thresholds.
	Passes additional kwargs to the monitoring module.
	"""
	for disk in MOUNT_POINTS:
		for threshold_str, interval in ALERT_THRESHOLDS.items():
			threshold = int(threshold_str)
			last_time = last_alert_time[disk][threshold_str]

			if should_alert(last_time, interval):
				logger.info("Checking disk: {} at threshold {}%".format(disk, threshold))

				m.Disk_Maintenance_Check_On_Prem(
					logger=logger,
					DISK=disk,
					THRESHOLD=threshold
				)
				last_alert_time[disk][threshold_str] = datetime.now()


def usage():
	"""Display usage guide for all available operations."""
	print("\n[USAGE GUIDE]")
	print("-------------")
	print("[BACKUP] => python control_script_driver.py backup <SOURCE> <DESTINATION> <RUNNER>\n")
	print("[DATABASE BACKUP] => python control_script_driver.py database_backup <SCHEMA1,SCHEMA2> <RUNNER> <DB_NAME>\n")
	print("[DISK UTILIZATION] => python control_script_driver.py Disk_Maintenance_Check_On_Prem <MOUNT_POINT> <THRESHOLD>\n")
	print("[COMPRESS] => python control_script_driver.py compress <FILE_PATH> <RUNNER> <DESTINATION>\n")
	print("[UNCOMPRESS] => python control_script_driver.py uncompress <FILE_PATH> <RUNNER> <DESTINATION>\n")
	print("[DATABASE IMPORT] => python control_script_driver.py database_import <COMPRESSED_DUMPFILE_PATH> <RUNNER> <DB_NAME> <DIRECTORY>\n")
	print("[PATCHING] => python control_script_driver.py patching \"SERVER1,PATCH_TYPE1,SERVER2,PATCH_TYPE2\" <RUNNER>\n")
	print("--- Goodbye! ---")


# =============================================================================
# MAIN
# =============================================================================

# Defining Timestamp Global Variables
timestring = time.localtime()
TS = time.strftime("%m%d%y%H%M%S", timestring)

if __name__ == "__main__":
	if len(sys.argv) < 2:
		print("\nYou entered an incorrect number of command line arguments.\n")
		usage()
		sys.exit(1)

	ACTION = sys.argv[1]

	logger, log_file = m.setup_logger(command_name=ACTION)

	if ACTION == "backup":
		if len(sys.argv) - 1 != 4:
			logger.info("You have entered the wrong number for command line arguments.")
			logger.info("USAGE => python control_script_driver.py backup <SOURCE> <DESTINATION> <RUNNER>\n")
		else:
			SOURCE = sys.argv[2]
			DESTINATION = sys.argv[3]
			RUNNER = sys.argv[4]

			# Calling backup function
			m.backup(logger=logger, SOURCE=SOURCE, DESTINATION=DESTINATION)
			logger.success("Successfully copied {} to {} ".format(SOURCE, DESTINATION))

	elif ACTION == "database_backup":
		if len(sys.argv) - 1 != 4:
			logger.info("You have entered the wrong number for command line arguments.\n")
			logger.info("USAGE => python control_script_driver.py database_backup <SCHEMA1,SCHEMA2> OPERATOR DBNAME")
		else:
			SCHEMAS = sys.argv[2].upper().split(",")
			RUNNER = sys.argv[3].upper()
			DB_NAME = sys.argv[4]

			# Calling DB backup function
			success = m.database_backup(logger=logger, RUNNER=RUNNER, SCHEMAS=SCHEMAS, DB_NAME=DB_NAME)

			if success:
				logger.success("The Database has been successfully backed up!\n")
			else:
				logger.error("Database backup failed. Check logs for more details.\n")

	elif ACTION == "Disk_Maintenance_Check_On_Prem":
		# One-time manual check
		if len(sys.argv) - 1 != 3:
			logger.info("You have entered the wrong number for command line arguments.\n")
			logger.info("USAGE => python control_script_driver.py Disk_Maintenance_Check_On_Prem <mount_point> <threshold>")
		else:
			MOUNT_POINT = sys.argv[2]
			THRESHOLD = sys.argv[3]

			# Calling Disk Maintenance
			m.Disk_Maintenance_Check_On_Prem(logger=logger, DISK=MOUNT_POINT, THRESHOLD=THRESHOLD)

			logger.info("Disk utilization function completed on MOUNT POINT: {}\n".format(MOUNT_POINT))

	elif ACTION == "Auto_Disk_Monitoring":
		# Automated continuous monitoring mode
		logger.info("Started automated disk monitoring...")

		printed_notice = False

		try:
			while True:
				try:
					run_disk_monitoring(logger=logger)
				except Exception as e:
					logger.error("Monitoring loop error: {}".format(e))
				if not printed_notice:
					print("\nDisk monitoring started. Press Ctrl + C to stop\n")
					printed_notice = True

				time.sleep(60)
		except KeyboardInterrupt:
			logger.info("Disk monitoring stopped by user (Ctrl+C). Exiting gracefully.")

	elif ACTION == "compress":
		if len(sys.argv) - 1 != 4:
			logger.info("You have entered the wrong number for command line arguments.\n")
			logger.info("USAGE => python control_script_driver.py compress <file_path> <runner> <destination>")
		else:
			FILE_PATH = sys.argv[2]
			RUNNER = sys.argv[3]
			DESTINATION = sys.argv[4]

			# Ensure FILE_PATH is passed in as a list to G_Zipp()
			FILES_TO_COMPRESS = [FILE_PATH] if "," not in FILE_PATH else FILE_PATH.split(",")

			# Calling Compression Function
			archive_file = m.G_Zipp(FILES=FILE_PATH, RUNNER=RUNNER, DESTINATION=DESTINATION)

			if archive_file:
				logger.success("{} has been compressed".format(FILE_PATH))
			else:
				logger.error("[ERROR] Compression failed!")

	elif ACTION == "uncompress":
		if len(sys.argv) - 1 != 4:
			logger.info("You have entered the wrong number of command line arguments for uncompression.\n")
			logger.info("USAGE => python control_script_driver.py uncompress <file_path> <runner> <destination>")
		else:
			FILE_PATH = sys.argv[2]
			RUNNER = sys.argv[3]
			DESTINATION = sys.argv[4]

			# Calling the Uncompress Function
			extracted_path = m.G_Unzipp(FILE_PATH=FILE_PATH, RUNNER=RUNNER, DESTINATION=DESTINATION)

		if extracted_path:
			logger.success("'{}' has been successfully extracted to '{}'\n".format(FILE_PATH, extracted_path))
		else:
			logger.error("Uncompression failed for '{}'.\n".format(FILE_PATH))

	elif ACTION == "database_import":
		if len(sys.argv) - 1 != 5:
			logger.info("You have entered the wrong number of command line arguments for database import.")
			logger.info("USAGE => python control_script_driver.py database_import <compressed_dumpfile_path> <runner> <db_name> <directory>")
		else:
			DUMPFILE = sys.argv[2]
			RUNNER = sys.argv[3].upper()
			DB_NAME = sys.argv[4].upper()
			DIRECTORY = sys.argv[5]

			# Calling database_import function
			success = m.database_import(logger=logger, DUMPFILE=DUMPFILE, RUNNER=RUNNER, DB_NAME=DB_NAME, DIRECTORY=DIRECTORY)

			if success:
				logger.success("The database has been successfully imported!\n")
			else:
				logger.error("Database import failed. Check logs for more details.\n")

	elif ACTION == "patching":
		if len(sys.argv) - 1 != 3:
			logger.info("You have entered the wrong number of command line arguments for patching.")
			logger.info("Usage: python control_script_driver.py patching \"SERVER1,PATCH_TYPE1,SERVER2,PATCH_TYPE2,...\" RUNNER")
		else:
			SERVERS_STR = sys.argv[2]
			RUNNER = sys.argv[3].upper()
			SERVERS = [item.strip() for item in SERVERS_STR.split(',')]

			m.patch_server(server_list=SERVERS, RUNNER=RUNNER, logger=logger)

	else:
		logger.error("You selected the incorrect function, Try again\n")
		usage()
