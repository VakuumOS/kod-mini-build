#!/usr/bin/env bash
# =====================================================================
#  Vakuum OS Builder (kod-mini) — image builder
# ---------------------------------------------------------------------
#  Builds, from the sources fetched by scripts/fetch.sh:
#    * musl libc sysroot + "kod-cc" (clang + lld, static musl)
#    * Linux kernel (make LLVM=1, defconfig + configs/kernel-*.config)
#    * static BusyBox, GNU Bash, util-linux (sfdisk/fdisk/lsblk/...),
#      e2fsprogs (mkfs.ext4/e2fsck/...), dosfstools (mkfs.fat/...)
#    * console assets (Terminus/Cyrillic PSF fonts, EN/RU keymaps)
#    * root filesystem -> SquashFS (zstd) -> rootfs.img (newc cpio)
#    * stage 1 initramfs (BusyBox + stage1/init, zstd)
#    * hybrid BIOS + UEFI ISO with Limine: out/vakuum-builder-$ARCH.iso
#
#  Usage: scripts/build.sh [--arch ARCH] [-j N] [--clean] [STAGE...]
# =====================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

ALL_STAGES=(toolchain kernel busybox bash disktools console rootfs initramfs iso)

ARCH="${ARCH:-x86_64}"
JOBS="${JOBS:-$(nproc_safe)}"
CLEAN=0
STAGES=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [STAGE...]

Stages (default: all, in this order):
  ${ALL_STAGES[*]}
Extra stages:
  kernel-config   configure + verify the kernel only (no compilation)
  all             every stage above

Options:
  -a, --arch ARCH  target architecture: x86_64 (default) or aarch64
  -j, --jobs N     parallel make jobs (default: ${JOBS})
  -c, --clean      remove work/ARCH before building
  -v, --verbose    stream build logs to the terminal
  -h, --help       show this help

Environment:
  KOD_CCACHE=0          disable ccache even if it is installed
  KERNEL_HEADERS_DIR=   use prebuilt sanitized kernel headers (skip
                        "make headers_install")
  SOURCE_DATE_EPOCH=    timestamp for reproducible output
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -a|--arch) ARCH="${2:?--arch needs a value}"; shift ;;
        --arch=*) ARCH="${1#--arch=}" ;;
        -j|--jobs) JOBS="${2:?--jobs needs a value}"; shift ;;
        -j*) JOBS="${1#-j}" ;;
        -c|--clean) CLEAN=1 ;;
        -v|--verbose) KOD_VERBOSE=1 ;;
        -h|--help) usage; exit 0 ;;
        all) STAGES+=("${ALL_STAGES[@]}") ;;
        -*) usage >&2; die "unknown option: $1" ;;
        *) STAGES+=("$1") ;;
    esac
    shift
done
[ "${#STAGES[@]}" -gt 0 ] || STAGES=("${ALL_STAGES[@]}")

arch_setup
load_resolved_versions

# ---------------------------------------------------------------------
#  Layout
# ---------------------------------------------------------------------
A_WORK="${WORK_DIR}/${ARCH}"
SRC="${A_WORK}/src"
SYSROOT="${A_WORK}/sysroot"
TOOLS="${A_WORK}/tools"
STAGING="${A_WORK}/staging"
STAMPS="${A_WORK}/stamps"
LOGS="${A_WORK}/logs"
KSRC="${WORK_DIR}/src/linux-${KERNEL_VERSION}"
KBUILD="${A_WORK}/linux-build"
ROOTFS="${A_WORK}/rootfs"
INITRAMFS="${A_WORK}/initramfs"
ISO_ROOT="${A_WORK}/iso"
IMAGES="${A_WORK}/images"
ISO_NAME="vakuum-builder-${ARCH}.iso"
ISO_PATH="${OUT_DIR}/${ISO_NAME}"

if [ "${CLEAN}" = 1 ]; then
    log "cleaning ${A_WORK}"
    rm -rf "${A_WORK}"
fi
mkdir -p "${SRC}" "${SYSROOT}" "${TOOLS}/bin" "${STAGING}" "${STAMPS}" \
    "${LOGS}" "${IMAGES}" "${OUT_DIR}" "${WORK_DIR}/src"

export PATH="${TOOLS}/bin:${PATH}"
export LC_ALL=C
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
unset PKG_CONFIG_PATH CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

# Reproducible builds -----------------------------------------------------
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH="$(git -C "${KOD_ROOT}" log -1 --format=%ct 2>/dev/null || date +%s)"
fi
export SOURCE_DATE_EPOCH
export KBUILD_BUILD_TIMESTAMP="@${SOURCE_DATE_EPOCH}"
export KBUILD_BUILD_USER=kod
export KBUILD_BUILD_HOST=vakuum

GIT_REV="$(git -C "${KOD_ROOT}" rev-parse --short=10 HEAD 2>/dev/null || echo local)"
if [ -n "$(git -C "${KOD_ROOT}" status --porcelain 2>/dev/null)" ]; then
    GIT_REV="${GIT_REV}-dirty"
fi
BUILD_DATE="$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y%m%d%H%M%S)"
BUILD_ID="kod-mini-${KOD_VERSION}-${ARCH}-${GIT_REV}-${BUILD_DATE}"

# Native or cross build? (configure scripts need to know)
HOST_ARCH="$(uname -m)"
IS_CROSS=0
[ "${HOST_ARCH}" = "${ARCH}" ] || IS_CROSS=1
BUILD_TRIPLE="$(cc -dumpmachine 2>/dev/null || echo "${HOST_ARCH}-pc-linux-gnu")"

# ccache (optional, used by CI to make rebuilds fast)
CCACHE=""
if [ "${KOD_CCACHE:-1}" != 0 ] && command -v ccache >/dev/null 2>&1; then
    CCACHE=ccache
fi

KOD_CC="${TOOLS}/bin/kod-cc"
HOST_CC="${HOST_CC:-clang}"
TOOL_ENV=(
    CC="${KOD_CC}"
    AR=llvm-ar
    RANLIB=llvm-ranlib
    NM=llvm-nm
    STRIP=llvm-strip
    OBJCOPY=llvm-objcopy
    READELF=llvm-readelf
)
CONFIGURE_HOST=()
if [ "${IS_CROSS}" = 1 ]; then
    CONFIGURE_HOST=(--host="${TRIPLE}" --build="${BUILD_TRIPLE}")
fi

# ---------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------

