#!/usr/bin/env bash

################################################################
# 02-create-vpc-workers.sh
#
# Run this ANYWHERE that has the ibmcloud CLI and your API key
# (the bastion works fine; so does your laptop).
#
# What it does (mirrors modules/6_worker + modules/1_vpc_prepare):
#   1. Logs in to IBM Cloud.
#   2. Verifies the VPC routing-table entry to PowerVS CIDR exists
#      (and creates it if missing, unless --skip-route is passed).
#   3. Verifies/creates the worker security group with the correct
#      inbound/outbound rules.
#   4. Confirms the RHCOS image and SSH key exist.
#   5. Builds the ignition stub pointer JSON (plain HTTP to bastion).
#   6. Creates one VPC VSI per worker in the target zone.
#   7. Prints the private IPs of all created VSIs.
#
# Usage:
#   bash 02-create-vpc-workers.sh [--dry-run] [--skip-route] [--skip-sg]
#
#   --dry-run    Print all ibmcloud commands without executing them
#   --skip-route Do not check/create the routing table entry
#   --skip-sg    Do not check/create the security group
################################################################

set -euo pipefail

### ── YOUR ENVIRONMENT ─────────────────────────────────────────
IBMCLOUD_API_KEY="${IBMCLOUD_API_KEY:-}"   # or set here directly

VPC_NAME="ocp-upivpc"
VPC_REGION="us-south"
VPC_ZONE="us-south-2"                     # target zone (us-south-1/2/3)
RESOURCE_GROUP="default"

# Worker VSI settings
WORKER_COUNT=1
WORKER_PROFILE="bx2-4x16"
NAME_PREFIX="dal14-vpc-worker"            # results in dal14-vpc-worker-0, -1, …
RHCOS_IMAGE_NAME="rhcos-420-118"          # partial match OK; script finds the ID
SSH_KEY_NAME="mgg"

# Bastion private IP (the ignition_ip) – MUST be reachable from VPC subnet
BASTION_PRIVATE_IP="192.168.100.122"

# PowerVS machine CIDR – must be routable from VPC via Transit Gateway
POWERVS_MACHINE_CIDR="192.168.100.0/24"

# Security group name to attach – script will create it if absent
WORKER_SG_NAME="${VPC_NAME}-workers-sg"

# VPC subnet for the target zone – script auto-detects the first subnet in
# VPC_ZONE; override here if you want a specific one.
TARGET_SUBNET_NAME=""                     # leave empty for auto-detect
### ─────────────────────────────────────────────────────────────

DRY_RUN=false
SKIP_ROUTE=false
SKIP_SG=false

for arg in "$@"; do
  case $arg in
    --dry-run)    DRY_RUN=true ;;
    --skip-route) SKIP_ROUTE=true ;;
    --skip-sg)    SKIP_SG=true ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%T)] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%T)] WARN: $*${NC}"; }
die()  { echo -e "${RED}[$(date +%T)] ERROR: $*${NC}"; exit 1; }
cmd()  {
  echo -e "${CYAN}  → $*${NC}"
  if [[ "${DRY_RUN}" == "false" ]]; then
    eval "$@"
  fi
}

[[ -z "${IBMCLOUD_API_KEY}" ]] && die "Set IBMCLOUD_API_KEY env var or edit the script"
command -v ibmcloud >/dev/null || die "ibmcloud CLI not found"
command -v jq       >/dev/null || die "jq not found"

################################################################
# LOGIN
################################################################
log "Logging in to IBM Cloud (region: ${VPC_REGION}, rg: ${RESOURCE_GROUP})"
cmd ibmcloud login --apikey "${IBMCLOUD_API_KEY}" -r "${VPC_REGION}" -g "${RESOURCE_GROUP}" -q
cmd ibmcloud plugin install vpc-infrastructure -f -q 2>/dev/null || true
cmd ibmcloud target -r "${VPC_REGION}" -g "${RESOURCE_GROUP}" > /dev/null

################################################################
# LOOK UP VPC
################################################################
log "Looking up VPC: ${VPC_NAME}"
VPC_JSON=$(ibmcloud is vpc "${VPC_NAME}" --output json 2>/dev/null) \
  || die "VPC '${VPC_NAME}' not found in region ${VPC_REGION}"
VPC_ID=$(echo "${VPC_JSON}" | jq -r '.id')
DEFAULT_RT=$(echo "${VPC_JSON}" | jq -r '.default_routing_table.id')
log "  VPC ID: ${VPC_ID}"
log "  Default routing table: ${DEFAULT_RT}"

################################################################
# STEP 1 — Routing table entry to PowerVS CIDR
################################################################
if [[ "${SKIP_ROUTE}" == "true" ]]; then
  warn "STEP 1: Skipping routing table check (--skip-route)"
