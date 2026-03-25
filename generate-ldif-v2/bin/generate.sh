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

DIRECTORY_PATH="${1:-$ROOT_DIR/${DIRECTORY_FILE:-directory.yaml}}"
GENERATED_PATH="$ROOT_DIR/${GENERATED_DIR:-generated}"
USERS_TSV="$GENERATED_PATH/users.tsv"
GROUPS_TSV="$GENERATED_PATH/groups.tsv"
PLAN_TXT="$GENERATED_PATH/plan.txt"
USERS_LDIF="$GENERATED_PATH/users.preview.ldif"
GROUPS_LDIF="$GENERATED_PATH/groups.preview.ldif"

mkdir -p "$GENERATED_PATH"

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

require_bin yq
require_bin openssl
require_bin base64
require_bin awk
require_bin sort
require_bin tr

if [[ ! -f "$DIRECTORY_PATH" ]]; then
  printf 'Directory file not found: %s\n' "$DIRECTORY_PATH" >&2
  exit 1
fi

ssha_hash() {
  local plain="$1"
  local salt digest combined
  salt="$(openssl rand -out /dev/stdout 4 | base64 | tr -d '=+/\n' | cut -c1-4)"
  digest="$(printf '%s%s' "$plain" "$salt" | openssl dgst -binary -sha1 | base64)"
  combined="$(printf '%s%s' "$(printf '%s%s' "$plain" "$salt" | openssl dgst -binary -sha1)" "$salt" | base64 | tr -d '\n')"
  printf '{SSHA}%s\n' "$combined"
}

random_password() {
  local length="${DEFAULT_PASSWORD_LENGTH:-18}"
  openssl rand -base64 48 | tr -d '\n' | tr '/+' 'AZ' | cut -c1-"$length"
}

trim() {
  awk '{gsub(/^[ \t]+|[ \t]+$/, ""); print}' <<<"$1"
}

users_count="$(yq '.users | length // 0' "$DIRECTORY_PATH")"
groups_count="$(yq '.groups | length // 0' "$DIRECTORY_PATH")"
uid_start="$(yq -r '.uid_start // ""' "$DIRECTORY_PATH")"
gid_start="$(yq -r '.gid_start // ""' "$DIRECTORY_PATH")"
uid_start="${uid_start:-${DEFAULT_UID_START:-7000}}"
gid_start="${gid_start:-${DEFAULT_GID_START:-6000}}"

: > "$USERS_TSV"
: > "$GROUPS_TSV"
: > "$PLAN_TXT"
: > "$USERS_LDIF"
: > "$GROUPS_LDIF"

printf 'uid\tdn\tgivenName\tsn\tdisplayName\tmail\tuidNumber\tgidNumber\thomeDirectory\tloginShell\tpasswordSource\tpasswordPlain\tpasswordHash\n' > "$USERS_TSV"
printf 'groupName\tdn\tgidNumber\tmembers\n' > "$GROUPS_TSV"

current_uid="$uid_start"
current_gid="$gid_start"

declare -A seen_users=()
declare -A direct_group_members=()
declare -A all_groups=()

append_group_member() {
  local group_name="$1"
  local member_uid="$2"
  local current_value="${direct_group_members[$group_name]:-}"

  if [[ -z "$current_value" ]]; then
    direct_group_members["$group_name"]="$member_uid"
  else
    direct_group_members["$group_name"]+="|$member_uid"
  fi
}

group_member_join() {
  local group_name="$1"
  local value="${direct_group_members[$group_name]:-}"
  printf '%s' "$value"
}

