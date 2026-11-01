#!/usr/bin/env bash
# GitHub Actions version of the JohnMaJPGateway retry loop.
# Same spec as the local script, with one Actions-specific addition:
# MAX_RUNTIME_MINUTES (default 330) — the loop exits cleanly with
# retry_result=TIMEOUT before the job timeout (340 min), so the next
# scheduled run can resume. It does NOT run forever inside one job.
#
# Inputs come only from environment variables set by the workflow from
# GitHub Secrets. No OCID, key, or secret is hardcoded in this file.
# This script never prints a private key or the full OCI config.
set -u

COMPARTMENT_OCID="${COMPARTMENT_OCID:-}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-}"
REGION="${REGION:-ap-osaka-1}"
INSTANCE_NAME="${INSTANCE_NAME:-JohnMaJPGateway}"
VCN_NAME="${VCN_NAME:-JohnMaJPGatewayVCN}"
PUBLIC_SUBNET_NAME="${PUBLIC_SUBNET_NAME:-public subnet-JohnMaJPGatewayVCN}"
SLEEP_SECONDS="${SLEEP_SECONDS:-60}"
MAX_RUNTIME_MINUTES="${MAX_RUNTIME_MINUTES:-330}"
LOG_FILE="${LOG_FILE:-./retry.log}"
RESULT_FILE="${RESULT_FILE:-./retry_result}"
START_EPOCH="$(date +%s)"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*" | tee -a "$LOG_FILE"
}
write_result() { printf '%s\n' "$1" > "$RESULT_FILE"; }
die() {
  log "ERROR: $*"
  write_result "FAILED"
  exit 1
}

command -v oci >/dev/null 2>&1 || die "oci CLI not found"
command -v jq >/dev/null 2>&1 || die "jq not found"
[ -n "$COMPARTMENT_OCID" ] || die "COMPARTMENT_OCID is empty (set it from secrets in the workflow)"
[ -f "$SSH_PUBLIC_KEY_FILE" ] || die "Instance SSH public key file not found: $SSH_PUBLIC_KEY_FILE"

log "Starting retry loop: $INSTANCE_NAME, VM.Standard.A1.Flex 2 OCPU / 12 GB, Ubuntu 24.04 ARM, region $REGION, VCN $VCN_NAME, max runtime ${MAX_RUNTIME_MINUTES} min, sleep ${SLEEP_SECONDS}s"

log "Resolving VCN OCID for $VCN_NAME ..."
VCN_OCID="$(oci network vcn list --compartment-id "$COMPARTMENT_OCID" --display-name "$VCN_NAME" --query 'data[0].id' --raw-output 2>>"$LOG_FILE")"
[ -n "$VCN_OCID" ] && [ "$VCN_OCID" != "null" ] || die "Could not find VCN $VCN_NAME"

log "Resolving public subnet OCID for $PUBLIC_SUBNET_NAME ..."
SUBNET_OCID="$(oci network subnet list --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_OCID" --display-name "$PUBLIC_SUBNET_NAME" --query 'data[0].id' --raw-output 2>>"$LOG_FILE")"
[ -n "$SUBNET_OCID" ] && [ "$SUBNET_OCID" != "null" ] || die "Could not find public subnet $PUBLIC_SUBNET_NAME"

log "Resolving availability domain AD-1 ..."
AD_NAME="$(oci iam availability-domain list --compartment-id "$COMPARTMENT_OCID" --query 'data[0].name' --raw-output 2>>"$LOG_FILE")"
[ -n "$AD_NAME" ] && [ "$AD_NAME" != "null" ] || die "Could not list availability domains"
log "Availability domain: $AD_NAME"

log "Resolving pinned Ubuntu 24.04 ARM image (no image list) ..."
# 2026-11-01 pinned-image change: oci compute image list returned
# empty stdout (exit 0, no stderr) in all three forms tried in the
# Actions runner (query, full broad, full version+shape), while
# VCN / subnet / AD lists in the same script succeed. Further list
# tweaking is therefore not expected to help. Instead, use the exact
# image OCID the user copied from Console > Compute > Images on
# 2026-11-01. This is a public Oracle platform image OCID, not a
# secret, so logging its display name (not the OCID itself, to keep
# Actions logs clean) is safe. The script verifies the image with
# oci compute image get BEFORE launching, and refuses to launch if
# the name is not Ubuntu 24.04 ARM, if it is Minimal, or if it is
# not AVAILABLE — so a wrong OCID cannot silently launch the wrong OS.
PINNED_IMAGE_OCID="${IMAGE_OCID:-ocid1.image.oc1.ap-osaka-1.aaaaaaaafjymvqo2bqj5uur45dfvhch6sp72yedb7xfaenkbvufx5zisnmya}"
IMAGE_ERR_FILE="$(mktemp)"
IMAGE_GET_JSON="$(oci compute image get --image-id "$PINNED_IMAGE_OCID" 2>"$IMAGE_ERR_FILE")"
IMAGE_GET_STATUS=$?
if [ "$IMAGE_GET_STATUS" -ne 0 ] || [ -z "$IMAGE_GET_JSON" ]; then
  log "oci compute image get failed, exit $IMAGE_GET_STATUS"
  if [ -s "$IMAGE_ERR_FILE" ]; then
    sed -E 's/ocid1\.[a-zA-Z0-9._-]+/<OCID>/g' "$IMAGE_ERR_FILE" | while IFS= read -r line; do log "  oci error: $line"; done
  fi
  rm -f "$IMAGE_ERR_FILE"
  die "Could not verify the pinned image — check that the OCID copied from Console is correct and that the API key can read images in ap-osaka-1"