# run_logged NAME CMD... — run CMD (command or function) with errexit
# in a subshell, log to logs/NAME.log, show the tail on failure.
run_logged() {
    local name="$1" logf="${LOGS}/$1.log" rc=0
    shift
    if [ "${KOD_VERBOSE:-0}" = 1 ]; then
        set +e
        (set -e; "$@") 2>&1 | tee "${logf}"
        rc="${PIPESTATUS[0]}"
        set -e
    else
        set +e
        (set -e; "$@") >"${logf}" 2>&1
        rc=$?
        set -e
    fi
    if [ "${rc}" != 0 ]; then
        echo "----- last 60 lines of ${logf#"${KOD_ROOT}"/} -----" >&2
        tail -n 60 "${logf}" >&2
        die "${name} failed (exit ${rc}); full log: ${logf#"${KOD_ROOT}"/}"
    fi
}

# extract TARBALL DESTDIR — fresh extraction of a tarball with a single
# top-level directory; prints the path of that directory.
extract() {
    local tarball="${SOURCES_DIR}/$1" dest="$2" tmp top
    [ -f "${tarball}" ] || die "missing ${tarball} — run scripts/fetch.sh"
    mkdir -p "${dest}"
    tmp="$(mktemp -d "${dest}/.extract.XXXXXX")"
    tar -xf "${tarball}" -C "${tmp}" --no-same-owner
    top="$(find "${tmp}" -mindepth 1 -maxdepth 1 -printf '%f\n')"
    if [ -z "${top}" ] || [ "$(echo "${top}" | wc -l)" != 1 ] ||
        [ ! -d "${tmp}/${top}" ]; then
        rm -rf "${tmp}"
        die "${tarball##*/}: expected a single top-level directory"
    fi
    rm -rf "${dest:?}/${top}"
    mv "${tmp}/${top}" "${dest}/${top}"
    rmdir "${tmp}"
    echo "${dest}/${top}"
}

# Stamps: skip a stage when its inputs are unchanged.
stamp_key() { printf '%s\n' "$@" | sha256sum | cut -c1-32; }
stamp_ok() { [ -f "${STAMPS}/$1" ] && [ "$(cat "${STAMPS}/$1")" = "$2" ]; }
stamp_set() { echo "$2" >"${STAMPS}/$1"; }
file_hash() { cat "$@" | sha256sum | cut -c1-16; }

# is_static_elf FILE — true for ELF files without a program interpreter.
is_elf() { [ "$(head -c4 "$1" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ]; }
is_static_elf() { is_elf "$1" && ! llvm-readelf -l "$1" 2>/dev/null | grep -q 'INTERP'; }

# apply_kconfig_fragment FRAGMENT CONFIG — override symbols in CONFIG.
apply_kconfig_fragment() {
    local frag="$1" cfg="$2" line sym
    while IFS= read -r line; do
        sym=""
        case "${line}" in
            CONFIG_*=*) sym="${line%%=*}" ;;
            "# CONFIG_"*" is not set") sym="${line#\# }"; sym="${sym%% *}" ;;
            *) continue ;;
        esac
        sed -i -e "/^${sym}=/d" -e "/^# ${sym} is not set\$/d" "${cfg}"
        echo "${line}" >>"${cfg}"
    done <"${frag}"
}

# verify_kconfig CONFIG FRAGMENT... — every fragment line must be in CONFIG.
verify_kconfig() {
    local cfg="$1" frag line sym bad=0 want got
    shift
    for frag in "$@"; do
        while IFS= read -r line; do
            case "${line}" in
                CONFIG_*=*)
                    sym="${line%%=*}"
                    want="${line}"
                    ;;
                "# CONFIG_"*" is not set")
                    sym="${line#\# }"
                    sym="${sym%% *}"
                    want="n"
                    ;;
                *) continue ;;
            esac
            got="$(grep -E "^${sym}=" "${cfg}" || true)"
            if [ "${want}" = "n" ]; then
                [ -z "${got}" ] && continue
            elif [ "${got}" = "${want}" ]; then
                continue
            fi
            warn "  ${frag##*/}: wanted '${line}', got '${got:-not set}'"
            bad=$((bad + 1))
        done <"${frag}"
    done
    [ "${bad}" = 0 ] || die "${bad} configuration option(s) were not applied (unmet dependencies?)"
}

# ---------------------------------------------------------------------
#  Stage: toolchain (kernel headers + musl + kod-cc)
# ---------------------------------------------------------------------
ensure_kernel_source() {
    if [ -f "${KSRC}/.kod-extracted" ]; then
        return 0
    fi
    log "extracting linux ${KERNEL_VERSION}"
    rm -rf "${KSRC}"
    extract "$(kernel_tarball)" "${WORK_DIR}/src" >/dev/null
    touch "${KSRC}/.kod-extracted"
}

kernel_make() {
    local args=(make -C "${KSRC}" O="${KBUILD}" ARCH="${KARCH}" LLVM=1)
    if [ -n "${CCACHE}" ]; then
        args+=(CC="ccache clang" HOSTCC="ccache clang")
    fi
    "${args[@]}" "$@"
}

_install_kernel_headers() {
    rm -rf "${SYSROOT}/usr/include/linux" "${SYSROOT}/usr/include/asm" \
        "${SYSROOT}/usr/include/asm-generic"
    mkdir -p "${SYSROOT}/usr/include"
    if [ -n "${KERNEL_HEADERS_DIR:-}" ]; then
        cp -a "${KERNEL_HEADERS_DIR}/." "${SYSROOT}/usr/include/"
    else
        make -C "${KSRC}" O="${A_WORK}/linux-headers" ARCH="${KARCH}" LLVM=1 \
            INSTALL_HDR_PATH="${SYSROOT}/usr" headers_install
    fi
}

_build_musl() {
    local src
    src="$(extract "$(musl_tarball)" "${SRC}")"
    cd "${src}"
    CC="${CCACHE:+ccache }clang --target=${TRIPLE}" \
        AR=llvm-ar RANLIB=llvm-ranlib CFLAGS="-O2 -pipe" \
        ./configure --target="${TRIPLE}" --prefix=/usr --syslibdir=/lib \
        --disable-shared
    make -j"${JOBS}" AR=llvm-ar RANLIB=llvm-ranlib
    make DESTDIR="${SYSROOT}" AR=llvm-ar RANLIB=llvm-ranlib install
}

