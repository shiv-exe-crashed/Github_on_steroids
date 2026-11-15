#!/bin/bash
# Double-click this file in Finder to remove GitHub Desktop Profiles.
# It asks before removing anything (mac/ghdp uninstall).
cd "$(/usr/bin/dirname "$0")" || exit 1
/bin/bash ./mac/ghdp uninstall
status=$?
echo
read -r -p "Press Return to close this window. " _ || true
exit "$status"
