__MCP__ (Master Control Program) is server software, designed to be self-hosted and used on a personal basis. Mostly just a side project for now, experimenting with different designs for personal assistants.

### Setting up a new machine

MCP works with a single machine, or multiple. Most users should probably stick to one, as multiple is likely overkill for 99%+ of use cases.

1. Install [Tailscale](https://tailscale.com) (optional)
    - `curl -fsSL https://tailscale.com/install.sh | sh`
    - `tailscale up`
    - Disable key expiry, add to `MCP` ACL group, allow traffic between `MCP` machines
2. Create or update `.env` file locally with `MACHINES` variable
    - Should be comma seperated list of (preferably Tailscale) IPs
3. Run `./deploy.sh`, deploys to all machines
    - Builds MCP for Linux x86
    - Will create systemd service file if not exists
    - Uploads the new binary, restarts the systemd service
