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

EXPORT_FILE="${1:-$ROOT_DIR/export-no-root.ldif}"
USERS_BASE_DN="${LDAP_USERS_OU},${LDAP_BASE_DN}"
GROUPS_BASE_DN="${LDAP_GROUPS_OU},${LDAP_BASE_DN}"

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

require_bin ldapsearch
require_bin mktemp

USER_FILTER='(&(objectClass=posixAccount)(!(uid=sas))(!(uid=cas))(!(uid=sasadm))(!(uid=sasdev))(!(uid=sasuser)))'
GROUP_FILTER='(&(objectClass=groupOfNames)(!(cn=sas))(!(cn=sasadmins))(!(cn=sasdevs))(!(cn=sasusers)))'

user_tmp="$(mktemp)"
group_tmp="$(mktemp)"
trap 'rm -f "$user_tmp" "$group_tmp"' EXIT

ldapsearch -x -LLL -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
  -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
  -b "$USERS_BASE_DN" "$USER_FILTER" > "$user_tmp"

ldapsearch -x -LLL -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
  -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
  -b "$GROUPS_BASE_DN" "$GROUP_FILTER" > "$group_tmp"

mkdir -p "$(dirname "$EXPORT_FILE")"
{
  printf '# export-no-root.ldif\n'
  printf '# Exported from live LDAP\n\n'
  cat "$user_tmp"
  printf '\n'
  cat "$group_tmp"
  printf '\n'
} > "$EXPORT_FILE"

printf 'Export created: %s\n' "$EXPORT_FILE"
printf 'Users base DN: %s\n' "$USERS_BASE_DN"
printf 'Groups base DN: %s\n' "$GROUPS_BASE_DN"
printf 'User filter: %s\n' "$USER_FILTER"
printf 'Group filter: %s\n' "$GROUP_FILTER"
