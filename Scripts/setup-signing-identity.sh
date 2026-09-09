#!/bin/bash
# setup-signing-identity.sh — create a stable self-signed code-signing
# identity so Supervisor's TCC grants (Accessibility) and Keychain ACLs
# survive rebuilds.
#
# The problem: ad-hoc signing (`codesign --sign -`) gives the app a
# designated requirement of `cdhash H"..."`. The cdhash changes on every
# build, so macOS treats each rebuild as a different program and drops
# the Accessibility grant and the Keychain access ACL. The user has to
# re-grant Accessibility and click through a Keychain prompt after every
# self-deploy.
#
# The fix: sign with a stable self-signed certificate. codesign then
# generates a designated requirement that references the certificate
# (`identifier "live.supervisor.app" and certificate leaf = H"..."`).
# The cert hash is the same across rebuilds, so TCC and the Keychain
# keep the grants.
#
# Notes:
#   - The cert does NOT need to be "trusted" in the system policy sense.
#     codesign signs with it by name; the designated requirement is
#     cert-based regardless. So this script needs no admin and pops no
#     password dialog.
#   - Locally built apps run fine even though `spctl` would reject a
#     self-signed app. spctl only gates quarantined (downloaded) apps;
#     a locally built bundle with no quarantine xattr launches normally,
#     exactly like the previous ad-hoc builds did.
#
# Idempotent: no-ops if the identity already signs. Run once per machine:
#   Scripts/setup-signing-identity.sh
# Then build as usual; the sign step uses this identity automatically.

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY_CN="Supervisor Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SIGN_DIR="$HOME/Library/Application Support/Supervisor/signing"
CERT_PEM="$SIGN_DIR/supervisor-codesign.cert.pem"
KEY_PEM="$SIGN_DIR/supervisor-codesign.key.pem"
P12="$SIGN_DIR/supervisor-codesign.p12"
# PKCS#12 needs a non-empty passphrase + a SHA1 MAC for macOS's
# `security import` to verify it (LibreSSL's default MAC is rejected).
# Generated fresh per run and never written anywhere: the .p12 exists only
# for the seconds between `openssl pkcs12 -export` and `security import`,
# and this script used to ship a fixed literal ("supervisor-local") that
# anyone reading the repo could use against a .p12 it also left on disk.
P12_PASS="$(openssl rand -hex 24)"

# Helper: can codesign actually sign with this identity right now?
can_sign() {
    local t; t="$(mktemp -d)/probe.app"
    mkdir -p "$t/Contents/MacOS"
    cp /usr/bin/true "$t/Contents/MacOS/probe" 2>/dev/null || cp /bin/echo "$t/Contents/MacOS/probe"
    cat > "$t/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>live.supervisor.app</string>
<key>CFBundleExecutable</key><string>probe</string>
</dict></plist>
EOF
    codesign --force --sign "$IDENTITY_CN" --identifier live.supervisor.app "$t" >/dev/null 2>&1
}

# 1. Already usable? Then we are done.
if can_sign; then
    echo "[setup-signing] identity '$IDENTITY_CN' already usable. Nothing to do."
    exit 0
fi

echo "[setup-signing] creating self-signed code-signing identity '$IDENTITY_CN'"
mkdir -p "$SIGN_DIR"; chmod 700 "$SIGN_DIR"

# 2. OpenSSL config with the code-signing extended key usage. A config
# file is the portable way to set extensions across OpenSSL and the
# LibreSSL that ships with macOS.
CONF="$(mktemp)"; trap 'rm -f "$CONF"' EXIT
cat > "$CONF" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3_codesign
prompt             = no
[ dn ]
CN = $IDENTITY_CN
[ v3_codesign ]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
subjectKeyIdentifier   = hash
EOF

# 3. Generate a 10-year self-signed cert + key. `-nodes` leaves the key
# unencrypted on disk, which is what keeps the pkcs12 export below
# non-interactive on macOS's LibreSSL. Both staging files are 0600 inside a
# 0700 directory, and step 5 deletes them the moment `security import`
# succeeds — the Keychain is the only place the key is meant to live.
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -days 3650 -config "$CONF" >/dev/null 2>&1
chmod 600 "$KEY_PEM"

# 4. Bundle into PKCS#12 (SHA1 MAC + non-empty pass for macOS import).
openssl pkcs12 -export -inkey "$KEY_PEM" -in "$CERT_PEM" \
    -out "$P12" -passout "pass:$P12_PASS" -macalg sha1 -name "$IDENTITY_CN" >/dev/null 2>&1
chmod 600 "$P12"

# 5. Import into the login keychain. -T /usr/bin/codesign lets codesign
# use the private key without an interactive prompt on each sign.
#
# On success both staging files go. Nothing reads them again — the private
# key lives in the Keychain from here — and leaving them behind meant every
# machine that ever ran this script kept an unencrypted code-signing key
# under Application Support forever.
#
# On failure they stay, because they are the only way to retry the import by
# hand. The passphrase is printed in that one case: the plaintext key sits
# right beside the .p12, so the passphrase guards nothing the directory does
# not already expose, and without it the .p12 is unusable.
if security import "$P12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null; then
    echo "[setup-signing] imported into login keychain"
    rm -f "$KEY_PEM" "$P12"
    echo "[setup-signing] removed the staged private key + .p12 (the key is in the Keychain now)"
else
    echo "[setup-signing] ERROR: 'security import' failed." >&2
    echo "  The staging files are LEFT IN PLACE so you can retry:" >&2
    echo "    key:  $KEY_PEM   (unencrypted private key)" >&2
    echo "    p12:  $P12" >&2
    echo "    pass: $P12_PASS" >&2
    echo "  Retry:  security import \"$P12\" -k \"$KEYCHAIN\" -P '$P12_PASS' -T /usr/bin/codesign" >&2
    echo "  Then delete both:  rm -f \"$KEY_PEM\" \"$P12\"" >&2
    exit 1
fi

# 6. Let codesign use the key without the per-use prompt.
security set-key-partition-list -S apple-tool:,apple: -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

# 7. Confirm by actually signing.
if can_sign; then
    echo "[setup-signing] verified: codesign can sign with '$IDENTITY_CN'."
    echo "[setup-signing] The designated requirement is now cert-based and"
    echo "stable across rebuilds. The FIRST stably-signed deploy still needs"
    echo "one re-grant of Accessibility (the requirement changes from cdhash"
    echo "to cert once). After that, rebuilds keep the grant."
else
    echo "[setup-signing] ERROR: identity imported but codesign still cannot"
    echo "  sign with it. Open Keychain Access, find '$IDENTITY_CN', and set"
    echo "  its Code Signing trust to Always Trust, then re-run." >&2
    exit 1
fi
