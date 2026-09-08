#!/usr/bin/env bash

################################################################
# run-all.sh
#
# Master orchestration script.
# Runs all three stages to add VPC (x86/amd64) worker nodes
# to an existing PowerVS OpenShift cluster.
#
# STAGE 1 (bastion)  – 01-prepare-bastion.sh
#   Run ON the PowerVS bastion (ssh root@67.18.71.69).
#   Sets up ignition server, MCP migration, OVN patch, chrony.
#
# STAGE 2 (anywhere) – 02-create-vpc-workers.sh
#   Run ANYWHERE with ibmcloud CLI + your API key.
#   Creates VPC VSIs with the correct ignition stub.
#
# STAGE 3 (bastion)  – 03-approve-csr.sh
#   Run ON the PowerVS bastion.
#   Approves node CSRs and applies topology labels.
#
# Usage:
#   # Run stage 1 on the bastion:
#   bash run-all.sh bastion-prep
#
#   # Run stage 2 (from anywhere with ibmcloud CLI):
#   IBMCLOUD_API_KEY=<key> bash run-all.sh create-workers
#
#   # Run stage 3 on the bastion (after VSIs boot, ~3 min):
#   bash run-all.sh approve-csr
#
#   # Run stages 2+3 back-to-back from bastion
#   # (bastion must have ibmcloud CLI installed):
#   IBMCLOUD_API_KEY=<key> bash run-all.sh create-and-approve
################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()     { echo -e "${GREEN}[$(date +%T)] $*${NC}"; }
header()  { echo -e "\n${BOLD}══════════════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}  $*${NC}"; \
            echo -e "${BOLD}══════════════════════════════════════════════════${NC}\n"; }
die()     { echo -e "${RED}[$(date +%T)] ERROR: $*${NC}"; exit 1; }

COMMAND="${1:-help}"

case "${COMMAND}" in

  bastion-prep)
    header "STAGE 1 — Bastion Preparation"
    bash "${SCRIPT_DIR}/01-prepare-bastion.sh"
    ;;

  create-workers)
    header "STAGE 2 — Create VPC Worker VSIs"
    bash "${SCRIPT_DIR}/02-create-vpc-workers.sh"
    ;;

  approve-csr)
    header "STAGE 3 — Approve CSRs and Label Nodes"
    bash "${SCRIPT_DIR}/03-approve-csr.sh"
    ;;

  create-and-approve)
    header "STAGE 2 — Create VPC Worker VSIs"
    bash "${SCRIPT_DIR}/02-create-vpc-workers.sh"
    log "Waiting 3 minutes for VSIs to boot before approving CSRs..."
    sleep 180
    header "STAGE 3 — Approve CSRs and Label Nodes"
    bash "${SCRIPT_DIR}/03-approve-csr.sh"
    ;;

  help|*)
    echo ""
    echo -e "${BOLD}Usage: bash run-all.sh <command>${NC}"
    echo ""
    echo "Commands:"
    echo "  bastion-prep        Run stage 1 on the PowerVS bastion"
    echo "  create-workers      Run stage 2 (requires ibmcloud CLI + IBMCLOUD_API_KEY)"
    echo "  approve-csr         Run stage 3 on the PowerVS bastion"
    echo "  create-and-approve  Run stages 2 then 3 (requires ibmcloud CLI)"
    echo ""
    echo "Typical workflow:"
    echo "  1. SSH to bastion:  bash run-all.sh bastion-prep"
    echo "  2. From laptop:     IBMCLOUD_API_KEY=xxx bash run-all.sh create-workers"
    echo "  3. SSH to bastion:  bash run-all.sh approve-csr"
    echo ""
    ;;
esac
