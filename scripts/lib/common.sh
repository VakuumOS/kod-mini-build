# shellcheck shell=bash disable=SC2034
# =====================================================================
#  Vakuum OS Builder (kod-mini) — shared helpers for fetch.sh/build.sh
# =====================================================================

# Repository layout ------------------------------------------------------
KOD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCES_DIR="${SOURCES_DIR:-${KOD_ROOT}/sources}"
WORK_DIR="${WORK_DIR:-${KOD_ROOT}/work}"
OUT_DIR="${OUT_DIR:-${KOD_ROOT}/out}"
CONFIGS_DIR="${KOD_ROOT}/configs"
FALLBACK_ROOTFS_DIR="${KOD_ROOT}/fallback-rootfs"
STAGE1_DIR="${KOD_ROOT}/stage1"

# Resolved versions written by fetch.sh, consumed by build.sh.
VERSIONS_ENV="${WORK_DIR}/versions.env"
# Merged root filesystem overlay (kod-mini-rootfs or fallback-rootfs).
OVERLAY_DIR="${WORK_DIR}/rootfs-overlay"

# shellcheck source=../../configs/versions.conf
. "${CONFIGS_DIR}/versions.conf"

# Logging ----------------------------------------------------------------
# Colour on a terminal, or when forced with KOD_COLOR=1 (CI logs).
if [ -z "${NO_COLOR:-}" ] && { [ -t 2 ] || [ "${KOD_COLOR:-0}" = 1 ]; }; then
    _C_INFO=$'\033[1;34m' _C_OK=$'\033[1;32m' _C_WARN=$'\033[1;33m'
    _C_ERR=$'\033[1;31m' _C_OFF=$'\033[0m'
else
    _C_INFO='' _C_OK='' _C_WARN='' _C_ERR='' _C_OFF=''
fi

log()  { printf '%s==>%s %s\n' "${_C_INFO}" "${_C_OFF}" "$*" >&2; }
ok()   { printf '%s ok%s %s\n' "${_C_OK}" "${_C_OFF}" "$*" >&2; }
warn() { printf '%s!!!%s %s\n' "${_C_WARN}" "${_C_OFF}" "$*" >&2; }
die()  { printf '%sERR%s %s\n' "${_C_ERR}" "${_C_OFF}" "$*" >&2; exit 1; }

# GitHub Actions log groups (no-op outside CI).
group_start() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::group::$*"
    else
        log "$*"
    fi
}
group_end() { [ -z "${GITHUB_ACTIONS:-}" ] || echo "::endgroup::"; }

# Utilities --------------------------------------------------------------
need_cmd() {
    local missing=() c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [ "${#missing[@]}" -eq 0 ] ||
        die "missing host tools: ${missing[*]} (see README.md, 'Host packages')"
}

nproc_safe() { nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2; }

# Map ARCH -> kernel/toolchain/bootloader parameters.
# Exports: KARCH KIMAGE TRIPLE EFI_BOOT_FILE HAVE_BIOS SERIAL_TTY
arch_setup() {
    case "${ARCH}" in
        x86_64|amd64)
            ARCH=x86_64
            KARCH=x86_64
            KIMAGE=arch/x86/boot/bzImage
            TRIPLE=x86_64-linux-musl
            EFI_BOOT_FILE=BOOTX64.EFI
            HAVE_BIOS=1
            SERIAL_TTY=ttyS0
            ;;
        aarch64|arm64)
            ARCH=aarch64
            KARCH=arm64
            KIMAGE=arch/arm64/boot/Image
            TRIPLE=aarch64-linux-musl
            EFI_BOOT_FILE=BOOTAA64.EFI
            HAVE_BIOS=0
            SERIAL_TTY=ttyAMA0
            ;;
        *)
            die "unsupported ARCH='${ARCH}' (supported: x86_64, aarch64)"
            ;;
    esac
    export ARCH KARCH KIMAGE TRIPLE EFI_BOOT_FILE HAVE_BIOS SERIAL_TTY
}

# Download URLs ----------------------------------------------------------
# Each *_urls function prints candidate URLs (primary first, mirrors next).
BUILDROOT_MIRROR="https://sources.buildroot.net"
GNU_MIRRORS="https://ftp.gnu.org/gnu https://ftpmirror.gnu.org"

kernel_tarball() { echo "linux-${KERNEL_VERSION}.tar.xz"; }
kernel_urls() {
    local major="${KERNEL_VERSION%%.*}"
    echo "https://cdn.kernel.org/pub/linux/kernel/v${major}.x/$(kernel_tarball)"
    echo "https://mirrors.edge.kernel.org/pub/linux/kernel/v${major}.x/$(kernel_tarball)"
    echo "${BUILDROOT_MIRROR}/linux/$(kernel_tarball)"
}

