#!/usr/bin/env bash

################################################################
# 03-approve-csr.sh
#
# Run this ON THE POWERVS BASTION (67.18.71.69) as root,
# AFTER the VPC VSIs have been created and ~2-3 minutes have
# passed for them to boot and contact the MachineConfig Server.
#
# What it does (mirrors modules/7_post):
#   1. Fixes /etc/resolv.conf to IBM Cloud DNS.
#   2. Loops, approving pending CSRs for nodes whose name starts
#      with NAME_PREFIX.  Handles both bootstrap CSRs
#      (system:serviceaccount:openshift-machine-config-operator:node-bootstrapper)
#      and node identity CSRs (system:node:<name>).
#   3. Waits until all expected workers show Ready.
#   4. Applies topology/region/zone labels to the new amd64 nodes.
#   5. Prints a summary.
#
# NOTE: This does NOT update IBM Cloud Load Balancers – that is
# only needed if you are using UPI-generated LBs with the
# *-ocp-sec-group pattern.  If you have your own LB or are using
# NodePort / Routes only, skip that step.
################################################################

set -euo pipefail

### ── YOUR ENVIRONMENT ─────────────────────────────────────────
# Must match the NAME_PREFIX used in 02-create-vpc-workers.sh
NAME_PREFIX="dal14-vpc-worker"

# How many workers you created in 02-create-vpc-workers.sh
WORKER_COUNT=1

# VPC region and zone (for topology labels)
VPC_REGION="us-south"
VPC_ZONE="us-south-2"

# Worker profile (for instance-type labels)
WORKER_PROFILE="bx2-4x16"

# Max minutes to wait for all workers to become Ready
MAX_WAIT_MINUTES=60
### ─────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%T)] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%T)] WARN: $*${NC}"; }
die()  { echo -e "${RED}[$(date +%T)] ERROR: $*${NC}"; exit 1; }

[[ $EUID -ne 0 ]] && die "Run as root"
command -v oc >/dev/null || die "oc not found"

################################################################
# FIX RESOLV.CONF  (mirrors approve_and_issue.sh line 8-12)
################################################################
log "Ensuring /etc/resolv.conf uses IBM Cloud DNS"
cat > /etc/resolv.conf <<EOF
nameserver 161.26.0.10
nameserver 161.26.0.11
nameserver 127.0.0.1
EOF

