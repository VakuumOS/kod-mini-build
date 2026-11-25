#!/usr/bin/env bash
# =====================================================================
#  Vakuum OS Builder (kod-mini) — source fetcher
# ---------------------------------------------------------------------
#  Downloads every upstream source into sources/ (cache-friendly: files
#  that are already present and verified are not downloaded again),
#  resolves the kod-mini-rootfs overlay (with automatic fallback to
#  fallback-rootfs/) into work/rootfs-overlay/ and writes the resolved
#  versions to work/versions.env for scripts/build.sh.
#
#  Usage: scripts/fetch.sh [--resolve] [--prune] [--no-rootfs] [-h]
# =====================================================================
# Several variables are only read indirectly via ${!name}:
# shellcheck disable=SC2034
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

ARCH="${ARCH:-x86_64}"
MODE=fetch
PRUNE=0
DO_ROOTFS=1

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --resolve     Resolve versions only, print KEY=VALUE lines and exit
                (used by CI to build the sources/ cache key).
  --prune       Delete stale tarballs/dirs from sources/ that are not
                needed by the current version set.
  --no-rootfs   Do not (re)resolve the root filesystem overlay.
  -h, --help    Show this help.

Environment (see configs/versions.conf for the full list):
  ARCH=${ARCH}            target architecture (used by KOD_TOOLCHAIN_URL)
  KERNEL_VERSION=auto|X.Y.Z   kernel to fetch (auto = newest ${KERNEL_SERIES}.x)
  KOD_ROOTFS_REPO=URL     root filesystem overlay repository
  KOD_ROOTFS_REF=REF      branch/tag of the overlay repository
  KOD_ROOTFS_DIR=PATH     use a local overlay checkout instead of cloning
  KOD_TOOLCHAIN_URL=URL   Stage 2 toolchain archive ("@ARCH@" is replaced)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --resolve) MODE=resolve ;;
        --prune) PRUNE=1 ;;
        --no-rootfs) DO_ROOTFS=0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

need_cmd curl git tar xz gzip bzip2 sha256sum sort grep sed

# ---------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------
CURL_OPTS=(
    --fail --location --silent --show-error
    --retry 3 --retry-delay 3 --retry-all-errors
    --connect-timeout 20
)

# download DEST URL... — try every URL until one succeeds (atomic).
download() {
    local dest="$1" url
    shift
    mkdir -p "$(dirname "${dest}")"
    for url in "$@"; do
        log "  GET ${url}"
        if curl "${CURL_OPTS[@]}" --max-time 1800 -o "${dest}.part" "${url}"; then
            mv -f "${dest}.part" "${dest}"
            return 0
        fi
        warn "  failed: ${url}"
    done
    rm -f "${dest}.part"
    return 1
}

# verify_archive FILE [SHA256] — integrity test + optional checksum.
verify_archive() {
    local file="$1" sha="${2:-}"
    [ -s "${file}" ] || return 1
    case "${file}" in
        *.tar.xz)  xz -t "${file}" 2>/dev/null || return 1 ;;
        *.tar.gz)  gzip -t "${file}" 2>/dev/null || return 1 ;;
        *.tar.bz2) bzip2 -t "${file}" 2>/dev/null || return 1 ;;
        *.tar.zst) zstd -q -t "${file}" 2>/dev/null || return 1 ;;
        *.tar)     tar -tf "${file}" >/dev/null 2>&1 || return 1 ;;
        *) ;;
    esac
    if [ -n "${sha}" ]; then
        echo "${sha}  ${file}" | sha256sum -c --status - || {
            warn "  sha256 mismatch: ${file}"
            return 1
        }
    fi
    return 0
}

# fetch_archive LABEL FILE SHA256 URL... — cached download + verification.
fetch_archive() {
    local label="$1" file="$2" sha="$3"
    shift 3
    local dest="${SOURCES_DIR}/${file}"
    if [ -f "${dest}" ] && verify_archive "${dest}" "${sha}"; then
        ok "${label}: cached (${file})"
        return 0
    fi
    rm -f "${dest}"
    log "${label}: downloading ${file}"
    download "${dest}" "$@" || die "${label}: all download mirrors failed"
    if ! verify_archive "${dest}" "${sha}"; then
        rm -f "${dest}"
        die "${label}: downloaded archive failed verification"
    fi
    ok "${label}: ${file}"
}

