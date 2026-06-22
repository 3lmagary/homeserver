#!/bin/bash
# Sourcing the local modified .sys_check.sh
source ./.sys_check.sh

echo "Starting failure test..."
sleep 1

# This command doesn't exist, it will trigger the ERR trap!
non_existent_command_to_test_errors

echo "Continuing script..."
# Exit with a non-zero status code (e.g., 5) to trigger failed status
exit 5