# Minimal crtbegin/crtend objects: musl runs init/fini arrays itself,
# only __dso_handle is needed. Used when compiler-rt ships none.
_build_crt_objects() {
    local d="${A_WORK}/crt"
    mkdir -p "${d}"
    cat >"${d}/crtbegin.c" <<'EOF'
/* kod-mini: minimal crtbegin for static musl binaries */
void *__dso_handle __attribute__((visibility("hidden"))) = &__dso_handle;
EOF
    cat >"${d}/crtend.c" <<'EOF'
/* kod-mini: minimal crtend (intentionally empty) */
typedef int kod_crtend_unused;
EOF
    clang --target="${TRIPLE}" -O2 -fPIC -ffreestanding -c "${d}/crtbegin.c" -o "${d}/crtbegin.o"
    clang --target="${TRIPLE}" -O2 -fPIC -ffreestanding -c "${d}/crtend.c" -o "${d}/crtend.o"
    local f
    for f in crtbegin.o crtbeginS.o crtbeginT.o; do
        install -m 0644 "${d}/crtbegin.o" "${SYSROOT}/usr/lib/${f}"
    done
    for f in crtend.o crtendS.o; do
        install -m 0644 "${d}/crtend.o" "${SYSROOT}/usr/lib/${f}"
    done
}

# Pick the compiler runtime: LLVM compiler-rt builtins if installed
# (libclang-rt-*-dev), otherwise the host libgcc (native builds only).
_detect_rtlib() {
    local rt gcc_rt resdir
    rt="$(clang --target="${TRIPLE}" -rtlib=compiler-rt \
        -print-libgcc-file-name 2>/dev/null || true)"
    if [ -n "${rt}" ] && [ -f "${rt}" ]; then
        KOD_RTLIB=compiler-rt
        log "compiler runtime: LLVM compiler-rt (${rt})"
        return 0
    fi
    # Per-target runtime dirs are keyed by the full triple (…-linux-gnu),
    # so clang may not find them for *-linux-musl: look them up by hand
    # and install them into the sysroot under the name the driver links
    # with -rtlib=libgcc (the builtins are a drop-in libgcc.a for C).
    resdir="$(clang -print-resource-dir 2>/dev/null || true)"
    rt=""
    if [ -n "${resdir}" ] && [ -d "${resdir}/lib" ]; then
        rt="$(find "${resdir}/lib" \( -name "libclang_rt.builtins-${ARCH}.a" -o \
            -path "*/${ARCH}-*linux*/libclang_rt.builtins.a" \) | sort | head -n1)"
    fi
    if [ -n "${rt}" ]; then
        KOD_RTLIB=libgcc
        install -m 0644 "${rt}" "${SYSROOT}/usr/lib/libgcc.a"
        llvm-ar rcs "${SYSROOT}/usr/lib/libgcc_eh.a"
        log "compiler runtime: LLVM compiler-rt (${rt}, linked as libgcc.a)"
        return 0
    fi
    if [ "${IS_CROSS}" = 0 ] && gcc_rt="$(gcc -print-libgcc-file-name 2>/dev/null)" &&
        [ -f "${gcc_rt}" ]; then
        KOD_RTLIB=libgcc
        install -m 0644 "${gcc_rt}" "${SYSROOT}/usr/lib/libgcc.a"
        if [ -f "$(dirname "${gcc_rt}")/libgcc_eh.a" ]; then
            install -m 0644 "$(dirname "${gcc_rt}")/libgcc_eh.a" "${SYSROOT}/usr/lib/libgcc_eh.a"
        else
            llvm-ar rcs "${SYSROOT}/usr/lib/libgcc_eh.a"
        fi
        warn "compiler-rt builtins not found (install libclang-rt-dev);"
        warn "falling back to the host libgcc.a"
        return 0
    fi
    die "no compiler runtime for ${TRIPLE}: install compiler-rt builtins for ${ARCH}"
}

_write_kod_cc() {
    local unwind=""
    [ "${KOD_RTLIB}" = compiler-rt ] && unwind="--unwindlib=none"
    cat >"${KOD_CC}" <<EOF
#!/bin/sh
# Generated by kod-mini scripts/build.sh — static C compiler for
# ${TRIPLE}: clang + lld + musl sysroot (${SYSROOT}).
exec ${CCACHE:+${CCACHE} }clang --target=${TRIPLE} --sysroot=${SYSROOT} \\
    -fuse-ld=lld -static -rtlib=${KOD_RTLIB} ${unwind} -Qunused-arguments "\$@"
EOF
    chmod 0755 "${KOD_CC}"
}

_sanity_check_cc() {
    local t="${A_WORK}/cc-test"
    mkdir -p "${t}"
    cat >"${t}/hello.c" <<'EOF'
#include <stdio.h>
#include <locale.h>
#include <wchar.h>
#include <linux/version.h>
int main(void)
{
    setlocale(LC_ALL, "C.UTF-8");
    printf("kod-cc ok: musl static, linux uapi %d.%d, %zu\n",
           LINUX_VERSION_CODE >> 16, (LINUX_VERSION_CODE >> 8) & 255,
           mbstowcs(NULL, "\xd0\x9f\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82", 0));
    return 0;
}
EOF
    "${KOD_CC}" -O2 -o "${t}/hello" "${t}/hello.c"
    is_static_elf "${t}/hello" || die "kod-cc produced a dynamic binary"
    if [ "${IS_CROSS}" = 0 ]; then
        "${t}/hello"
    fi
}

stage_toolchain() {
    need_cmd clang ld.lld llvm-ar llvm-ranlib llvm-nm llvm-strip \
        llvm-objcopy llvm-readelf make tar
    local key
    key="$(stamp_key "${KERNEL_VERSION}" "${MUSL_VERSION}" "${TRIPLE}" \
        "$(clang --version | head -n1)" "${KERNEL_HEADERS_DIR:-}" "${CCACHE}")"
    if stamp_ok toolchain "${key}" && [ -x "${KOD_CC}" ]; then
        ok "toolchain: up to date"
        return 0
    fi
    group_start "toolchain: kernel headers + musl ${MUSL_VERSION} + kod-cc"
    ensure_kernel_source
    rm -rf "${SYSROOT}"
    mkdir -p "${SYSROOT}/usr/lib"
    run_logged kernel-headers _install_kernel_headers
    run_logged musl _build_musl
    _build_crt_objects
    _detect_rtlib
    _write_kod_cc
    run_logged cc-test _sanity_check_cc
    tail -n1 "${LOGS}/cc-test.log" >&2
    stamp_set toolchain "${key}"
    group_end
    ok "toolchain: ${KOD_CC##*/} -> clang --target=${TRIPLE} (${KOD_RTLIB})"
}