# Escape dots for use inside an extended regular expression.
re_escape() { printf '%s' "$1" | sed 's/\./\\./g'; }

# ---------------------------------------------------------------------
#  Version resolution
# ---------------------------------------------------------------------
resolve_kernel_version() {
    [ "${KERNEL_VERSION}" = "auto" ] || return 0
    local re v="" data major="${KERNEL_SERIES%%.*}"
    re="$(re_escape "${KERNEL_SERIES}")"

    # 1) kernel.org release metadata (lists the newest longterm release).
    if data="$(curl "${CURL_OPTS[@]}" --max-time 30 \
        https://www.kernel.org/releases.json 2>/dev/null)"; then
        v="$(printf '%s\n' "${data}" |
            grep -oE "\"${re}\.[0-9]+\"" | tr -d '"' | sort -V | tail -n1 || true)"
    fi
    # 2) Directory index of the CDN.
    if [ -z "${v}" ] && data="$(curl "${CURL_OPTS[@]}" --max-time 60 \
        "https://cdn.kernel.org/pub/linux/kernel/v${major}.x/" 2>/dev/null)"; then
        v="$(printf '%s\n' "${data}" |
            grep -oE "linux-${re}\.[0-9]+\.tar\.xz" |
            sed -e 's/^linux-//' -e 's/\.tar\.xz$//' | sort -uV | tail -n1 || true)"
    fi
    # 3) Pinned fallback.
    if [ -z "${v}" ]; then
        warn "kernel.org unreachable — using pinned ${KERNEL_FALLBACK_VERSION}"
        v="${KERNEL_FALLBACK_VERSION}"
    fi
    KERNEL_VERSION="${v}"
}

resolve_toolchain_url() {
    KOD_TOOLCHAIN_URL="${KOD_TOOLCHAIN_URL//@ARCH@/${ARCH}}"
}

print_versions() {
    local v
    for v in KERNEL_VERSION MUSL_VERSION BUSYBOX_VERSION GNU_BASH_VERSION \
        GNU_BASH_PATCHLEVEL UTIL_LINUX_VERSION E2FSPROGS_VERSION \
        DOSFSTOOLS_VERSION KBD_VERSION TERMINUS_VERSION LIMINE_BRANCH \
        KOD_TOOLCHAIN_URL; do
        printf '%s=%q\n' "${v}" "${!v}"
    done
}

# ---------------------------------------------------------------------
#  Fetchers
# ---------------------------------------------------------------------
fetch_kernel() {
    local file sha="" sums major="${KERNEL_VERSION%%.*}"
    file="$(kernel_tarball)"
    # kernel.org publishes a (PGP-clearsigned) list of SHA-256 sums.
    if sums="$(curl "${CURL_OPTS[@]}" --max-time 60 \
        "https://cdn.kernel.org/pub/linux/kernel/v${major}.x/sha256sums.asc" \
        2>/dev/null)"; then
        sha="$(printf '%s\n' "${sums}" |
            awk -v f="${file}" '$2 == f { print $1; exit }')"
    fi
    if [ -n "${sha}" ]; then
        log "linux: upstream sha256 ${sha}"
    else
        warn "linux: upstream sha256sums.asc unavailable — integrity test only"
    fi
    # shellcheck disable=SC2046
    fetch_archive "linux ${KERNEL_VERSION}" "${file}" "${sha}" $(kernel_urls)
}

fetch_busybox() {
    local file sha=""
    file="$(busybox_tarball)"
    if sha="$(curl "${CURL_OPTS[@]}" --max-time 30 \
        "https://busybox.net/downloads/${file}.sha256" 2>/dev/null)"; then
        sha="$(printf '%s\n' "${sha}" | awk 'NR == 1 { print $1 }')"
        [[ "${sha}" =~ ^[0-9a-f]{64}$ ]] || sha=""
    else
        sha=""
    fi
    # shellcheck disable=SC2046
    fetch_archive "busybox ${BUSYBOX_VERSION}" "${file}" "${sha}" $(busybox_urls)
}

