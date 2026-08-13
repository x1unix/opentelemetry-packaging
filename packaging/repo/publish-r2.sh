#!/bin/bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Publishes a COPR build's RPMs to the R2 bucket behind the custom domain.
# Invoked by the "publish" job in .github/workflows/copr-build.yml, and safe
# to run by hand for a manual/debug publish against the same bucket.
#
# Required env (secrets):
#   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT, R2_BUCKET
# Required env (not secret; set as workflow-level env in copr-build.yml):
#   BUILD_ID             - COPR build id to publish, e.g. 10791755
#   COPR_OWNER           - COPR project owner, e.g. x1unix
#   COPR_PROJECT_NAME    - COPR project name, e.g. opentelemetry-packaging
#   CUSTOM_DOMAIN        - public domain the bucket is bound to, e.g. https://otel.pkg.x1unix.dev
#
# Deps: bash, curl, jq, copr-cli, rpm, gnupg2, createrepo_c, rclone (>=1.63
# for --metadata-set).
#
# No key or checksum is pinned anywhere: the pubkey is fetched fresh every
# run. That means a key rotation is trusted silently instead of failing the
# run -- accepted tradeoff for this PoC (see .plans/copr-custom-domain-blob-mirror.md).

set -euo pipefail

required_vars=(R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET BUILD_ID COPR_OWNER COPR_PROJECT_NAME CUSTOM_DOMAIN)
missing=()
for v in "${required_vars[@]}"; do
  [ -z "${!v:-}" ] && missing+=("${v}")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: missing required env var(s): ${missing[*]}" >&2
  exit 1
fi

COPR_API="https://copr.fedorainfracloud.org/api_3"
COPR_PUBKEY_URL="https://download.copr.fedorainfracloud.org/results/${COPR_OWNER}/${COPR_PROJECT_NAME}/pubkey.gpg"
REMOTE="r2"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# rclone env-var config, no rclone.conf needed. no_check_bucket skips a
# ListBuckets call the scoped R2 token isn't granted.
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_R2_ENDPOINT="${R2_ENDPOINT}"
export RCLONE_CONFIG_R2_REGION=auto
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

# COPR chroot -> public bucket prefix. Static on purpose: an unmapped chroot
# must fail the run instead of silently publishing to the wrong place.
declare -A CHROOT_PREFIX=(
  [fedora-43-x86_64]="fedora/43/x86_64"
  [fedora-43-aarch64]="fedora/43/aarch64"
  [fedora-44-x86_64]="fedora/44/x86_64"
  [fedora-44-aarch64]="fedora/44/aarch64"
  [epel-9-x86_64]="el/9/x86_64"
  [epel-9-aarch64]="el/9/aarch64"
  [epel-10-x86_64]="el/10/x86_64"
  [epel-10-aarch64]="el/10/aarch64"
)

log() { echo "[$(date -u +%H:%M:%S 2>/dev/null || echo '--:--:--')] $*"; }

r2_upload() {
  # r2_upload <local-file> <remote-path> <cache-control>
  rclone copyto --metadata \
    --metadata-set cache-control="$3" \
    --metadata-set content-type="$([[ "$1" == *.rpm ]] && echo application/x-rpm || echo application/octet-stream)" \
    "$1" "${REMOTE}:${R2_BUCKET}/rpm/$2"
}

log "resolving chroots for build ${BUILD_ID}"
mapfile -t BUILD_CHROOTS < <(curl -sSf "${COPR_API}/build/${BUILD_ID}" | jq -r '.chroots[]')
if [ "${#BUILD_CHROOTS[@]}" -eq 0 ]; then
  echo "ERROR: build ${BUILD_ID} reports no chroots" >&2
  exit 1
fi
for chroot in "${BUILD_CHROOTS[@]}"; do
  if [ -z "${CHROOT_PREFIX[$chroot]+x}" ]; then
    echo "ERROR: unrecognised chroot '${chroot}' -- update CHROOT_PREFIX before publishing" >&2
    exit 1
  fi
done
log "chroots: ${BUILD_CHROOTS[*]}"

log "downloading build artifacts"
copr-cli download-build "${BUILD_ID}" --dest "${WORKDIR}/copr-artifacts"
find "${WORKDIR}/copr-artifacts" -name '*.src.rpm' -delete

log "fetching COPR pubkey"
curl -sSf "${COPR_PUBKEY_URL}" -o "${WORKDIR}/pubkey.gpg"
rpmkeys --import "${WORKDIR}/pubkey.gpg"

