#!/bin/bash
#
# Build opencore-amr (AMR-NB / AMR-WB) static libraries for
#   - iOS device        (arm64)
#   - iOS simulator     (arm64, x86_64)
#   - macOS             (arm64, x86_64)
# and package them as XCFrameworks of static framework bundles — the canonical
# modular binary layout:
#
#   opencore-amrnb.xcframework/<slice>/opencore_amrnb.framework/
#       opencore_amrnb                 static archive (bundle name == module name)
#       Headers/*.h                    public headers
#       Headers/opencore-amrnb.h       generated umbrella header (single entry)
#       Modules/module.modulemap       the ONE module map:
#         framework module opencore_amrnb {
#             umbrella header "opencore-amrnb.h"
#             export *
#         }
#       Info.plist
#
# Consumers:
#   import opencore_amrnb                   // Swift (module names use '_')
#   @import opencore_amrnb;                 // ObjC with -fmodules
#   #include <opencore_amrnb/interf_dec.h>  // textual, framework style
#
# SwiftPM: usable directly as binaryTarget artifacts — including BOTH libraries
# in one package (framework bundles are not merged into a shared include dir).
#
# Usage:
#   ./build_ios.sh
#
# Environment overrides:
#   OUTPUT_DIR                  artifact root                  (default: ./output)
#   IPHONEOS_DEPLOYMENT_TARGET  minimum iOS version            (default: 12.0)
#   MACOSX_DEPLOYMENT_TARGET    minimum macOS version          (default: 10.13)
#   EXTRA_CFLAGS                extra flags for every compile
#   ARCH2                       override the compiled -arch
#   MAKE_JOBS                   make parallelism               (default: ncpu)
#   BUILD_PARALLEL              1 = build targets in parallel (default), 0 = serial

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"
BUILD_ROOT="${OUTPUT_DIR}/build"

readonly DEVELOPER="$(xcode-select --print-path)"
readonly PLATFORMSROOT="${DEVELOPER}/Platforms"

IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-12.0}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.13}"
MAKE_JOBS="${MAKE_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
BUILD_PARALLEL="${BUILD_PARALLEL:-1}"

# Framework bundle version — kept in sync with configure.ac's AC_INIT.
VERSION="${VERSION:-$(sed -n 's/^AC_INIT(\[opencore-amr\], *\[\([^]]*\)\].*/\1/p' "${SRC_DIR}/configure.ac" 2>/dev/null | head -1)}"
VERSION="${VERSION:-0.1.6}"

# Targets to build, as platform:arch:sdk.
TARGET_SPECS=(
    "macosx:arm64:MacOSX"
    "macosx:x86_64:MacOSX"
    "iphoneos:arm64:iPhoneOS"
    "iphonesimulator:x86_64:iPhoneSimulator"
    "iphonesimulator:arm64:iPhoneSimulator"
)

# Libraries to package.
LIBRARIES=(opencore-amrnb opencore-amrwb)

die() { echo "error: $*" >&2; exit 1; }

# Clang module names cannot contain '-': opencore-amrnb -> opencore_amrnb.
module_name_for() { printf '%s\n' "${1//-/_}"; }

headers_for() {
    case "$1" in
        opencore-amrnb) printf 'interf_dec.h interf_enc.h\n' ;;
        opencore-amrwb) printf 'dec_if.h if_rom.h\n' ;;
        *) die "unknown library '$1'" ;;
    esac
}

bootstrap_autotools() {
    # configure's aux scripts (compile, depcomp, install-sh, ...) are gitignored;
    # regenerate them when missing or when configure itself is missing/stale.
    local aux missing="" stale=0
    for aux in compile config.guess config.sub depcomp install-sh ltmain.sh missing; do
        if [[ ! -e "${SRC_DIR}/${aux}" ]]; then missing+="${aux} "; fi
    done
    if [[ ! -x "${SRC_DIR}/configure" ]]; then
        stale=1
    elif [[ "${SRC_DIR}/configure.ac" -nt "${SRC_DIR}/configure" ]]; then
        stale=1
    fi
    if [[ "${stale}" -eq 0 && -z "${missing}" ]]; then
        return 0
    fi

    if command -v aclocal >/dev/null 2>&1 && command -v autoconf >/dev/null 2>&1 \
       && command -v automake >/dev/null 2>&1; then
        (cd "${SRC_DIR}" && aclocal && autoconf && automake --add-missing)
        return 0
    fi

    # Without autotools we can still build when only `compile` is absent: this
    # project never compiles plain C sources (dummy.c exists solely to make
    # automake emit the $(LINK) rule), so configure just needs the file to be
    # there. Write a pass-through stand-in.
    if [[ "${stale}" -eq 0 && "${missing}" == "compile " ]]; then
        echo "note: automake not found — writing pass-through '${SRC_DIR}/compile' shim" >&2
        cat > "${SRC_DIR}/compile" <<'SHIM'
#!/bin/sh
# Pass-through stand-in for the automake 'compile' wrapper script.
# Written by build_ios.sh when autotools are unavailable; configure only
# checks for this file's presence and it is never invoked for this build.
exec "$@"
SHIM
        chmod +x "${SRC_DIR}/compile"
        return 0
    fi

    die "autotools needed but not installed (missing aux files: ${missing:-none}; configure stale: ${stale}).
       Install with: brew install autoconf automake libtool"
}

