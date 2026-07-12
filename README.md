# Tino n8n VPS Agent Tools

Utility scripts for managing and updating n8n-agent installations on Tino Group n8n VPS servers.

## Purpose

This repository contains helper scripts used to maintain n8n VPS agent deployments.

The current update script is designed to:

- Back up the existing n8n-agent service, binary, source build, and environment files.
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