fetch_bash() {
    local name dir
    # shellcheck disable=SC2046
    fetch_archive "bash ${GNU_BASH_VERSION}" "$(bash_tarball)" \
        "${GNU_BASH_SHA256}" $(bash_urls)

    dir="${SOURCES_DIR}/bash-${GNU_BASH_VERSION}-patches"
    mkdir -p "${dir}"
    while read -r name; do
        [ -n "${name}" ] || continue
        if [ -s "${dir}/${name}" ] && grep -q '^\*\*\* \|^--- ' "${dir}/${name}"; then
            continue
        fi
        # shellcheck disable=SC2046
        download "${dir}/${name}" $(bash_patch_urls "${name}") ||
            die "bash: cannot download official patch ${name}"
        grep -q '^\*\*\* \|^--- ' "${dir}/${name}" ||
            die "bash: ${name} does not look like a patch"
    done < <(bash_patch_names)
    ok "bash: ${GNU_BASH_PATCHLEVEL} official patches"
}

fetch_limine() {
    local dir="${SOURCES_DIR}/limine-${LIMINE_BRANCH}" f
    if [ -d "${dir}/.git" ]; then
        log "limine: updating ${LIMINE_BRANCH}"
        if git -C "${dir}" fetch --quiet --depth 1 origin "${LIMINE_BRANCH}" &&
            git -C "${dir}" reset --quiet --hard FETCH_HEAD; then
            git -C "${dir}" clean -qfdx
        else
            warn "limine: update failed — using cached checkout"
        fi
    else
        log "limine: cloning ${LIMINE_REPO} (${LIMINE_BRANCH})"
        rm -rf "${dir}"
        GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 \
            --branch "${LIMINE_BRANCH}" "${LIMINE_REPO}" "${dir}" ||
            die "limine: clone failed"
    fi
    for f in limine.c limine-bios.sys limine-bios-cd.bin limine-uefi-cd.bin \
        BOOTX64.EFI BOOTAA64.EFI; do
        [ -f "${dir}/${f}" ] || die "limine: ${f} missing in ${LIMINE_BRANCH}"
    done
    LIMINE_COMMIT="$(git -C "${dir}" rev-parse HEAD)"
    ok "limine: $(git -C "${dir}" log -1 --format=%s) (${LIMINE_COMMIT:0:12})"
}

fetch_terminus() {
    TERMINUS_AVAILABLE=0
    local file
    file="$(terminus_tarball)"
    if [ -f "${SOURCES_DIR}/${file}" ] &&
        verify_archive "${SOURCES_DIR}/${file}" "${TERMINUS_SHA256}"; then
        ok "terminus: cached (${file})"
        TERMINUS_AVAILABLE=1
        return 0
    fi
    rm -f "${SOURCES_DIR:?}/${file}"
    log "terminus: downloading ${file} (optional)"
    # shellcheck disable=SC2046
    if download "${SOURCES_DIR}/${file}" $(terminus_urls) &&
        verify_archive "${SOURCES_DIR}/${file}" "${TERMINUS_SHA256}"; then
        ok "terminus: ${file}"
        TERMINUS_AVAILABLE=1
    else
        rm -f "${SOURCES_DIR:?}/${file}"
        warn "terminus: unavailable — the kbd Cyrillic font will be used"
    fi
}

fetch_toolchain() {
    TOOLCHAIN_FILE=""
    if [ -z "${KOD_TOOLCHAIN_URL}" ]; then
        log "toolchain: Stage 2 disabled (KOD_TOOLCHAIN_URL is empty)"
        return 0
    fi
    local name="${KOD_TOOLCHAIN_URL%%\?*}"
    name="${name##*/}"
    case "${name}" in
        *.tar.zst|*.tar.xz|*.tar.gz|*.tar) ;;
        *) die "toolchain: unsupported archive type '${name}'" ;;
    esac
    fetch_archive "toolchain" "toolchain/${name}" "${KOD_TOOLCHAIN_SHA256}" \
        "${KOD_TOOLCHAIN_URL}"
    TOOLCHAIN_FILE="toolchain/${name}"
}

# ---------------------------------------------------------------------
#  Root filesystem overlay: kod-mini-rootfs with fallback-rootfs/
# ---------------------------------------------------------------------

