#!/usr/bin/env bash
# Exercise the actual Alpine image, with only temporary local data and no network.
set -euo pipefail
image="${1:-salvage-crane-restic:audit}"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/volume" "$test_root/meta" "$test_root/repo" "$test_root/restore"
printf 'image restore test\n' > "$test_root/volume/payload"
printf '{"test":true}\n' > "$test_root/meta/meta.json"
chmod 640 "$test_root/volume/payload"
ln -s payload "$test_root/volume/link"
args=(--rm --network none --user "$(id -u):$(id -g)"
  --mount "type=bind,src=$test_root/repo,dst=/repo"
  --mount "type=bind,src=$test_root/meta,dst=/salvage/meta,readonly"
  -e RESTIC_PASSWORD=image-test-only -e RESTIC_CACHE_DIR=/tmp/cache
  -e REPO_BASE_LOCATION=/repo -e SALVAGE_MACHINE_NAME=test
  -e SALVAGE_VOLUME_NAME=volume -e SALVAGE_CRANE_NAME=restic
  -e SALVAGE_TIDE_TIMESTAMP=1626262626)
if docker run "${args[@]}" "$image" > "$test_root/missing.log" 2>&1; then
  echo 'FAIL: image accepted missing source mount' >&2
  exit 1
fi
grep -q 'is not mounted' "$test_root/missing.log"
[[ ! -e "$test_root/repo/config" ]]
args+=(--mount "type=bind,src=$test_root/volume,dst=/salvage/volume,readonly")
docker run "${args[@]}" "$image"
docker run "${args[@]}" -e FORGET_ARGS='--keep-last 1' -e DO_PRUNE=true "$image"
docker run "${args[@]}" --mount "type=bind,src=$test_root/restore,dst=/restore" \
  --entrypoint restic "$image" -r /repo restore latest --target /restore --verify
cmp "$test_root/volume/payload" "$test_root/restore/salvage/volume/payload"
cmp "$test_root/meta/meta.json" "$test_root/restore/salvage/meta/meta.json"
[[ "$(readlink "$test_root/restore/salvage/volume/link")" == payload ]]
[[ "$(stat -c %a "$test_root/restore/salvage/volume/payload")" == 640 ]]
echo 'Image backup, prune, restore and missing-mount checks passed.'