musl_tarball() { echo "musl-${MUSL_VERSION}.tar.gz"; }
musl_urls() {
    echo "https://musl.libc.org/releases/$(musl_tarball)"
    echo "${BUILDROOT_MIRROR}/musl/$(musl_tarball)"
}

busybox_tarball() { echo "busybox-${BUSYBOX_VERSION}.tar.bz2"; }
busybox_urls() {
    echo "https://busybox.net/downloads/$(busybox_tarball)"
    echo "https://www.busybox.net/downloads/$(busybox_tarball)"
    echo "${BUILDROOT_MIRROR}/busybox/$(busybox_tarball)"
}

bash_tarball() { echo "bash-${GNU_BASH_VERSION}.tar.gz"; }
bash_urls() {
    local m
    for m in ${GNU_MIRRORS}; do echo "${m}/bash/$(bash_tarball)"; done
    echo "${BUILDROOT_MIRROR}/bash/$(bash_tarball)"
}
# bash53-001 ... bash53-0NN
bash_patch_names() {
    local tag="${GNU_BASH_VERSION//./}" i
    for ((i = 1; i <= GNU_BASH_PATCHLEVEL; i++)); do
        printf 'bash%s-%03d\n' "${tag}" "${i}"
    done
}
bash_patch_urls() {
    local name="$1" m
    for m in ${GNU_MIRRORS}; do
        echo "${m}/bash/bash-${GNU_BASH_VERSION}-patches/${name}"
    done
}

util_linux_tarball() { echo "util-linux-${UTIL_LINUX_VERSION}.tar.xz"; }
util_linux_urls() {
    local mm
    mm="$(echo "${UTIL_LINUX_VERSION}" | cut -d. -f1,2)"
    echo "https://www.kernel.org/pub/linux/utils/util-linux/v${mm}/$(util_linux_tarball)"
    echo "https://mirrors.edge.kernel.org/pub/linux/utils/util-linux/v${mm}/$(util_linux_tarball)"
    echo "${BUILDROOT_MIRROR}/util-linux/$(util_linux_tarball)"
}

e2fsprogs_tarball() { echo "e2fsprogs-${E2FSPROGS_VERSION}.tar.xz"; }
e2fsprogs_urls() {
    local p="pub/linux/kernel/people/tytso/e2fsprogs/v${E2FSPROGS_VERSION}"
    echo "https://www.kernel.org/${p}/$(e2fsprogs_tarball)"
    echo "https://mirrors.edge.kernel.org/${p}/$(e2fsprogs_tarball)"
    echo "${BUILDROOT_MIRROR}/e2fsprogs/$(e2fsprogs_tarball)"
}

dosfstools_tarball() { echo "dosfstools-${DOSFSTOOLS_VERSION}.tar.gz"; }
dosfstools_urls() {
    local v="${DOSFSTOOLS_VERSION}"
    echo "https://github.com/dosfstools/dosfstools/releases/download/v${v}/$(dosfstools_tarball)"
    echo "${BUILDROOT_MIRROR}/dosfstools/$(dosfstools_tarball)"
}

kbd_tarball() { echo "kbd-${KBD_VERSION}.tar.xz"; }
kbd_urls() {
    echo "https://www.kernel.org/pub/linux/utils/kbd/$(kbd_tarball)"
    echo "https://mirrors.edge.kernel.org/pub/linux/utils/kbd/$(kbd_tarball)"
    echo "${BUILDROOT_MIRROR}/kbd/$(kbd_tarball)"
}

terminus_tarball() { echo "terminus-font-${TERMINUS_VERSION}.tar.gz"; }
terminus_urls() {
    local mm="${TERMINUS_VERSION%.*}"
    local sf="https://downloads.sourceforge.net/project/terminus-font"
    echo "${sf}/terminus-font-${mm}/$(terminus_tarball)"
    echo "https://sourceforge.net/projects/terminus-font/files/terminus-font-${mm}/$(terminus_tarball)/download"
    echo "${BUILDROOT_MIRROR}/terminus-font/$(terminus_tarball)"
}

# Load versions resolved by fetch.sh (kernel "auto" -> concrete version).
load_resolved_versions() {
    [ -f "${VERSIONS_ENV}" ] ||
        die "${VERSIONS_ENV} not found — run scripts/fetch.sh first"
    # shellcheck disable=SC1090
    . "${VERSIONS_ENV}"
    [ "${KERNEL_VERSION}" != "auto" ] ||
        die "KERNEL_VERSION is still 'auto' — re-run scripts/fetch.sh"
}