require_toolchain() {
    [ -x "${KOD_CC}" ] || die "toolchain not built — run: scripts/build.sh toolchain"
}

# ---------------------------------------------------------------------
#  Stage: kernel
# ---------------------------------------------------------------------
KFRAGS=()
kernel_fragments() {
    KFRAGS=("${CONFIGS_DIR}/kernel-common.config" "${CONFIGS_DIR}/kernel-${ARCH}.config")
    local f
    for f in "${KFRAGS[@]}"; do
        [ -f "${f}" ] || die "missing kernel fragment ${f}"
    done
}

_configure_kernel() {
    mkdir -p "${KBUILD}"
    cd "${KBUILD}"   # merge_config.sh creates its temporary files in $PWD
    kernel_make defconfig
    "${KSRC}/scripts/kconfig/merge_config.sh" -m -O "${KBUILD}" \
        "${KBUILD}/.config" "${KFRAGS[@]}"
    kernel_make olddefconfig
}

stage_kernel_config() {
    need_cmd clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-strip make \
        flex bison bc perl
    kernel_fragments
    ensure_kernel_source
    group_start "kernel: configuring linux ${KERNEL_VERSION} (${KARCH}, LLVM=1)"
    run_logged kernel-config _configure_kernel
    verify_kconfig "${KBUILD}/.config" "${KFRAGS[@]}"
    group_end
    ok "kernel: configuration verified ($(grep -c '=y$' "${KBUILD}/.config") built-in options)"
}

_compile_kernel() {
    kernel_make -j"${JOBS}" "$(basename "${KIMAGE}")"
}

stage_kernel() {
    kernel_fragments
    local key
    key="$(stamp_key "${KERNEL_VERSION}" "$(file_hash "${KFRAGS[@]}")" \
        "$(clang --version | head -n1)" "${SOURCE_DATE_EPOCH}")"
    if stamp_ok kernel "${key}" && [ -f "${IMAGES}/vmlinuz" ]; then
        ok "kernel: up to date"
        return 0
    fi
    stage_kernel_config
    group_start "kernel: compiling $(basename "${KIMAGE}") with ${JOBS} jobs"
    run_logged kernel-build _compile_kernel
    install -m 0644 "${KBUILD}/${KIMAGE}" "${IMAGES}/vmlinuz"
    install -m 0644 "${KBUILD}/.config" "${OUT_DIR}/kernel-${ARCH}.config"
    stamp_set kernel "${key}"
    group_end
    ok "kernel: $(du -h "${IMAGES}/vmlinuz" | cut -f1) $(basename "${KIMAGE}")"
}

# ---------------------------------------------------------------------
#  Stage: busybox
# ---------------------------------------------------------------------
busybox_make() {
    make -C "${BB_SRC}" "${TOOL_ENV[@]}" LD=ld.lld \
        HOSTCC="${CCACHE:+ccache }${HOST_CC}" CROSS_COMPILE= "$@"
}

_configure_busybox() {
    busybox_make defconfig
    apply_kconfig_fragment "${CONFIGS_DIR}/busybox.config" "${BB_SRC}/.config"
    { yes "" || true; } | busybox_make oldconfig
}

_compile_busybox() {
    busybox_make -j"${JOBS}" busybox
    rm -rf "${STAGING}/busybox"
    busybox_make CONFIG_PREFIX="${STAGING}/busybox" install
}

stage_busybox() {
    require_toolchain
    local key
    key="$(stamp_key "${BUSYBOX_VERSION}" "$(file_hash "${CONFIGS_DIR}/busybox.config")" \
        "$(cat "${STAMPS}/toolchain")")"
    if stamp_ok busybox "${key}" && [ -x "${STAGING}/busybox/bin/busybox" ]; then
        ok "busybox: up to date"
        return 0
    fi
    group_start "busybox ${BUSYBOX_VERSION}: static, musl"
    BB_SRC="$(extract "$(busybox_tarball)" "${SRC}")"
    run_logged busybox-config _configure_busybox
    verify_kconfig "${BB_SRC}/.config" "${CONFIGS_DIR}/busybox.config"
    run_logged busybox-build _compile_busybox
    rm -f "${STAGING}/busybox/linuxrc"
    is_static_elf "${STAGING}/busybox/bin/busybox" || die "busybox is not static"
    stamp_set busybox "${key}"
    group_end
    ok "busybox: $(du -h "${STAGING}/busybox/bin/busybox" | cut -f1)," \
        "$(find "${STAGING}/busybox" -type l | wc -l) applets"
}

# ---------------------------------------------------------------------
#  Stage: bash
# ---------------------------------------------------------------------
_build_bash() {
    local src name cross_cache=()
    src="$(extract "$(bash_tarball)" "${SRC}")"
    while read -r name; do
        patch -d "${src}" -p0 -s <"${SOURCES_DIR}/bash-${GNU_BASH_VERSION}-patches/${name}"
    done < <(bash_patch_names)
    if [ "${IS_CROSS}" = 1 ]; then
        cross_cache=(
            bash_cv_func_sigsetjmp=present
            bash_cv_getcwd_malloc=yes
            bash_cv_job_control_missing=present
            bash_cv_sys_named_pipes=present
            bash_cv_func_strcoll_broken=no
            bash_cv_printf_a_format=yes
            bash_cv_unusable_rtsigs=no
            bash_cv_wcwidth_broken=no
            ac_cv_rl_version=8.3
            CC_FOR_BUILD=cc
        )
    fi
    cd "${src}"
    env "${TOOL_ENV[@]}" CFLAGS="-Os -pipe" "${cross_cache[@]}" \
        ./configure "${CONFIGURE_HOST[@]}" \
        --prefix=/usr --bindir=/bin \
        --enable-static-link --without-bash-malloc \
        --disable-nls --enable-readline --enable-history \
        --enable-job-control --enable-multibyte
    make -j"${JOBS}"
    rm -rf "${STAGING}/bash"
    install -D -m 0755 bash "${STAGING}/bash/bin/bash"
    llvm-strip "${STAGING}/bash/bin/bash"
}

stage_bash() {
    require_toolchain
    local key
    key="$(stamp_key "${GNU_BASH_VERSION}" "${GNU_BASH_PATCHLEVEL}" "$(cat "${STAMPS}/toolchain")")"
    if stamp_ok bash "${key}" && [ -x "${STAGING}/bash/bin/bash" ]; then
        ok "bash: up to date"
        return 0
    fi
    group_start "bash ${GNU_BASH_VERSION}.${GNU_BASH_PATCHLEVEL}: static, musl"
    run_logged bash _build_bash
    is_static_elf "${STAGING}/bash/bin/bash" || die "bash is not static"
    stamp_set bash "${key}"
    group_end
    ok "bash: $(du -h "${STAGING}/bash/bin/bash" | cut -f1)"
}

