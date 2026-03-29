#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Mirror all gists for a GitHub account.

Usage:
  mirror-github-gists.sh --account ACCOUNT [--dest DIR] [--token TOKEN] [--token-file FILE] [--dry-run] [--gist-regex REGEX]

Options:
  -a, --account ACCOUNT   GitHub username whose gists will be mirrored (required)
  -d, --dest DIR          Destination directory for mirrored gists (default: ./mirrors-gists)
  -t, --token TOKEN       GitHub token (or set GITHUB_TOKEN env var)
  -T, --token-file FILE   Read .env-style credentials file (ACCOUNT/GITHUB_TOKEN)
  -n, --dry-run           Print planned actions without cloning/fetching
  -r, --gist-regex REGEX  Only process gists whose ID matches REGEX
  -h, --help              Show this help

Notes:
  - Existing mirrors are updated with fetch --prune.
  - New gists are mirrored with git clone --mirror.
  - Credential file supports ACCOUNT/GITHUB_ACCOUNT and TOKEN/GITHUB_TOKEN.
  - For private gists, pass a token that belongs to the same ACCOUNT.
  - Uses curl when available, otherwise falls back to wget.
EOF
}

err() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Required command not found: $1"
}

select_http_client() {
  if command -v curl >/dev/null 2>&1; then
    HTTP_CLIENT="curl"
  elif command -v wget >/dev/null 2>&1; then
    HTTP_CLIENT="wget"
  else
    err "Required command not found: curl or wget"
  fi
}

