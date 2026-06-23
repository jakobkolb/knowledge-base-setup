# knowledge-base-setup

Idempotent bootstrap for a Raspberry Pi running MicroK8s with ArgoCD,
deploying the [knowledge-base](https://github.com/jakobkolb/knowledge-base)
MCP server stack (Obsidian + Calendar, protected by Dex + oauth2-proxy).

## Architecture

```
claude.ai
  │
  │ HTTPS  *.<baseDomain>
  ▼
nginx ingress (MicroK8s)
  │
  ├─ /.well-known/*  ──►  well-known pod (OpenResty)
  │                         • oauth-protected-resource (RFC 9728)
  │                         • oauth-authorization-server (RFC 8414)
  │                         • /register  — dynamic client registration (RFC 7591)
  │                         • /auth      — scope injection → Dex
  │                         • /.well-known/openid-configuration → Dex
  │
  ├─ auth.<baseDomain> ─►  Dex  (GitHub OAuth connector, issues JWTs)
  │
  └─ *.<baseDomain>  ───►  oauth2-proxy (Bearer JWT validation)
                              │  202 OK
                              ▼
                           MCP server pod (mcp-obsidian / mcp-calendar)
```

## Prerequisites

- Raspberry Pi (aarch64) running Raspberry Pi OS
- Public DNS wildcard record: `*.<baseDomain>` → your Pi's IP
- A DNS record for ArgoCD: `argocd.<yourDomain>` → your Pi's IP
- Two [GitHub OAuth Apps](https://github.com/settings/developers):
  - **MCP stack**: callback URL `https://auth.<baseDomain>/callback`
  - **ArgoCD SSO**: callback URL `https://argocd.<baseDomain>/api/dex/callback`
- Port 80 and 443 forwarded to the Pi

## Quick start

```bash
# 1. Clone this repo
git clone https://github.com/jakobkolb/knowledge-base-setup.git
cd knowledge-base-setup

# 2. Create your secrets file (never committed — gitignored)
cp argocd/apps/secrets.values.yaml.example argocd/apps/secrets.values.yaml
#    ↑ edit it — see "Secrets" section below

# 3. Run the bootstrap (requires sudo)
sudo ./setup.sh
```

The script is fully idempotent — safe to re-run after a reboot or partial failure.

A reboot is required after the first run (boot params + cgroups).
Re-run `sudo ./setup.sh` after the reboot to complete the install.

### Re-bootstrapping secrets only

If you need to recreate secrets without re-running the full install:

```bash
sudo bash -c '
  SCRIPT_DIR=$(pwd)
  source ./setup.sh
  bootstrap_argocd_sso_secret          argocd/apps/secrets.values.yaml
  bootstrap_mcp_secrets mcp-prod    knowledge-base-prod    argocd/apps/secrets.values.yaml
  bootstrap_mcp_secrets mcp-staging knowledge-base-staging argocd/apps/secrets-staging.values.yaml
'
```

---

## What the script does

| Phase | Step |
|-------|------|
| 1 | Boot config — 64-bit kernel, cgroup memory |
| 2 | Kernel modules — vxlan, ip_tables, ip_vs, … |
| 3 | Snap + MicroK8s 1.32/stable |
| 4 | cgroup v2 delegation for containerd |
| 5 | MicroK8s addons: dns, storage, ingress, cert-manager |
| 6 | kubectl + helm (snap) |
| 7 | **Calico IPv6 veth fix** (first pass — covers interfaces existing at this point) |
| 8 | cert-manager ClusterIssuer (Let's Encrypt HTTP-01) |
| 9 | ArgoCD via Helm |
| 9b | **ArgoCD GitHub SSO secret** — creates `argocd-github-sso` secret in `argocd` namespace |
| 10 | **MCP secrets bootstrap** — creates all secrets in `mcp-prod` and `mcp-staging` namespaces before first ArgoCD sync |
| 11 | ArgoCD Application manifests |
| 12 | Nextcloud reverse-proxy ingress |
| 13 | **Calico IPv6 veth fix** (second pass — covers new `cali*` interfaces created by ArgoCD pod deployments) |

---

## Secrets

Create `argocd/apps/secrets.values.yaml` (this file is gitignored):

```yaml
argocd:
  githubClientId: ""        # ArgoCD GitHub OAuth App → Client ID
  githubClientSecret: ""    # ArgoCD GitHub OAuth App → Client Secret
  # Callback URL: https://argocd.<baseDomain>/api/dex/callback

global:
  secrets:
    githubClientId: ""        # MCP stack GitHub OAuth App → Client ID
    githubClientSecret: ""    # MCP stack GitHub OAuth App → Client Secret

    # Shared secret between Dex (staticClient) and oauth2-proxy.
    # Also enter this value as the "Client Secret" in claude.ai MCP settings.
    # Generate: openssl rand -hex 32
    dexClientSecret: ""

    # oauth2-proxy session cookie encryption key.
    # Must decode to exactly 16, 24, or 32 bytes.
    # Generate: python3 -c 'import os,base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())'
    cookieSecret: ""

mcp-obsidian:
  mcp:
    secretEnv:
      # API key for the Obsidian Local REST API plugin (set inside Obsidian).
      OBSIDIAN_API_KEY: ""
  headlessAuth:
    obsidianEmail: ""
    obsidianPassword: ""       # Obsidian account password
    obsidianSyncPassword: ""   # Obsidian Sync end-to-end encryption password
    obsidianVault: "Default"   # vault name as shown in Obsidian Sync

mcp-calendar:
  configFile:
    content: |
      calendars:
        # iCloud — use an app-specific password
        # (appleid.apple.com → Security → App-Specific Passwords)
        - type: icloud
          name: personal
          username: user@icloud.com
          password: ""

        # Google Calendar — use an app-specific password
        # (myaccount.google.com → Security → App passwords)
        - type: google
          name: work
          username: user@gmail.com
          password: ""
```

### Secret reference

| Secret | Namespace | Key | Description |
|--------|-----------|-----|-------------|
| `argocd-github-sso` | `argocd` | `clientID` | ArgoCD GitHub OAuth App client ID |
| `argocd-github-sso` | `argocd` | `clientSecret` | ArgoCD GitHub OAuth App client secret |
| `dex-github-client` | `mcp-prod` / `mcp-staging` | `GITHUB_CLIENT_ID` | MCP stack GitHub OAuth App client ID |
| `dex-github-client` | `mcp-prod` / `mcp-staging` | `GITHUB_CLIENT_SECRET` | MCP stack GitHub OAuth App client secret |
| `dex-static-client` | `mcp-prod` / `mcp-staging` | `DEX_CLIENT_SECRET` | Shared Dex↔oauth2-proxy secret |
| `oauth2-proxy` | `mcp-prod` / `mcp-staging` | `client-id` | Always `claude-mcp` |
| `oauth2-proxy` | `mcp-prod` / `mcp-staging` | `client-secret` | Same as `dexClientSecret` |
| `oauth2-proxy` | `mcp-prod` / `mcp-staging` | `cookie-secret` | AES key — must be 16/24/32 bytes after base64 decode |
| `knowledge-base-mcp-obsidian-mcp-secrets` | `mcp-prod` / `mcp-staging` | `OBSIDIAN_API_KEY` | Obsidian Local REST API key |
| `obsidian-headless-auth` | `mcp-prod` / `mcp-staging` | `email` | Obsidian account email |
| `obsidian-headless-auth` | `mcp-prod` / `mcp-staging` | `password` | Obsidian account password |
| `obsidian-headless-auth` | `mcp-prod` / `mcp-staging` | `sync-password` | Obsidian Sync end-to-end encryption password |
| `obsidian-headless-auth` | `mcp-prod` / `mcp-staging` | `vault` | Vault name as shown in Obsidian Sync |
| `<app-name>-mcp-calendar-config` | `mcp-prod` / `mcp-staging` | `config.yaml` | Calendar YAML config (from `configFile.content`) |

Secrets are created in both the `mcp-prod` namespace (app name `knowledge-base-prod`) and `mcp-staging`
(app name `knowledge-base-staging`). The calendar config secret name follows the pattern
`<app-name>-mcp-calendar-config`, e.g. `knowledge-base-staging-mcp-calendar-config` in staging.

---

## Configuring claude.ai

1. Go to **claude.ai → Settings → Integrations → Add MCP server**
2. Add each server:

| Name | URL |
|------|-----|
| Obsidian | `https://obsidian.<baseDomain>/mcp/` |
| Calendar | `https://calendar.<baseDomain>/mcp/` |

*Note: won't work without the trailing slash*

3. Set **Client ID** to `claude-mcp`
4. Set **Client Secret** to the value of `dexClientSecret`
5. Authenticate with GitHub when prompted

---

## Calico IPv6 fix (RPi-specific)

All Calico veth pairs on the RPi share the MAC `ee:ee:ee:ee:ee:ee`, which
gives them the same IPv6 link-local address. The kernel's DAD mechanism
oscillates the address, causing kubelet probes to fail with `EINVAL`.

The fix persists `net.ipv6.conf.default.disable_ipv6=1` via
`/etc/sysctl.d/99-calico-no-ipv6.conf` so new `cali*` veth pairs inherit the
setting. `net.ipv6.conf.all` is intentionally **not** used — it would also disable
IPv6 on `lo`, breaking the MicroK8s API server which listens on `[::1]:16443`.

For existing interfaces the script loops over all `cali*` interfaces explicitly.
Because `default` does not reliably propagate to new veths on this kernel,
`configure_calico_ipv6_fix` is called **twice**: once before ArgoCD and once
after, so interfaces created by ArgoCD pod deployments are also covered.

If a pod is restarted manually after setup and its readiness probe returns `EINVAL`,
re-run the fix with:

```bash
sudo sysctl -w $(ip link show | grep cali | awk '{print $2}' | tr -d ':' | cut -d'@' -f1 | \
  xargs -I{} echo "net.ipv6.conf.{}.disable_ipv6=1") 2>/dev/null || true
```

---

## Disaster recovery

To tear down and redeploy the MCP stack from scratch:

```bash
kubectl delete namespace mcp mcp-staging
sudo bash -c '
  SCRIPT_DIR=$(pwd)
  source ./setup.sh
  bootstrap_mcp_secrets mcp-prod    knowledge-base-prod    argocd/apps/secrets.values.yaml
  bootstrap_mcp_secrets mcp-staging knowledge-base-staging argocd/apps/secrets-staging.values.yaml
  configure_argocd_apps
  configure_calico_ipv6_fix
'
```

ArgoCD will resync automatically, Obsidian syncs notes to remote and the calendars are their respective CALDAV Servers.
