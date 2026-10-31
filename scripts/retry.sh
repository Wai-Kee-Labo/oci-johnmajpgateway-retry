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
# NOTE on the 2026-11-01 failures, in order:
#   1. First run: full list with version+shape filters returned JSON
#      but the jq name filter found no match.
#   2. Second run: full list with --all returned nothing.
#   3. Third run (log 17:50 UTC): full list WITHOUT --all, broad AND
#      version+shape fallback, BOTH returned empty stdout with exit 0
#      and no stderr. That is the key clue: VCN / subnet / AD lists
#      in this same script DO succeed, and they all use
#      --query ... --raw-output. The full-JSON image list does not.
#      So this version tries the --query form FIRST (the proven
#      pattern in this environment), asking OCI for only id,
#      display-name and time-created per image, then normalises that
#      array back to the {data: [...]} shape the picker expects.
#      It logs every attempt (exit code, output length, count) so the
#      next log will show which form actually works, instead of
#      dying on the first empty output. OCID-looking strings are
#      redacted in logged stderr, since Actions logs for a public
#      repo are public.
IMAGE_ERR_FILE="$(mktemp)"
IMAGE_JSON=""
try_list() {
  # $1 = label; the caller sets TRY_ARGS as an array before calling.
  # IMPORTANT: diagnostic lines inside this function must NOT go to
  # stdout, because the caller captures this function's stdout as the
  # oci JSON output. They go to retry.log AND to stderr (which GitHub
  # Actions still shows in the step log), via tee >&2.
  local label="$1"
  local out status len ts
  out="$(oci compute image list --compartment-id "$COMPARTMENT_OCID" "${TRY_ARGS[@]}" 2>"$IMAGE_ERR_FILE")"
  status=$?
  len=${#out}
  ts="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "[$ts] image list try [$label]: exit $status, stdout length $len" | tee -a "$LOG_FILE" >&2
  if [ -s "$IMAGE_ERR_FILE" ]; then
    sed -E 's/ocid1\.[a-zA-Z0-9._-]+/<OCID>/g' "$IMAGE_ERR_FILE" | while IFS= read -r line; do echo "[$ts]   oci error: $line" | tee -a "$LOG_FILE" >&2; done
  fi
  printf '%s' "$out"
}
# Try 1: query-filtered list (proven pattern) — returns a JSON array
# of {id, name, time}, which we normalise to {data: [...]}.
TRY_ARGS=(--operating-system Ubuntu --query 'data[].{id: id, name: "display-name", time: "time-created"}')
QUERY_OUT="$(try_list "query id/name/time")"
if [ -n "$QUERY_OUT" ]; then
  IMAGE_JSON="$(printf '%s' "$QUERY_OUT" | jq '{data: map({id: .id, "display-name": .name, "time-created": .time})}' 2>/dev/null || echo "")"
  if [ -n "$IMAGE_JSON" ]; then
    log "image list try [query id/name/time]: normalised data length $(printf '%s' "$IMAGE_JSON" | jq -r '.data | length' 2>/dev/null || echo '?')"
  fi
fi
# Try 2: full list, broad (no version/shape filter).
if [ -z "$IMAGE_JSON" ]; then
  TRY_ARGS=(--operating-system Ubuntu)
  IMAGE_JSON="$(try_list "full broad")"
fi
# Try 3: full list, version+shape filtered (original form).
if [ -z "$IMAGE_JSON" ]; then
  TRY_ARGS=(--operating-system Ubuntu --operating-system-version 24.04 --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC)
  IMAGE_JSON="$(try_list "full version+shape")"
fi
rm -f "$IMAGE_ERR_FILE"
if [ -z "$IMAGE_JSON" ]; then
  die "oci compute image list returned nothing in all three forms (query, full broad, full version+shape) — all exited 0 with no stderr in the previous run, so the list API itself is returning empty stdout in this runner; check the try logs above and, if they are all empty, use a pinned image OCID from Console > Compute > Images instead"
fi
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
