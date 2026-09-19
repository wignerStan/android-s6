#!/system/bin/sh
# Bring the compiled s6-rc database up. Run once per boot by Android init
# (oneshot), after k70-s6-svscan is supervising /data/adb/s6/scan.
#
# Each boot must start from a CLEAN live state:
#  - s6-rc-init refuses to start services if a stale live dir (state = all down)
#    is reused, and
#  - if a stale live target survives, s6-rc-init silently "recovers" it instead
#    of building a fresh one.
# So remove both the `live` symlink AND every `live:s6-rc-init:*` target.
export PATH=/data/adb/s6/bin:$PATH
B=/data/adb/s6/bin
S=/data/adb/s6

rm -rf "$S"/live "$S"/live:s6-rc-init:* 2>/dev/null
# clear stale servicedir links but keep the scandir itself (s6-svscan is already
# running on it; the hidden .s6-svscan control dir must survive)
rm -f "$S"/scan/* 2>/dev/null
mkdir -p "$S/scan"

"$B/s6-rc-init" -c "$S/current" -l "$S/live" "$S/scan"
"$B/s6-rc" -l "$S/live" -u change default
