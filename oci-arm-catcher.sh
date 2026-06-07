#!/usr/bin/env bash
#
# oci-arm-catcher — grabs free Oracle Cloud ARM capacity (VM.Standard.A1.Flex)
# and launches an instance the moment capacity appears.
#
# It calls `oci compute instance launch` in a loop. On capacity-related errors
# ("Out of host capacity", InternalError, LimitExceeded, TooManyRequests,
# timeouts) it waits RETRY_INTERVAL and retries, optionally rotating across
# several Availability Domains. On success it parses the instance OCID and
# fires a desktop notification.
#
# Prerequisites:
#   - OCI CLI installed:  https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm
#   - Config created:     oci setup config   (creates ~/.oci/config)
#
# Usage:
#   cp .env.example .env      # then fill in your values
#   chmod +x oci-arm-catcher.sh
#   ./oci-arm-catcher.sh
#
# See README.md for how to obtain each OCID.

set -euo pipefail

# Errors that mean "no capacity right now, keep trying".
RETRYABLE_ERRORS='out of capacity|out of host capacity|InternalError|LimitExceeded|TooManyRequests|timed out|RequestException|ServiceUnavailable|Service Unavailable'

# ─── HELPERS ──────────────────────────────────────────────────────────────────

# Cross-platform desktop notification (macOS, Linux). Always echoes too.
notify() {
    local msg="$1"
    if command -v osascript &>/dev/null; then
        osascript -e "display notification \"$msg\" with title \"oci-arm-catcher\" sound name \"Glass\"" 2>/dev/null || true
    elif command -v notify-send &>/dev/null; then
        notify-send "oci-arm-catcher" "$msg" 2>/dev/null || true
    fi
    echo "$msg"
}

