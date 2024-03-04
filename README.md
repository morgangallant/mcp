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

### Project goals

Inspired by [TRON's MCP](https://tron.fandom.com/wiki/Master_Control_Program), MCP is designed to be a programmable, flexible companion which runs your life, or at least helps out wherever possible. Eventually, we'll ship hardware interfaces which run MCP in your home, and act almost as an Alexa or Google Home.

### Behind the scenes

MCP is built in [Zig](https://ziglang.org), and _generally_ follows [Tiger Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md), though isn't super strict about it. We try to minimize dependencies wherever possible, though if there's a high quality C or Zig library that exists to do something we need to, we might use it for the sake of development velocity.

Code files:
- [stdx.zig](/src/stdx.zig) — extensions to the standard library we use frequently
- [http.zig](/src/http.zig) — high-performance http client/server built atop [libxev](https://github.com/mitchellh/libxev)
