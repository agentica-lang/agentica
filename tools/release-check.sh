#!/usr/bin/env bash
# Checks of a release binary, in the format of the platform it was built for (release.yml; `make release-check`).
#
#   release-check.sh elf   BINARY ARCH GLIBC          Linux: glibc floor, hardening, no libgc or OpenSSL
#   release-check.sh macho BINARY ARCH MIN_MACOS      macOS: arch, deployment target, only system libraries
#   release-check.sh pe    BINARY ARCH                Windows: arch, only Windows DLLs, hardening
#
# ARCH is the architecture the package claims (x86_64 or arm64). It is read from the binary itself and compared with
# it, and with the machine that runs the check where the binary can run on it, so a runner that is not what its name
# says fails here. Every check reads a tool's output once into a variable: `grep -q` in a pipe under pipefail can fail
# from SIGPIPE.
set -euo pipefail
export LC_ALL=C

die() { echo "$1" >&2; exit 1; }

[ "$#" -ge 3 ] || die "usage: release-check.sh elf|macho|pe BINARY ARCH [GLIBC|MIN_MACOS]"
kind=$1 binary=$2 arch=$3 floor=${4:-}
[ -f "$binary" ] || die "no binary at $binary"
name=$(basename "$binary")
root=$(cd "$(dirname "$0")/.." && pwd)
case $binary in */*) ;; *) binary=./$binary ;; esac

host_arch() {
  # The machine running the check, in the names of the packages.
  local m
  m=$(uname -m)
  case "$m" in
    x86_64 | amd64 | AMD64) echo x86_64 ;;
    arm64 | aarch64) echo arm64 ;;
    *) echo "$m" ;;
  esac
}

# The build runs the binary it checks, so the machine has to be the package's.
vendored_openssl() {
  local ossl
  ossl=$(awk -F= '/^(MAJOR|MINOR|PATCH)=/ { printf "%s%s", sep, $2; sep = "." }' "$root/vm/third_party/openssl/VERSION.dat")
  "$binary" run --version | grep -qF "OpenSSL $ossl" || die "$name does not report the vendored OpenSSL $ossl"
}

[ "$(host_arch)" = "$arch" ] || die "this machine is $(host_arch), not $arch: the $arch package must be built and tested on $arch hardware"

case "$kind" in
  elf)
    case "$arch" in
      x86_64) machine='Advanced Micro Devices X86-64' ;;
      arm64) machine='AArch64' ;;
      *) die "the ELF check knows x86_64 and arm64 only" ;;
    esac
    header=$(readelf -h "$binary")
    grep -q "Machine:[[:space:]]*$machine" <<< "$header" || die "$name is not an $arch ELF"
    grep -q 'Class:[[:space:]]*ELF64' <<< "$header" || die "$name is not a 64-bit ELF"
    sections=$(readelf -SW "$binary")
    if grep -qE '[.](debug_info|symtab)[[:space:]]' <<< "$sections"; then
      die "$name still has .debug_info or .symtab after strip"
    fi
    # grep finds nothing when objdump prints no versions: `|| true` keeps pipefail from ending the check before the
    # message below.
    newest=$({ objdump -T "$binary" | grep -o 'GLIBC_[0-9.]*' || true; } | sort -uV | tail -n 1)
    [ -n "$newest" ] || die "objdump found no GLIBC symbol versions in $name"
    echo "$name needs $newest"
    [ "$(printf '%s\n' "$newest" "GLIBC_$floor" | sort -V | tail -n 1)" = "GLIBC_$floor" ] || die "$name needs $newest, newer than GLIBC_$floor"
    dynamic=$(readelf -d "$binary")
    segments=$(readelf -lW "$binary")
    symbols=$(objdump -T "$binary")
    grep -q 'Type:[[:space:]]*DYN' <<< "$header" || die "$name is not PIE"
    if grep -qE 'NEEDED.*lib(ssl|crypto)' <<< "$dynamic"; then die "$name links OpenSSL dynamically"; fi
    if grep -qE 'NEEDED.*libgc[.]' <<< "$dynamic"; then die "$name links libgc dynamically"; fi
    if grep -qE 'NEEDED.*libz[.]' <<< "$dynamic"; then die "$name links zlib dynamically"; fi
    vendored_openssl
    grep -q 'FLAGS_1).*PIE' <<< "$dynamic" || die "$name is not PIE"
    grep -q '(FLAGS).*BIND_NOW' <<< "$dynamic" || die "$name lacks BIND_NOW"
    grep -q 'GNU_RELRO' <<< "$segments" || die "$name lacks RELRO"
    # The stack protector of glibc, imported: a local definition (zig's compiler_rt has one, with a constant canary)
    # would replace it. arm64 glibc also exports the canary itself, __stack_chk_guard; x86_64 keeps it in the TCB.
    grep -qE '[*]UND[*].*[[:space:]]__stack_chk_fail$' <<< "$symbols" || die "$name lacks glibc's stack protector"
    if [ "$arch" = arm64 ]; then
      grep -qE '[*]UND[*].*[[:space:]]__stack_chk_guard$' <<< "$symbols" || die "$name lacks glibc's stack canary"
    fi
    grep -qE '__(memcpy|read|vsnprintf)_chk' <<< "$symbols" || die "$name lacks _FORTIFY_SOURCE"
    needed=$(grep -o 'NEEDED.*' <<< "$dynamic" || true)
    echo "$name: shared libraries: $(sed 's/.*\[\(.*\)\]/\1/' <<< "$needed" | tr '\n' ' ')"
    ;;

  macho)
    [ -n "$floor" ] || die "macho needs the deployment target, such as 12.0"
    thin=$(lipo -archs "$binary")
    [ "$thin" = "$arch" ] || die "$name holds the architectures '$thin', expected only '$arch'"
    described=$(file -b "$binary")
    grep -q "Mach-O 64-bit executable $arch" <<< "$described" || die "file says: $described"
    build=$(vtool -arch "$arch" -show-build "$binary")
    grep -qE 'platform[[:space:]]+MACOS' <<< "$build" || die "$name is not built for macOS: $build"
    minos=$(awk '$1 == "minos" { print $2 }' <<< "$build")
    [ "$minos" = "$floor" ] || die "$name has minos '$minos', expected $floor"
    # Only the system: libSystem and, if ever used, frameworks under /System. A path under /usr/local, /opt or @rpath
    # (Homebrew's OpenSSL or libgc, a build folder) exists on the build machine only.
    libs=$(otool -L "$binary" | tail -n +2 | awk '{ print $1 }')
    echo "$name: libraries: $(tr '\n' ' ' <<< "$libs")"
    grep -qx '/usr/lib/libSystem.B.dylib' <<< "$libs" || die "$name does not link libSystem"
    bad=$(grep -vE '^(/usr/lib/|/System/Library/)' <<< "$libs" || true)
    [ -z "$bad" ] || die "$name links libraries outside the system: $bad"
    if grep -qE 'lib(ssl|crypto|gc|uv|z)[.0-9]*[.]dylib' <<< "$libs"; then die "$name links a third-party library dynamically"; fi
    vendored_openssl
    header=$(otool -hv -arch "$arch" "$binary")
    grep -qE '(^|[[:space:]])PIE([[:space:]]|$)' <<< "$header" || die "$name is not PIE"
    symbols=$(nm -u "$binary")
    grep -q '___stack_chk_fail' <<< "$symbols" || die "$name lacks the stack protector"
    grep -qE '___(memcpy|vsnprintf)_chk' <<< "$symbols" || die "$name lacks _FORTIFY_SOURCE"
    # arm64 macOS refuses code without a signature; strip removes the linker's, so the release signs ad hoc (no
    # identity, no notarization) and this check proves the signature is whole.
    codesign --verify --strict "$binary" || die "$name has no valid code signature (ad hoc is enough)"
    ;;

  pe)
    [ "$arch" = x86_64 ] || die "the PE check knows x86_64 only"
    info=$(objdump -f "$binary")
    grep -q 'file format pei-x86-64' <<< "$info" || die "$name is not a 64-bit x86 PE file: $info"
    private=$(objdump -p "$binary")
    # A DLL the system does not have fails to start the program: MSYS2's msys-2.0.dll, GCC's libgcc_s_seh-1.dll and
    # libwinpthread-1.dll, and any libssl, libgc or zlib1 belong to the build environment. Allowed: the Windows system DLLs
    # and the Universal C Runtime (ucrtbase.dll and the api-ms-win-* forwarders), part of Windows 10 and later.
    dlls=$(awk '/DLL Name:/ { print tolower($3) }' <<< "$private" | sort -u)
    echo "$name: imports: $(tr '\n' ' ' <<< "$dlls")"
    [ -n "$dlls" ] || die "objdump found no imported DLLs in $name"
    allowed='^(kernel32|ntdll|user32|advapi32|ws2_32|iphlpapi|userenv|psapi|dbghelp|ole32|shell32|bcrypt|crypt32|secur32|shlwapi|ucrtbase)[.]dll$|^api-ms-win-[a-z0-9-]*[.]dll$'
    bad=$(grep -vE "$allowed" <<< "$dlls" || true)
    [ -z "$bad" ] || die "$name imports DLLs that Windows does not provide: $bad"
    "$binary" run --version | grep -q 'libgc ' || die "$name does not report its built-in libgc"
    # DllCharacteristics: 0x20 high-entropy ASLR, 0x40 ASLR, 0x100 DEP (the link flags of the Makefile).
    characteristics=$(awk '$1 == "DllCharacteristics" { print $2 }' <<< "$private")
    [ -n "$characteristics" ] || die "objdump printed no DllCharacteristics for $name"
    [ $(( 0x$characteristics & 0x160 )) -eq $(( 0x160 )) ] || die "$name lacks ASLR, high-entropy ASLR or DEP (DllCharacteristics $characteristics)"
    ;;

  *) die "unknown check '$kind'" ;;
esac
echo "$name: $kind checks passed"
