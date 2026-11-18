#!/bin/sh
# Character-safe bootstrap stub (docs/06 route C). Served over plain HTTP at
# the install domain so it can be fetched with just "wget tpinst.com" and run
# with "sh index.html" from a broken VNC console. It downloads the real
# installer over HTTPS and runs it only if its SHA-256 matches the value
# baked in below. Short on purpose: read it first with "cat index.html".
set -eu
U=__TP_INSTALL_URL__
H=__TP_INSTALL_SHA256__
F=/tmp/tp-install.$$
if command -v curl >/dev/null 2>&1; then curl -fsSL "$U" -o "$F"; else wget -q -O "$F" "$U"; fi
echo "$H  $F" | sha256sum -c - || { echo "install.sh checksum mismatch, aborting"; rm -f "$F"; exit 1; }
sh "$F" "$@"
rm -f "$F"
