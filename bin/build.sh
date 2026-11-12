#!/bin/bash
# ============================================================
# build.sh — compile the user-space probes and the kernel module
#
# The two kinds of artifacts have different build requirements:
#   · User-space probes (minictx / bwtest2): any machine can build them,
#     they only need gcc + libcuda
#   · Kernel module (gen2kr.ko): **must use the target machine's kernel headers**
#     (/lib/modules/$(uname -r)/build)
#     => build it on the machine that runs the P104s; do not borrow kernel
#        headers from some other machine
#
# ★ Do not run this with sudo. Artifacts built by root end up owned by root,
#   and afterwards a normal user cannot modify them; if the repo sits on NFS
#   (root_squash), root cannot even write there
#   (.gen2kr.o.d: permission denied).
#
# Usage:
#   bash bin/build.sh              # build everything
#   bash bin/build.sh --user-only  # user-space probes only (any machine)
# ============================================================
set -u

# ============================================================
# 1. Variables
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

KERNEL_BUILD_DIR="/lib/modules/${KVER}/build"

DO_USER_ONLY=0          # 1 = build the user-space probes only
COMPILE_USER=""         # which user compiles the kernel module (downgraded from root)

# User-space probes: artifact name:description (the source file is always src/<name>.c)
USER_PROBES=(
    "minictx:zero DMA, only creates/destroys CUDA contexts"
    "bwtest2:bandwidth test H2D / D2H"
)

# ============================================================
# 2. Functions
# ============================================================

# Decide which user compiles and owns the artifacts
#
# ★ Pitfall hit on 2026-10-29: under NFS root_squash, root is mapped to
#   nobody -- it cannot write the kmod's .gen2kr.o.d and cannot overwrite
#   the files in build/ owned by the union. When SUDO_USER exists, downgrade;
#   when it does not, the user must run this as a normal user.
determine_compile_user() {
    if [ "$(id -u)" != "0" ]; then
        COMPILE_USER="$(id -un)"
        return 0
    fi
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        COMPILE_USER="${SUDO_USER}"
        return 0
    fi
    return 1
}

# Run a command as the given user (downgraded when root; just run when not root)
run_as() {
    local user="$1"; shift
    if [ "${user}" = "$(id -un)" ]; then
        "$@"
    else
        sudo -u "${user}" "$@"
    fi
}

# Print a section heading
section() {
    echo
    echo "=============================================="
    echo " $*"
    echo "=============================================="
}

# Build every user-space probe. Returns 1 if any build fails.
build_user_probes() {
    local item name desc
    section "1. User-space probes"

    for item in "${USER_PROBES[@]}"; do
        name="${item%%:*}"
        desc="${item#*:}"

        if run_as "${COMPILE_USER}" gcc -O2 -o "build/${name}" "src/${name}.c" -ldl 2>/dev/null; then
            echo "  ${name}  ✓   (${desc})"
        else
            echo "  ✗ ${name} failed to compile"
            echo "    source file: src/${name}.c"
            echo "    if libcuda.so.1 is missing: ls -l /usr/lib/x86_64-linux-gnu/libcuda.so.1"
            return 1
        fi
    done
    return 0
}

