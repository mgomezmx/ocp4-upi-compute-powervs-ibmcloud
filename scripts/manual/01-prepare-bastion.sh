#!/usr/bin/env bash

################################################################
# 01-prepare-bastion.sh
#
# Run this ON THE POWERVS BASTION (67.18.71.69) as root.
#
# What it does (mirrors modules/4_pvs_support in order):
#   1. Adds static routes on the bastion's internal NIC so it
#      can route back to all three VPC worker subnets via the
#      PowerVS gateway (192.168.100.1).
#   2. Annotates openshift-cluster-csi-drivers to ppc64le only.
#   3. Migrates preinstall-worker-kargs out of worker MCP into
#      a dedicated 'power' MCP (only if it exists).
#   4. Patches OVN-Kubernetes routingViaHost=true.
#   5. Updates chrony to allow NTP from VPC subnets.
#   6. Refreshes /var/www/html/ignition/worker.ign from the
#      live MachineConfig Server (waits for mpath to be gone).
#   7. Verifies Apache is serving the file on port 8080.
#
# Prerequisites on the bastion:
#   - oc CLI logged in (kubeconfig present)
#   - ansible installed  (yum install -y ansible)
#   - httpd installed and running on port 8080
#   - Transit Gateway connecting VPC <-> PowerVS already active
################################################################

set -euo pipefail

### ── EDIT THESE IF NEEDED ─────────────────────────────────────
BASTION_PRIVATE_IP="192.168.100.122"    # env3 bastion private IP
PVS_GATEWAY="192.168.100.1"             # first host in /24 = gateway

# VPC worker subnets (all three zones; comment out zones you skip)
VPC_SUBNETS=(
  "10.240.0.0/18"    # us-south-1
  "10.240.64.0/18"   # us-south-2
  "10.240.128.0/18"  # us-south-3
)

# Internal NIC name on the bastion (the one that holds 192.168.100.122)
# The script auto-detects it; override here if needed.
INT_IFACE=""
### ─────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%T)] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%T)] WARN: $*${NC}"; }
die()  { echo -e "${RED}[$(date +%T)] ERROR: $*${NC}"; exit 1; }

[[ $EUID -ne 0 ]] && die "Run as root"
command -v oc      >/dev/null || die "oc not found – log in to the cluster first"
command -v ansible >/dev/null || die "ansible not found – run: yum install -y ansible"

################################################################
# STEP 1 — Add static routes on bastion's internal NIC
################################################################
log "STEP 1: Adding static routes to VPC subnets on bastion"

# Auto-detect the NIC that owns BASTION_PRIVATE_IP
if [[ -z "${INT_IFACE}" ]]; then
  INT_IFACE=$(nmcli -t -f NAME,IP4.ADDRESS connection show --active \
    | awk -F: -v ip="${BASTION_PRIVATE_IP}" '$2 ~ ip {print $1; exit}')
fi

if [[ -z "${INT_IFACE}" ]]; then
  die "Could not detect internal NIC for ${BASTION_PRIVATE_IP}. Set INT_IFACE manually."
fi
log "  Internal NIC: ${INT_IFACE}"

for SUBNET in "${VPC_SUBNETS[@]}"; do
  # Check if route already exists
  if ip route show | grep -q "^${SUBNET}"; then
    warn "  Route ${SUBNET} already present, skipping"
    continue
  fi
  log "  Adding route: ${SUBNET} via ${PVS_GATEWAY} on ${INT_IFACE}"
  nmcli connection modify "${INT_IFACE}" +ipv4.routes "${SUBNET} ${PVS_GATEWAY}"
done

nmcli connection up "${INT_IFACE}" || true
sleep 5
nmcli connection up "${INT_IFACE}" || true

log "  Current routes:"
ip route show | grep -E "(10\.240\.|192\.168\.)" || true

################################################################
# STEP 2 — Limit CSI driver to ppc64le nodes only
################################################################
log "STEP 2: Annotating openshift-cluster-csi-drivers namespace to ppc64le"

CURRENT=$(oc get ns openshift-cluster-csi-drivers \
  -o jsonpath='{.metadata.annotations.scheduler\.alpha\.kubernetes\.io/node-selector}' 2>/dev/null || true)

