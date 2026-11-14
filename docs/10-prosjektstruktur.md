# 10 – Prosjektstruktur

Dart pub workspace (monorepo).

```
terminal-prompter/
├── CLAUDE.md
├── README.md
├── LICENSE                      Apache-2.0
├── Makefile
├── pubspec.yaml                 workspace-rot
├── analysis_options.yaml        strict + lints/recommended
├── dev/
│   └── config.toml              lokal utviklingskonfig (TLS av, 127.0.0.1:7681)
├── docs/                        denne arkitekturen
├── packages/
│   ├── tp_protocol/             DELT – ren Dart (ingen dart:io / dart:html)
│   │   ├── lib/tp_protocol.dart
│   │   ├── lib/src/messages.dart        sealed class Message + alle typer
│   │   ├── lib/src/codec.dart           JSON + binærframe encode/decode
│   │   ├── lib/src/keymap/              layouts.dart, profile.dart, encoder.dart
│   │   ├── lib/src/limits.dart          felles grenser og konstanter
│   │   └── test/
│   ├── tp_agent/                SERVER
│   │   ├── bin/tp_agent.dart
│   │   ├── lib/src/{config,server,auth,session,pty,transport,files,audit,update,relay}/
│   │   ├── lib/src/generated/assets.g.dart
│   │   ├── tool/embed_assets.dart
│   │   └── test/
│   ├── tp_web/                  KLIENT
│   │   ├── web/{index.html,styles.css,main.dart,vendor/xterm/}
│   │   ├── lib/src/{interop,conn,ui,i18n}/
│   │   └── test/                dart test -p chrome
│   └── tp_netsim/               TESTVERKTØY
│       ├── lib/src/proxy.dart   TCP-proxy med latens/jitter/brudd/båndbredde
│       ├── lib/src/profiles.dart  geo, leo, hostile
│       └── test/
├── install/
│   ├── install.sh               POSIX sh
│   ├── stub.sh                  liten http-stub for tegnsikker bootstrap
│   ├── tp-agent.service
│   ├── cloud-init.yaml.tmpl
│   └── proxy-snippets/{Caddyfile,nginx.conf,traefik.yaml}
├── docker/
│   └── Dockerfile               multi-stage: dart:stable → debian:stable-slim
└── .github/workflows/
    ├── ci.yml                   analyze, test, netsim
    └── release.yml              bygg x64+arm64, SHA256SUMS, ed25519-signer, GitHub Release, GHCR-image
```

## Rot-`pubspec.yaml`

```yaml
name: terminal_prompter_workspace
publish_to: none
environment:
  sdk: ^3.8.0
workspace:
  - packages/tp_protocol
  - packages/tp_agent
  - packages/tp_web
  - packages/tp_netsim
```

Hver pakke har `resolution: workspace` i sin `pubspec.yaml`.

## Makefile (skisse)

```make
VERSION ?= $(shell git describe --tags --always)

bootstrap:
	dart pub get

web:
	cd packages/tp_web && dart compile js -O2 --no-source-maps -o build/main.dart.js web/main.dart
	rm -rf packages/tp_agent/web_build && mkdir -p packages/tp_agent/web_build
	cp -r packages/tp_web/web/index.html packages/tp_web/web/styles.css packages/tp_web/web/vendor \
	      packages/tp_web/build/main.dart.js packages/tp_agent/web_build/

embed: web
	cd packages/tp_agent && dart run tool/embed_assets.dart web_build lib/src/generated/assets.g.dart

build: embed
	mkdir -p bin
	cd packages/tp_agent && dart compile exe -DTP_VERSION=$(VERSION) \
	    --target-os linux --target-arch x64   -o ../../bin/tp-agent-linux-x64   bin/tp_agent.dart
	cd packages/tp_agent && dart compile exe -DTP_VERSION=$(VERSION) \
	    --target-os linux --target-arch arm64 -o ../../bin/tp-agent-linux-arm64 bin/tp_agent.dart

run:
	cd packages/tp_agent && dart run bin/tp_agent.dart run --config ../../dev/config.toml

test:
	dart analyze --fatal-infos
	cd packages/tp_protocol && dart test
	cd packages/tp_agent && dart test
	cd packages/tp_netsim && dart test
	cd packages/tp_web && dart test -p chrome

netsim:
	cd packages/tp_agent && dart test --tags netsim
```

Versjon bakes inn med `-DTP_VERSION` og leses via `const String.fromEnvironment('TP_VERSION')`.

## Utviklingsløkke

- `make run` starter agenten med `dev/config.toml` (passord `dev`, ingen TLS, kun localhost).
- Under utvikling serverer agenten web-filer fra disk (`--dev-web-dir packages/tp_agent/web_build`) i stedet for innebygde, så `make web` + refresh holder.
- PTY-koden krever Linux. På macOS/Windows: utvikle i Docker (`docker/Dockerfile.dev`) eller WSL2.