# Preload groups
if (( groups_count > 0 )); then
  for ((i=0; i<groups_count; i++)); do
    group_name="$(yq -r ".groups[$i].name // \"\"" "$DIRECTORY_PATH")"
    group_name="$(trim "$group_name")"
    [[ -n "$group_name" ]] || { printf 'Group at index %s has empty name\n' "$i" >&2; exit 1; }
    [[ -z "${all_groups[$group_name]:-}" ]] || { printf 'Duplicate group name: %s\n' "$group_name" >&2; exit 1; }
    all_groups["$group_name"]="1"

    member_count="$(yq ".groups[$i].members | length // 0" "$DIRECTORY_PATH")"
    if (( member_count > 0 )); then
      for ((j=0; j<member_count; j++)); do
        member_uid="$(yq -r ".groups[$i].members[$j] // \"\"" "$DIRECTORY_PATH")"
        member_uid="$(trim "$member_uid")"
        [[ -n "$member_uid" ]] || continue
        append_group_member "$group_name" "$member_uid"
      done
    fi
  done
fi

# Users
if (( users_count > 0 )); then
  for ((i=0; i<users_count; i++)); do
    uid="$(yq -r ".users[$i].uid // .users[$i].id // \"\"" "$DIRECTORY_PATH")"
    uid="$(trim "$uid")"
    given_name="$(yq -r ".users[$i].givenName // .users[$i].name // \"\"" "$DIRECTORY_PATH")"
    sn="$(yq -r ".users[$i].sn // .users[$i].surname // \"\"" "$DIRECTORY_PATH")"
    mail="$(yq -r ".users[$i].mail // \"\"" "$DIRECTORY_PATH")"
    plain_password="$(yq -r ".users[$i].password // \"\"" "$DIRECTORY_PATH")"
    explicit_uid="$(yq -r ".users[$i].uidNumber // .users[$i].uid_number // \"\"" "$DIRECTORY_PATH")"
    explicit_gid="$(yq -r ".users[$i].gidNumber // .users[$i].gid_number // \"\"" "$DIRECTORY_PATH")"
    display_name="$(yq -r ".users[$i].displayName // \"\"" "$DIRECTORY_PATH")"
    home_directory="$(yq -r ".users[$i].homeDirectory // \"\"" "$DIRECTORY_PATH")"
    login_shell="$(yq -r ".users[$i].loginShell // \"\"" "$DIRECTORY_PATH")"

    [[ -n "$uid" ]] || { printf 'User at index %s has empty uid/id\n' "$i" >&2; exit 1; }
    [[ -n "$given_name" ]] || { printf 'User %s has empty givenName/name\n' "$uid" >&2; exit 1; }
    [[ -n "$sn" ]] || { printf 'User %s has empty sn/surname\n' "$uid" >&2; exit 1; }
    [[ -z "${seen_users[$uid]:-}" ]] || { printf 'Duplicate user uid: %s\n' "$uid" >&2; exit 1; }
    seen_users["$uid"]="1"

    if [[ -z "$display_name" ]]; then
      display_name="$given_name $sn"
    fi

    if [[ -z "$mail" ]]; then
      mail="$uid@${DEFAULT_MAIL_DOMAIN:-sasldap.com}"
    fi

    if [[ -z "$home_directory" ]]; then
      home_directory="${DEFAULT_HOME_PREFIX:-/home}/$uid"
    fi

    if [[ -z "$login_shell" ]]; then
      login_shell="${DEFAULT_LOGIN_SHELL:-/bin/bash}"
    fi

    if [[ -n "$explicit_uid" && "$explicit_uid" != "null" ]]; then
      uid_number="$explicit_uid"
    else
      uid_number="$current_uid"
      current_uid=$((current_uid + 1))
    fi

    if [[ -n "$explicit_gid" && "$explicit_gid" != "null" ]]; then
      gid_number="$explicit_gid"
    else
      gid_number="$uid_number"
    fi

    if [[ -n "$plain_password" ]]; then
      password_source="explicit"
    else
      password_source="generated"
      plain_password="$(random_password)"
    fi

    password_hash="$(ssha_hash "$plain_password")"
    dn="uid=$uid,${LDAP_USERS_OU:-ou=users},${LDAP_BASE_DN:?}"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$uid" "$dn" "$given_name" "$sn" "$display_name" "$mail" "$uid_number" "$gid_number" "$home_directory" "$login_shell" "$password_source" "$plain_password" "$password_hash" >> "$USERS_TSV"

    cat >> "$USERS_LDIF" <<EOF

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

    user_group_count="$(yq ".users[$i].groups | length // 0" "$DIRECTORY_PATH")"
    if (( user_group_count > 0 )); then
      for ((j=0; j<user_group_count; j++)); do
        group_name="$(yq -r ".users[$i].groups[$j] // \"\"" "$DIRECTORY_PATH")"
        group_name="$(trim "$group_name")"
        [[ -n "$group_name" ]] || continue
        all_groups["$group_name"]="1"
        append_group_member "$group_name" "$uid"
      done
    fi
  done