if [[ "${CURRENT}" == "kubernetes.io/arch=ppc64le" ]]; then
  log "  Already annotated, skipping"
else
  oc annotate ns openshift-cluster-csi-drivers \
    scheduler.alpha.kubernetes.io/node-selector=kubernetes.io/arch=ppc64le \
    --overwrite
  log "  Done"
fi

################################################################
# STEP 3 — MCP migration (move preinstall-worker-kargs → power MCP)
################################################################
log "STEP 3: Checking MCP / preinstall-worker-kargs"

VAL=$(oc get mc -o yaml 2>/dev/null | grep -c preinstall-worker-kargs || true)
if [[ "${VAL}" -ge 1 ]]; then
  log "  preinstall-worker-kargs found – running MCP migration"

  # Label all existing ppc64le nodes
  log "  Labeling ppc64le nodes with node-role.kubernetes.io/power="
  for NODE in $(oc get nodes -l kubernetes.io/arch=ppc64le,node-role.kubernetes.io/worker \
                  --no-headers=true | awk '{print $1}'); do
    log "    Labeling: ${NODE}"
    oc label node "${NODE}" node-role.kubernetes.io/power= --overwrite
  done

  # Create the 'power' MachineConfigPool
  log "  Creating 'power' MachineConfigPool"
  oc apply -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: power
spec:
  maxUnavailable: 2
  machineConfigSelector:
    matchExpressions:
    - key: machineconfiguration.openshift.io/role
      operator: In
      values: [worker, power]
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/power: ""
EOF

  # Create the power-specific kargs MC
  log "  Creating preinstall-power-kargs MachineConfig"
  oc apply -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: power
  name: preinstall-power-kargs
spec:
  kernelArguments:
  - rd.multipath=default
  - root=/dev/disk/by-label/dm-mpath-root
EOF

  # Wait for power MCP to stabilize
  log "  Waiting for 'power' MCP to stabilize (up to 25 min)..."
  sleep 60
  oc wait --for=condition=Updated=True  --timeout=25m mcp/power || true
  oc wait --for=condition=Updating=False --timeout=5m  mcp/power || true

  # Delete the worker kargs
  log "  Deleting preinstall-worker-kargs from worker MCP"
  oc delete mc preinstall-worker-kargs

  # Wait for worker MCP to stabilize
  log "  Waiting for 'worker' MCP to stabilize (up to 25 min)..."
  oc wait --for=condition=Updated=True  --timeout=25m mcp/worker || true
  oc wait --for=condition=Updating=False --timeout=5m  mcp/worker || true

  log "  Stabilization pause (3 min)..."
  sleep 180

  log "  MCP status:"
  oc get mcp
else
  log "  preinstall-worker-kargs not found – worker MCP already clean"
  oc get mc | grep -v rendered- | grep worker || true
fi

################################################################
# STEP 4 — OVN routingViaHost
################################################################
log "STEP 4: Patching OVN-Kubernetes routingViaHost=true"

CURRENT_RVH=$(oc get network.operator/cluster \
  -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}' 2>/dev/null || true)

if [[ "${CURRENT_RVH}" == "true" ]]; then
  log "  routingViaHost already true, skipping"
else
  oc patch network.operator/cluster --type merge -p \
    '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'
  log "  Done – waiting 60s for network operator to reconcile"
  sleep 60
fi

################################################################
# STEP 5 — Update chrony to allow VPC subnets
################################################################
log "STEP 5: Updating chrony to allow NTP from VPC subnets"

cp -f /etc/chrony.conf /etc/chrony.conf.backup-$(date +%s) 2>/dev/null || true

for SUBNET in "${VPC_SUBNETS[@]}"; do
  if grep -q "allow ${SUBNET}" /etc/chrony.conf; then
    warn "  chrony already allows ${SUBNET}, skipping"
  else
    log "  Adding: allow ${SUBNET}"
    sed -i "/# Allow NTP client access from local network./a allow ${SUBNET}" /etc/chrony.conf || \
      echo "allow ${SUBNET}" >> /etc/chrony.conf
  fi
done

systemctl restart chronyd
log "  chronyd restarted"

