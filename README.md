# knowledge-base-setup

Idempotent bootstrap for a Raspberry Pi running MicroK8s with ArgoCD,
deploying the [knowledge-base](https://github.com/jakobkolb/knowledge-base)
MCP server stack (Obsidian + Calendar, protected by Dex + oauth2-proxy).

## Architecture

```
claude.ai
  │
  │ HTTPS  *.mcp.<baseDomain>
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
  ├─ auth.mcp.*  ──────►  Dex  (GitHub OAuth connector, issues JWTs)
  │
  └─ *.mcp.*  ──────────►  oauth2-proxy (Bearer JWT validation)
                              │  202 OK
                              ▼
                           MCP server pod (mcp-obsidian / mcp-calendar)
```

## Prerequisites

- Raspberry Pi (aarch64) running Raspberry Pi OS
- Public DNS wildcard record: `*.mcp.<baseDomain>` → your Pi's IP
- A DNS record for ArgoCD: `argocd.<yourDomain>` → your Pi's IP
- A [GitHub OAuth App](https://github.com/settings/developers) with callback URL:
  `https://auth.mcp.<baseDomain>/callback`
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
sudo bash -c 'SCRIPT_DIR=/path/to/repo source ./setup.sh; bootstrap_mcp_secrets'
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
| 7 | cert-manager ClusterIssuer (Let's Encrypt HTTP-01) |
| 8 | ArgoCD via Helm |
| 9 | **MCP secrets bootstrap** — creates all secrets in `mcp` namespace before first ArgoCD sync |
| 10 | ArgoCD Application manifests |
| 11 | Nextcloud reverse-proxy ingress |
| 12 | Calico IPv6 veth fix (RPi-specific) |

---

## Secrets

Create `argocd/apps/secrets.values.yaml` (this file is gitignored):

```yaml
global:
  secrets:
    githubClientId: ""        # GitHub OAuth App → Settings → Client ID
    githubClientSecret: ""    # GitHub OAuth App → Settings → Client Secret

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

| Secret | Key | Description |
|--------|-----|-------------|
| `dex-github-client` | `GITHUB_CLIENT_ID` | GitHub OAuth App client ID |
| `dex-github-client` | `GITHUB_CLIENT_SECRET` | GitHub OAuth App client secret |
| `dex-static-client` | `DEX_CLIENT_SECRET` | Shared Dex↔oauth2-proxy secret |
| `oauth2-proxy` | `client-id` | Always `claude-mcp` |
| `oauth2-proxy` | `client-secret` | Same as `dexClientSecret` |
| `oauth2-proxy` | `cookie-secret` | AES key — must be 16/24/32 bytes after base64 decode |
| `knowledge-base-mcp-obsidian-mcp-secrets` | `OBSIDIAN_API_KEY` | Obsidian Local REST API key |
| `knowledge-base-mcp-calendar-config` | `config.yaml` | Calendar YAML config (from `configFile.content`) |

All secrets are created in the `mcp` namespace with the name shown above.

---

## Configuring claude.ai

1. Go to **claude.ai → Settings → Integrations → Add MCP server**
2. Add each server:

| Name | URL |
|------|-----|
| Obsidian | `https://obsidian.mcp.<baseDomain>/mcp/` |
| Calendar | `https://calendar.mcp.<baseDomain>/mcp/` |

3. Set **Client Secret** to the value of `dexClientSecret`
4. Authenticate with GitHub when prompted

---

## Calico IPv6 fix (RPi-specific)

All Calico veth pairs on the RPi share the MAC `ee:ee:ee:ee:ee:ee`, which
gives them the same IPv6 link-local address. The kernel's DAD mechanism
oscillates the address, causing kubelet probes to fail with `EINVAL`.

The fix (applied in PHASE 12) persists `net.ipv6.conf.default.disable_ipv6=1`
via `/etc/sysctl.d/99-calico-no-ipv6.conf`. New veths inherit the setting
automatically. If Dex or oauth2-proxy crash-loop on a fresh pod, wait 2–3
restart cycles — they recover once Calico settles.

---

## Disaster recovery

To tear down and redeploy the MCP stack from scratch:

```bash
kubectl delete namespace mcp
sudo bash -c 'SCRIPT_DIR=$(pwd) source ./setup.sh; bootstrap_mcp_secrets && configure_argocd_apps'
```

ArgoCD will resync automatically. All pods except Dex/oauth2-proxy come up
on the first try; those two need 1–2 restart cycles for Calico to settle.
