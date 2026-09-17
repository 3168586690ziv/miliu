#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"; OUT="$REPO/build/real-webkit-redirect-tests"
mkdir -p "$OUT"
TLS="$(mktemp -d "$OUT/tls.XXXXXX")"
printf '%s\n' '[req]' 'distinguished_name=dn' 'x509_extensions=ext' 'prompt=no' '[dn]' 'CN=127.0.0.1' '[ext]' 'subjectAltName=IP:127.0.0.1' 'basicConstraints=critical,CA:TRUE' 'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign' 'extendedKeyUsage=serverAuth' > "$TLS/openssl.cnf"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$TLS/openssl.cnf" -keyout "$TLS/key.pem" -out "$TLS/cert.pem" > "$TLS/generate.log" 2>&1
openssl x509 -in "$TLS/cert.pem" -outform der -out "$TLS/cert.der"
export RD_WEBKIT_CA="$TLS/cert.der"
python3 "$REPO/tests/Tests/fixtures/webkit_redirect_server.py" "$TLS/cert.pem" "$TLS/key.pem" > "$OUT/server.log" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT
PORT=""
for _ in {1..50}; do PORT="$(head -1 "$OUT/server.log")"; [[ "$PORT" =~ ^[0-9]+[[:space:]][0-9]+$ ]] && break; sleep .1; done
[[ "$PORT" =~ ^[0-9]+[[:space:]][0-9]+$ ]] || exit 1
export RD_WEBKIT_HTTP="http://127.0.0.1:${PORT%% *}"
export RD_WEBKIT_HTTPS="https://127.0.0.1:${PORT##* }"
printf '%s\n' '<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict></dict></plist>' > "$OUT/fixture.plist"
SRC=("$REPO/tests/Tests/RealWebKitRedirectTests.m")
for f in WebProbe URLPolicy DetectedMedia RDQualityTier RDResourceDisplayMetadata; do SRC+=("$ROOT/Features/ResourceDetector/$f.m"); done
for f in AppError DNSResolver IPAddressPolicy HTTPPrivacyPolicy HTTPRequest HTTPResult HTTPClient; do SRC+=("$ROOT/Shared/Infrastructure/$f.m"); done
SRC+=("$ROOT/Shared/Infrastructure/Async/RequestGeneration.m")
xcrun clang -fobjc-arc -g -O1 -framework Cocoa -framework WebKit -framework AVFoundation -framework Security \
 -I"$ROOT/Features/ResourceDetector" -I"$ROOT/Shared/Infrastructure" -I"$ROOT/Shared/Infrastructure/Async" \
 -sectcreate __TEXT __info_plist "$OUT/fixture.plist" "${SRC[@]}" -o "$OUT/RealWebKitRedirectTests" > "$OUT/compile.log" 2>&1
"$OUT/RealWebKitRedirectTests"
if grep -q 'path=/downgrade-final' "$OUT/server.log"; then echo 'FAIL downgrade reached HTTP server'; exit 1; fi
echo 'PASS HTTPS downgrade never reached HTTP target server'
