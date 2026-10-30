#!/bin/zsh
# Keep signing continuity across local builds without adding a trusted root.
set -euo pipefail
identity_name="SoftLock Local Development"
project_root="${0:A:h:h}"
expected_identity="$(python3 "$project_root/Tools/Distribution/release-guard.py" signing-pin)"
find_identity() {
    security find-identity -p codesigning | awk -v expected="$expected_identity" '
        /Valid identities only/ { valid_section=1 }
        !valid_section && !found && tolower($2) == tolower(expected) { print $2; found=1 }
    '
}
identity="$(find_identity)"
if [[ -n "$identity" ]]; then
    print -r -- "$identity"
    exit 0
fi

# A clean checkout is not evidence that the user's approved identity is absent.
if [[ "${SOFTLOCK_ENROLL_SIGNING_IDENTITY:-0}" != "1" || "${SOFTLOCK_ALLOW_IDENTITY_MIGRATION:-0}" != "1" ]]; then
    print -u2 "The pinned SoftLock signing identity ($expected_identity) is unavailable. No identity was created. Use a session with the original private key. Intentional enrollment requires SOFTLOCK_ENROLL_SIGNING_IDENTITY=1 and SOFTLOCK_ALLOW_IDENTITY_MIGRATION=1."
    exit 1
fi
# Explicit enrollment may create a new identity; the public release baseline is
# never rewritten automatically. Avoid creating duplicate same-name identities.
if security find-identity -p codesigning | awk -v name="$identity_name" '
    /Valid identities only/ { valid_section=1 }
    !valid_section && index($0, "\"" name "\"") { found=1 }
    END { exit !found }
'; then
    print -u2 "Another SoftLock Local Development identity already exists. Select its fingerprint explicitly with SOFTLOCK_SIGNING_IDENTITY; no identity was created."
    exit 1
fi

umask 077
temporary="$(mktemp -d "${TMPDIR:-/private/tmp}/softlock-signing.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$temporary/certificate.cnf" <<'EOF'
[req]
distinguished_name = subject
x509_extensions = code_signing
prompt = no
[subject]
CN = SoftLock Local Development
[code_signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
/usr/bin/openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -config "$temporary/certificate.cnf" -keyout "$temporary/key.pem" \
    -out "$temporary/certificate.pem" 2> "$temporary/generation.log"
transfer_password="$(/usr/bin/openssl rand -hex 32)"
/usr/bin/openssl pkcs12 -export -name "$identity_name" \
    -inkey "$temporary/key.pem" -in "$temporary/certificate.pem" \
    -out "$temporary/identity.p12" -passout "pass:$transfer_password"
keychain="$(security default-keychain -d user | sed 's/^ *"//;s/"$//')"
[[ -n "$keychain" ]] || { print -u2 "No user keychain is available."; exit 1; }
print -u2 "Creating a persistent SoftLock signing identity in the user keychain (no system trust changes)."
security import "$temporary/identity.p12" -k "$keychain" -f pkcs12 \
    -P "$transfer_password" -T /usr/bin/codesign >&2
# Select the freshly generated public certificate by fingerprint, never its name.
expected_identity="$(/usr/bin/openssl x509 -in "$temporary/certificate.pem" -noout -fingerprint -sha1 | sed 's/.*=//;s/://g')"
identity="$(find_identity)"
[[ -n "$identity" && "$identity" != *$'\n'* ]] || { print -u2 "Cannot find the imported SoftLock identity."; exit 1; }
print -r -- "$identity"
