#!/usr/bin/env bash
set -Eeuo pipefail

INSTANCE_ID="${1:?Usage: ssm-run.sh <instance-id> <command>}"
COMMAND="${2:?Usage: ssm-run.sh <instance-id> <command>}"
REQUEST_FILE="$(mktemp)"
trap 'rm -f "$REQUEST_FILE"' EXIT

python3 - "$REQUEST_FILE" "$INSTANCE_ID" "$COMMAND" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as request:
    json.dump({
        "DocumentName": "AWS-RunShellScript",
        "InstanceIds": [sys.argv[2]],
        "Parameters": {"commands": [sys.argv[3]]},
    }, request)
PY

COMMAND_ID="$(aws ssm send-command \
  --cli-input-json "file://$REQUEST_FILE" \
  --query Command.CommandId \
  --output text)"
DEADLINE=$((SECONDS + 1800))

while (( SECONDS < DEADLINE )); do
  STATUS="$(aws ssm list-command-invocations \
    --command-id "$COMMAND_ID" \
    --details \
    --query 'CommandInvocations[0].Status' \
    --output text)"

  case "$STATUS" in
    Success)
      echo "SSM command completed successfully."
      exit 0
      ;;
    Failed|TimedOut|Cancelled|Cancelling)
      echo "SSM command failed with status: $STATUS"
      exit 1
      ;;
    Pending|InProgress|Delayed|None)
      sleep 10
      ;;
    *)
      echo "Unexpected SSM command status: $STATUS"
      exit 1
      ;;
  esac
done

echo "Timed out waiting for the SSM command."
exit 1