fi
rm -f "$IMAGE_ERR_FILE"
IMAGE_NAME="$(printf '%s' "$IMAGE_GET_JSON" | jq -r '.data."display-name" // empty' 2>/dev/null)"
IMAGE_OS="$(printf '%s' "$IMAGE_GET_JSON" | jq -r '.data."operating-system" // empty' 2>/dev/null)"
IMAGE_OS_VERSION="$(printf '%s' "$IMAGE_GET_JSON" | jq -r '.data."operating-system-version" // empty' 2>/dev/null)"
IMAGE_STATE="$(printf '%s' "$IMAGE_GET_JSON" | jq -r '.data."lifecycle-state" // empty' 2>/dev/null)"
log "Pinned image verified from OCI: name=$IMAGE_NAME, OS=$IMAGE_OS $IMAGE_OS_VERSION, state=$IMAGE_STATE"
case "$IMAGE_NAME" in
  *aarch64*) ;;
  *) die "Pinned image is not ARM (display name does not contain aarch64: $IMAGE_NAME) — refusing to launch, check the OCID copied from Console" ;;
esac
case "$IMAGE_NAME" in
  *Minimal*) die "Pinned image is a Minimal variant ($IMAGE_NAME) — refusing to launch, the spec requires the full (non-Minimal) Ubuntu 24.04 ARM image" ;;
esac
case "$IMAGE_OS $IMAGE_OS_VERSION" in
  "Ubuntu 24.04") ;;
  *) die "Pinned image is not Ubuntu 24.04 (got OS=$IMAGE_OS version=$IMAGE_OS_VERSION, name=$IMAGE_NAME) — refusing to launch" ;;
esac
if [ "$IMAGE_STATE" != "AVAILABLE" ]; then
  die "Pinned image is not AVAILABLE (state=$IMAGE_STATE, name=$IMAGE_NAME) — refusing to launch"
fi
IMAGE_ID="$PINNED_IMAGE_OCID"
log "Image resolved (pinned): $IMAGE_NAME"

log "Checking whether instance $INSTANCE_NAME already exists ..."
EXISTING="$(oci compute instance list --compartment-id "$COMPARTMENT_OCID" --display-name "$INSTANCE_NAME" --query 'data[?lifecycle-state!=`TERMINATED`].id' --raw-output 2>>"$LOG_FILE" || true)"
if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ]; then
  log "Instance $INSTANCE_NAME already exists — exiting without creating a duplicate."
  write_result "ALREADY_EXISTS"
  exit 0
fi
log "No existing instance named $INSTANCE_NAME found. Starting attempts."

ATTEMPT=0
while true; do
  NOW_EPOCH="$(date +%s)"
  ELAPSED_MINUTES=$(( (NOW_EPOCH - START_EPOCH) / 60 ))
  if [ "$ELAPSED_MINUTES" -ge "$MAX_RUNTIME_MINUTES" ]; then
    log "Time budget (${MAX_RUNTIME_MINUTES} min) reached after $ATTEMPT attempts. Exiting cleanly — the next scheduled run will resume."
    write_result "TIMEOUT"
    exit 0
  fi

  ATTEMPT=$((ATTEMPT + 1))
  log "Attempt $ATTEMPT: launching $INSTANCE_NAME (2 OCPU / 12 GB, $IMAGE_NAME) ..."
  OUT="$(oci compute instance launch \
    --availability-domain "$AD_NAME" \
    --compartment-id "$COMPARTMENT_OCID" \
    --shape VM.Standard.A1.Flex \
    --shape-config '{"ocpus":2,"memoryInGBs":12}' \
    --image-id "$IMAGE_ID" \
    --subnet-id "$SUBNET_OCID" \
    --assign-public-ip true \
    --display-name "$INSTANCE_NAME" \
    --ssh-authorized-keys-file "$SSH_PUBLIC_KEY_FILE" 2>&1)"
  STATUS=$?
  echo "$OUT" >> "$LOG_FILE"

  if [ $STATUS -eq 0 ]; then
    log "SUCCESS on attempt $ATTEMPT — instance launch accepted."
    log "Reminder: public ingress is currently blocked on the Default Security List, so SSH from the internet will be blocked until an SSH ingress rule is added back."
    write_result "SUCCESS"
    exit 0
  fi

  if printf '%s' "$OUT" | grep -qiE 'Out of capacity|Out of host capacity'; then
    log "Attempt $ATTEMPT failed: Out of capacity in AD-1. Sleeping ${SLEEP_SECONDS}s, then retrying..."
    sleep "$SLEEP_SECONDS"
    continue
  fi
  if printf '%s' "$OUT" | grep -qiE 'LimitExceeded|service limit'; then
    log "Attempt $ATTEMPT failed with a limit error (not capacity). STOPPING — check Console > Instances and Limits. Full error is in $LOG_FILE."
    write_result "FAILED"
    exit 2
  fi

  log "Attempt $ATTEMPT failed with a NON-capacity error. STOPPING. Full error is in $LOG_FILE."
  printf '%s\n' "$OUT" | head -n 20 | tee -a "$LOG_FILE"
  write_result "FAILED"
  exit 3
done
