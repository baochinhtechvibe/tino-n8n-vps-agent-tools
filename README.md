# Tino n8n VPS Agent Tools

Utility scripts for managing and updating `n8n-agent` deployments on Tino Group n8n VPS servers.

## Purpose

This repository contains helper scripts used to maintain n8n VPS agent deployments.

The current update script is designed to:

- Back up the existing `n8n-agent` service, binary, source build, and environment files.
- Preserve `AGENT_API_KEY` in `/etc/n8n-agent.env`.
- Fetch the latest source from `tinovn/n8n-manage`.
- Build the n8n-agent backend locally on the VPS.
- Switch the `n8n-agent` systemd service to run the built source version.
- Restart and verify the n8n-agent API.
- Provide rollback instructions after each run.

## Scripts

### `update-n8n-agent-source-build.sh`

Builds and runs the latest `tinovn/n8n-manage` source as the local `n8n-agent` service on a VPS.

This is useful when the packaged binary in `tinovn/n8n-agent` has not yet been rebuilt or released, but a VPS needs to receive the latest backend fixes from `n8n-manage`.

## Usage

Download and run on the target n8n VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/baochinhtechvibe/tino-n8n-vps-agent-tools/main/update-n8n-agent-source-build.sh \
  -o /root/update-n8n-agent-source-build.sh

chmod +x /root/update-n8n-agent-source-build.sh
bash -n /root/update-n8n-agent-source-build.sh
AGENT_API_KEY='YOUR_SECRET_KEY' bash /root/update-n8n-agent-source-build.sh
```

If `AGENT_API_KEY` is not provided, the script tries to read it from:

```text
/etc/n8n-agent.env
/opt/n8n-agent/.env
/opt/n8n/.env
```

If no key is found, the script prompts for it securely.

## What the script changes

The script changes the `n8n-agent` systemd service from the packaged binary mode:

```text
/opt/n8n-agent/n8n-agent
```

to source-build mode:

```text
/usr/bin/node /opt/n8n-agent-src/dist/main.js
```

The service keeps loading environment variables from:

```text
/etc/n8n-agent.env
```

## Backup and rollback

Before making changes, the script creates a timestamped backup under:

```text
/root/n8n-agent-backup-YYYY-MM-DD-HHMMSS
/root/n8n-agent-backup-YYYY-MM-DD-HHMMSS.tar.gz
```

The summary at the end of each run includes rollback commands.

## Security notes

Do not commit secrets to this repository.

Never commit:

- `AGENT_API_KEY`
- `.env` files
- VPS passwords
- GitHub tokens
- SSH private keys

Store runtime secrets on the VPS in:

```text
/etc/n8n-agent.env
```

with permission:

```bash
chmod 600 /etc/n8n-agent.env
```

## Long-term release flow

This script is a VPS-side workaround for cases where the `tinovn/n8n-agent` packaged binary is not yet updated.

The preferred long-term flow is:

```text
tinovn/n8n-manage source
→ build packaged n8n-agent binary
→ push binary to tinovn/n8n-agent
→ VPS runs /opt/n8n-agent/update-agent.sh
```

Once the packaged binary is updated, VPS servers can return to the normal update flow using:

```bash
bash /opt/n8n-agent/update-agent.sh
```