build_target() {
    local platform=$1 arch=$2 sdk=$3
    local name="${platform}-${arch}-${sdk}"
    local prefix="${OUTPUT_DIR}/${name}"
    local build_dir="${BUILD_ROOT}/${name}"
    local sdkroot="${PLATFORMSROOT}/${sdk}.platform/Developer/SDKs/${sdk}.sdk"

    local cflags="-arch ${ARCH2:-${arch}} -pipe -isysroot ${sdkroot} -O3 -DNDEBUG"
    case "${platform}" in
        iphoneos)        cflags+=" -miphoneos-version-min=${IPHONEOS_DEPLOYMENT_TARGET}" ;;
        iphonesimulator) cflags+=" -mios-simulator-version-min=${IPHONEOS_DEPLOYMENT_TARGET}" ;;
        macosx)          cflags+=" -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}" ;;
    esac
    cflags+="${EXTRA_CFLAGS:+ ${EXTRA_CFLAGS}}"

    # rm -rf can transiently fail with "Directory not empty" on macOS when a
    # security/indexing agent touches files mid-delete — retry once.
    rm -rf "${build_dir}" || { sleep 1; rm -rf "${build_dir}"; }
    rm -rf "${prefix}" || { sleep 1; rm -rf "${prefix}"; }
    mkdir -p "${build_dir}" "${prefix}"

    # Out-of-source (VPATH) build: keeps the source tree clean and lets all
    # targets build in parallel without interfering with each other.
    cd "${build_dir}"
    "${SRC_DIR}/configure" \
        --host="${arch}-apple-darwin" \
        --build="$("${SRC_DIR}/config.guess")" \
        --prefix="${prefix}" \
        --disable-shared --enable-static \
        CXX="xcrun --sdk ${platform} clang++ -arch ${ARCH2:-${arch}}" \
        CFLAGS="${cflags}" \
        CXXFLAGS="${cflags} -isystem ${sdkroot}/usr/include"
    make -j"${MAKE_JOBS}" V=0
    make install
}

build_all_targets() {
    local spec platform arch sdk
    if [[ "${BUILD_PARALLEL}" != "1" ]]; then
        for spec in "${TARGET_SPECS[@]}"; do
            IFS=: read -r platform arch sdk <<< "${spec}"
            echo "==> Building ${platform}-${arch}"
            ( build_target "${platform}" "${arch}" "${sdk}" )
        done
        return 0
    fi

    local pids=() names=() log
    for spec in "${TARGET_SPECS[@]}"; do
        IFS=: read -r platform arch sdk <<< "${spec}"
        log="${BUILD_ROOT}/${platform}-${arch}-${sdk}.log"
        ( build_target "${platform}" "${arch}" "${sdk}" ) >"${log}" 2>&1 &
        pids+=("$!")
        names+=("${platform}-${arch}-${sdk}")
        echo "  started ${platform}-${arch}-${sdk}  (log: ${log})"
    done

    local i failed=0
    for i in "${!pids[@]}"; do
        if wait "${pids[$i]}"; then
            echo "  ✓ ${names[$i]}"
        else
            echo "  ✗ ${names[$i]} FAILED — tail of ${BUILD_ROOT}/${names[$i]}.log:" >&2
            tail -n 30 "${BUILD_ROOT}/${names[$i]}.log" >&2 || true
            failed=1
        fi
    done
    [[ "${failed}" -eq 0 ]] || die "one or more targets failed to build"
}

