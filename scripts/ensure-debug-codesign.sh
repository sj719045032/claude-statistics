#!/bin/bash
set -euo pipefail

DEBUG_CODE_SIGN_IDENTITY="${DEBUG_CODE_SIGN_IDENTITY:-Claude Statistics Debug Code Signing}"
DEBUG_CODE_SIGN_VALID_DAYS="${DEBUG_CODE_SIGN_VALID_DAYS:-3650}"
DEBUG_CODE_SIGN_ORGANIZATION="${DEBUG_CODE_SIGN_ORGANIZATION:-Claude Statistics Debug}"
DEBUG_CODE_SIGN_KEYCHAIN="${DEBUG_CODE_SIGN_KEYCHAIN:-}"
DEBUG_CODE_SIGN_P12_PASSWORD="${DEBUG_CODE_SIGN_P12_PASSWORD:-}"
DEBUG_CODE_SIGN_SET_PARTITION_LIST="${DEBUG_CODE_SIGN_SET_PARTITION_LIST:-0}"
DEBUG_CODE_SIGN_KEYCHAIN_PASSWORD="${DEBUG_CODE_SIGN_KEYCHAIN_PASSWORD:-}"

usage() {
  cat <<EOF
Usage: bash scripts/ensure-debug-codesign.sh [--check]

Ensures the local code-signing identity "${DEBUG_CODE_SIGN_IDENTITY}" exists in
the user's keychain. When missing, creates a self-signed identity for stable
local debug signing.

Environment variables:
  DEBUG_CODE_SIGN_IDENTITY           Identity common name.
  DEBUG_CODE_SIGN_VALID_DAYS         Certificate validity in days. Default: 3650.
  DEBUG_CODE_SIGN_ORGANIZATION       Certificate organization field.
  DEBUG_CODE_SIGN_KEYCHAIN           Explicit keychain path/name to import into.
  DEBUG_CODE_SIGN_P12_PASSWORD       PKCS#12 export password. Auto-generated when empty.
  DEBUG_CODE_SIGN_SET_PARTITION_LIST Set to 1 to run set-key-partition-list.
  DEBUG_CODE_SIGN_KEYCHAIN_PASSWORD  Required when DEBUG_CODE_SIGN_SET_PARTITION_LIST=1.
EOF
}

resolve_keychain() {
  if [[ -n "${DEBUG_CODE_SIGN_KEYCHAIN}" ]]; then
    printf '%s\n' "${DEBUG_CODE_SIGN_KEYCHAIN}"
    return
  fi

  local keychain
  keychain="$(security default-keychain -d user | tr -d '"' | xargs)"
  if [[ -n "${keychain}" ]]; then
    printf '%s\n' "${keychain}"
    return
  fi

  printf '%s\n' "${HOME}/Library/Keychains/login.keychain-db"
}

has_identity() {
  local keychain="$1"
  security find-identity -v -p codesigning "${keychain}" 2>/dev/null | grep -Fq "\"${DEBUG_CODE_SIGN_IDENTITY}\""
}

check_requirements() {
  command -v openssl >/dev/null 2>&1 || {
    echo "ERROR: openssl not found" >&2
    exit 1
  }
  command -v security >/dev/null 2>&1 || {
    echo "ERROR: security not found" >&2
    exit 1
  }
}

MODE="create"
if [[ "${1:-}" == "--check" ]]; then
  MODE="check"
elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
elif [[ $# -gt 0 ]]; then
  usage >&2
  exit 1
fi

check_requirements

KEYCHAIN="$(resolve_keychain)"

if has_identity "${KEYCHAIN}"; then
  echo "==> Debug signing identity already present: ${DEBUG_CODE_SIGN_IDENTITY}"
  exit 0
fi

if [[ "${MODE}" == "check" ]]; then
  echo "==> Debug signing identity missing: ${DEBUG_CODE_SIGN_IDENTITY}"
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-stats-codesign.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

KEY_PEM="${TMP_DIR}/debug-signing.key.pem"
KEY_PK8="${TMP_DIR}/debug-signing.key.pk8"
CERT_PEM="${TMP_DIR}/debug-signing.cert.pem"
P12_PATH="${TMP_DIR}/debug-signing.identity.p12"
OPENSSL_CONFIG="${TMP_DIR}/debug-signing.openssl.cnf"

cat > "${OPENSSL_CONFIG}" <<EOF
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_codesign

[ dn ]
CN = ${DEBUG_CODE_SIGN_IDENTITY}
O = ${DEBUG_CODE_SIGN_ORGANIZATION}

[ v3_codesign ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

if [[ -z "${DEBUG_CODE_SIGN_P12_PASSWORD}" ]]; then
  DEBUG_CODE_SIGN_P12_PASSWORD="$(openssl rand -hex 16)"
fi

echo "==> Creating self-signed debug code-signing identity: ${DEBUG_CODE_SIGN_IDENTITY}"
openssl req \
  -new \
  -newkey rsa:2048 \
  -x509 \
  -sha256 \
  -days "${DEBUG_CODE_SIGN_VALID_DAYS}" \
  -nodes \
  -keyout "${KEY_PEM}" \
  -out "${CERT_PEM}" \
  -config "${OPENSSL_CONFIG}" >/dev/null 2>&1

openssl pkcs12 \
  -legacy \
  -export \
  -inkey "${KEY_PEM}" \
  -in "${CERT_PEM}" \
  -out "${P12_PATH}" \
  -name "${DEBUG_CODE_SIGN_IDENTITY}" \
  -passout "pass:${DEBUG_CODE_SIGN_P12_PASSWORD}" >/dev/null 2>&1

if ! security import "${P12_PATH}" \
  -k "${KEYCHAIN}" \
  -f pkcs12 \
  -P "${DEBUG_CODE_SIGN_P12_PASSWORD}" \
  -A \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null; then
  echo "==> PKCS#12 import failed; retrying with certificate + PKCS#8 key..."
  openssl pkcs8 \
    -topk8 \
    -nocrypt \
    -in "${KEY_PEM}" \
    -out "${KEY_PK8}" >/dev/null 2>&1

  security import "${CERT_PEM}" \
    -k "${KEYCHAIN}" \
    -t cert \
    -f openssl >/dev/null

  security import "${KEY_PK8}" \
    -k "${KEYCHAIN}" \
    -t priv \
    -f pkcs8 \
    -A \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null
fi

if [[ "${DEBUG_CODE_SIGN_SET_PARTITION_LIST}" == "1" ]]; then
  if [[ -z "${DEBUG_CODE_SIGN_KEYCHAIN_PASSWORD}" ]]; then
    echo "ERROR: DEBUG_CODE_SIGN_KEYCHAIN_PASSWORD is required when DEBUG_CODE_SIGN_SET_PARTITION_LIST=1" >&2
    exit 1
  fi
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "${DEBUG_CODE_SIGN_KEYCHAIN_PASSWORD}" \
    "${KEYCHAIN}" >/dev/null
fi

if ! has_identity "${KEYCHAIN}"; then
  echo "ERROR: Failed to register debug signing identity in keychain ${KEYCHAIN}" >&2
  exit 1
fi

echo "==> Debug signing identity is ready in ${KEYCHAIN}"