# ---------------------------------------------------------------------
#  Stage: disktools (util-linux, e2fsprogs, dosfstools)
# ---------------------------------------------------------------------
_build_util_linux() {
    local src
    src="$(extract "$(util_linux_tarball)" "${SRC}")"
    cd "${src}"
    env "${TOOL_ENV[@]}" CFLAGS="-Os -pipe" \
        ./configure "${CONFIGURE_HOST[@]}" --prefix=/usr \
        --disable-all-programs \
        --enable-libuuid --enable-libblkid --enable-libmount \
        --enable-libsmartcols --enable-libfdisk \
        --enable-fdisks=check --enable-blkid --enable-wipefs --enable-lsblk \
        --disable-shared --enable-static \
        --without-ncurses --without-ncursesw --without-tinfo \
        --without-readline --without-libz --without-libmagic \
        --without-user --without-systemd --without-udev \
        --without-python --without-cryptsetup --without-econf \
        --without-selinux --without-audit --without-smack \
        --disable-nls --disable-asciidoc --disable-poman \
        --disable-bash-completion --disable-pylibmount \
        --disable-liblastlog2 --disable-makeinstall-chown \
        --disable-makeinstall-setuid
    make -j"${JOBS}"
    rm -rf "${STAGING}/util-linux"
    make DESTDIR="${STAGING}/util-linux" install
}

_build_e2fsprogs() {
    local src
    src="$(extract "$(e2fsprogs_tarball)" "${SRC}")"
    cd "${src}"
    env "${TOOL_ENV[@]}" CFLAGS="-Os -pipe" \
        ./configure "${CONFIGURE_HOST[@]}" --prefix=/usr --sysconfdir=/etc \
        --disable-nls --disable-elf-shlibs --disable-bsd-shlibs \
        --disable-fuse2fs --disable-uuidd --disable-debugfs \
        --disable-imager --disable-defrag --disable-e2initrd-helper \
        --disable-tdb --disable-backtrace --without-libarchive \
        --enable-libuuid --enable-libblkid
    make -j"${JOBS}"
    rm -rf "${STAGING}/e2fsprogs"
    make DESTDIR="${STAGING}/e2fsprogs" install
}

_build_dosfstools() {
    local src
    src="$(extract "$(dosfstools_tarball)" "${SRC}")"
    cd "${src}"
    env "${TOOL_ENV[@]}" CFLAGS="-Os -pipe" \
        ./configure "${CONFIGURE_HOST[@]}" --prefix=/usr \
        --enable-compat-symlinks --without-udev
    make -j"${JOBS}"
    rm -rf "${STAGING}/dosfstools"
    make DESTDIR="${STAGING}/dosfstools" install
}

# pick_tool PKG NAME — path of an installed program in staging/PKG.
pick_tool() {
    local p
    p="$(find "${STAGING}/$1" \( -type f -o -type l \) -name "$2" \
        \( -path '*/bin/*' -o -path '*/sbin/*' \) | head -n1)"
    [ -n "${p}" ] || die "$1: program '$2' was not built"
    echo "${p}"
}

# Collect the disk tools into staging/disktools/usr/{bin,sbin}.
_collect_disktools() {
    local d="${STAGING}/disktools" t
    rm -rf "${d}"
    mkdir -p "${d}/usr/sbin" "${d}/usr/bin" "${d}/etc"
    for t in sfdisk fdisk wipefs blkid; do
        install -m 0755 "$(pick_tool util-linux "${t}")" "${d}/usr/sbin/${t}"
    done
    install -m 0755 "$(pick_tool util-linux lsblk)" "${d}/usr/bin/lsblk"
    for t in mke2fs e2fsck tune2fs resize2fs dumpe2fs; do
        install -m 0755 "$(pick_tool e2fsprogs "${t}")" "${d}/usr/sbin/${t}"
    done
    for t in mkfs.ext2 mkfs.ext3 mkfs.ext4; do ln -sf mke2fs "${d}/usr/sbin/${t}"; done
    for t in fsck.ext2 fsck.ext3 fsck.ext4; do ln -sf e2fsck "${d}/usr/sbin/${t}"; done
    ln -sf tune2fs "${d}/usr/sbin/e2label"
    install -m 0644 "$(find "${STAGING}/e2fsprogs" -name mke2fs.conf | head -n1)" \
        "${d}/etc/mke2fs.conf"
    for t in mkfs.fat fsck.fat fatlabel; do
        install -m 0755 "$(pick_tool dosfstools "${t}")" "${d}/usr/sbin/${t}"
    done
    ln -sf mkfs.fat "${d}/usr/sbin/mkfs.vfat"
    ln -sf mkfs.fat "${d}/usr/sbin/mkdosfs"
    ln -sf fsck.fat "${d}/usr/sbin/fsck.vfat"
    ln -sf fsck.fat "${d}/usr/sbin/dosfsck"
    ln -sf fatlabel "${d}/usr/sbin/dosfslabel"
    find "${d}" -type f -perm -u+x -exec llvm-strip {} +
}

stage_disktools() {
    require_toolchain
    local key
    key="$(stamp_key "${UTIL_LINUX_VERSION}" "${E2FSPROGS_VERSION}" \
        "${DOSFSTOOLS_VERSION}" "$(cat "${STAMPS}/toolchain")")"
    if stamp_ok disktools "${key}" && [ -x "${STAGING}/disktools/usr/sbin/sfdisk" ]; then
        ok "disktools: up to date"
        return 0
    fi
    group_start "disk tools: util-linux ${UTIL_LINUX_VERSION}," \
        "e2fsprogs ${E2FSPROGS_VERSION}, dosfstools ${DOSFSTOOLS_VERSION}"
    run_logged util-linux _build_util_linux
    run_logged e2fsprogs _build_e2fsprogs
    run_logged dosfstools _build_dosfstools
    _collect_disktools
    local f
    while IFS= read -r f; do
        is_static_elf "${f}" || die "${f##*/} is not a static binary"
    done < <(find "${STAGING}/disktools" -type f -perm -u+x)
    stamp_set disktools "${key}"
    group_end
    ok "disktools: $(find "${STAGING}/disktools" -type f -perm -u+x | wc -l) static binaries"
}

