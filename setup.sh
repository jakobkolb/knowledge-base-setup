#!/bin/bash
# =============================================================================
# Idempotent Raspberry Pi Kubernetes Setup Script
# Installs: MicroK8s, kubectl, helm, cert-manager, ArgoCD
# Assumes: Raspberry Pi OS (aarch64), user "jakob"
# =============================================================================

set -euo pipefail

ARGOCD_HOSTNAME="argocd.jakobjkolb.xyz"
NEXTCLOUD_HOSTNAME="shitcloud.hopto.org"
K8S_USER="${SUDO_USER:-jakob}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo -e "\n\033[1;32m==> $*\033[0m"; }
warn() { echo -e "\033[1;33mWARN: $*\033[0m"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0"
    exit 1
  fi
}

# =============================================================================
# PHASE 1: Boot config (requires reboot to take effect)
# =============================================================================

configure_boot() {
  log "Configuring boot parameters..."

  # Enable 64-bit kernel
  if ! grep -q "arm_64bit=1" /boot/firmware/config.txt; then
    echo "arm_64bit=1" >> /boot/firmware/config.txt
    echo "  Added arm_64bit=1"
  else
    echo "  arm_64bit=1 already set"
  fi

  # Enable cgroup memory controller
  CGROUP_PARAMS="cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 swapaccount=1"
  for param in $CGROUP_PARAMS; do
    if ! grep -q "$param" /boot/firmware/cmdline.txt; then
      sed -i "s/$/ $param/" /boot/firmware/cmdline.txt
      echo "  Added $param to cmdline.txt"
    else
      echo "  $param already set"
    fi
  done
}

# =============================================================================
# PHASE 2: Kernel modules
# =============================================================================

configure_kernel_modules() {
  log "Loading kernel modules..."

  MODULES="vxlan ip_tables ip6_tables xt_set ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh"

  for mod in $MODULES; do
    modprobe "$mod" 2>/dev/null && echo "  Loaded $mod" || warn "Could not load $mod"
  done

  # Persist across reboots
  cat > /etc/modules-load.d/microk8s.conf << EOF
vxlan
ip_tables
ip6_tables
xt_set
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
EOF
  echo "  Persisted modules to /etc/modules-load.d/microk8s.conf"
}

# =============================================================================
# PHASE 3: Snap + MicroK8s
# =============================================================================

install_microk8s() {
  log "Installing snap and MicroK8s..."

  # Snap
  if ! command -v snap &>/dev/null; then
    apt-get update && apt-get install -y snapd
    systemctl enable --now snapd.socket
    ln -sf /var/lib/snapd/snap /snap
  fi

  # PATH
  if ! echo "$PATH" | grep -q "/snap/bin"; then
    echo 'export PATH=$PATH:/snap/bin' >> /home/${K8S_USER}/.bashrc
    export PATH=$PATH:/snap/bin
  fi

  # MicroK8s
  if ! snap list microk8s &>/dev/null; then
    snap install microk8s --classic --channel=1.32/stable
  else
    echo "  MicroK8s already installed"
  fi

  # User group
  usermod -aG microk8s "$K8S_USER"
  mkdir -p /home/${K8S_USER}/.kube
  chown -R ${K8S_USER}:${K8S_USER} /home/${K8S_USER}/.kube
}

# =============================================================================
# PHASE 4: cgroup v2 delegation for containerd
# =============================================================================

configure_cgroup_delegation() {
  log "Configuring cgroup v2 delegation for containerd..."

  mkdir -p /etc/systemd/system/snap.microk8s.daemon-containerd.service.d/

  cat > /etc/systemd/system/snap.microk8s.daemon-containerd.service.d/delegate.conf << EOF
[Service]
Delegate=yes
EOF

  systemctl daemon-reload
  echo "  Delegate=yes applied to snap.microk8s.daemon-containerd"
}

# =============================================================================
# PHASE 5: Wait for MicroK8s and enable addons
# =============================================================================

configure_microk8s() {
  log "Starting MicroK8s and enabling addons..."

  microk8s start || true
  microk8s status --wait-ready --timeout 120 || warn "MicroK8s not ready yet, continuing..."

  for addon in dns storage ingress cert-manager; do
    microk8s enable "$addon" 2>/dev/null || echo "  $addon already enabled"
  done

  # Enable ssl-passthrough on ingress controller
  log "Enabling ssl-passthrough on nginx ingress..."
  INGRESS_DS="nginx-ingress-microk8s-controller"
  if ! microk8s kubectl get daemonset -n ingress "$INGRESS_DS" \
      -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q "ssl-passthrough"; then
    microk8s kubectl patch daemonset -n ingress "$INGRESS_DS" --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-ssl-passthrough"}]'
    echo "  ssl-passthrough enabled"
  else
    echo "  ssl-passthrough already enabled"
  fi

  # Export kubeconfig
  microk8s config > /home/${K8S_USER}/.kube/config
  chmod 600 /home/${K8S_USER}/.kube/config
  chown ${K8S_USER}:${K8S_USER} /home/${K8S_USER}/.kube/config
  export KUBECONFIG="/home/${K8S_USER}/.kube/config"
  echo "  kubeconfig written to ~/.kube/config"
}

# =============================================================================
# PHASE 6: kubectl + helm
# =============================================================================

install_tools() {
  log "Installing kubectl and helm..."

  if ! snap list kubectl &>/dev/null; then
    snap install kubectl --classic
  else
    echo "  kubectl already installed"
  fi

  if ! snap list helm &>/dev/null; then
    snap install helm --classic
  else
    echo "  helm already installed"
  fi
}

# =============================================================================
# PHASE 7: cert-manager
# =============================================================================

install_cert_manager() {
  log "Configuring cert-manager ClusterIssuer..."

  kubectl apply -f "${SCRIPT_DIR}/Issuer.yaml"
  echo "  ClusterIssuer letsencrypt created"
}

# =============================================================================
# PHASE 8: ArgoCD
# =============================================================================

install_argocd() {
  log "Installing ArgoCD..."

  helm repo add argo https://argoproj.github.io/argo-helm --force-update

  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --values "${SCRIPT_DIR}/argocd/argocd-values.yaml" \
    --wait --timeout 10m

  echo "  ArgoCD installed at https://${ARGOCD_HOSTNAME}"
  echo "  Initial admin password:"
  kubectl get secret argocd-initial-admin-secret -n argocd \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d && echo || true
}

# =============================================================================
# PHASE 9: Pre-create MCP secrets (must exist before ArgoCD first sync)
# =============================================================================

bootstrap_mcp_secrets() {
  log "Bootstrapping MCP secrets in namespace mcp..."

  local SECRETS_FILE="${SCRIPT_DIR}/argocd/apps/secrets.values.yaml"

  if [[ ! -f "$SECRETS_FILE" ]]; then
    warn "argocd/apps/secrets.values.yaml not found — skipping secret bootstrap."
    warn "Copy it from secrets.values.yaml.example, fill in real values, and re-run."
    return
  fi

  # Parse scalar values from the YAML (python3 ships on RPi OS; no external deps needed)
  read -r GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET DEX_CLIENT_SECRET COOKIE_SECRET OBSIDIAN_API_KEY < <(
    python3 - "$SECRETS_FILE" <<'EOF'
import sys, re
text = open(sys.argv[1]).read()
def val(key):
    m = re.search(r'^\s+' + re.escape(key) + r':\s+"?([^"\n]+)"?', text, re.MULTILINE)
    return (m.group(1).strip('"').strip("'") if m else '')
print(val('githubClientId'), val('githubClientSecret'), val('dexClientSecret'),
      val('cookieSecret'), val('OBSIDIAN_API_KEY'))
EOF
  )

  # Extract calendar configFile.content multiline block
  CALENDAR_CONFIG=$(python3 - "$SECRETS_FILE" <<'EOF'
import sys, re
text = open(sys.argv[1]).read()
# Match the indented block after "content: |"
m = re.search(r'content:\s+\|\n((?:[ \t]+[^\n]*\n?)+)', text)
if m:
    import textwrap
    print(textwrap.dedent(m.group(1)).rstrip())
EOF
  )

  # Validate required values
  local missing=()
  [[ -z "$GITHUB_CLIENT_ID" ]]     && missing+=("githubClientId")
  [[ -z "$GITHUB_CLIENT_SECRET" ]] && missing+=("githubClientSecret")
  [[ -z "$DEX_CLIENT_SECRET" ]]    && missing+=("dexClientSecret")
  [[ -z "$COOKIE_SECRET" ]]        && missing+=("cookieSecret")
  [[ -z "$OBSIDIAN_API_KEY" ]]     && missing+=("OBSIDIAN_API_KEY")
  if (( ${#missing[@]} > 0 )); then
    warn "Missing values in secrets.values.yaml: ${missing[*]}"
    warn "Fill in all required fields and re-run."
    return 1
  fi

  kubectl create namespace mcp --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n mcp create secret generic dex-github-client \
    --from-literal=GITHUB_CLIENT_ID="$GITHUB_CLIENT_ID" \
    --from-literal=GITHUB_CLIENT_SECRET="$GITHUB_CLIENT_SECRET" \
    --save-config --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n mcp create secret generic dex-static-client \
    --from-literal=DEX_CLIENT_SECRET="$DEX_CLIENT_SECRET" \
    --save-config --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n mcp create secret generic oauth2-proxy \
    --from-literal=client-id="claude-mcp" \
    --from-literal=client-secret="$DEX_CLIENT_SECRET" \
    --from-literal=cookie-secret="$COOKIE_SECRET" \
    --save-config --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n mcp create secret generic knowledge-base-mcp-obsidian-mcp-secrets \
    --from-literal=OBSIDIAN_API_KEY="$OBSIDIAN_API_KEY" \
    --save-config --dry-run=client -o yaml | kubectl apply -f -

  if [[ -n "$CALENDAR_CONFIG" ]]; then
    kubectl -n mcp create secret generic knowledge-base-mcp-calendar-config \
      --from-literal=config.yaml="$CALENDAR_CONFIG" \
      --save-config --dry-run=client -o yaml | kubectl apply -f -
    echo "  Calendar config secret created"
  else
    warn "No calendar config found in secrets.values.yaml — knowledge-base-mcp-calendar-config not created"
  fi

  echo "  All MCP secrets created in namespace mcp"
}

# =============================================================================
# PHASE 10: ArgoCD apps
# =============================================================================

configure_argocd_apps() {
  log "Configuring ArgoCD apps..."

  for app in "${SCRIPT_DIR}"/argocd/apps/*.yaml; do
    # Skip helm values files (not Kubernetes manifests)
    [[ "$(basename "$app")" == *.values.yaml ]] && continue
    kubectl apply -f "$app"
    echo "  Applied $(basename "$app")"
  done
}

# =============================================================================
# PHASE 11: Nextcloud ingress (reverse proxy to external service)
# =============================================================================

configure_nextcloud_ingress() {
  log "Configuring Nextcloud ingress..."

  kubectl apply -f "${SCRIPT_DIR}/nextcloud-ingress/ingress.yaml"
  echo "  Nextcloud ingress configured for ${NEXTCLOUD_HOSTNAME}"
}

# =============================================================================
# PHASE 12: Calico IPv6 veth fix
# =============================================================================

configure_calico_ipv6_fix() {
  log "Disabling IPv6 on Calico veth interfaces..."

  # All cali* veth pairs share MAC ee:ee:ee:ee:ee:ee, giving them the same
  # IPv6 link-local (fe80::ecee:eeff:feee:eeee). The kernel's DAD detects the
  # collision and oscillates the address, triggering constant Calico iptables
  # reconciliation loops that cause kubelet HTTP probes to return EINVAL.
  cat > /etc/sysctl.d/99-calico-no-ipv6.conf << 'EOF'
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sysctl -p /etc/sysctl.d/99-calico-no-ipv6.conf

  # Apply immediately to any existing cali* interfaces
  for iface in $(ip link show | grep "cali" | awk '{print $2}' | tr -d ':' | cut -d'@' -f1); do
    sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=1" 2>/dev/null || true
  done

  echo "  IPv6 disabled on Calico veth interfaces"
}

# =============================================================================
# Main — only runs when executed directly, not when sourced
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  require_root

  echo "=============================================="
  echo " Raspberry Pi Kubernetes Setup"
  echo "=============================================="

  configure_boot
  configure_kernel_modules
  install_microk8s
  configure_cgroup_delegation
  configure_microk8s
  install_tools
  configure_calico_ipv6_fix
  install_cert_manager
  install_argocd
  bootstrap_mcp_secrets
  configure_argocd_apps
  configure_nextcloud_ingress

  log "Setup complete!"
  echo ""
  echo "  ArgoCD:    https://${ARGOCD_HOSTNAME}"
  echo "  Nextcloud: https://${NEXTCLOUD_HOSTNAME}"
  echo ""
  warn "If this is a fresh install, a reboot is required for boot params to take effect."
  warn "After reboot, re-run this script to continue from where it left off."
fi