else
  log "STEP 1: Checking VPC routing table for ${POWERVS_MACHINE_CIDR}"
  EXISTING_ROUTE=$(ibmcloud is vpc-routing-table-routes "${VPC_NAME}" "${DEFAULT_RT}" \
    --output json 2>/dev/null \
    | jq -r --arg dst "${POWERVS_MACHINE_CIDR}" \
      '.[] | select(.destination == $dst) | .id' || true)

  if [[ -n "${EXISTING_ROUTE}" ]]; then
    log "  Route to ${POWERVS_MACHINE_CIDR} already exists (id: ${EXISTING_ROUTE})"
  else
    warn "  Route not found – creating delegate_vpc route to ${POWERVS_MACHINE_CIDR}"
    # Get a subnet in the target zone to infer the zone parameter
    ZONE_SUBNET=$(ibmcloud is subnets --vpc "${VPC_NAME}" --output json \
      | jq -r --arg z "${VPC_ZONE}" '.[] | select(.zone.name == $z) | .id' | head -1)
    [[ -z "${ZONE_SUBNET}" ]] && die "No subnet found in zone ${VPC_ZONE} for VPC ${VPC_NAME}"

    cmd ibmcloud is vpc-routing-table-route-create \
      "${VPC_NAME}" "${DEFAULT_RT}" \
      --zone "${VPC_ZONE}" \
      --destination "${POWERVS_MACHINE_CIDR}" \
      --action delegate_vpc \
      --name "to-powervs-route-manual" \
      --output json
    log "  Route created"
  fi
fi

################################################################
# STEP 2 — Worker Security Group
################################################################
if [[ "${SKIP_SG}" == "true" ]]; then
  warn "STEP 2: Skipping security group check (--skip-sg)"
  log "  Looking up existing SG by name for VSI attachment"
  WORKER_SG_ID=$(ibmcloud is security-groups --vpc "${VPC_NAME}" --output json \
    | jq -r --arg n "${WORKER_SG_NAME}" '.[] | select(.name == $n) | .id') \
    || die "SG '${WORKER_SG_NAME}' not found and --skip-sg passed"
else
  log "STEP 2: Ensuring security group '${WORKER_SG_NAME}' exists"
  WORKER_SG_ID=$(ibmcloud is security-groups --vpc "${VPC_NAME}" --output json \
    | jq -r --arg n "${WORKER_SG_NAME}" '.[] | select(.name == $n) | .id' || true)

  if [[ -z "${WORKER_SG_ID}" ]]; then
    log "  Creating security group: ${WORKER_SG_NAME}"
    WORKER_SG_ID=$(ibmcloud is security-group-create "${WORKER_SG_NAME}" \
      "${VPC_NAME}" --resource-group-name "${RESOURCE_GROUP}" --output json \
      | jq -r '.id')
    log "  Created SG id: ${WORKER_SG_ID}"

    log "  Adding rules..."

    # Outbound all
    cmd ibmcloud is security-group-rule-add "${WORKER_SG_ID}" \
      outbound all --remote "0.0.0.0/0" --output json \> /dev/null

    # Outbound to PowerVS CIDR
    cmd ibmcloud is security-group-rule-add "${WORKER_SG_ID}" \
      outbound all --remote "${POWERVS_MACHINE_CIDR}" --output json \> /dev/null

    # Inbound from own SG (inter-worker)
    cmd ibmcloud is security-group-rule-add "${WORKER_SG_ID}" \
      inbound all --remote "${WORKER_SG_ID}" --output json \> /dev/null

    # Inbound from PowerVS CIDR
    cmd ibmcloud is security-group-rule-add "${WORKER_SG_ID}" \
      inbound all --remote "${POWERVS_MACHINE_CIDR}" --output json \> /dev/null

    log "  Security group rules added"
  else
    log "  Security group already exists: ${WORKER_SG_ID}"
  fi
fi

# Extra check: inbound from bastion private IP for port 22623 (MCS) is needed
# only on the bastion side – VPC workers need OUTBOUND to 22623 already covered.
log "  SG ID to use: ${WORKER_SG_ID}"

################################################################
# STEP 3 — Look up RHCOS image ID
################################################################
log "STEP 3: Looking up RHCOS image '${RHCOS_IMAGE_NAME}'"
RHCOS_IMAGE_ID=$(ibmcloud is images --output json \
  | jq -r --arg n "${RHCOS_IMAGE_NAME}" \
    '.[] | select(.name | startswith($n)) | .id' | head -1 || true)
[[ -z "${RHCOS_IMAGE_ID}" ]] && \
  die "No image found matching '${RHCOS_IMAGE_NAME}' in ${VPC_REGION}"
log "  Image ID: ${RHCOS_IMAGE_ID}"

################################################################
# STEP 4 — Look up SSH key
################################################################
log "STEP 4: Looking up SSH key '${SSH_KEY_NAME}'"
SSH_KEY_ID=$(ibmcloud is keys --output json \
  | jq -r --arg n "${SSH_KEY_NAME}" '.[] | select(.name == $n) | .id' | head -1 || true)
[[ -z "${SSH_KEY_ID}" ]] && die "SSH key '${SSH_KEY_NAME}' not found"
log "  Key ID: ${SSH_KEY_ID}"

