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

GENERATED_PATH="$ROOT_DIR/${GENERATED_DIR:-generated}"
USERS_TSV="$GENERATED_PATH/users.tsv"
GROUPS_TSV="$GENERATED_PATH/groups.tsv"
NEW_PASSWORDS_REPORT="$GENERATED_PATH/new-user-passwords.txt"

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

require_bin kubectl
require_bin awk
require_bin mktemp

if [[ ! -f "$USERS_TSV" || ! -f "$GROUPS_TSV" ]]; then
  printf 'Missing generated files. Run ./bin/generate.sh first.\n' >&2
  exit 1
fi

pod_name="$(kubectl get pod -n "$LDAP_NAMESPACE" -l "$LDAP_APP_LABEL" -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$pod_name" ]] || { printf 'No LDAP pod found in namespace %s\n' "$LDAP_NAMESPACE" >&2; exit 1; }

ldap_exec() {
  kubectl -n "$LDAP_NAMESPACE" exec "$pod_name" -- "$@"
}

ldap_entry_exists() {
  local dn="$1"
  ldap_exec ldapsearch -x -H "ldap://${LDAP_HOST}:${LDAP_PORT}" -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" -b "$dn" -s base '(objectClass=*)' dn >/dev/null 2>&1
}

apply_ldif_content() {
  local ldif_content="$1"
  local mode="$2"
  local tmp_file remote_file
  tmp_file="$(mktemp)"
  printf '%s' "$ldif_content" > "$tmp_file"
  remote_file="/tmp/$(basename "$tmp_file").ldif"
  kubectl cp "$tmp_file" "$LDAP_NAMESPACE/$pod_name:$remote_file" >/dev/null
  if [[ "$mode" == "add" ]]; then
    ldap_exec ldapadd -x -H "ldap://${LDAP_HOST}:${LDAP_PORT}" -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" -f "$remote_file" >/dev/null
  else
    ldap_exec ldapmodify -x -H "ldap://${LDAP_HOST}:${LDAP_PORT}" -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" -f "$remote_file" >/dev/null
  fi
  rm -f "$tmp_file"
  ldap_exec rm -f "$remote_file" >/dev/null 2>&1 || true
}

apply_ldif_file() {
  local local_file="$1"
  local mode="$2"
  local remote_file

  [[ -f "$local_file" ]] || {
    printf 'LDIF file not found: %s\n' "$local_file" >&2
    exit 1
  }

  remote_file="/tmp/$(basename "$local_file")"
  kubectl cp "$local_file" "$LDAP_NAMESPACE/$pod_name:$remote_file" >/dev/null
  if [[ "$mode" == "add" ]]; then
    ldap_exec ldapadd -x -H "ldap://${LDAP_HOST}:${LDAP_PORT}" -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" -f "$remote_file" >/dev/null
  else
    ldap_exec ldapmodify -x -H "ldap://${LDAP_HOST}:${LDAP_PORT}" -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" -f "$remote_file" >/dev/null
  fi
  ldap_exec rm -f "$remote_file" >/dev/null 2>&1 || true
}

ldap_group_has_member() {
  local group_dn="$1"
  local member_dn="$2"
  ldap_exec ldapsearch -x -LLL -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
    -b "$group_dn" -s base '(objectClass=*)' member 2>/dev/null \
    | awk -v target="member: $member_dn" '$0 == target { found=1 } END { exit(found ? 0 : 1) }'
}

ensure_required_ous() {
  ldap_entry_exists "${LDAP_USERS_OU},${LDAP_BASE_DN}" || {
    printf 'Missing users OU: %s,%s\n' "$LDAP_USERS_OU" "$LDAP_BASE_DN" >&2
    exit 1
  }
  ldap_entry_exists "${LDAP_GROUPS_OU},${LDAP_BASE_DN}" || {
    printf 'Missing groups OU: %s,%s\n' "$LDAP_GROUPS_OU" "$LDAP_BASE_DN" >&2
    exit 1
  }
}

ensure_required_ous

: > "$NEW_PASSWORDS_REPORT"
new_user_count=0
updated_user_count=0
group_add_count=0
group_update_count=0

