#!/usr/bin/env bash
#
# oci-arm-catcher — grabs free Oracle Cloud ARM capacity (VM.Standard.A1.Flex)
# and launches an instance the moment capacity appears.
#
# It calls `oci compute instance launch` in a loop. On capacity-related /
# transient errors it waits RETRY_INTERVAL and retries, optionally rotating
# across several Availability Domains. On success it parses the instance OCID
# and fires a desktop notification.
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

# ─── RETRY CLASSIFICATION ─────────────────────────────────────────────────────
#
# IMPORTANT DESIGN NOTE (fixes a real bug that hit this script in production):
#
# The previous version used an *allow-list* of "known retryable" error
# substrings, and treated anything that didn't match as fatal ("Unexpected
# error, stopping."). That's backwards for a tool whose whole job is to sit
# and wait for transient capacity errors: OCI/the CLI doesn't always phrase a
# transient/capacity error the same way (different `code`, a raw Python
# traceback instead of clean JSON, an unfamiliar 5xx, a network blip, etc.),
# so the allow-list would eventually miss one and the script would silently
# quit after hundreds/thousands of otherwise-identical attempts — which is
# exactly what was happening, at a different attempt number each time,
# whenever OCI worded a capacity/rate-limit error slightly differently than
# the last one.
#
# Fix: flip it to a *deny-list* of genuinely fatal, non-retryable errors
# (bad config, bad auth, invalid resource ids — things that will NEVER be
# fixed by waiting and retrying). Everything else is treated as retryable by
# default. Worst case with this approach is a wasted retry; worst case with
# the old approach was the hunt silently dying for hours without you knowing.

# Errors that will NEVER be fixed by retrying — stop immediately on these.
NON_RETRYABLE_ERRORS='NotAuthenticated|AuthenticationFailed|NotAuthorized|AuthorizationFailed|InvalidParameter|InvalidCredentials|MissingParameter|IncorrectState|InvalidatedRetryToken|Http400|Http401|Http403|Http404|does not exist|not found in compartment|InvalidImageCompartment|InvalidSubnet|TenantIdMismatch'

# Kept for quick, readable log labelling only — no longer used to decide
# whether to stop. (Not load-bearing; is_retryable() below defaults to true.)
KNOWN_TRANSIENT_ERRORS='out of capacity|out of host capacity|InternalError|LimitExceeded|TooManyRequests|timed out|RequestException|ServiceUnavailable|Service Unavailable|Http5|connection reset|EOF occurred'

# Optional safety valve: if set to a positive integer, stop after this many
# CONSECUTIVE errors that don't match either list above (i.e. genuinely
# unrecognized output) — guards against silently hammering a broken setup
# forever. Unset/0 = never stop on this basis (the default: keep trying).
MAX_CONSECUTIVE_UNKNOWN="${MAX_CONSECUTIVE_UNKNOWN:-0}"

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
# The real ServiceError JSON block from OCI is flat (no nested braces).
# Find ALL brace-delimited blocks and use the LAST one — if the CLI ever
# echoes back request parameters (which can also look like a JSON blob)
# before the actual error, this avoids merging them into one broken blob.
matches = re.findall(r"\{[^{}]*\}", raw, re.S)
if matches:
    for candidate in reversed(matches):
        try:
            d = json.loads(candidate)
            code = d.get("code") or d.get("status") or ""
            msg  = d.get("message") or ""
            if code or msg:
                break
        except Exception:
            continue
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
        parsed="Error   $(printf '%s' "$output" | tr '\n' ' ' | cut -c1-200)"
    fi
    printf '%s\n' "$parsed"
}

# Extract the instance OCID from a successful launch response.
parse_instance_id() {
    printf '%s' "$1" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null || echo "unknown"
}

# True unless the output matches a genuinely fatal (non-retryable) error.
# Default is TRUE (retry) — see design note above.
is_retryable() {
    if printf '%s' "$1" | grep -qiE "$NON_RETRYABLE_ERRORS"; then
        return 1
    fi
    return 0
}

# True if the output matches one of the well-known transient/capacity
# patterns. Used only for nicer logging (e.g. flagging truly unrecognized
# errors), not for the retry decision itself.
is_known_transient() {
    printf '%s' "$1" | grep -qiE "$KNOWN_TRANSIENT_ERRORS"
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
ERROR_LOG="${ERROR_LOG:-$SCRIPT_DIR/oci-arm-catcher-errors.log}"

# ─── MAIN LOOP ────────────────────────────────────────────────────────────────

echo "=== oci-arm-catcher started at $(date) ==="
echo "Shape: VM.Standard.A1.Flex  |  OCPU: $OCPUS  |  RAM: ${MEMORY_GB}GB"
if [ ${#ADS[@]} -gt 1 ]; then
    echo "Availability Domains (rotating): ${ADS[*]}"
else
    echo "Availability Domain: ${ADS[0]}"
fi
echo "Retry interval: $((RETRY_INTERVAL / 60)) min"
echo "Errors are logged to: $ERROR_LOG"
echo ""

attempt=0
ad_index=0
consecutive_unknown=0

while true; do
    attempt=$((attempt + 1))
    current_ad="${ADS[$ad_index]}"
    if [ ${#ADS[@]} -gt 1 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Attempt #$attempt  (AD: $current_ad)"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Attempt #$attempt"
    fi

    TMPOUT=$(mktemp)
    # --no-retry is important: the OCI CLI's Python SDK has its own internal
    # retry/backoff that is independent of --connection-timeout/--read-timeout.
    # On a 500 it can silently loop on 429 "Too Many Requests" for minutes
    # inside a single attempt, which makes RETRY_INTERVAL meaningless and looks
    # like the script has hung. We do our own retrying, so disable the SDK's.
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
        --no-retry \
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

    # Always log the full raw error, regardless of classification, so it's
    # possible to review afterwards what actually happened (background/
    # unattended runs lose terminal scrollback).
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Attempt #$attempt (AD: $current_ad)"
        printf '%s\n' "$output"
        echo "---"
    } >> "$ERROR_LOG"

    if is_retryable "$output"; then
        if is_known_transient "$output"; then
            consecutive_unknown=0
        else
            consecutive_unknown=$((consecutive_unknown + 1))
            echo "  -> (unrecognized error text, but not fatal — retrying. [$consecutive_unknown consecutive])"
            if [[ "$MAX_CONSECUTIVE_UNKNOWN" -gt 0 && "$consecutive_unknown" -ge "$MAX_CONSECUTIVE_UNKNOWN" ]]; then
                echo "  -> Hit MAX_CONSECUTIVE_UNKNOWN ($MAX_CONSECUTIVE_UNKNOWN), stopping as a precaution." >&2
                printf '%s\n' "$output" >&2
                notify "Too many unrecognized errors in a row — check $ERROR_LOG"
                exit 1
            fi
        fi
        # Rotate to the next AD for the following attempt.
        if [ ${#ADS[@]} -gt 1 ]; then
            ad_index=$(((ad_index + 1) % ${#ADS[@]}))
        fi
        wait_countdown "$RETRY_INTERVAL"
    else
        echo "  -> Fatal (non-retryable) error, stopping." >&2
        printf '%s\n' "$output" >&2
        notify "Fatal OCI error — check the terminal / $ERROR_LOG"
        exit 1
    fi
done