# ---------------------------------------------------------------------
#  Stage: console (fonts + keymaps)
# ---------------------------------------------------------------------
# install_font SRC DEST — copy a PSF font, decompressing .gz if needed.
install_font() {
    case "$1" in
        *.gz) gzip -dc "$1" >"$2" ;;
        *) cp "$1" "$2" ;;
    esac
    chmod 0644 "$2"
}

_build_terminus() {
    local src
    src="$(extract "$(terminus_tarball)" "${SRC}")"
    cd "${src}"
    ./configure --prefix=/usr
    make -j"${JOBS}" psf
}

# compile_keymap NAME SOURCE.map DESTDIR — text keymap -> DESTDIR/NAME.bmap
compile_keymap() {
    local out="$3/$1.bmap" logf="${LOGS}/keymap-$1.log"
    if loadkeys -q -b -u "$2" >"${out}" 2>"${logf}" && [ -s "${out}" ]; then
        return 0
    fi
    rm -f "${out}"
    warn "keymap: compiling $1 failed (see ${logf#"${KOD_ROOT}"/})"
    return 1
}

stage_console() {
    local d="${STAGING}/console" fonts="${STAGING}/console/usr/share/consolefonts"
    local maps="${STAGING}/console/usr/share/keymaps" kbd f
    group_start "console: Cyrillic fonts + EN/RU keymaps"
    rm -rf "${d}"
    mkdir -p "${fonts}" "${maps}"

    kbd="$(extract "$(kbd_tarball)" "${SRC}")"
    for f in cyr-sun16.psfu UniCyr_8x16.psf; do
        if [ -f "${kbd}/data/consolefonts/${f}" ]; then
            install_font "${kbd}/data/consolefonts/${f}" "${fonts}/${f}"
        elif [ -f "${kbd}/data/consolefonts/${f}.gz" ]; then
            install_font "${kbd}/data/consolefonts/${f}.gz" "${fonts}/${f}"
        else
            warn "kbd: font ${f} not found"
        fi
    done

    if [ "${TERMINUS_AVAILABLE:-0}" = 1 ] && command -v python3 >/dev/null 2>&1; then
        run_logged terminus _build_terminus
        local tsrc
        tsrc="${SRC}/terminus-font-${TERMINUS_VERSION}"
        for f in ter-u16n ter-u16b ter-u20n ter-u24n ter-u32n ter-v16n; do
            if [ -f "${tsrc}/${f}.psf" ]; then
                install_font "${tsrc}/${f}.psf" "${fonts}/${f}.psf"
            elif [ -f "${tsrc}/${f}.psf.gz" ]; then
                install_font "${tsrc}/${f}.psf.gz" "${fonts}/${f}.psf"
            fi
        done
    else
        warn "Terminus not available — Cyrillic fallback font: cyr-sun16"
    fi

    # Binary keymaps for BusyBox loadkmap, compiled with the host loadkeys.
    if command -v loadkeys >/dev/null 2>&1; then
        local qwerty="${kbd}/data/keymaps/i386/qwerty"
        compile_keymap ru "${qwerty}/ruwin_ct_sh-UTF-8.map" "${maps}" ||
            die "cannot build the Russian keymap"
        compile_keymap us "${qwerty}/us.map" "${maps}" ||
            die "cannot build the US keymap"
        ok "keymaps: ru (ruwin_ct_sh-UTF-8, Ctrl+Shift toggles EN/RU), us"
    else
        die "host 'loadkeys' not found — install the 'kbd' package"
    fi
    if [ -z "$(find "${fonts}" -type f -name '*.psf*')" ]; then
        die "no Cyrillic console font could be installed"
    fi
    group_end
    ok "console: fonts: $(cd "${fonts}" && echo *)"
}

# ---------------------------------------------------------------------
#  Stage: rootfs (-> SquashFS -> rootfs.img)
# ---------------------------------------------------------------------
# drop_busybox_links NAME... — remove BusyBox applet links shadowed by
# real tools (util-linux, e2fsprogs, dosfstools).
drop_busybox_links() {
    local n d l
    for n in "$@"; do
        for d in bin sbin usr/bin usr/sbin; do
            l="${ROOTFS}/${d}/${n}"
            if [ -L "${l}" ]; then
                case "$(readlink "${l}")" in
                    busybox|*/busybox) rm -f "${l}" ;;
                esac
            fi
        done
    done
}

install_toolchain_payload() {
    [ -n "${TOOLCHAIN_FILE:-}" ] || return 0
    local archive="${SOURCES_DIR}/${TOOLCHAIN_FILE}" dest="${ROOTFS}/opt/kod-toolchain"
    local strip=0 tops
    [ -f "${archive}" ] || die "toolchain archive ${archive} missing — run fetch.sh"
    tops="$(tar -tf "${archive}" | sed -e 's|^\./||' -e 's|/.*||' | sort -u | grep -c . || true)"
    [ "${tops}" = 1 ] && strip=1
    mkdir -p "${dest}"
    tar -xf "${archive}" -C "${dest}" --strip-components="${strip}"
    ok "rootfs: Stage 2 toolchain installed to /opt/kod-toolchain"
}

write_kod_release() {
    cat >"${ROOTFS}/etc/kod-release" <<EOF
# Vakuum OS Builder (kod-mini) — generated by scripts/build.sh
KOD_VERSION="${KOD_VERSION}"
KOD_BUILD_ID="${BUILD_ID}"
KOD_ARCH="${ARCH}"
KOD_SERIAL_TTY="${SERIAL_TTY}"
KOD_KERNEL="${KERNEL_VERSION}"
KOD_ROOTFS_SOURCE="${ROOTFS_SOURCE:-fallback-rootfs}@${ROOTFS_COMMIT:-unknown}"
KOD_BUILDER_REV="${GIT_REV}"
KOD_MUSL="${MUSL_VERSION}"
KOD_BUSYBOX="${BUSYBOX_VERSION}"
KOD_BASH="${GNU_BASH_VERSION}.${GNU_BASH_PATCHLEVEL}"
KOD_UTIL_LINUX="${UTIL_LINUX_VERSION}"
KOD_E2FSPROGS="${E2FSPROGS_VERSION}"
KOD_DOSFSTOOLS="${DOSFSTOOLS_VERSION}"
EOF
}

# rootfs_has_cmd NAME — NAME exists in one of the standard bin dirs.
rootfs_has_cmd() {
    local d
    for d in bin sbin usr/bin usr/sbin usr/local/bin usr/local/sbin; do
        if [ -e "${ROOTFS}/${d}/$1" ] || [ -L "${ROOTFS}/${d}/$1" ]; then
            return 0
        fi
    done
    return 1
}