# Parse OCI CLI JSON error output into "CODE\tMESSAGE".
# Falls back gracefully so we never print "?: ?".
parse_oci_error() {
    local output="$1" parsed
    parsed=$(printf '%s' "$output" | python3 -c '
import sys, json, re
raw = sys.stdin.read()
code = msg = ""
m = re.search(r"\{.*\}", raw, re.S)
if m:
    try:
        d = json.loads(m.group(0))
        code = d.get("code") or d.get("status") or ""
        msg  = d.get("message") or ""
    except Exception:
        pass
if not msg:
    picked = ""
    for line in raw.splitlines():
        line = line.strip()
        if line and not line.startswith("{") and ":" in line:
            picked = line
            break
    msg = picked or (raw.strip().splitlines()[-1] if raw.strip() else "")
print((code or "Error") + "\t" + (msg or "no message"))
' 2>/dev/null) || parsed=""
    if [[ -z "$parsed" ]]; then
        parsed="Error	$(printf '%s' "$output" | tr '\n' ' ' | cut -c1-200)"
    fi
    printf '%s\n' "$parsed"
}

# Extract the instance OCID from a successful launch response.
parse_instance_id() {
    printf '%s' "$1" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null || echo "unknown"
}

# True if the given output is a retryable (capacity) error.
is_retryable() {
    printf '%s' "$1" | grep -qiE "$RETRYABLE_ERRORS"
}

# Spinner — interactive terminals only.
spin() {
    local pid=$1 msg="$2" i=0
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  %s %s" "${frames:$((i % 10)):1}" "$msg"
        i=$((i + 1))
        sleep 0.1
    done
    printf "\r\033[K"
}

# Countdown between attempts. Smooth in a TTY, once-a-minute in a log file.
wait_countdown() {
    local total=$1
    if [ -t 1 ]; then
        local end=$((SECONDS + total))
        while [ $SECONDS -lt $end ]; do
            local rem=$((end - SECONDS))
            printf "\r  ⏳ %02d:%02d until next attempt" $((rem / 60)) $((rem % 60))
            sleep 1
        done
        printf "\r\033[K"
    else
        local remaining=$total
        while [ "$remaining" -gt 60 ]; do
            sleep 60
            remaining=$((remaining - 60))
            echo "  ⏳ $((remaining / 60)) min remaining..."
        done
        sleep "$remaining"
    fi
}

# When sourced for testing, stop here — define functions but don't run anything.
if [[ "${OCI_ARM_CATCHER_LIB:-}" == "1" ]]; then
    return 0 2>/dev/null
    # shellcheck disable=SC2317
    exit 0
fi

# ─── LOCATE & LOAD CONFIG ─────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Allow an explicit config path:  ./oci-arm-catcher.sh /path/to/my.env
ENV_FILE="${1:-${OCI_ARM_CATCHER_ENV:-$SCRIPT_DIR/.env}}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: config file not found: $ENV_FILE" >&2
    echo "Copy .env.example to .env and fill in your values, or pass a path:" >&2
    echo "    ./oci-arm-catcher.sh /path/to/your.env" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# ─── VALIDATE CONFIG ──────────────────────────────────────────────────────────

# Support either a single AVAILABILITY_DOMAIN or a comma-separated
# AVAILABILITY_DOMAINS list (AD rotation). Normalise into an array.
declare -a ADS=()
if [[ -n "${AVAILABILITY_DOMAINS:-}" ]]; then
    IFS=',' read -ra _raw <<< "$AVAILABILITY_DOMAINS"
    for ad in "${_raw[@]}"; do
        ad="$(echo "$ad" | xargs)"   # trim whitespace
        [[ -n "$ad" ]] && ADS+=("$ad")
    done
elif [[ -n "${AVAILABILITY_DOMAIN:-}" ]]; then
    ADS+=("$AVAILABILITY_DOMAIN")
fi

REQUIRED=(COMPARTMENT_ID IMAGE_ID SUBNET_ID SSH_KEY_FILE OCPUS MEMORY_GB DISPLAY_NAME)
missing=0
for var in "${REQUIRED[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: required config variable is empty: $var" >&2
        missing=1
    fi
done
if [[ ${#ADS[@]} -eq 0 ]]; then
    echo "Error: set AVAILABILITY_DOMAIN or AVAILABILITY_DOMAINS in your config." >&2
    missing=1
fi
if [[ -n "${SSH_KEY_FILE:-}" && ! -f "$SSH_KEY_FILE" ]]; then
    echo "Error: SSH public key not found: $SSH_KEY_FILE" >&2
    missing=1
fi
if ! command -v oci &>/dev/null; then
    echo "Error: the 'oci' CLI is not installed or not on PATH." >&2
    echo "Install it: https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm" >&2
    missing=1
fi
[[ $missing -eq 0 ]] || exit 1

RETRY_INTERVAL="${RETRY_INTERVAL:-300}"

# ─── MAIN LOOP ────────────────────────────────────────────────────────────────

echo "=== oci-arm-catcher started at $(date) ==="
echo "Shape: VM.Standard.A1.Flex  |  OCPU: $OCPUS  |  RAM: ${MEMORY_GB}GB"
if [ ${#ADS[@]} -gt 1 ]; then
    echo "Availability Domains (rotating): ${ADS[*]}"
else
    echo "Availability Domain: ${ADS[0]}"
fi
echo "Retry interval: $((RETRY_INTERVAL / 60)) min"
echo ""

attempt=0
ad_index=0

while true; do
    attempt=$((attempt + 1))
    current_ad="${ADS[$ad_index]}"
    if [ ${#ADS[@]} -gt 1 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Attempt #$attempt  (AD: $current_ad)"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Attempt #$attempt"
    fi

    TMPOUT=$(mktemp)
    oci compute instance launch \
        --compartment-id      "$COMPARTMENT_ID" \
        --availability-domain "$current_ad" \
        --display-name        "$DISPLAY_NAME" \
        --shape               "VM.Standard.A1.Flex" \
        --shape-config        "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}" \
        --image-id            "$IMAGE_ID" \
        --subnet-id           "$SUBNET_ID" \
        --ssh-authorized-keys-file "$SSH_KEY_FILE" \
        --assign-public-ip    true \
        --connection-timeout  60 \
        --read-timeout        120 \
        > "$TMPOUT" 2>&1 &
    oci_pid=$!

    [ -t 1 ] && spin "$oci_pid" "Calling OCI..."
    wait "$oci_pid" && status=0 || status=$?
    output=$(cat "$TMPOUT")
    rm -f "$TMPOUT"

    if [ "$status" -eq 0 ]; then
        instance_id=$(parse_instance_id "$output")
        notify "SUCCESS! Instance created: $instance_id"
        printf '%s\n' "$output" | python3 -m json.tool 2>/dev/null || printf '%s\n' "$output"
        exit 0
    fi

    # Readable error line (never "?: ?").
    IFS=$'\t' read -r error_code error_msg < <(parse_oci_error "$output") || true
    echo "  -> ${error_code}: ${error_msg}"

    if is_retryable "$output"; then
        # Rotate to the next AD for the following attempt.
        if [ ${#ADS[@]} -gt 1 ]; then
            ad_index=$(((ad_index + 1) % ${#ADS[@]}))
        fi
        wait_countdown "$RETRY_INTERVAL"
    else
        echo "  -> Unexpected error, stopping." >&2
        printf '%s\n' "$output" >&2
        notify "Unexpected OCI error — check the terminal."
        exit 1
    fi
done
