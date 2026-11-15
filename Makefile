# Terminal Prompter build entry points (see CLAUDE.md and docs/10-prosjektstruktur.md).
# Recipes use ">" instead of a leading tab so the file is safe to edit anywhere.
.RECIPEPREFIX := >

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo 0.0.0-dev)
DART    ?= dart
CHROME  := $(shell command -v google-chrome google-chrome-stable chromium chromium-browser 2>/dev/null | head -n1)

AGENT      := packages/tp_agent
WEB        := packages/tp_web
WEB_BUILD  := $(AGENT)/web_build
ASSETS_OUT := lib/src/generated/assets.g.dart

.PHONY: bootstrap gen-assets analyze format web embed build run test netsim clean

bootstrap:
> $(DART) pub get

# Regenerates the embedded-asset source. Writes an empty bundle when the web
# client has not been built yet, so analyze/test never depend on `make web`.
gen-assets:
> cd $(AGENT) && $(DART) run tool/embed_assets.dart web_build $(ASSETS_OUT)

analyze: gen-assets
> $(DART) analyze --fatal-infos
> $(DART) format --output=none --set-exit-if-changed .

format:
> $(DART) format .

web:
> cd $(WEB) && $(DART) compile js -O2 --no-source-maps -DTP_VERSION=$(VERSION) -o build/main.dart.js web/main.dart
> rm -rf $(WEB_BUILD) && mkdir -p $(WEB_BUILD)
> cp $(WEB)/web/index.html $(WEB)/web/styles.css $(WEB)/build/main.dart.js $(WEB_BUILD)/
> if [ -d $(WEB)/web/vendor ]; then cp -r $(WEB)/web/vendor $(WEB_BUILD)/; fi

embed: web gen-assets

build: embed
> mkdir -p bin
> cd $(AGENT) && $(DART) compile exe -DTP_VERSION=$(VERSION) \
>     --target-os linux --target-arch x64   -o ../../bin/tp-agent-linux-x64   bin/tp_agent.dart
> cd $(AGENT) && $(DART) compile exe -DTP_VERSION=$(VERSION) \
>     --target-os linux --target-arch arm64 -o ../../bin/tp-agent-linux-arm64 bin/tp_agent.dart
> ls -la bin/

run: web gen-assets
> cd $(AGENT) && $(DART) run bin/tp_agent.dart run --config ../../dev/config.toml --dev-web-dir web_build

test: analyze
> cd packages/tp_protocol && $(DART) test
> cd packages/tp_agent    && $(DART) test --exclude-tags netsim
> cd packages/tp_netsim   && $(DART) test
> cd packages/tp_web      && $(DART) test
ifneq ($(CHROME),)
> cd packages/tp_web      && CHROME_EXECUTABLE=$(CHROME) $(DART) test -p chrome
endif

netsim: gen-assets
> cd packages/tp_agent && $(DART) test --tags netsim

clean:
> rm -rf bin $(WEB_BUILD) $(WEB)/build $(AGENT)/$(ASSETS_OUT)
