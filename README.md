__MCP__ (Master Control Program) is server software, designed to be self-hosted and used on a personal basis. Mostly just a side project for now, experimenting with different designs for personal assistants.

### Project goals

Inspired by [TRON's MCP](https://tron.fandom.com/wiki/Master_Control_Program), MCP is designed to be a programmable, flexible companion which runs your life, or at least helps out wherever possible. Eventually, we'll ship hardware interfaces which run MCP in your home, and act almost as an Alexa or Google Home.

### Behind the scenes

MCP is built in [Zig](https://ziglang.org). We try to minimize dependencies wherever possible, though if there's a high quality C or Zig library that exists to do something we need to, we might use it for the sake of development velocity.

Code files:
- [stdx.zig](/src/stdx.zig) — extensions to the standard library we use frequently
- [http.zig](/src/http.zig) — high-performance http client/server built atop [libxev](https://github.com/mitchellh/libxev)