# Files that describe a repository rather than the root filesystem.
OVERLAY_TAR_EXCLUDES=(
    --anchored --no-wildcards-match-slash
    --exclude=./.git --exclude=./.github
    --exclude=./.gitignore --exclude=./.gitattributes
    --exclude='./README*' --exclude='./LICENSE*' --exclude='./COPYING*'
    --exclude='./*.md'
)

# overlay_payload_count DIR — number of rootfs files in an overlay tree.
overlay_payload_count() {
    (cd "$1" && tar "${OVERLAY_TAR_EXCLUDES[@]}" -cf - . 2>/dev/null) |
        tar -tvf - | grep -cv '^d' || true
}

# clone_rootfs DEST — returns 0 when a non-empty repo was cloned.
clone_rootfs() {
    local dest="$1" errlog="${WORK_DIR}/kod-mini-rootfs.clone.log"
    rm -rf "${dest}"
    export GIT_TERMINAL_PROMPT=0
    if ! git clone --quiet --depth 1 --branch "${KOD_ROOTFS_REF}" \
        "${KOD_ROOTFS_REPO}" "${dest}" 2>"${errlog}"; then
        # The ref may not exist (yet) — retry with the default branch.
        rm -rf "${dest}"
        if ! git clone --quiet --depth 1 "${KOD_ROOTFS_REPO}" "${dest}" \
            2>>"${errlog}"; then
            warn "rootfs: ${KOD_ROOTFS_REPO} is unreachable:"
            sed 's/^/      /' "${errlog}" >&2
            return 1
        fi
    fi
    # An empty repository clones "successfully" but has no commits.
    if ! git -C "${dest}" rev-parse --verify --quiet HEAD >/dev/null; then
        warn "rootfs: ${KOD_ROOTFS_REPO} has no commits"
        return 1
    fi
    return 0
}

resolve_rootfs() {
    local clone="${WORK_DIR}/kod-mini-rootfs" src="" count
    ROOTFS_SOURCE="fallback-rootfs"
    ROOTFS_COMMIT="$(git -C "${KOD_ROOT}" rev-parse --short HEAD 2>/dev/null || echo local)"

    rm -rf "${OVERLAY_DIR}"
    mkdir -p "${OVERLAY_DIR}"

    if [ -n "${KOD_ROOTFS_DIR:-}" ]; then
        [ -d "${KOD_ROOTFS_DIR}" ] || die "rootfs: KOD_ROOTFS_DIR=${KOD_ROOTFS_DIR} not found"
        src="${KOD_ROOTFS_DIR}"
        log "rootfs: using local overlay ${src}"
    elif clone_rootfs "${clone}"; then
        src="${clone}"
    fi

    # Repositories may keep the tree either at the top level or in rootfs/.
    if [ -n "${src}" ] && [ -d "${src}/rootfs" ]; then
        src="${src}/rootfs"
    fi

    # Base layer: always the in-tree fallback (guarantees /init & co).
    [ -x "${FALLBACK_ROOTFS_DIR}/init" ] || die "fallback-rootfs/init missing or not executable"
    cp -a "${FALLBACK_ROOTFS_DIR}/." "${OVERLAY_DIR}/"

    if [ -n "${src}" ]; then
        count="$(overlay_payload_count "${src}")"
        if [ "${count}" -gt 0 ]; then
            (cd "${src}" && tar "${OVERLAY_TAR_EXCLUDES[@]}" -cf - .) |
                tar -C "${OVERLAY_DIR}" -xf -
            ROOTFS_SOURCE="kod-mini-rootfs"
            if git -C "${src}" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
                ROOTFS_COMMIT="$(git -C "${src}" rev-parse --short HEAD)"
            else
                ROOTFS_COMMIT="local"
            fi
            ok "rootfs: kod-mini-rootfs@${ROOTFS_COMMIT} (${count} files) over fallback-rootfs"
        else
            warn "rootfs: kod-mini-rootfs contains no rootfs files (empty repo)"
        fi
    fi
    if [ "${ROOTFS_SOURCE}" = "fallback-rootfs" ]; then
        ok "rootfs: using built-in fallback-rootfs/ (${ROOTFS_COMMIT})"
    fi

    [ -f "${OVERLAY_DIR}/init" ] || die "rootfs: overlay has no /init"
    chmod 0755 "${OVERLAY_DIR}/init"
    printf 'source=%s\ncommit=%s\n' "${ROOTFS_SOURCE}" "${ROOTFS_COMMIT}" \
        >"${WORK_DIR}/rootfs-overlay.info"
}

