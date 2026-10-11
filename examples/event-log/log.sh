#!/bin/bash
# Appends one line per event to ~/server-mode-events.log, e.g.
#   2026-10-11 09:30:02 server-paused battery=34% ac=0 previous=on
echo "$(date '+%F %T') $LSM_EVENT battery=$LSM_BATTERY% ac=$LSM_ON_AC${LSM_PREVIOUS:+ previous=$LSM_PREVIOUS}${LSM_SERVICE:+ service=$LSM_SERVICE}" >> ~/server-mode-events.log