log "checking package signatures"
while IFS= read -r -d '' rpm; do
  if ! rpm --checksig "${rpm}" >/dev/null; then
    echo "ERROR: ${rpm} failed signature verification" >&2
    rpm --checksig -v "${rpm}" >&2
    exit 1
  fi
done < <(find "${WORKDIR}/copr-artifacts" -name '*.rpm' -print0)

for chroot in "${BUILD_CHROOTS[@]}"; do
  prefix="${CHROOT_PREFIX[$chroot]}"
  src_dir="${WORKDIR}/copr-artifacts/${chroot}"
  work_dir="${WORKDIR}/work/${prefix}"

  if [ ! -d "${src_dir}" ] || [ -z "$(find "${src_dir}" -maxdepth 1 -name '*.rpm')" ]; then
    log "skip ${chroot}: no rpms in this build (chroot skipped upstream)"
    continue
  fi

  log "=== ${chroot} -> rpm/${prefix} ==="
  mkdir -p "${work_dir}/Packages"

  log "syncing existing Packages/ down"
  rclone copy "${REMOTE}:${R2_BUCKET}/rpm/${prefix}/Packages" "${work_dir}/Packages" || true

  new_rpms=()
  while IFS= read -r -d '' rpm; do
    cp "${rpm}" "${work_dir}/Packages/"
    new_rpms+=("${rpm}")
  done < <(find "${src_dir}" -maxdepth 1 -name '*.rpm' -print0)

  # Run against work_dir, not work_dir/Packages: createrepo_c records package
  # hrefs relative to whatever directory it's pointed at. Pointed at Packages/
  # itself, hrefs come out as bare filenames, but repodata/ is published as a
  # sibling of Packages/ (per the bucket layout) -- so dnf resolves
  # baseurl/foo.rpm instead of baseurl/Packages/foo.rpm and 404s. Pointing at
  # the parent makes createrepo_c recurse into Packages/ and record hrefs as
  # "Packages/foo.rpm", matching the real layout.
  log "rebuilding metadata"
  createrepo_c --update --workers 4 "${work_dir}"

  log "archiving current repodata before overwrite"
  rclone copy "${REMOTE}:${R2_BUCKET}/rpm/${prefix}/repodata" \
    "${REMOTE}:${R2_BUCKET}/rpm/${prefix}/repodata-archive/${BUILD_ID}" || true

  log "uploading new packages"
  for rpm in "${new_rpms[@]}"; do
    r2_upload "${work_dir}/Packages/$(basename "${rpm}")" \
      "${prefix}/Packages/$(basename "${rpm}")" \
      "public, max-age=31536000, immutable"
  done

  log "uploading repodata (excluding repomd.xml)"
  for f in "${work_dir}/repodata"/*; do
    [ "$(basename "${f}")" = "repomd.xml" ] && continue
    r2_upload "${f}" "${prefix}/repodata/$(basename "${f}")" "public, max-age=300"
  done

  log "uploading repomd.xml (atomic pointer swap)"
  r2_upload "${work_dir}/repodata/repomd.xml" "${prefix}/repodata/repomd.xml" "public, max-age=60"

  log "retention pruning not implemented in this run -- see plan step 5, stale objects are left in place"
done

log "uploading gpg key and .repo files"
r2_upload "${WORKDIR}/pubkey.gpg" "RPM-GPG-KEY-opentelemetry" "public, max-age=300"

cat > "${WORKDIR}/opentelemetry-el.repo" <<EOF
[opentelemetry]
name=OpenTelemetry Auto-Instrumentation Packages
baseurl=${CUSTOM_DOMAIN}/rpm/el/\$releasever/\$basearch/
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=${CUSTOM_DOMAIN}/rpm/RPM-GPG-KEY-opentelemetry
EOF

cat > "${WORKDIR}/opentelemetry-fedora.repo" <<EOF
[opentelemetry]
name=OpenTelemetry Auto-Instrumentation Packages
baseurl=${CUSTOM_DOMAIN}/rpm/fedora/\$releasever/\$basearch/
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=${CUSTOM_DOMAIN}/rpm/RPM-GPG-KEY-opentelemetry
EOF

r2_upload "${WORKDIR}/opentelemetry-el.repo" "opentelemetry-el.repo" "public, max-age=300"
r2_upload "${WORKDIR}/opentelemetry-fedora.repo" "opentelemetry-fedora.repo" "public, max-age=300"

log "done"
echo "Published build ${BUILD_ID} to ${CUSTOM_DOMAIN}/rpm/" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