################################################################
# HELPER: approve all pending CSRs matching our prefix
################################################################
approve_matching_csrs() {
  local APPROVED=0

  # Pass 1 – bootstrapper CSRs: decode the CSR and match CN
  local JSON_BODY
  JSON_BODY=$(oc get csr -o json | jq -r '
    .items[]
    | select(.spec.username == "system:serviceaccount:openshift-machine-config-operator:node-bootstrapper")
    | select(.status == {})
    | "\(.metadata.name),\(.spec.request)"' 2>/dev/null || true)

  while IFS= read -r LINE; do
    [[ -z "${LINE}" ]] && continue
    CSR_NAME=$(echo "${LINE}" | cut -d',' -f1)
    CSR_B64=$(echo "${LINE}"  | cut -d',' -f2)
    NODE_NAME=$(echo "${CSR_B64}" | base64 -d 2>/dev/null \
      | openssl req -text -noout 2>/dev/null \
      | grep 'Subject:' | awk '{print $NF}' || true)
    log "  Bootstrapper CSR ${CSR_NAME} → subject: ${NODE_NAME}"
    if echo "${NODE_NAME}" | grep -q "system:node:${NAME_PREFIX}"; then
      log "  Approving bootstrapper CSR: ${CSR_NAME}"
      oc adm certificate approve "${CSR_NAME}" 2>/dev/null || true
      APPROVED=$((APPROVED+1))
    fi
  done <<< "${JSON_BODY}"

  # Pass 2 – node identity CSRs: match by username directly
  for ((idx=0; idx<WORKER_COUNT; idx++)); do
    local NODE_USERNAME="system:node:${NAME_PREFIX}-${idx}"
    for CSR_NAME in $(oc get csr -o json | jq -r \
      --arg u "${NODE_USERNAME}" \
      '.items[] | select(.spec.username == $u) | select(.status == {}) | .metadata.name' \
      2>/dev/null || true); do
      log "  Approving node CSR: ${CSR_NAME} (${NODE_USERNAME})"
      oc adm certificate approve "${CSR_NAME}" 2>/dev/null || true
      APPROVED=$((APPROVED+1))
    done
  done

  echo "${APPROVED}"
}

################################################################
# MAIN LOOP — approve CSRs until all workers are Ready
################################################################
log "Waiting for ${WORKER_COUNT} worker(s) with prefix '${NAME_PREFIX}' to become Ready"
log "  (max ${MAX_WAIT_MINUTES} minutes)"

MAX_ITERATIONS=$(( MAX_WAIT_MINUTES * 2 ))   # check every 30 s
ITERATION=0

while true; do
  ITERATION=$((ITERATION+1))

  # Count Ready amd64 nodes matching our prefix
  READY_COUNT=$(oc get nodes -l kubernetes.io/arch=amd64 --no-headers 2>/dev/null \
    | grep "${NAME_PREFIX}" | grep -v NotReady | grep -c Ready || true)

  log "Iteration ${ITERATION}/${MAX_ITERATIONS}: ${READY_COUNT}/${WORKER_COUNT} workers Ready"

  if [[ "${READY_COUNT}" -ge "${WORKER_COUNT}" ]]; then
    log "All ${WORKER_COUNT} workers are Ready!"
    break
  fi

  # Show current node states
  log "  Current node state:"
  oc get nodes -l kubernetes.io/arch=amd64 --no-headers 2>/dev/null \
    | grep "${NAME_PREFIX}" || warn "  No matching amd64 nodes yet"

  log "  Pending CSRs:"
  oc get csr --no-headers 2>/dev/null | grep -i pending || warn "  No pending CSRs"

  # Approve any pending CSRs
  APPROVED=$(approve_matching_csrs)
  if [[ "${APPROVED}" -gt 0 ]]; then
    log "  Approved ${APPROVED} CSR(s) this round"
  fi

  if [[ "${ITERATION}" -ge "${MAX_ITERATIONS}" ]]; then
    warn "Exceeded ${MAX_WAIT_MINUTES} min wait. Current state:"
    oc get nodes -l kubernetes.io/arch=amd64 || true
    oc get csr || true
    die "Workers did not reach Ready in time. Check 'oc describe node <name>' and VSI console for boot errors."
  fi

  sleep 30
done

################################################################
# APPLY TOPOLOGY LABELS  (mirrors ansible/post/tasks/main.yml)
################################################################
log "Applying topology labels to new amd64 nodes"

NODE_LABELS=(
  "topology.kubernetes.io/region=${VPC_REGION}"
  "topology.kubernetes.io/zone=${VPC_ZONE}"
  "failure-domain.beta.kubernetes.io/region=${VPC_REGION}"
  "failure-domain.beta.kubernetes.io/zone=${VPC_ZONE}"
  "node.kubernetes.io/instance-type=${WORKER_PROFILE}"
  "beta.kubernetes.io/instance-type=${WORKER_PROFILE}"
  "vpc-block-csi-driver-labels=false"
)

for NODE in $(oc get nodes -l kubernetes.io/arch=amd64 --no-headers \
              | grep "${NAME_PREFIX}" | awk '{print $1}'); do
  log "  Labeling node: ${NODE}"
  oc label node "${NODE}" "${NODE_LABELS[@]}" --overwrite
done

################################################################
# SUMMARY
################################################################
log ""
log "════════════════════════════════════════════════════════"
log "  CSR approval complete – final node state:"
oc get nodes -l kubernetes.io/arch=amd64 || true
log ""
log "  Verify cluster operators:"
log "    oc get co"
log ""
log "  If you have UPI-generated IBM Cloud Load Balancers"
log "  (*-internal-loadbalancer / *-external-loadbalancer),"
log "  run update_lbs.sh from modules/7_post/ibmcloud_lb/files/"
log "  to register the new worker IPs in the ingress pools."
log "════════════════════════════════════════════════════════"
