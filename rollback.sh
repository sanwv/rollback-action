#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'rollback-action: %s\n' "$*" >&2; exit 1; }
for cmd in bash ssh base64; do command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"; done
host=${INPUT_REMOTE_HOST:?remote_host is required}
user=${INPUT_REMOTE_USER:?remote_user is required}
port=${INPUT_REMOTE_PORT:-22}
target=${INPUT_TARGET:?target is required}
release_id=${INPUT_RELEASE_ID:-}
steps=${INPUT_STEPS:-}
[[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535)) || fail 'remote_port must be between 1 and 65535'
[[ "$host" =~ ^[A-Za-z0-9._:-]+$ ]] || fail 'remote_host contains unsupported characters'
[[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'remote_user contains unsupported characters'
[[ "$target" = /* && "$target" != / && "$target" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail 'target must be an absolute path containing only letters, digits, dot, underscore, slash, and hyphen'
[[ "$target" != *'/../'* && "$target" != */.. && "$target" != */./* && "$target" != */. ]] || fail 'target may not contain dot path components'
if [[ -n "$release_id" && -n "$steps" ]]; then fail 'release_id and steps are mutually exclusive'; fi
if [[ -n "$release_id" ]]; then
  [[ "$release_id" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'release_id contains unsupported characters'
  steps=0
else
  steps=${steps:-1}
  [[ "$steps" =~ ^[1-9][0-9]{0,2}$ ]] && ((steps <= 100)) || fail 'steps must be between 1 and 100'
fi

umask 077
tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT
key_file=$tmpdir/id
known_file=$tmpdir/known_hosts
printf '%s\n' "${INPUT_SSH_PRIVATE_KEY:?ssh_private_key is required}" > "$key_file"
chmod 600 "$key_file"
ssh_opts=(-i "$key_file" -p "$port" -o BatchMode=yes -o ConnectTimeout=20)
if [[ -n "${INPUT_SSH_KNOWN_HOSTS:-}" ]]; then
  printf '%s\n' "$INPUT_SSH_KNOWN_HOSTS" > "$known_file"
  chmod 600 "$known_file"
  ssh_opts+=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_file")
else
  ssh_opts+=(-o StrictHostKeyChecking=accept-new)
fi

before_b64=$(printf '%s' "${INPUT_SCRIPT_BEFORE:-}" | base64 -w0)
after_b64=$(printf '%s' "${INPUT_SCRIPT_AFTER:-}" | base64 -w0)
empty_arg=__ROLLBACK_ACTION_EMPTY__
requested_arg=${release_id:-$empty_arg}
before_arg=${before_b64:-$empty_arg}
after_arg=${after_b64:-$empty_arg}
remote_script=$(cat <<'REMOTE'
set -Eeuo pipefail
target=$1; requested=$2; steps=$3; before_b64=$4; after_b64=$5
[[ "$requested" != __ROLLBACK_ACTION_EMPTY__ ]] || requested=''
[[ "$before_b64" != __ROLLBACK_ACTION_EMPTY__ ]] || before_b64=''
[[ "$after_b64" != __ROLLBACK_ACTION_EMPTY__ ]] || after_b64=''
root="$target/releases"
[[ -d "$target" && -d "$root" ]] || { echo 'deployment target or releases directory does not exist' >&2; exit 1; }
exec 9>"$target/.deploy.lock"
flock -x 9
[[ -L "$target/current" ]] || { echo 'current is missing or is not a symlink' >&2; exit 1; }
current=$(realpath -e -- "$target/current")
root_real=$(realpath -e -- "$root")
[[ "$current" == "$root_real"/* && -d "$current" ]] || { echo 'current does not point to a valid release directory' >&2; exit 1; }
previous=${current##*/}
if [[ -n "$requested" ]]; then
  destination="$root/$requested"
  [[ -d "$destination" && ! -L "$destination" ]] || { echo "release does not exist: $requested" >&2; exit 1; }
  destination=$(realpath -e -- "$destination")
  [[ "$destination" == "$root_real"/* ]] || { echo 'requested release resolves outside releases directory' >&2; exit 1; }
  target_id=${destination##*/}
else
  # The deploy action generates lexically sortable UTC IDs: timestamp-run-attempt.
  # Do not use directory mtimes: rsync and maintenance can alter them.
  mapfile -t releases < <(find "$root_real" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort -r)
  current_index=-1
  for i in "${!releases[@]}"; do [[ "${releases[$i]}" == "$previous" ]] && current_index=$i; done
  [[ "$current_index" -ge 0 ]] || { echo 'current release is absent from release list' >&2; exit 1; }
  target_index=$((current_index + steps))
  ((target_index < ${#releases[@]})) || { echo "no older release available: current=$previous steps=$steps retained=${#releases[@]}" >&2; exit 1; }
  target_id=${releases[$target_index]}
  destination="$root_real/$target_id"
fi
if [[ "$destination" == "$current" ]]; then
  printf 'previous_release=%s\nrelease_id=%s\n' "$previous" "$target_id"
  echo "rollback-action: $target_id is already active; no switch needed"
  exit 0
fi
release_path="$root_real/$target_id"
run_hook() {
  local phase=$1 encoded=$2
  [[ -n "$encoded" ]] || return 0
  local body
  body=$(printf '%s' "$encoded" | base64 -d)
  (cd -- "$release_path" && ROLLBACK_TARGET="$target" ROLLBACK_CURRENT_RELEASE="$previous" ROLLBACK_RELEASE_ID="$target_id" ROLLBACK_RELEASE_PATH="$release_path" ROLLBACK_HOOK="$phase" bash -Eeuo pipefail -c "$body")
}
run_hook before "$before_b64"
tmp_link="$target/.current.rollback.$$"
ln -s -- "releases/$target_id" "$tmp_link"
mv -Tf -- "$tmp_link" "$target/current"
if ! run_hook after "$after_b64"; then
  restore="$target/.current.restore.$$"
  ln -s -- "releases/$previous" "$restore"
  mv -Tf -- "$restore" "$target/current"
  echo 'post-rollback script failed; current was restored to its previous release' >&2
  exit 1
fi
printf 'previous_release=%s\nrelease_id=%s\n' "$previous" "$target_id"
REMOTE
)
remote_output=$(printf '%s\n' "$remote_script" | ssh "${ssh_opts[@]}" "$user@$host" bash -s -- "$target" "$requested_arg" "$steps" "$before_arg" "$after_arg") || { status=$?; exit "$status"; }
printf '%s\n' "$remote_output"
previous=$(sed -n 's/^previous_release=//p' <<< "$remote_output" | tail -n1)
activated=$(sed -n 's/^release_id=//p' <<< "$remote_output" | tail -n1)
[[ -n "$previous" && -n "$activated" ]] || fail 'remote rollback did not return release outputs'
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  { printf 'previous_release=%s\n' "$previous"; printf 'release_id=%s\n' "$activated"; } >> "$GITHUB_OUTPUT"
fi
