# Terminal Prompter

A real terminal in the browser over HTTPS/443, built for ships, rigs and other
networks where SSH is blocked and the VNC rescue console mangles characters.

- **tp-agent** – single static-ish binary (Dart AOT) that owns PTY sessions,
  serves the client and speaks WebSocket (SSE fallback).
- **tp_web** – small Dart web client with xterm.js and a latency-friendly
  "Prompter" input field.
- **tp_protocol** – shared messages, codec and the keymap compensator used to
  bootstrap through a broken VNC console.
- **tp_netsim** – satellite-network simulator used by the integration tests.

The full architecture (in Norwegian) lives in [`docs/`](docs/README.md); build
rules and conventions for contributors and Claude Code are in
[`CLAUDE.md`](CLAUDE.md). Progress follows the milestones in
[`docs/12-roadmap.md`](docs/12-roadmap.md).

## Development

Requires Dart SDK ≥ 3.8 and Linux (the PTY layer is Linux-only).

```bash
make bootstrap   # dart pub get
make test        # analyze + format check + unit tests
make build       # bin/tp-agent-linux-x64 and bin/tp-agent-linux-arm64
make run         # dev agent on http://127.0.0.1:7681 (dev/config.toml)
```

## License

Apache-2.0 for the agent, client and protocol. See [LICENSE](LICENSE).
