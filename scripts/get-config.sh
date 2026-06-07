#!/usr/bin/env bash
#
# get-config.sh — interactive helper that prints the OCIDs you need for .env.
#
# It uses your existing OCI CLI config (~/.oci/config). Nothing is written or
# launched; this only reads metadata. Copy the printed values into your .env.
#
# Usage:
#   ./scripts/get-config.sh
#   ./scripts/get-config.sh --compartment ocid1.compartment.oc1..xxxx
#   ./scripts/get-config.sh --os "Canonical Ubuntu"

set -euo pipefail

OS_NAME="Canonical Ubuntu"
COMPARTMENT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --compartment) COMPARTMENT="$2"; shift 2 ;;
        --os)          OS_NAME="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

command -v oci >/dev/null || { echo "Error: 'oci' CLI not found. Install it first." >&2; exit 1; }
command -v jq  >/dev/null || echo "Note: 'jq' not found — output will be raw JSON. Install jq for pretty tables." >&2

have_jq() { command -v jq >/dev/null; }

echo "════════════════════════════════════════════════════════════════"
echo " oci-arm-catcher — config discovery"
echo "════════════════════════════════════════════════════════════════"

# 1) Tenancy OCID (default compartment = root)
TENANCY=$(oci iam compartment list --all 2>/dev/null \
    | { have_jq && jq -r '.data[0]."compartment-id"' || cat; } 2>/dev/null || true)
if [[ -n "${TENANCY:-}" && "$TENANCY" != "null" ]]; then
    echo
    echo "# Root compartment (tenancy) OCID — usable as COMPARTMENT_ID:"
    echo "COMPARTMENT_ID=\"$TENANCY\""
fi
[[ -z "$COMPARTMENT" && -n "${TENANCY:-}" && "$TENANCY" != "null" ]] && COMPARTMENT="$TENANCY"

echo
echo "# All compartments (pick one for COMPARTMENT_ID):"
if have_jq; then
    oci iam compartment list --all 2>/dev/null | jq -r '.data[] | "  \(.name)\t\(.id)"' || true
else
    oci iam compartment list --all || true
fi

# 2) Availability domains
echo
echo "# Availability Domains (AVAILABILITY_DOMAIN / AVAILABILITY_DOMAINS):"
if have_jq; then
    oci iam availability-domain list 2>/dev/null | jq -r '.data[] | "  \(.name)"' || true
else
    oci iam availability-domain list || true
fi

# 3) Subnets in the chosen compartment
if [[ -n "$COMPARTMENT" ]]; then
    echo
    echo "# Subnets in compartment (SUBNET_ID):"
    if have_jq; then
        oci network subnet list --compartment-id "$COMPARTMENT" --all 2>/dev/null \
            | jq -r '.data[] | "  \(."display-name")\t\(.id)"' || true
    else
        oci network subnet list --compartment-id "$COMPARTMENT" --all || true
    fi

    # 4) Latest ARM image for the requested OS
    echo
    echo "# Latest ARM (A1.Flex) image for \"$OS_NAME\" (IMAGE_ID):"
    if have_jq; then
        oci compute image list --compartment-id "$COMPARTMENT" \
            --operating-system "$OS_NAME" --shape "VM.Standard.A1.Flex" --all 2>/dev/null \
            | jq -r '.data[0] | "  \(."display-name")\t\(.id)"' || true
    else
        oci compute image list --compartment-id "$COMPARTMENT" \
            --operating-system "$OS_NAME" --shape "VM.Standard.A1.Flex" --all || true
    fi
fi

echo
echo "# Your SSH public key (SSH_KEY_FILE) — typical locations:"
for k in "$HOME"/.ssh/id_ed25519.pub "$HOME"/.ssh/id_rsa.pub; do
    [[ -f "$k" ]] && echo "  $k"
done
echo
echo "Done. Paste the values above into your .env (see .env.example)."
