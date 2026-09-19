#!/system/bin/sh
# Wrapper so Android init execs /system/bin/sh (a system_file it may execute)
# instead of exec'ing a binary in /data/adb. init's own domain cannot execute
# files labelled adb_data_file:
#   avc: denied { execute } ... scontext=u:r:init:s0 tcontext=adb_data_file
# Going through sh also lets the service pick up seclabel u:r:ksu:s0.
export PATH=/data/adb/s6/bin:$PATH
exec /data/adb/s6/bin/s6-svscan /data/adb/s6/scan