fi

# Validate group members exist and write groups TSV
for group_name in "${!all_groups[@]}"; do
  deduped_members=""

  while IFS= read -r member_uid; do
    member_uid="$(trim "$member_uid")"
    [[ -n "$member_uid" ]] || continue
    [[ -n "${seen_users[$member_uid]:-}" ]] || { printf 'Group %s references unknown user: %s\n' "$group_name" "$member_uid" >&2; exit 1; }
    case ",$deduped_members," in
      *",$member_uid,"*) ;;
      *) deduped_members+="${deduped_members:+,}$member_uid" ;;
    esac
  done < <(
    {
      yq -r ".groups[]? | select(.name == \"$group_name\") | .members[]?" "$DIRECTORY_PATH"
      yq -r '.users[]? | [(.uid // .id // ""), ((.groups // [])[]?)] | @tsv' "$DIRECTORY_PATH" \
        | awk -F '\t' -v target="$group_name" '$2 == target { print $1 }'
    } | sed '/^null$/d' | sed '/^$/d'
  )

  [[ -n "$deduped_members" ]] || { printf 'Group %s has no members after merge\n' "$group_name" >&2; exit 1; }

  explicit_gid="$(yq -r ".groups[]? | select(.name == \"$group_name\") | (.gid // .gidNumber // \"\")" "$DIRECTORY_PATH" | head -n1)"
  if [[ -n "$explicit_gid" && "$explicit_gid" != "null" ]]; then
    gid_number="$explicit_gid"
  else
    gid_number="$current_gid"
    current_gid=$((current_gid + 1))
  fi

  dn="cn=$group_name,${LDAP_GROUPS_OU:-ou=groups},${LDAP_BASE_DN:?}"
  printf '%s\t%s\t%s\t%s\n' "$group_name" "$dn" "$gid_number" "$deduped_members" >> "$GROUPS_TSV"

  {
    printf '\ndn: %s\n' "$dn"
    printf 'objectClass: groupOfNames\n'
    printf 'objectClass: posixGroup\n'
    printf 'objectClass: top\n'
    printf 'gidNumber: %s\n' "$gid_number"
    printf 'cn: %s\n' "$group_name"
    while IFS= read -r member_uid; do
      [[ -n "$member_uid" ]] || continue
      printf 'member: uid=%s,%s,%s\n' "$member_uid" "${LDAP_USERS_OU:-ou=users}" "${LDAP_BASE_DN:?}"
    done < <(printf '%s\n' "$deduped_members" | tr ',' '\n')
    printf 'o: %s\n' "${DEFAULT_ORGANIZATION:-SAS Institute}"
  } >> "$GROUPS_LDIF"
done

{
  printf 'Users: %s\n' "$users_count"
  printf 'Groups: %s\n' "${#all_groups[@]}"
  printf 'Users TSV: %s\n' "$USERS_TSV"
  printf 'Groups TSV: %s\n' "$GROUPS_TSV"
  printf 'Users preview LDIF: %s\n' "$USERS_LDIF"
  printf 'Groups preview LDIF: %s\n' "$GROUPS_LDIF"
} | tee "$PLAN_TXT"
