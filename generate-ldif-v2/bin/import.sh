#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  printf 'Missing .env file: %s\n' "$ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

LDIF_FILE="${1:-$ROOT_DIR/export-no-root.ldif}"
MODE="${2:-add}"

if [[ ! -f "$LDIF_FILE" ]]; then
  printf 'LDIF file not found: %s\n' "$LDIF_FILE" >&2
  exit 1
fi

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

require_bin ldapadd
require_bin ldapmodify

case "$MODE" in
  add)
    ldapadd -x -c -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
      -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
      -f "$LDIF_FILE"
    ;;
  modify)
    ldapmodify -x -c -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
      -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
      -f "$LDIF_FILE"
    ;;
  *)
    printf 'Unsupported mode: %s (use: add|modify)\n' "$MODE" >&2
    exit 1
    ;;
 esac
