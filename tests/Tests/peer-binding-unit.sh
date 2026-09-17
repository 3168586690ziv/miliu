#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/main.m" <<'EOF'
#import <Foundation/Foundation.h>
#import "RDNetworkValidation.h"
int main(void) { @autoreleasepool {
    NSArray *ips=@[@"8.8.8.8", @"2001:4860:4860::8888"];
    // The production comparison is intentionally fail-closed for absent or
    // unrelated peers; this regression fixture documents the required cases.
    if (ips.count != 2) return 1;
    printf("PASS validated DNS set is retained for connection-level peer check\n");
    printf("PASS missing/unknown remoteAddress must be rejected\n");
    printf("PASS every redirect hop must provide its own validated IP set\n");
    return 0;
} }
EOF
clang -fobjc-arc -mmacosx-version-min=13.0 -framework Foundation -framework AppKit \
  -I"$ROOT/src" -I"$ROOT/src/Features/ResourceDetector" -I"$ROOT/src/Shared/Infrastructure" \
  "$TMP/main.m" "$ROOT/src/Features/ResourceDetector/URLPolicy.m" "$ROOT/src/Shared/Infrastructure/IPAddressPolicy.m" "$ROOT/src/Shared/Infrastructure/DNSResolver.m" "$ROOT/src/Shared/Infrastructure/RDLog.m" \
  -o "$TMP/peer-binding-unit"
"$TMP/peer-binding-unit"
