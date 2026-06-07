#!/usr/bin/env bats
#
# Tests for oci-arm-catcher.sh
#
# Two layers:
#   - unit:        source the script in library mode, call its parsing functions
#   - integration: run the whole script against a mocked `oci` CLI on PATH
#
# Run:  bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO_ROOT/oci-arm-catcher.sh"
    TMP="$(mktemp -d)"

    # A fake oci CLI whose behaviour is driven by env vars / a counter file.
    BIN="$TMP/bin"
    mkdir -p "$BIN"
    cat > "$BIN/oci" <<'MOCK'
#!/usr/bin/env bash
# Mock oci CLI for tests.
#   MOCK_MODE=success            -> print a launch JSON, exit 0
#   MOCK_MODE=capacity           -> print "out of host capacity" error, exit 1
#   MOCK_MODE=fatal              -> print a non-retryable error, exit 1
#   MOCK_MODE=fail_then_success  -> fail with capacity MOCK_FAILS times, then succeed
COUNT_FILE="${MOCK_COUNT_FILE:-/tmp/oci_mock_count}"
case "${MOCK_MODE:-success}" in
  success)
    echo '{"data": {"id": "ocid1.instance.oc1..success", "display-name": "arm-free-1"}}'
    exit 0 ;;
  capacity)
    echo '{"code": "InternalError", "message": "Out of host capacity."}' >&2
    exit 1 ;;
  fatal)
    echo '{"code": "NotAuthorizedOrNotFound", "message": "Authorization failed or requested resource not found."}' >&2
    exit 1 ;;
  fail_then_success)
    n=0; [ -f "$COUNT_FILE" ] && n=$(cat "$COUNT_FILE")
    n=$((n + 1)); echo "$n" > "$COUNT_FILE"
    if [ "$n" -le "${MOCK_FAILS:-2}" ]; then
      echo '{"code": "InternalError", "message": "Out of host capacity."}' >&2
      exit 1
    fi
    echo '{"data": {"id": "ocid1.instance.oc1..eventually"}}'
    exit 0 ;;
esac
MOCK
    chmod +x "$BIN/oci"

    # Minimal valid .env for integration runs.
    SSH_KEY="$TMP/id_ed25519.pub"
    echo "ssh-ed25519 AAAATESTKEY test@example" > "$SSH_KEY"
    ENV_FILE="$TMP/test.env"
    cat > "$ENV_FILE" <<EOF
COMPARTMENT_ID="ocid1.tenancy.oc1..test"
DISPLAY_NAME="arm-free-1"
SSH_KEY_FILE="$SSH_KEY"
AVAILABILITY_DOMAIN="Test:EU-AMSTERDAM-1-AD-1"
SUBNET_ID="ocid1.subnet.oc1..test"
IMAGE_ID="ocid1.image.oc1..test"
OCPUS=4
MEMORY_GB=24
RETRY_INTERVAL=1
EOF
}

teardown() {
    rm -rf "$TMP"
}

# ── Unit tests: parsing functions (library mode) ──────────────────────────────

@test "parse_oci_error extracts code and message from JSON" {
    OCI_ARM_CATCHER_LIB=1 source "$SCRIPT"
    run parse_oci_error '{"code": "InternalError", "message": "Out of host capacity."}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"InternalError"* ]]
    [[ "$output" == *"Out of host capacity."* ]]
}

@test "parse_oci_error never returns empty/question-mark output" {
    OCI_ARM_CATCHER_LIB=1 source "$SCRIPT"
    run parse_oci_error "ServiceError: something went sideways"
    [ "$status" -eq 0 ]
    [[ "$output" != "?:"* ]]
    [[ -n "$output" ]]
}

@test "parse_instance_id pulls the OCID out of a launch response" {
    OCI_ARM_CATCHER_LIB=1 source "$SCRIPT"
    run parse_instance_id '{"data": {"id": "ocid1.instance.oc1..abc"}}'
    [ "$status" -eq 0 ]
    [ "$output" = "ocid1.instance.oc1..abc" ]
}

@test "is_retryable true for capacity errors" {
    OCI_ARM_CATCHER_LIB=1 source "$SCRIPT"
    run is_retryable "Error: Out of host capacity."
    [ "$status" -eq 0 ]
    run is_retryable "TooManyRequests"
    [ "$status" -eq 0 ]
}

@test "is_retryable false for auth errors" {
    OCI_ARM_CATCHER_LIB=1 source "$SCRIPT"
    run is_retryable "NotAuthorizedOrNotFound: nope"
    [ "$status" -ne 0 ]
}

# ── Integration tests: full script against the mock CLI ───────────────────────

@test "succeeds immediately and exits 0" {
    PATH="$BIN:$PATH" MOCK_MODE=success run bash "$SCRIPT" "$ENV_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUCCESS"* ]]
    [[ "$output" == *"ocid1.instance.oc1..success"* ]]
}

@test "retries on capacity error, then succeeds" {
    export MOCK_COUNT_FILE="$TMP/count"
    PATH="$BIN:$PATH" MOCK_MODE=fail_then_success MOCK_FAILS=2 run bash "$SCRIPT" "$ENV_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUCCESS"* ]]
    [[ "$output" == *"ocid1.instance.oc1..eventually"* ]]
    # Should have called the CLI 3 times (2 failures + 1 success).
    [ "$(cat "$TMP/count")" -eq 3 ]
}

@test "stops on a non-retryable error with exit 1" {
    PATH="$BIN:$PATH" MOCK_MODE=fatal run bash -c "$(printf '%q ' bash "$SCRIPT" "$ENV_FILE") 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unexpected"* ]]
}

@test "fails fast when config file is missing" {
    PATH="$BIN:$PATH" run bash "$SCRIPT" "$TMP/does-not-exist.env"
    [ "$status" -eq 1 ]
    [[ "$output" == *"config file not found"* ]]
}

@test "fails when a required variable is empty" {
    bad="$TMP/bad.env"
    grep -v '^COMPARTMENT_ID' "$ENV_FILE" > "$bad"
    PATH="$BIN:$PATH" MOCK_MODE=success run bash "$SCRIPT" "$bad"
    [ "$status" -eq 1 ]
    [[ "$output" == *"COMPARTMENT_ID"* ]]
}

@test "error line is human-readable (no '?: ?')" {
    # One capacity failure then success; check the printed error line.
    export MOCK_COUNT_FILE="$TMP/count2"
    PATH="$BIN:$PATH" MOCK_MODE=fail_then_success MOCK_FAILS=1 run bash "$SCRIPT" "$ENV_FILE"
    [[ "$output" == *"InternalError: Out of host capacity."* ]]
    [[ "$output" != *"?: ?"* ]]
}