# Assemble one static framework bundle per platform variant. Bundle name ==
# clang module name (underscores) so module import and autolinking agree.
make_framework_bundles() {
    local lib=$1
    local module; module="$(module_name_for "${lib}")"
    local stage="${OUTPUT_DIR}/staging/${lib}"
    # Headers are architecture-independent; take them from one target's install
    # tree so we ship exactly what `make install` exports.
    local installed="${OUTPUT_DIR}/iphoneos-arm64-iPhoneOS/include/${lib}"
    local h variant archive bundle fat

    rm -rf "${stage}"
    mkdir -p "${stage}/headers"
    for h in $(headers_for "${lib}"); do
        [[ -f "${installed}/${h}" ]] || die "missing installed header: ${installed}/${h}"
        cp -p "${installed}/${h}" "${stage}/headers/"
    done

    # Generated umbrella header — single entry point for the module and for
    # textual consumers (#include <opencore_amrnb/opencore-amrnb.h>).
    local guard; guard="$(printf '%s' "${lib}" | tr '[:lower:]-' '[:upper:]_')_H"
    {
        printf '/* Umbrella header for %s (module %s). Generated by build_ios.sh. */\n' "${lib}" "${module}"
        printf '#ifndef %s\n#define %s\n\n' "${guard}" "${guard}"
        for h in $(headers_for "${lib}"); do printf '#include "%s"\n' "${h}"; done
        printf '\n#endif /* %s */\n' "${guard}"
    } > "${stage}/headers/${lib}.h"

    for variant in iphoneos iphonesimulator macosx; do
        case "${variant}" in
            iphoneos)
                archive="${OUTPUT_DIR}/iphoneos-arm64-iPhoneOS/lib/lib${lib}.a" ;;
            *)
                # Merge per-arch archives: create-xcframework takes exactly one
                # binary per platform+variant.
                fat="${OUTPUT_DIR}/fat/${lib}-${variant}"
                rm -rf "${fat}"; mkdir -p "${fat}"
                if [[ "${variant}" == "iphonesimulator" ]]; then
                    lipo -create \
                        "${OUTPUT_DIR}/iphonesimulator-x86_64-iPhoneSimulator/lib/lib${lib}.a" \
                        "${OUTPUT_DIR}/iphonesimulator-arm64-iPhoneSimulator/lib/lib${lib}.a" \
                        -output "${fat}/lib${lib}.a"
                else
                    lipo -create \
                        "${OUTPUT_DIR}/macosx-x86_64-MacOSX/lib/lib${lib}.a" \
                        "${OUTPUT_DIR}/macosx-arm64-MacOSX/lib/lib${lib}.a" \
                        -output "${fat}/lib${lib}.a"
                fi
                archive="${fat}/lib${lib}.a" ;;
        esac

        bundle="${stage}/${variant}/${module}.framework"
        mkdir -p "${bundle}/Headers" "${bundle}/Modules"
        cp -p "${stage}/headers/"*.h "${bundle}/Headers/"
        cp -p "${archive}" "${bundle}/${module}"

        # The ONE module map. Inside a *.framework bundle, clang resolves the
        # bare umbrella name against Headers/ automatically (framework module
        # semantics) — no Headers/module.modulemap copy is needed or wanted.
        {
            printf 'framework module %s {\n' "${module}"
            printf '    umbrella header "%s.h"\n' "${lib}"
            printf '    export *\n'
            printf '}\n'
        } > "${bundle}/Modules/module.modulemap"

        printf '%s\n' \
            '<?xml version="1.0" encoding="UTF-8"?>' \
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
            '<plist version="1.0">' \
            '<dict>' \
            "	<key>CFBundleIdentifier</key><string>com.opencore.${module}</string>" \
            "	<key>CFBundleName</key><string>${module}</string>" \
            "	<key>CFBundlePackageType</key><string>FMWK</string>" \
            "	<key>CFBundleShortVersionString</key><string>${VERSION}</string>" \
            "	<key>CFBundleVersion</key><string>${VERSION}</string>" \
            '</dict>' \
            '</plist>' > "${bundle}/Info.plist"
    done
}

create_xcframework() {
    local lib=$1
    local module; module="$(module_name_for "${lib}")"
    local stage="${OUTPUT_DIR}/staging/${lib}"
    local xcf="${OUTPUT_DIR}/${lib}.xcframework"

    rm -rf "${xcf}"
    xcodebuild -create-xcframework \
        -framework "${stage}/iphoneos/${module}.framework" \
        -framework "${stage}/iphonesimulator/${module}.framework" \
        -framework "${stage}/macosx/${module}.framework" \
        -output "${xcf}"
}

