# Terminal Prompter build entry points (see CLAUDE.md and docs/10-prosjektstruktur.md).
# Recipes use ">" instead of a leading tab so the file is safe to edit anywhere.
.RECIPEPREFIX := >

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo 0.0.0-dev)
DART    ?= dart
# Release settings baked into the binary (docs/05 selfupdate). Set by CI.
TP_RELEASE_KEY ?=
TP_RELEASE_URL ?=
DEFINES := -DTP_VERSION=$(VERSION) -DTP_RELEASE_KEY=$(TP_RELEASE_KEY) -DTP_RELEASE_URL=$(TP_RELEASE_URL)
CHROME  := $(shell command -v google-chrome google-chrome-stable chromium chromium-browser 2>/dev/null | head -n1)

AGENT      := packages/tp_agent
WEB        := packages/tp_web
WEB_BUILD  := $(AGENT)/web_build
ASSETS_OUT := lib/src/generated/assets.g.dart

.PHONY: bootstrap gen-assets analyze format web embed build run test netsim install-test release clean

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
> cp $(WEB)/web/index.html $(WEB)/web/styles.css $(WEB)/web/manifest.webmanifest $(WEB)/build/main.dart.js $(WEB_BUILD)/
> cp -r $(WEB)/web/vendor $(WEB)/web/icons $(WEB_BUILD)/
> # Cache key = hash of the client files, so every rebuild invalidates the
> # service worker cache even when the git version is unchanged.
> hash=$$(cd $(WEB_BUILD) && find . -type f ! -name sw.js | sort | xargs cat | sha256sum | cut -c1-12); \
>   sed "s/__TP_VERSION__/$(VERSION)-$$hash/" $(WEB)/web/sw.js > $(WEB_BUILD)/sw.js

embed: web gen-assets

build: embed
> mkdir -p bin
> cd $(AGENT) && $(DART) compile exe $(DEFINES) \
>     --target-os linux --target-arch x64   -o ../../bin/tp-agent-linux-x64   bin/tp_agent.dart
> cd $(AGENT) && $(DART) compile exe $(DEFINES) \
>     --target-os linux --target-arch arm64 -o ../../bin/tp-agent-linux-arm64 bin/tp_agent.dart
> ls -la bin/

run: web gen-assets
> cd $(AGENT) && $(DART) run bin/tp_agent.dart run --config ../../dev/config.toml --dev-web-dir web_build

test: analyze
> cd packages/tp_protocol && $(DART) test
> cd packages/tp_agent    && $(DART) test --exclude-tags netsim,install
> cd packages/tp_netsim   && $(DART) test
> cd packages/tp_web      && $(DART) test
ifneq ($(CHROME),)
> cd packages/tp_web      && CHROME_EXECUTABLE=$(CHROME) $(DART) test -p chrome
endif

netsim: gen-assets
> cd packages/tp_agent && $(DART) test --tags netsim

# install/install.sh end to end under dash and BusyBox (sandboxed, no root).
install-test: gen-assets
> cd packages/tp_agent && $(DART) test --tags install

# Signed release in dist/: binaries, install.sh, stub.sh, SHA256SUMS(.sig).
# Needs TP_RELEASE_KEY, TP_RELEASE_URL and the secret TP_RELEASE_SIGNING_KEY.
release: build
> test -n "$(TP_RELEASE_KEY)" && test -n "$(TP_RELEASE_URL)" || { echo "set TP_RELEASE_KEY and TP_RELEASE_URL"; exit 1; }
> rm -rf dist && mkdir -p dist
> cp bin/tp-agent-linux-x64 bin/tp-agent-linux-arm64 dist/
> sed 's#__TP_RELEASE_URL__#$(TP_RELEASE_URL)#' install/install.sh > dist/install.sh
> cd $(AGENT) && $(DART) run tool/sign_release.dart ../../dist $(VERSION)
> sed -e 's#__TP_INSTALL_URL__#$(TP_RELEASE_URL)/install.sh#' -e "s#__TP_INSTALL_SHA256__#$$(sha256sum dist/install.sh | cut -d' ' -f1)#" install/stub.sh > dist/stub.sh

clean:
> rm -rf bin dist $(WEB_BUILD) $(WEB)/build $(AGENT)/$(ASSETS_OUT)