# Build the kernel module gen2kr.ko. On failure, list the usual causes.
build_kernel_module() {
    local build_log

    section "2. Kernel module gen2kr.ko"
    echo "  this machine's kernel: ${KVER}"

    if [ "${COMPILE_USER}" != "$(id -un)" ]; then
        echo "  compiling as: ${COMPILE_USER} (root cannot write the artifacts; downgraded)"
    fi

    # Precondition 2: the matching kernel headers must exist
    if [ ! -d "${KERNEL_BUILD_DIR}" ]; then
        echo "  ✗ kernel headers missing: ${KERNEL_BUILD_DIR}"
        echo "    install: sudo apt install linux-headers-${KVER}"
        return 1
    fi

    if [ -z "${KMOD_DIR}" ]; then
        echo "  ✗ cannot find the kernel module source directory"
        echo "    expected: drivers/<driver version>/kernel/<kernel version>/gen2kr.c"
        return 1
    fi
    echo "  source directory: ${KMOD_DIR#${PKG_ROOT}/}"

    # ★ The directory name records "the kernel version this module set was
    #   validated on"; warn when it differs from the current kernel
    local dir_kver
    dir_kver="$(basename "${KMOD_DIR}")"
    if [ "${dir_kver}" != "${KVER_SHORT}" ]; then
        echo "  ⚠ the directory records kernel version ${dir_kver}, current is ${KVER_SHORT}"
        echo "    stable APIs usually let it compile, but the artifact is not validated on this kernel"
    fi

    cd "${KMOD_DIR}" || return 1

    # ★ Stale artifacts must be removed, otherwise make says "nothing to do"
    rm -f gen2kr.o gen2kr.ko .gen2kr.o.d \
          gen2kr.mod gen2kr.mod.c gen2kr.mod.o .gen2kr.mod.o.d \
          .module-common.o Module.symvers modules.order 2>/dev/null || true

    # Make the directory owned by (and writable to) the compiling user
    [ "${COMPILE_USER}" != "$(id -un)" ] && chown "${COMPILE_USER}" "${KMOD_DIR}" 2>/dev/null || true

    build_log="$(mktemp)"
    if run_as "${COMPILE_USER}" make -C "${KERNEL_BUILD_DIR}" M="${KMOD_DIR}" modules >"${build_log}" 2>&1; then
        echo "  compile succeeded"
    else
        echo "  ✗ compile failed, last 20 lines:"
        tail -20 "${build_log}" | sed 's/^/     /'
        rm -f "${build_log}"
        cd "${PKG_ROOT}" || true
        print_kmod_failure_hints
        return 1
    fi
    rm -f "${build_log}"
    cd "${PKG_ROOT}" || return 1

    # Confirm the artifact was really produced
    if [ ! -f "${KMOD_DIR}/gen2kr.ko" ]; then
        echo "  ✗ compile \"succeeded\" but no artifact exists; check ${KMOD_DIR}/Makefile"
        return 1
    fi

    # The copy is also downgraded, so build/ does not end up with root-owned artifacts
    mkdir -p build
    [ "${COMPILE_USER}" != "$(id -un)" ] && chown "${COMPILE_USER}" build 2>/dev/null || true
    run_as "${COMPILE_USER}" cp -f "${KMOD_DIR}/gen2kr.ko" build/
    echo "  gen2kr.ko ✓  ($(stat -c%s "${KMOD_DIR}/gen2kr.ko") bytes)"
    return 0
}

# Troubleshooting hints for a kernel module build failure
print_kmod_failure_hints() {
    echo
    echo "  common causes:"
    echo "    1. kernel header version mismatch -- you must build on the machine that runs the P104s"
    echo "       (current ${KVER}; if the target machine's kernel differs, run there)"
    echo "    2. compiler mismatch with the kernel build (a clang-built kernel + gcc-built"
    echo "       module reports unrecognized command-line option '-mstack-alignment')"
    echo "    3. NFS root_squash -- do not use sudo"
}

# List the artifacts and hint at the next step
show_products() {
    section "Artifacts"
    ls -la build/
    echo
    echo "next step: sudo bash bin/10-check.sh    (self-check, strictly read-only)"
}

# Parse command-line arguments
parse_args() {
    case "${1:-}" in
        --user-only) DO_USER_ONLY=1 ;;
        "")          ;;
        *)
            echo "unknown argument: $1" >&2
            echo "usage: bash bin/build.sh [--user-only]" >&2
            exit 2
            ;;
    esac
}

# ============================================================
# 3. main
# ============================================================
main() {
    parse_args "$@"

    cd "${PKG_ROOT}" || exit 1

    if ! determine_compile_user; then
        echo "✗ running as root without SUDO_USER; cannot determine the compiling identity" >&2
        echo "  run as a normal user: bash bin/build.sh" >&2
        exit 1
    fi

    mkdir -p build
    # If build/ was created by root earlier, hand it to the compiling user, otherwise it cannot write
    if [ "${COMPILE_USER}" != "$(id -un)" ]; then
        chown "${COMPILE_USER}" build 2>/dev/null || true
    fi

    build_user_probes || exit 1

    if [ "${DO_USER_ONLY}" = "1" ]; then
        echo
        echo "skipped the kernel module (--user-only)"
        exit 0
    fi

    build_kernel_module || exit 1
    show_products
}

main "$@"