while IFS=$'\t' read -r uid dn given_name sn display_name mail uid_number gid_number home_directory login_shell password_source password_plain password_hash; do
  [[ "$uid" == "uid" ]] && continue
  [[ -n "$uid" ]] || continue

  if ldap_entry_exists "$dn"; then
    read -r -d '' modify_ldif <<EOF || true
dn: $dn
changetype: modify
replace: cn
cn: $uid
-
replace: givenName
givenName: $given_name
-
replace: sn
sn: $sn
-
replace: displayName
displayName: $display_name
-
replace: mail
mail: $mail
-
replace: uidNumber
uidNumber: $uid_number
-
replace: gidNumber
gidNumber: $gid_number
-
replace: homeDirectory
homeDirectory: $home_directory
-
replace: loginShell
loginShell: $login_shell
-
replace: o
o: ${DEFAULT_ORGANIZATION:-SAS Institute}
-
replace: l
l: ${DEFAULT_LOCALITY:-Italy}
EOF

    if [[ "$password_source" == "explicit" ]]; then
      modify_ldif+=$'\n-\nreplace: userPassword\n'
      modify_ldif+="userPassword: $password_hash"
      modify_ldif+=$'\n'
    fi

    apply_ldif_content "$modify_ldif" modify
    updated_user_count=$((updated_user_count + 1))
  else
    read -r -d '' add_ldif <<EOF || true
dn: $dn
objectClass: inetOrgPerson
objectClass: organizationalPerson
objectClass: person
objectClass: posixAccount
objectClass: top
uid: $uid
cn: $uid
givenName: $given_name
sn: $sn
displayName: $display_name
mail: $mail
uidNumber: $uid_number
gidNumber: $gid_number
homeDirectory: $home_directory
loginShell: $login_shell
o: ${DEFAULT_ORGANIZATION:-SAS Institute}
l: ${DEFAULT_LOCALITY:-Italy}
userPassword: $password_hash
EOF
    apply_ldif_content "$add_ldif" add
    new_user_count=$((new_user_count + 1))
    printf '%s\t%s\n' "$uid" "$password_plain" >> "$NEW_PASSWORDS_REPORT"
  fi
done < "$USERS_TSV"

while IFS=$'\t' read -r group_name dn gid_number members_csv; do
  [[ "$group_name" == "groupName" ]] && continue
  [[ -n "$group_name" ]] || continue

  member_block=""
  while IFS= read -r member_uid; do
    [[ -n "$member_uid" ]] || continue
    member_block+="member: uid=${member_uid},${LDAP_USERS_OU},${LDAP_BASE_DN}"$'\n'
  done < <(printf '%s\n' "$members_csv" | tr ',' '\n')

  if ldap_entry_exists "$dn"; then
    while IFS= read -r member_uid; do
      [[ -n "$member_uid" ]] || continue
      member_dn="uid=${member_uid},${LDAP_USERS_OU},${LDAP_BASE_DN}"
      if ! ldap_group_has_member "$dn" "$member_dn"; then
        read -r -d '' group_member_add <<EOF || true
dn: $dn
changetype: modify
add: member
member: $member_dn
EOF
        apply_ldif_content "$group_member_add" modify
      fi
    done < <(printf '%s\n' "$members_csv" | tr ',' '\n')
    group_update_count=$((group_update_count + 1))
  else
    read -r -d '' group_add <<EOF || true
dn: $dn
objectClass: groupOfNames
objectClass: posixGroup
objectClass: top
gidNumber: $gid_number
cn: $group_name
${member_block}o: ${DEFAULT_ORGANIZATION:-SAS Institute}
EOF
    apply_ldif_content "$group_add" add
    group_add_count=$((group_add_count + 1))
  fi
done < "$GROUPS_TSV"

printf 'Apply completed.\n'
printf '  New users: %s\n' "$new_user_count"
printf '  Updated users: %s\n' "$updated_user_count"
printf '  New groups: %s\n' "$group_add_count"
printf '  Updated groups: %s\n' "$group_update_count"

if (( new_user_count > 0 )); then
  printf '\nNew user passwords (shown only for newly added users):\n'
  while IFS=$'\t' read -r uid password; do
    [[ -n "$uid" ]] || continue
    printf '  - %s -> %s\n' "$uid" "$password"
  done < "$NEW_PASSWORDS_REPORT"
else
  printf '\nNo new users added, so no generated passwords are shown.\n'
fi