verify_rootfs() {
    local f missing=()
    for f in init bin/busybox bin/sh bin/bash etc/udhcpc.script etc/kod-release; do
        [ -e "${ROOTFS}/${f}" ] || missing+=("/${f}")
    done
    # Everything /init, the banner and kod_help rely on.
    for f in switch_root setsid cttyhack start-stop-daemon udhcpc ip mount \
        losetup mountpoint sfdisk fdisk lsblk wipefs blkid mkfs.ext4 \
        mkfs.fat setfont loadkmap kbd_mode mkswap swapon swapoff fallocate \
        chattr findfs wget vakuum-console vakuum-prep-swap; do
        rootfs_has_cmd "${f}" || missing+=("${f}")
    done
    [ "${#missing[@]}" = 0 ] || die "rootfs is missing: ${missing[*]}"
    [ -x "${ROOTFS}/init" ] || die "/init is not executable"
    while IFS= read -r f; do
        if is_elf "${f}" && ! is_static_elf "${f}"; then
            die "dynamic binary in rootfs: ${f#"${ROOTFS}"}"
        fi
    done < <(find "${ROOTFS}" -path "${ROOTFS}/opt" -prune -o -type f -perm -u+x -print)
}

stage_rootfs() {
    need_cmd mksquashfs "${HOST_CC}"
    local f
    for f in busybox/bin/busybox bash/bin/bash disktools/usr/sbin/sfdisk; do
        [ -e "${STAGING}/${f}" ] || die "staging/${f} missing — build the earlier stages first"
    done
    [ -f "${OVERLAY_DIR}/init" ] || die "rootfs overlay missing — run scripts/fetch.sh"

    group_start "rootfs: assembling (overlay: ${ROOTFS_SOURCE:-fallback-rootfs})"
    rm -rf "${ROOTFS}"
    mkdir -p "${ROOTFS}"
    (
        cd "${ROOTFS}"
        mkdir -p bin sbin usr/bin usr/sbin usr/lib usr/share usr/local/bin \
            usr/local/sbin etc etc/kod etc/profile.d dev proc sys run tmp \
            root mnt mnt/vakuum var/log var/tmp var/cache opt home
        ln -sfn ../run var/run
        ln -sfn /proc/self/mounts etc/mtab
    )

    # --remove-destination: never write *through* a BusyBox applet link.
    cp -a "${STAGING}/busybox/." "${ROOTFS}/"
    drop_busybox_links sfdisk fdisk wipefs blkid lsblk mke2fs mkfs.ext2 \
        mkfs.ext3 mkfs.ext4 e2fsck fsck.ext2 fsck.ext3 fsck.ext4 tune2fs \
        e2label resize2fs dumpe2fs mkfs.vfat mkdosfs fsck.vfat dosfsck \
        fatlabel mkfs.fat fsck.fat bash
    install -m 0755 "${STAGING}/bash/bin/bash" "${ROOTFS}/bin/bash"
    cp -a --remove-destination "${STAGING}/disktools/." "${ROOTFS}/"
    if [ -d "${STAGING}/console" ]; then
        cp -a --remove-destination "${STAGING}/console/." "${ROOTFS}/"
    fi
    install_toolchain_payload

    # The overlay goes last: kod-mini-rootfs / fallback-rootfs win.
    cp -a --remove-destination "${OVERLAY_DIR}/." "${ROOTFS}/"
    write_kod_release
    mkdir -p "${ROOTFS}/usr/share/udhcpc"
    [ -e "${ROOTFS}/usr/share/udhcpc/default.script" ] ||
        ln -sfn /etc/udhcpc.script "${ROOTFS}/usr/share/udhcpc/default.script"

    chmod 0755 "${ROOTFS}/init"
    chmod 1777 "${ROOTFS}/tmp" "${ROOTFS}/var/tmp"
    chmod 0700 "${ROOTFS}/root"
    [ -f "${ROOTFS}/etc/udhcpc.script" ] && chmod 0755 "${ROOTFS}/etc/udhcpc.script"
    find "${ROOTFS}/usr/local/bin" "${ROOTFS}/usr/local/sbin" -type f \
        -exec chmod 0755 {} +

    verify_rootfs

    rm -f "${IMAGES}/rootfs.sfs"
    # Timestamps come from SOURCE_DATE_EPOCH (honoured by mksquashfs).
    mksquashfs "${ROOTFS}" "${IMAGES}/rootfs.sfs" -noappend -quiet \
        -comp zstd -Xcompression-level 19 -b 1M -all-root -no-xattrs \
        -p 'dev/console c 600 0 0 5 1' -p 'dev/null c 666 0 0 1 3'

    # Wrap the SquashFS in a newc cpio with a single member "rootfs.sfs":
    # Limine can load it as an initrd module (RAM mode) and stage 1 can
    # loop-mount it at the data offset straight from the medium.
    build_gen_init_cpio
    printf 'file /rootfs.sfs %s 0644 0 0\n' "${IMAGES}/rootfs.sfs" >"${A_WORK}/rootfs.cpio.list"
    gen_init_cpio -t "${SOURCE_DATE_EPOCH}" "${A_WORK}/rootfs.cpio.list" >"${IMAGES}/rootfs.img"
    group_end
    ok "rootfs: $(du -sh "${ROOTFS}" | cut -f1) -> squashfs" \
        "$(du -h "${IMAGES}/rootfs.sfs" | cut -f1) (zstd)"
}

build_gen_init_cpio() {
    [ -x "${TOOLS}/bin/gen_init_cpio" ] && return 0
    ensure_kernel_source
    "${HOST_CC}" -O2 -o "${TOOLS}/bin/gen_init_cpio" "${KSRC}/usr/gen_init_cpio.c"
}