################################################################
# STEP 5 — Find the target subnet
################################################################
log "STEP 5: Finding subnet in zone ${VPC_ZONE}"
if [[ -n "${TARGET_SUBNET_NAME}" ]]; then
  SUBNET_ID=$(ibmcloud is subnets --vpc "${VPC_NAME}" --output json \
    | jq -r --arg n "${TARGET_SUBNET_NAME}" '.[] | select(.name == $n) | .id')
else
  SUBNET_ID=$(ibmcloud is subnets --vpc "${VPC_NAME}" --output json \
    | jq -r --arg z "${VPC_ZONE}" '.[] | select(.zone.name == $z) | .id' | head -1)
fi
[[ -z "${SUBNET_ID}" ]] && die "No subnet found in zone ${VPC_ZONE} for VPC ${VPC_NAME}"
log "  Subnet ID: ${SUBNET_ID}"

################################################################
# STEP 6 — Build the ignition stub (plain HTTP pointer to bastion)
################################################################
log "STEP 6: Building ignition stub"

# This is the KEY difference vs. what you were using before:
# - Plain HTTP (not HTTPS) to bastion:8080
# - No inline certificates, no MCS URL
# - httpTotal:15 is the fetch timeout in seconds
IGNITION_STUB=$(cat <<EOF
{
  "ignition": {
    "version": "3.4.0",
    "config": {
      "merge": [
        { "source": "http://${BASTION_PRIVATE_IP}:8080/ignition/worker.ign" }
      ]
    },
    "timeouts": { "httpTotal": 15 }
  },
  "storage": { "files": [] }
}
EOF
)

log "  Ignition stub:"
echo "${IGNITION_STUB}"

# Validate JSON
echo "${IGNITION_STUB}" | python3 -m json.tool > /dev/null \
  || die "Ignition stub is not valid JSON"

################################################################
# STEP 7 — Create VSIs
################################################################
log "STEP 7: Creating ${WORKER_COUNT} VPC worker VSI(s) in ${VPC_ZONE}"

CREATED_IPS=()

for ((i=0; i<WORKER_COUNT; i++)); do
  VSI_NAME="${NAME_PREFIX}-${i}"
  log "  Creating VSI: ${VSI_NAME}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo -e "${CYAN}  [DRY-RUN] ibmcloud is instance-create ${VSI_NAME} ${VPC_NAME} ${VPC_ZONE} ${WORKER_PROFILE} ${SUBNET_ID} --image ${RHCOS_IMAGE_ID} --keys ${SSH_KEY_ID} --sgs ${WORKER_SG_ID} --user-data '<ignition-stub>' --output json${NC}"
    continue
  fi

  INSTANCE_JSON=$(ibmcloud is instance-create \
    "${VSI_NAME}" \
    "${VPC_NAME}" \
    "${VPC_ZONE}" \
    "${WORKER_PROFILE}" \
    "${SUBNET_ID}" \
    --image "${RHCOS_IMAGE_ID}" \
    --keys "${SSH_KEY_ID}" \
    --sgs "${WORKER_SG_ID}" \
    --user-data "${IGNITION_STUB}" \
    --output json)

  INSTANCE_ID=$(echo "${INSTANCE_JSON}" | jq -r '.id')
  log "  Created: ${VSI_NAME} (id: ${INSTANCE_ID})"

  # Wait for the VSI to reach 'running' state
  log "  Waiting for ${VSI_NAME} to start (up to 5 min)..."
  for ((w=1; w<=30; w++)); do
    STATUS=$(ibmcloud is instance "${INSTANCE_ID}" --output json | jq -r '.status')
    if [[ "${STATUS}" == "running" ]]; then
      log "  ${VSI_NAME} is running"
      break
    fi
    echo "    [${w}/30] status=${STATUS}, waiting 10s..."
    sleep 10
  done

  # Get primary private IP
  PRIVATE_IP=$(ibmcloud is instance "${INSTANCE_ID}" --output json \
    | jq -r '.primary_network_interface.primary_ip.address')
  log "  Private IP: ${PRIVATE_IP}"
  CREATED_IPS+=("${VSI_NAME}=${PRIVATE_IP}")
done

################################################################
# SUMMARY
################################################################
log ""
log "════════════════════════════════════════════════════════"
log "  VPC worker VSIs created"
log ""
log "  Zone:    ${VPC_ZONE}"
log "  Subnet:  ${SUBNET_ID}"
log "  Image:   ${RHCOS_IMAGE_ID}"
log "  Profile: ${WORKER_PROFILE}"
log ""
log "  Created workers:"
for ENTRY in "${CREATED_IPS[@]}"; do
  log "    ${ENTRY}"
done
log ""
log "  Next step:"
log "    Wait ~3 minutes, then run 03-approve-csr.sh"
log "    The workers are trying to pull:"
log "    http://${BASTION_PRIVATE_IP}:8080/ignition/worker.ign"
log ""
log "  Verify from the bastion:"
log "    oc get csr   # should show Pending CSRs within ~2 minutes of boot"
log "════════════════════════════════════════════════════════"
