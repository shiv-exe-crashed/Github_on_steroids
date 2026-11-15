#!/bin/bash
# Double-click this file in Finder to set up GitHub Desktop Profiles.
# It opens Terminal and runs the guided setup (mac/ghdp setup).
cd "$(/usr/bin/dirname "$0")" || exit 1
/bin/bash ./mac/ghdp setup
status=$?
echo
read -r -p "Press Return to close this window. " _ || true
exit "$status"