# ---------------------------------------------------------------------
#  Stage: initramfs (stage 1)
# ---------------------------------------------------------------------
stage_initramfs() {
    need_cmd zstd "${HOST_CC}"
    [ -x "${STAGING}/busybox/bin/busybox" ] || die "busybox not built"
    group_start "initramfs: stage 1 (BusyBox + stage1/init)"
    build_gen_init_cpio
    rm -rf "${INITRAMFS}"
    mkdir -p "${INITRAMFS}"
    install -m 0755 "${STAGE1_DIR}/init" "${INITRAMFS}/init"
    install -m 0755 "${STAGING}/busybox/bin/busybox" "${INITRAMFS}/busybox"
    {
        local d
        for d in /bin /sbin /usr /usr/bin /usr/sbin /dev /proc /sys /run \
            /tmp /mnt /newroot; do
            echo "dir ${d} 0755 0 0"
        done
        echo "nod /dev/console 0600 0 0 c 5 1"
        echo "nod /dev/null 0666 0 0 c 1 3"
        echo "file /init ${INITRAMFS}/init 0755 0 0"
        echo "file /bin/busybox ${INITRAMFS}/busybox 0755 0 0"
        echo "slink /bin/sh busybox 0777 0 0"
    } >"${A_WORK}/initramfs.cpio.list"
    gen_init_cpio -t "${SOURCE_DATE_EPOCH}" "${A_WORK}/initramfs.cpio.list" |
        zstd -q -19 --no-progress -c >"${IMAGES}/initramfs.img"
    group_end
    ok "initramfs: $(du -h "${IMAGES}/initramfs.img" | cut -f1)"
}

# ---------------------------------------------------------------------
#  Stage: iso (Limine, hybrid BIOS + UEFI)
# ---------------------------------------------------------------------
stage_iso() {
    need_cmd xorriso "${HOST_CC}" sha256sum
    local limine="${SOURCES_DIR}/limine-${LIMINE_BRANCH}" f
    for f in vmlinuz initramfs.img rootfs.img; do
        [ -f "${IMAGES}/${f}" ] || die "${f} missing — build the earlier stages first"
    done
    [ -f "${limine}/limine.c" ] || die "limine missing — run scripts/fetch.sh"

    group_start "iso: ${ISO_NAME} (Limine ${LIMINE_BRANCH})"
    "${HOST_CC}" -O2 -pipe -std=c99 -o "${TOOLS}/bin/limine" "${limine}/limine.c"

    rm -rf "${ISO_ROOT}"
    mkdir -p "${ISO_ROOT}/boot/kod" "${ISO_ROOT}/boot/limine" "${ISO_ROOT}/EFI/BOOT"
    install -m 0644 "${IMAGES}/vmlinuz" "${IMAGES}/initramfs.img" \
        "${IMAGES}/rootfs.img" "${ISO_ROOT}/boot/kod/"
    echo "${BUILD_ID}" >"${ISO_ROOT}/boot/kod/build-id"
    install -m 0644 "${limine}/limine-uefi-cd.bin" "${ISO_ROOT}/boot/limine/"
    install -m 0644 "${limine}/${EFI_BOOT_FILE}" "${ISO_ROOT}/EFI/BOOT/"
    if [ "${HAVE_BIOS}" = 1 ]; then
        install -m 0644 "${limine}/limine-bios.sys" "${limine}/limine-bios-cd.bin" \
            "${ISO_ROOT}/boot/limine/"
        # 32-bit UEFI firmware (some tablets / old Macs).
        install -m 0644 "${limine}/BOOTIA32.EFI" "${ISO_ROOT}/EFI/BOOT/"
    fi

    local cmdline cmdline_serial
    cmdline="console=${SERIAL_TTY},115200 console=tty0 loglevel=4 kod.id=${BUILD_ID}"
    cmdline_serial="console=tty0 console=${SERIAL_TTY},115200 loglevel=6 kod.id=${BUILD_ID}"
    sed -e "s|@KOD_VERSION@|${KOD_VERSION}|g" \
        -e "s|@ARCH@|${ARCH}|g" \
        -e "s|@BUILD_ID@|${BUILD_ID}|g" \
        -e "s|@SERIAL_TTY@|${SERIAL_TTY}|g" \
        -e "s|@CMDLINE_SERIAL@|${cmdline_serial}|g" \
        -e "s|@CMDLINE@|${cmdline}|g" \
        "${CONFIGS_DIR}/limine.conf.in" >"${ISO_ROOT}/boot/limine/limine.conf"
    if grep -q '@[A-Z_]*@' "${ISO_ROOT}/boot/limine/limine.conf"; then
        die "unresolved placeholder in limine.conf"
    fi

    local xorriso_args=(-as mkisofs -R -r -J -V VAKUUM_KOD
        -appid "Vakuum OS Builder ${KOD_VERSION}" -publisher "VakuumOS")
    if [ "${HAVE_BIOS}" = 1 ]; then
        xorriso_args+=(-b boot/limine/limine-bios-cd.bin -no-emul-boot
            -boot-load-size 4 -boot-info-table)
    fi
    xorriso_args+=(-hfsplus -apm-block-size 2048
        --efi-boot boot/limine/limine-uefi-cd.bin -efi-boot-part
        --efi-boot-image --protective-msdos-label
        "${ISO_ROOT}" -o "${ISO_PATH}")
    rm -f "${ISO_PATH}"
    run_logged xorriso xorriso "${xorriso_args[@]}"
    if [ "${HAVE_BIOS}" = 1 ]; then
        run_logged limine-bios-install limine bios-install "${ISO_PATH}"
    fi
    (cd "${OUT_DIR}" && sha256sum "${ISO_NAME}" >"${ISO_NAME}.sha256")
    group_end
    ok "iso: ${ISO_PATH#"${KOD_ROOT}"/} ($(du -h "${ISO_PATH}" | cut -f1))"
}

# ---------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------
log "Vakuum OS Builder ${KOD_VERSION} — ARCH=${ARCH} (${TRIPLE}), jobs=${JOBS}"
log "build id: ${BUILD_ID}"
log "linux ${KERNEL_VERSION}, musl ${MUSL_VERSION}, busybox ${BUSYBOX_VERSION}," \
    "bash ${GNU_BASH_VERSION}.${GNU_BASH_PATCHLEVEL}"
[ "${IS_CROSS}" = 0 ] || warn "cross build ${HOST_ARCH} -> ${ARCH} (experimental)"
[ -z "${CCACHE}" ] || log "ccache: enabled"

for stage in "${STAGES[@]}"; do
    case "${stage}" in
        toolchain) stage_toolchain ;;
        kernel-config) stage_kernel_config ;;
        kernel) stage_kernel ;;
        busybox) stage_busybox ;;
        bash) stage_bash ;;
        disktools) stage_disktools ;;
        console) stage_console ;;
        rootfs) stage_rootfs ;;
        initramfs) stage_initramfs ;;
        iso) stage_iso ;;
        *) die "unknown stage '${stage}' (see --help)" ;;
    esac
done

if [ -f "${ISO_PATH}" ]; then
    ok "done: ${ISO_PATH#"${KOD_ROOT}"/}"
fi