################################################################
# STEP 6 — Refresh worker.ign via MCS
################################################################
log "STEP 6: Refreshing worker ignition file from MachineConfig Server"

# Ensure Apache is serving on 8080
if ! systemctl is-active --quiet httpd; then
  warn "  httpd is not running – attempting to start"
  systemctl enable --now httpd || die "Cannot start httpd"
fi

# Ensure the ignition directory exists
mkdir -p /var/www/html/ignition

# Get MCS internal hostname
MCS_HOST=$(oc whoami --show-server=true | sed 's|/api\.|/api-int.|' | sed 's|:6443||')
log "  MCS hostname: ${MCS_HOST}"

# Wait until worker ignition no longer contains mpath (MCP migration complete)
log "  Waiting for clean worker ignition (no mpath) at ${MCS_HOST}:22623..."
RETRIES=120
DELAY=15
for ((i=1; i<=RETRIES; i++)); do
  HTTP_CODE=$(curl -sk -o /tmp/worker_ign_check.json -w "%{http_code}" \
    -H 'Accept: application/vnd.coreos.ignition+json;version=3.2.0' \
    "${MCS_HOST}:22623/config/worker" || true)
  if [[ "${HTTP_CODE}" == "200" ]] && ! grep -q '"mpath"' /tmp/worker_ign_check.json; then
    log "  Clean ignition received (attempt ${i})"
    break
  fi
  if [[ $i -eq $RETRIES ]]; then
    warn "  Timed out waiting for clean ignition – proceeding anyway"
  fi
  echo "  Attempt ${i}/${RETRIES}: HTTP=${HTTP_CODE}, waiting ${DELAY}s..."
  sleep $DELAY
done

# Extract the real worker ignition via oc (uses in-cluster auth, no cert issues)
log "  Extracting worker-user-data secret"
oc extract -n openshift-machine-api secret/worker-user-data \
  --keys=userData --to=- > /var/www/html/ignition/worker.ign

# Fix SELinux and permissions
semanage fcontext -a -t httpd_sys_rw_content_t /var/www/html/ignition/worker.ign 2>/dev/null || true
chown -R apache:apache /var/www
chmod -R u+rwx,g-rx,o-rx /var/www
restorecon -vR /var/www/html/ignition || true

################################################################
# STEP 7 — Verify the ignition server is reachable
################################################################
log "STEP 7: Verifying ignition endpoint"

# Confirm the file is valid JSON
if python3 -m json.tool /var/www/html/ignition/worker.ign > /dev/null 2>&1; then
  log "  worker.ign is valid JSON"
else
  die "  worker.ign is NOT valid JSON – check extraction above"
fi

# Confirm Apache serves it locally
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://localhost:8080/ignition/worker.ign" || true)
if [[ "${HTTP_CODE}" == "200" ]]; then
  log "  ✓ http://localhost:8080/ignition/worker.ign → HTTP 200"
else
  die "  ✗ localhost:8080 returned HTTP ${HTTP_CODE} – check httpd config"
fi

# Quick reachability test from bastion to itself using the private IP
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://${BASTION_PRIVATE_IP}:8080/ignition/worker.ign" || true)
if [[ "${HTTP_CODE}" == "200" ]]; then
  log "  ✓ http://${BASTION_PRIVATE_IP}:8080/ignition/worker.ign → HTTP 200"
else
  warn "  ✗ ${BASTION_PRIVATE_IP}:8080 returned HTTP ${HTTP_CODE} – check firewall"
  log "  Running: firewall-cmd to open port 8080 from VPC subnets"
  for SUBNET in "${VPC_SUBNETS[@]}"; do
    firewall-cmd --add-rich-rule="rule family=ipv4 source address=${SUBNET} port port=8080 protocol=tcp accept" --permanent || true
  done
  firewall-cmd --reload || true
fi

log ""
log "════════════════════════════════════════════════════════"
log "  Bastion preparation complete."
log "  Ignition pointer for VPC VSI user_data:"
log ""
log '  http://'"${BASTION_PRIVATE_IP}"':8080/ignition/worker.ign'
log ""
log "  Paste the following JSON as user_data on your VPC VSIs:"
cat <<IGNEOF

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
IGNEOF
log "════════════════════════════════════════════════════════"
