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

log "Resolving latest Canonical Ubuntu 24.04 (non-Minimal) ARM image ..."
# 2026-11-01 first Actions run failed here, even though the same image
# (Canonical Ubuntu 24.04, build 2026.10.27-0, ARM) was verified in the
# browser Create form. The old query was too narrow: it filtered by
# --operating-system-version 24.04 AND --shape VM.Standard.A1.Flex AND
# sort, and any one of those filters returning nothing (or a paginated
# first page without the ARM build) made the whole resolution fail with
# no diagnostic output. The new logic is deliberately broad, then
# filters in jq, with fallbacks and diagnostic logging (display names
# are public, not secrets, so listing them in the log is safe):
#   1. List ALL Ubuntu images in the tenancy ( --all, no version/shape
#      filter, so pagination or a filter mismatch cannot hide the image).
#   2. Log how many were returned and the newest 20 display names.
#   3. Pick, newest first by time-created:
#      a) Canonical-Ubuntu-24.04 + aarch64 + not Minimal (the exact ARM build)
#      b) Canonical-Ubuntu-24.04 + not Minimal (any arch, if aarch64 naming changes)
#      c) Ubuntu 24.04 + aarch64 + not Minimal (if the Canonical prefix changes)
# NOTE on the 2026-11-01 second failure: the previous version used
# --all here and returned nothing at all. --all may not be valid for
# this list command in the installed OCI CLI version, and the old code
# hid the real oci error (stderr went only to retry.log, and the
# workflow tail showed only the die() line). This version therefore:
#   1. Runs WITHOUT --all (the original form, which at least returned
#      JSON on the first run).
#   2. Captures the oci exit code and stderr separately, and logs the
#      stderr lines visibly (with any OCID-looking strings redacted,
#      since Actions logs for a public repo are public).
#   3. If the broad list still returns nothing, retries the original
#      version+shape filtered list before giving up, so one filter
#      failure alone cannot kill the run.
IMAGE_ERR_FILE="$(mktemp)"
IMAGE_JSON="$(oci compute image list --compartment-id "$COMPARTMENT_OCID" --operating-system Ubuntu 2>"$IMAGE_ERR_FILE")"
IMAGE_STATUS=$?
if [ "$IMAGE_STATUS" -ne 0 ] || [ -z "$IMAGE_JSON" ]; then
  log "oci compute image list (broad) failed or returned nothing, exit $IMAGE_STATUS"
  if [ -s "$IMAGE_ERR_FILE" ]; then
    sed -E 's/ocid1\.[a-zA-Z0-9._-]+/<OCID>/g' "$IMAGE_ERR_FILE" | while IFS= read -r line; do log "  oci error: $line"; done
  else
    log "  oci error: (no stderr captured)"
  fi
  log "Trying fallback image list (version 24.04 + shape A1.Flex)..."
  IMAGE_JSON="$(oci compute image list --compartment-id "$COMPARTMENT_OCID" --operating-system Ubuntu --operating-system-version 24.04 --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC 2>"$IMAGE_ERR_FILE")"
  IMAGE_STATUS=$?
  if [ "$IMAGE_STATUS" -ne 0 ] || [ -z "$IMAGE_JSON" ]; then
    log "Fallback image list also failed or returned nothing, exit $IMAGE_STATUS"
    if [ -s "$IMAGE_ERR_FILE" ]; then
      sed -E 's/ocid1\.[a-zA-Z0-9._-]+/<OCID>/g' "$IMAGE_ERR_FILE" | while IFS= read -r line; do log "  oci error: $line"; done
    fi
    die "oci compute image list returned nothing — see the oci error lines above for the real cause (auth / config / region / CLI arguments)"
  fi
fi
rm -f "$IMAGE_ERR_FILE"
IMAGE_COUNT="$(printf '%s' "$IMAGE_JSON" | jq -r '.data | length' 2>/dev/null || echo "?")"
log "Ubuntu images returned by OCI: $IMAGE_COUNT"
printf '%s' "$IMAGE_JSON" | jq -r '.data | sort_by(.["time-created"]) | reverse | .[0:20][] | "\(.["time-created"]) \(.["display-name"])"' 2>/dev/null | while IFS= read -r line; do log "  image: $line"; done
pick_image() {
  # $1 = jq filter expression; prints "id<TAB>display-name" for the newest match, or nothing.
  printf '%s' "$IMAGE_JSON" | jq -r "
    .data
    | sort_by(.\"time-created\") | reverse
    | map(select($1))
    | .[0] // empty
    | \"\(.id)\t\(.\"display-name\")\"
  " 2>/dev/null
}
IMAGE_PICK="$(pick_image '.["display-name"] | test("Canonical-Ubuntu-24\\.04") and test("aarch64") and (test("Minimal") | not)')"
if [ -z "$IMAGE_PICK" ]; then
  log "Primary image filter (Canonical + 24.04 + aarch64 + not Minimal) found nothing; trying fallback (Canonical + 24.04 + not Minimal)..."
  IMAGE_PICK="$(pick_image '.["display-name"] | test("Canonical-Ubuntu-24\\.04") and (test("Minimal") | not)')"
fi
if [ -z "$IMAGE_PICK" ]; then
  log "Fallback 1 found nothing; trying fallback 2 (Ubuntu 24.04 + aarch64 + not Minimal)..."
  IMAGE_PICK="$(pick_image '.["display-name"] | test("24\\.04") and test("aarch64") and (test("Minimal") | not)')"
fi
IMAGE_ID="$(printf '%s' "$IMAGE_PICK" | cut -f1)"
IMAGE_NAME="$(printf '%s' "$IMAGE_PICK" | cut -f2-)"
[ -n "$IMAGE_ID" ] && [ "$IMAGE_ID" != "null" ] || die "Could not find a Canonical Ubuntu 24.04 (non-Minimal) ARM image — see the image list logged above for what OCI actually returned in this region"
log "Image resolved: $IMAGE_NAME"

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