url_encode() {
  local str="$1"
  local out=""
  local i c
  for ((i=0; i<${#str}; i++)); do
    c="${str:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v out '%s%%%02X' "$out" "'$c" ;;
    esac
  done
  printf '%s' "$out"
}

extract_json_string_field() {
  local json="$1"
  local field="$2"
  printf '%s\n' "$json" | awk -v key="$field" '
    BEGIN {
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\""
    }
    {
      if (match($0, pattern)) {
        rest = substr($0, RSTART + RLENGTH)
        if (match(rest, /"/)) {
          print substr(rest, 1, RSTART - 1)
          exit
        }
      }
    }
  '
}

json_gist_id_and_clone_url() {
  local json="$1"

  printf '%s' "$json" | tr -d '\n\r' | awk '
    function emit_gist(obj, gist_id, clone_url) {
      gist_id = ""
      clone_url = ""

      if (match(obj, /"id"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
        gist_id = substr(obj, RSTART, RLENGTH)
        sub(/^"id"[[:space:]]*:[[:space:]]*"/, "", gist_id)
        sub(/"$/, "", gist_id)
      }

      if (match(obj, /"git_pull_url"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
        clone_url = substr(obj, RSTART, RLENGTH)
        sub(/^"git_pull_url"[[:space:]]*:[[:space:]]*"/, "", clone_url)
        sub(/"$/, "", clone_url)
      }

      if (gist_id != "" && clone_url != "") {
        print gist_id "\t" clone_url
      }
    }

    BEGIN {
      array_level = 0
      object_level = 0
      in_string = 0
      escaped = 0
      object = ""
    }

    {
      data = $0
      for (i = 1; i <= length(data); i++) {
        c = substr(data, i, 1)

        if (in_string) {
          if (object_level > 0) {
            object = object c
          }

          if (escaped) {
            escaped = 0
          } else if (c == "\\") {
            escaped = 1
          } else if (c == "\"") {
            in_string = 0
          }
          continue
        }

        if (c == "\"") {
          in_string = 1
          if (object_level > 0) {
            object = object c
          }
          continue
        }

        if (c == "[") {
          array_level++
          continue
        }

        if (c == "]") {
          array_level--
          if (array_level == 0) {
            break
          }
          continue
        }

        if (c == "{") {
          if (object_level == 0) {
            object = ""
          }
          object_level++
          object = object c
          continue
        }

        if (c == "}") {
          if (object_level > 0) {
            object = object c
            object_level--
            if (object_level == 0) {
              emit_gist(object)
              object = ""
            }
          }
          continue
        }

        if (object_level > 0) {
          object = object c
        }
      }
    }
  '
}

http_get() {
  local url="$1"
  if [[ "$HTTP_CLIENT" == "curl" ]]; then
    if [[ -n "$TOKEN" ]]; then
      curl -fsSL -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${TOKEN}" "$url"
    else
      curl -fsSL -H "Accept: application/vnd.github+json" "$url"
    fi
  else
    if [[ -n "$TOKEN" ]]; then
      wget -qO- --header="Accept: application/vnd.github+json" --header="Authorization: Bearer ${TOKEN}" "$url"
    else
      wget -qO- --header="Accept: application/vnd.github+json" "$url"
    fi
  fi
}

get_authenticated_login() {
  [[ -z "$TOKEN" ]] && return 0
  local data
  data="$(http_get "https://api.github.com/user")" || return 1
  extract_json_string_field "$data" "login"
}

list_gists() {
  local account="$1"
  local auth_login="$2"

  local page=1
  local endpoint=""
  local page_data=""
  local rows=""

  while :; do
    if [[ -n "$TOKEN" && -n "$auth_login" && "$account" == "$auth_login" ]]; then
      endpoint="https://api.github.com/gists?per_page=100&page=${page}"
      USED_AUTH_GISTS_ENDPOINT="1"
    else
      endpoint="https://api.github.com/users/${account}/gists?per_page=100&page=${page}"
    fi

    page_data="$(http_get "$endpoint")" || {
      echo "Failed to fetch gist page ${page}" >&2
      return 1
    }

    local trimmed first_char
    trimmed="${page_data#"${page_data%%[![:space:]]*}"}"
    first_char="${trimmed:0:1}"
    if [[ "$first_char" != "[" ]]; then
      echo "GitHub API returned a non-gist response on page ${page}." >&2
      echo "This is often caused by rate limiting or insufficient token permissions." >&2
      return 1
    fi

    if printf '%s\n' "$page_data" | grep -q '"public"[[:space:]]*:[[:space:]]*false'; then
      PRIVATE_GISTS_VISIBLE="1"
    fi

    rows="$(json_gist_id_and_clone_url "$page_data")"
    if [[ -z "$rows" ]]; then
      break
    fi

    printf '%s\n' "$rows"
    ((page++))
  done
}

auth_clone_url() {
  local clean_url="$1"
  if [[ -n "$TOKEN" ]]; then
    local enc_token
    enc_token="$(url_encode "$TOKEN")"
    printf '%s\n' "$clean_url" | sed "s#^https://#https://x-access-token:${enc_token}@#"
  else
    printf '%s' "$clean_url"
  fi
}

safe_clone_url() {
  local clean_url="$1"
  printf '%s' "$clean_url"
}

load_credentials_file() {
  local creds_file="$1"
  local first_plain_value=""

  [[ ! -r "$creds_file" ]] && err "Token file is not readable: ${creds_file}"

  while IFS= read -r line || [[ -n "$line" ]]; do
    local trimmed key key_normalized value

    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    trimmed="${trimmed%$'\r'}"
    trimmed="${trimmed#$'\xEF\xBB\xBF'}"

    [[ -z "$trimmed" ]] && continue
    [[ "${trimmed:0:1}" == "#" ]] && continue

    if [[ "$trimmed" == export[[:space:]]* ]]; then
      trimmed="${trimmed#export}"
      trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    fi

    if [[ "$trimmed" != *=* ]]; then
      if [[ -z "$first_plain_value" ]]; then
        first_plain_value="$trimmed"
      fi
      continue
    fi

    key="${trimmed%%=*}"
    value="${trimmed#*=}"

    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value%$'\r'}"
    key_normalized="${key^^}"

    if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    fi

    case "$key_normalized" in
      ACCOUNT|GITHUB_ACCOUNT)
        if [[ "$ACCOUNT_SET_BY_ARG" == "0" && -z "$ACCOUNT" ]]; then
          ACCOUNT="$value"
        fi
        ;;
      TOKEN|GITHUB_TOKEN)
        if [[ "$TOKEN_SET_BY_ARG" == "0" && -z "$TOKEN" ]]; then
          TOKEN="$value"
        fi
        ;;
      *)
        ;;
    esac
  done < "$creds_file"

  # Backward compatibility: token-only file using first non-comment line.
  if [[ "$TOKEN_SET_BY_ARG" == "0" && -z "$TOKEN" && -n "$first_plain_value" ]]; then
    TOKEN="$first_plain_value"
  fi
}

clone_or_update_gist() {
  local gist_id="$1"
  local clone_url="$2"
  local dest_dir="$3"

  local gist_path auth_url clean_url
  gist_path="${dest_dir}/${gist_id}.git"
  auth_url="$(auth_clone_url "$clone_url")"
  clean_url="$(safe_clone_url "$clone_url")"

  if [[ -d "$gist_path" ]]; then
    if [[ ! -f "$gist_path/HEAD" ]]; then
      echo "Skipping ${gist_id}: ${gist_path} exists but does not look like a git mirror"
      LAST_ACTION="skipped"
      return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[dry-run] update ${gist_id} -> ${gist_path}"
      LAST_ACTION="planned_update"
      return 0
    fi

    echo "Updating ${gist_id}"
    if [[ -n "$TOKEN" ]]; then
      if ! git -C "$gist_path" fetch --prune "$auth_url" '+refs/*:refs/*'; then
        echo "Update failed for ${gist_id}" >&2
        return 1
      fi
    else
      if ! git -C "$gist_path" remote update --prune; then
        echo "Update failed for ${gist_id}" >&2
        return 1
      fi
    fi

    LAST_ACTION="updated"
  else
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[dry-run] mirror ${gist_id} -> ${gist_path}"
      LAST_ACTION="planned_mirror"
      return 0
    fi

    echo "Mirroring ${gist_id}"
    if ! git clone --mirror "$auth_url" "$gist_path"; then
      echo "Mirror failed for ${gist_id}" >&2
      return 1
    fi

    if ! git -C "$gist_path" remote set-url origin "$clean_url"; then
      echo "Failed to set clean origin URL for ${gist_id}" >&2
      return 1
    fi

    LAST_ACTION="mirrored"
  fi
}

ACCOUNT=""
DEST_DIR="./mirrors-gists"
TOKEN="${GITHUB_TOKEN:-}"
TOKEN_FILE=""
DRY_RUN="0"
GIST_REGEX=""
ACCOUNT_SET_BY_ARG="0"
TOKEN_SET_BY_ARG="0"
USED_AUTH_GISTS_ENDPOINT="0"
PRIVATE_GISTS_VISIBLE="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--account)
      [[ $# -lt 2 ]] && err "Missing value for $1"
      ACCOUNT="$2"
      ACCOUNT_SET_BY_ARG="1"
      shift 2
      ;;
    -d|--dest)
      [[ $# -lt 2 ]] && err "Missing value for $1"
      DEST_DIR="$2"
      shift 2
      ;;
    -t|--token)
      [[ $# -lt 2 ]] && err "Missing value for $1"
      TOKEN="$2"
      TOKEN_SET_BY_ARG="1"
      shift 2
      ;;
    -T|--token-file)
      [[ $# -lt 2 ]] && err "Missing value for $1"
      TOKEN_FILE="$2"
      shift 2
      ;;
    -n|--dry-run)
      DRY_RUN="1"
      shift
      ;;
    -r|--gist-regex)
      [[ $# -lt 2 ]] && err "Missing value for $1"
      GIST_REGEX="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      ;;
  esac
done

if [[ -n "$TOKEN_FILE" ]]; then
  load_credentials_file "$TOKEN_FILE"
elif [[ "$TOKEN_SET_BY_ARG" == "1" && -r "$TOKEN" ]]; then
  # Compatibility: if --token points to a readable file, treat it as credentials file.
  TOKEN_FILE="$TOKEN"
  TOKEN=""
  TOKEN_SET_BY_ARG="0"
  load_credentials_file "$TOKEN_FILE"
fi

if [[ -n "$GIST_REGEX" ]]; then
  set +e
  printf '' | grep -E "$GIST_REGEX" >/dev/null 2>&1
  regex_status=$?
  set -e
  if [[ "$regex_status" -eq 2 ]]; then
    err "Invalid regular expression for --gist-regex: ${GIST_REGEX}"
  fi
fi

[[ -z "$ACCOUNT" ]] && {
  usage
  err "--account is required"
}

require_cmd git
require_cmd awk
select_http_client

mkdir -p "$DEST_DIR"

auth_login=""
if [[ -n "$TOKEN" ]]; then
  auth_login="$(get_authenticated_login || true)"
  if [[ -n "$auth_login" && "$auth_login" != "$ACCOUNT" ]]; then
    echo "Token belongs to ${auth_login}; private gists are only available when --account matches token owner"
  fi
fi

echo "Listing gists for ${ACCOUNT}..."
gist_rows_file="$(mktemp)"
if ! list_gists "$ACCOUNT" "$auth_login" >"$gist_rows_file"; then
  rm -f "$gist_rows_file"
  err "Failed to list gists for ${ACCOUNT}"
fi

if ! grep -q '[^[:space:]]' "$gist_rows_file"; then
  rm -f "$gist_rows_file"
  echo "No gists found for ${ACCOUNT}"
  exit 0
fi

mapfile -t gist_rows <"$gist_rows_file"
rm -f "$gist_rows_file"

echo "Found ${#gist_rows[@]} gists"

if [[ -n "$TOKEN" && "$USED_AUTH_GISTS_ENDPOINT" == "1" && "$PRIVATE_GISTS_VISIBLE" == "0" ]]; then
  echo "Note: authenticated listing did not include any secret gists."
  echo "      If you expect secret gists, verify token access:"
  echo "      - classic PAT requires 'gist' scope (combined read/write; no read-only gist scope)"
  echo "      - fine-grained PATs may only return public gists; use classic PAT for secrets"
fi

gists=()
filtered_skip_count=0
for row in "${gist_rows[@]}"; do
  gist_id="${row%%$'\t'*}"
  clone_url="${row##*$'\t'}"

  if [[ -n "$GIST_REGEX" && ! "$gist_id" =~ $GIST_REGEX ]]; then
    echo "Skipping non-matching gist ${gist_id}"
    ((filtered_skip_count+=1))
    continue
  fi

  gists+=("${gist_id}"$'\t'"${clone_url}")
done

if [[ ${#gists[@]} -eq 0 ]]; then
  echo "No gists to mirror after filters"
  exit 0
fi

echo "Processing ${#gists[@]} gists"

failed_count=0
mirrored_count=0
updated_count=0
skipped_count="$filtered_skip_count"
planned_mirror_count=0
planned_update_count=0
for row in "${gists[@]}"; do
  gist_id="${row%%$'\t'*}"
  clone_url="${row##*$'\t'}"

  if ! clone_or_update_gist "$gist_id" "$clone_url" "$DEST_DIR"; then
    ((failed_count+=1))
    echo "Failed ${gist_id}; continuing"
    continue
  fi

  case "$LAST_ACTION" in
    mirrored)
      ((mirrored_count+=1))
      ;;
    updated)
      ((updated_count+=1))
      ;;
    skipped)
      ((skipped_count+=1))
      ;;
    planned_mirror)
      ((planned_mirror_count+=1))
      ;;
    planned_update)
      ((planned_update_count+=1))
      ;;
    *)
      ;;
  esac
done

echo "Summary:"
echo "  selected: ${#gists[@]}"
echo "  skipped: ${skipped_count}"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "  planned_mirror: ${planned_mirror_count}"
  echo "  planned_update: ${planned_update_count}"
else
  echo "  mirrored: ${mirrored_count}"
  echo "  updated: ${updated_count}"
fi
echo "  failed: ${failed_count}"

if [[ "$failed_count" -gt 0 ]]; then
  echo "Done with ${failed_count} failed gists"
  exit 1
fi

echo "Done"