# ---------------------------------------------------------------------
#  Housekeeping
# ---------------------------------------------------------------------
prune_sources() {
    local -A keep=()
    local p name
    for name in "$(kernel_tarball)" "$(musl_tarball)" "$(busybox_tarball)" \
        "$(bash_tarball)" "bash-${GNU_BASH_VERSION}-patches" \
        "$(util_linux_tarball)" "$(e2fsprogs_tarball)" \
        "$(dosfstools_tarball)" "$(kbd_tarball)" "$(terminus_tarball)" \
        "limine-${LIMINE_BRANCH}" toolchain; do
        keep["${name}"]=1
    done
    shopt -s nullglob
    for p in "${SOURCES_DIR}"/*; do
        name="${p##*/}"
        if [ -z "${keep[${name}]:-}" ]; then
            log "prune: removing stale ${name}"
            rm -rf "${p:?}"
        fi
    done
    shopt -u nullglob
}

write_versions_env() {
    local tmp="${VERSIONS_ENV}.tmp" v
    mkdir -p "${WORK_DIR}"
    {
        echo "# Generated by scripts/fetch.sh — do not edit."
        echo "# $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        print_versions
        for v in LIMINE_COMMIT TERMINUS_AVAILABLE TOOLCHAIN_FILE; do
            printf '%s=%q\n' "${v}" "${!v}"
        done
        if [ -f "${WORK_DIR}/rootfs-overlay.info" ]; then
            printf 'ROOTFS_SOURCE=%q\n' "$(sed -n 's/^source=//p' "${WORK_DIR}/rootfs-overlay.info")"
            printf 'ROOTFS_COMMIT=%q\n' "$(sed -n 's/^commit=//p' "${WORK_DIR}/rootfs-overlay.info")"
        fi
    } >"${tmp}"
    mv -f "${tmp}" "${VERSIONS_ENV}"
}

# ---------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------
resolve_kernel_version
resolve_toolchain_url

if [ "${MODE}" = "resolve" ]; then
    print_versions
    exit 0
fi

mkdir -p "${SOURCES_DIR}" "${WORK_DIR}"

group_start "Fetching sources into ${SOURCES_DIR}"
log "linux ${KERNEL_VERSION} (series ${KERNEL_SERIES})"
fetch_kernel
# shellcheck disable=SC2046
fetch_archive "musl ${MUSL_VERSION}" "$(musl_tarball)" "${MUSL_SHA256}" $(musl_urls)
fetch_busybox
fetch_bash
# shellcheck disable=SC2046
fetch_archive "util-linux ${UTIL_LINUX_VERSION}" "$(util_linux_tarball)" \
    "${UTIL_LINUX_SHA256}" $(util_linux_urls)
# shellcheck disable=SC2046
fetch_archive "e2fsprogs ${E2FSPROGS_VERSION}" "$(e2fsprogs_tarball)" \
    "${E2FSPROGS_SHA256}" $(e2fsprogs_urls)
# shellcheck disable=SC2046
fetch_archive "dosfstools ${DOSFSTOOLS_VERSION}" "$(dosfstools_tarball)" \
    "${DOSFSTOOLS_SHA256}" $(dosfstools_urls)
# shellcheck disable=SC2046
fetch_archive "kbd ${KBD_VERSION}" "$(kbd_tarball)" "${KBD_SHA256}" $(kbd_urls)
fetch_terminus
fetch_limine
fetch_toolchain
group_end

if [ "${DO_ROOTFS}" = 1 ]; then
    group_start "Resolving root filesystem overlay"
    resolve_rootfs
    group_end
fi

[ "${PRUNE}" = 0 ] || prune_sources

write_versions_env
ok "versions written to ${VERSIONS_ENV#"${KOD_ROOT}"/}"