verify_xcframework() {
    local lib=$1
    local module; module="$(module_name_for "${lib}")"
    local xcf="${OUTPUT_DIR}/${lib}.xcframework"
    local tmp; tmp="$(mktemp -d)"
    local smoke="${tmp}/smoke.swift"
    local slice name sdk triple h

    [[ -f "${xcf}/Info.plist" ]] || die "${lib}.xcframework: missing Info.plist"
    plutil -lint "${xcf}/Info.plist" >/dev/null

    # Swift snippet that loads the module and references its symbols.
    case "${lib}" in
        opencore-amrnb)
            cat > "${smoke}" <<EOF
import ${module}
let encoder = Encoder_Interface_init(0)
Encoder_Interface_exit(encoder)
let decoder = Decoder_Interface_init()
Decoder_Interface_exit(decoder)
EOF
            ;;
        opencore-amrwb)
            cat > "${smoke}" <<EOF
import ${module}
let decoder = D_IF_init()
D_IF_exit(decoder)
let sample: Word16 = 0   // from if_rom.h — proves the umbrella covers both headers
_ = sample
EOF
            ;;
    esac

    echo "  verifying ${lib}.xcframework:"
    local fw
    for slice in "${xcf}"/*/; do
        slice="${slice%/}"
        name="$(basename "${slice}")"
        fw="${slice}/${module}.framework"

        # Structure checks against the framework-bundle layout.
        [[ -d "${fw}" ]]                          || die "${name}: missing ${module}.framework"
        [[ -f "${fw}/${module}" ]]                || die "${name}: missing framework binary"
        [[ -f "${fw}/Modules/module.modulemap" ]] || die "${name}: missing Modules/module.modulemap"
        [[ -f "${fw}/Headers/${lib}.h" ]]         || die "${name}: missing umbrella Headers/${lib}.h"
        [[ ! -e "${fw}/Headers/module.modulemap" ]] || die "${name}: unexpected second module map in Headers/"
        for h in $(headers_for "${lib}"); do
            [[ -f "${fw}/Headers/${h}" ]] || die "${name}: missing Headers/${h}"
        done
        plutil -lint "${fw}/Info.plist" >/dev/null

        case "${name}" in
            *simulator*) sdk=iphonesimulator; triple="arm64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET}-simulator" ;;
            ios-*)       sdk=iphoneos;        triple="arm64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET}" ;;
            macos-*)     sdk=macosx;          triple="arm64-apple-macos${MACOSX_DEPLOYMENT_TARGET}" ;;
            *)           die "unrecognized slice '${name}'" ;;
        esac

        local archs; archs="$(lipo -info "${fw}/${module}" | awk -F': ' '{print $NF}')"
        if [[ "${sdk}" == "macosx" ]]; then
            # Host slice: compile + link + run proves the whole chain — plain
            # framework semantics, no module-map flags.
            xcrun --sdk macosx swiftc "${smoke}" \
                -target "${triple}" \
                -F "${slice}" -framework "${module}" \
                -o "${tmp}/smoke-${lib}"
            "${tmp}/smoke-${lib}"
            # Framework-style textual include — the consumer-facing form.
            printf '#include <%s/%s.h>\nint main(void) { return 0; }\n' "${module}" "${lib}" > "${tmp}/textual.m"
            xcrun clang -F "${slice}" -fsyntax-only "${tmp}/textual.m"
            echo "    ✓ ${name} [${archs}]: import ${module} compiled, linked, ran; #include <${module}/${lib}.h> OK"
        else
            # Cross slices: compile-only (iOS binaries cannot run here).
            xcrun --sdk "${sdk}" swiftc -c "${smoke}" \
                -target "${triple}" \
                -F "${slice}" \
                -o "${tmp}/smoke-${name}.o"
            echo "    ✓ ${name} [${archs}]: import ${module} compiled"
        fi
    done

    rm -rf "${tmp}"
}

main() {
    mkdir -p "${OUTPUT_DIR}" "${BUILD_ROOT}"

    echo "==> Bootstrapping autotools (if needed)"
    bootstrap_autotools

    echo "==> Building ${#TARGET_SPECS[@]} targets (parallel: ${BUILD_PARALLEL})"
    build_all_targets

    local lib
    for lib in "${LIBRARIES[@]}"; do
        echo "==> Packaging ${lib}.xcframework"
        make_framework_bundles "${lib}"
        create_xcframework "${lib}"
        verify_xcframework "${lib}"
    done

    echo
    echo "Done. XCFrameworks in ${OUTPUT_DIR}:"
    for lib in "${LIBRARIES[@]}"; do
        echo "  ${OUTPUT_DIR}/${lib}.xcframework"
    done
}

main "$@"
