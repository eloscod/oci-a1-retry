#!/bin/bash
###############################################################################
# OCI A1.Flex single-attempt script — designed for GitHub Actions.
#
# Tries every AD x size combo ONCE, then exits. GitHub Actions calls this
# on a schedule (e.g. every 15 min), so repeated invocations over 24h+
# effectively recreate the "infinite retry" loop — but running on GitHub's
# servers instead of your own PC.
#
# On success: writes instance details to instance_result.txt and exits 0.
# On failure: exits 1 (normal — just means try again next scheduled run).
###############################################################################

set -uo pipefail

# Config comes from environment variables, set via GitHub Actions secrets.
: "${COMPARTMENT_ID:?Missing COMPARTMENT_ID}"
: "${SUBNET_ID:?Missing SUBNET_ID}"
: "${IMAGE_ID:?Missing IMAGE_ID}"
: "${SSH_PUBLIC_KEY:?Missing SSH_PUBLIC_KEY}"
DISPLAY_NAME="${DISPLAY_NAME:-a1-flex-instance}"

SIZE_COMBOS=("1:6" "2:12" "4:24")

echo "Fetching availability domains..."
AD_LIST=$(oci iam availability-domain list \
  --compartment-id "$COMPARTMENT_ID" \
  --query "data[].name" --raw-output | tr -d '[]" ' | tr ',' '\n')

if [[ -z "$AD_LIST" ]]; then
  echo "ERROR: Could not fetch availability domains."
  exit 1
fi

echo "Availability domains: $AD_LIST"
echo "Size combos: ${SIZE_COMBOS[*]}"
echo ""

for COMBO in "${SIZE_COMBOS[@]}"; do
  OCPUS="${COMBO%%:*}"
  MEMORY_IN_GBS="${COMBO##*:}"

  for AD in $AD_LIST; do
    echo "Trying ${OCPUS} OCPU / ${MEMORY_IN_GBS}GB in AD: $AD ..."

    OUTPUT=$(oci compute instance launch \
      --compartment-id "$COMPARTMENT_ID" \
      --availability-domain "$AD" \
      --shape "VM.Standard.A1.Flex" \
      --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_IN_GBS}" \
      --subnet-id "$SUBNET_ID" \
      --image-id "$IMAGE_ID" \
      --display-name "${DISPLAY_NAME}-${OCPUS}ocpu-${MEMORY_IN_GBS}gb" \
      --assign-public-ip true \
      --metadata "{\"ssh_authorized_keys\": \"$SSH_PUBLIC_KEY\"}" \
      --wait-for-state RUNNING 2>&1)

    if echo "$OUTPUT" | grep -q '"lifecycle-state": "RUNNING"'; then
      echo "✅ SUCCESS! Instance launched: ${OCPUS} OCPU / ${MEMORY_IN_GBS}GB in $AD"
      {
        echo "SUCCESS: Instance launched"
        echo "Size: ${OCPUS} OCPU / ${MEMORY_IN_GBS}GB"
        echo "AD: $AD"
        echo "$OUTPUT" | grep -E '"id"|"display-name"|"public-ip"'
      } > instance_result.txt
      exit 0
    elif echo "$OUTPUT" | grep -qi "Out of capacity\|Out of host capacity"; then
      echo "  ✗ Out of capacity. Trying next..."
    elif echo "$OUTPUT" | grep -qi "LimitExceeded"; then
      echo "  ✗ LimitExceeded — quota may already be used. Trying next..."
    else
      echo "  ✗ Unexpected error:"
      echo "$OUTPUT" | head -n 15
    fi
  done
done

echo ""
echo "No capacity found this pass. Will retry on next scheduled run."
exit 1
