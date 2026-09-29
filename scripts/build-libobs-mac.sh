#!/usr/bin/env bash
#
# Build libobs.framework + the Mac plugin set we need from the Warcraft
# Recorder fork of obs-studio (same fork the Windows build uses, so the
# replay buffer "convert" proc is available), then vendor everything
# into this repo's Frameworks/, PlugIns/, and data/ directories.
#
# Run from the noobs repo root. Expects an obs-studio checkout at
# ../obs-studio (same parent dir as this repo). If that doesn't exist,
# the script clones it at the pinned ref. Patches in scripts/obs-patches
# are applied on top.
#
# Output:
#   Frameworks/libobs.framework
#   Frameworks/libobs-opengl.dylib
#   Frameworks/obs-ffmpeg-mux
#   Frameworks/{ffmpeg,ffprobe}          # CLI tools, linked against the
#                                        # same libav* dylibs
#   Frameworks/lib*.dylib                # ffmpeg + crypto runtime deps
#   PlugIns/{obs-x264,obs-ffmpeg,mac-capture,mac-videotoolbox,
#            image-source,obs-filters}.plugin
#   data/effects/                        # libobs effect files
#
# Prereqs (Homebrew): cmake, jq, ccache (optional). Xcode 16+ with
# command-line tools accepted (`xcodebuild -license accept`).

set -euo pipefail

OBS_REPO="${OBS_REPO:-https://github.com/aza547/warcraft-recorder-obs-studio.git}"
# replay-buffer-to-disk branch (31.1.1 + replay buffer convert + locking).
OBS_REF="${OBS_REF:-0d3069e631568e0e44d5301b535f9eb203ef81f9}"
NOOBS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBS_ROOT="${OBS_ROOT:-${NOOBS_ROOT}/../obs-studio}"
OBS_BUILD="${OBS_ROOT}/build_macos"
PATCH_DIR="${NOOBS_ROOT}/scripts/obs-patches"
FFMPEG_ROOT="${FFMPEG_ROOT:-${NOOBS_ROOT}/../ffmpeg}"

PLUGINS=(
  obs-x264
  obs-ffmpeg
  mac-capture
  mac-videotoolbox
  image-source
  obs-filters
)

# ffmpeg + crypto runtime libs that libobs and obs-ffmpeg's plugin
# binary link against via @rpath/<name>.dylib. Sourced from obs-deps.
RUNTIME_DYLIBS=(
  libavcodec
  libavdevice
  libavfilter
  libavformat
  libavutil
  libswresample
  libswscale
  librist
  libsrt
  libdatachannel
  libfreetype
  libmbedcrypto
  libmbedtls
  libmbedx509
  libx264
)

log() { printf '[build-libobs-mac] %s\n' "$*"; }

clone_or_update_obs() {
  if [[ ! -d "${OBS_ROOT}" ]]; then
    log "Cloning ${OBS_REPO} at ${OBS_REF} into ${OBS_ROOT}"
    git init --quiet "${OBS_ROOT}"
    git -C "${OBS_ROOT}" remote add origin "${OBS_REPO}"
    git -C "${OBS_ROOT}" fetch --quiet --depth 1 origin "${OBS_REF}"
    git -C "${OBS_ROOT}" checkout --quiet FETCH_HEAD
  fi

  # An existing checkout must be at the pinned revision. Plain OBS builds
  # fine but lacks the replay buffer convert proc buffered recording needs.
  local expected actual
  expected="$(git -C "${OBS_ROOT}" rev-parse --verify --quiet "${OBS_REF}^{commit}" || true)"
  actual="$(git -C "${OBS_ROOT}" rev-parse HEAD)"
  if [[ "${expected}" != "${actual}" ]]; then
    log "${OBS_ROOT} is at ${actual}, expected ${OBS_REF} from ${OBS_REPO}."
    log "Check out that revision there, or remove the directory to clone it."
    exit 1
  fi
  # obs-browser and obs-websocket are disabled below, but the plugins
  # CMakeLists still refuses to configure without their submodules.
  log "Initializing submodules"
  git -C "${OBS_ROOT}" submodule update --init --recursive --depth 1
}

apply_patches() {
  for patch in "${PATCH_DIR}"/*.patch; do
    [[ -e "${patch}" ]] || continue
    if git -C "${OBS_ROOT}" apply --reverse --check "${patch}" 2>/dev/null; then
      log "Patch already applied: $(basename "${patch}")"
    else
      log "Applying patch: $(basename "${patch}")"
      git -C "${OBS_ROOT}" apply "${patch}"
    fi
  done
}

deps_dir() {
  local version
  version="$(jq -r '.dependencies.prebuilt.version' "${OBS_ROOT}/buildspec.json")"
  echo "${OBS_ROOT}/.deps/obs-deps-${version}-universal"
}

configure_obs() {
  log "Configuring CMake (preset macos, no UI/browser/webrtc)"
  cmake -S "${OBS_ROOT}" --preset macos \
    -DENABLE_BROWSER=OFF \
    -DENABLE_VLC=OFF \
    -DENABLE_WEBRTC=OFF \
    -DENABLE_AJA=OFF \
    -DENABLE_DECKLINK=OFF \
    -DENABLE_UI=OFF \
    -DENABLE_WEBSOCKET=OFF \
    -DENABLE_SCRIPTING=OFF \
    -DCMAKE_COMPILE_WARNING_AS_ERROR=OFF
}

build_target() {
  local target=$1
  log "Building target: ${target}"
  xcodebuild -project "${OBS_BUILD}/obs-studio.xcodeproj" \
    -target "${target}" \
    -configuration Release \
    ONLY_ACTIVE_ARCH=NO \
    build > "${OBS_BUILD}/${target}.build.log" 2>&1 \
    || { log "build of ${target} failed; tail of log:"; tail -20 "${OBS_BUILD}/${target}.build.log"; exit 1; }
}

# obs-deps ships the libav* dylibs but not the ffmpeg/ffprobe programs
# Warcraft Recorder uses to cut videos. Build just the programs from the
# same FFmpeg release and point them at the obs-deps dylibs, the same
# way the Windows build ships a dynamically linked ffmpeg.exe.
build_ffmpeg_tools() {
  local deps version
  deps="$(deps_dir)"
  version="$(sed -n 's/.*FFMPEG_VERSION "\(.*\)".*/\1/p' "${deps}/include/libavutil/ffversion.h")"

  if [[ ! -d "${FFMPEG_ROOT}" ]]; then
    log "Cloning FFmpeg ${version} into ${FFMPEG_ROOT}"
    git clone --quiet --depth 1 --branch "${version}" \
      https://github.com/FFmpeg/FFmpeg.git "${FFMPEG_ROOT}"
  fi

  log "Building ffmpeg + ffprobe ${version}"
  (
    cd "${FFMPEG_ROOT}"
    ./configure \
      --enable-shared --disable-static \
      --disable-autodetect --disable-postproc \
      --disable-doc --disable-debug \
      --install-name-dir='@rpath' \
      --extra-ldflags='-Wl,-rpath,@executable_path' \
      > "${OBS_BUILD}/ffmpeg-configure.log" 2>&1
    make -j"$(sysctl -n hw.ncpu)" ffmpeg ffprobe \
      > "${OBS_BUILD}/ffmpeg-build.log" 2>&1
  ) || { log "ffmpeg build failed; see ${OBS_BUILD}/ffmpeg-*.log"; exit 1; }
}

vendor_ffmpeg_tools() {
  for tool in ffmpeg ffprobe; do
    local dst="${NOOBS_ROOT}/Frameworks/${tool}"
    cp "${FFMPEG_ROOT}/${tool}" "${dst}"
    # Built against versioned names (libavcodec.61.dylib); we ship the
    # obs-deps dylibs under their unversioned names.
    otool -L "${dst}" | awk '/@rpath\/lib.*\.[0-9]+\.dylib/ {print $1}' |
      while read -r versioned; do
        local unversioned
        unversioned="$(echo "${versioned}" | sed -E 's/\.[0-9]+\.dylib$/.dylib/')"
        install_name_tool -change "${versioned}" "${unversioned}" "${dst}"
      done
    codesign --force --sign - "${dst}" 2>/dev/null
  done
}

vendor_artifacts() {
  log "Vendoring artifacts into ${NOOBS_ROOT}"
  rm -rf "${NOOBS_ROOT}/Frameworks" "${NOOBS_ROOT}/PlugIns" "${NOOBS_ROOT}/data"
  mkdir -p "${NOOBS_ROOT}/Frameworks" "${NOOBS_ROOT}/PlugIns" "${NOOBS_ROOT}/data"

  cp -R "${OBS_BUILD}/libobs/Release/libobs.framework" \
        "${NOOBS_ROOT}/Frameworks/"
  cp "${OBS_BUILD}/libobs-opengl/Release/libobs-opengl.dylib" \
     "${NOOBS_ROOT}/Frameworks/"
  cp "${OBS_BUILD}/plugins/obs-ffmpeg/ffmpeg-mux/Release/obs-ffmpeg-mux" \
     "${NOOBS_ROOT}/Frameworks/"

  for p in "${PLUGINS[@]}"; do
    cp -R "${OBS_BUILD}/plugins/${p}/Release/${p}.plugin" \
          "${NOOBS_ROOT}/PlugIns/"
  done

  local deps arch
  deps="$(deps_dir)"
  arch="$(uname -m)"
  for lib in "${RUNTIME_DYLIBS[@]}"; do
    local dst="${NOOBS_ROOT}/Frameworks/${lib}.dylib"
    # obs-deps ships universal binaries; libobs is built for one arch.
    lipo "${deps}/lib/${lib}.dylib" -thin "${arch}" -output "${dst}" 2>/dev/null ||
      cp "${deps}/lib/${lib}.dylib" "${dst}"
  done

  cp -R "${OBS_ROOT}/libobs/data" "${NOOBS_ROOT}/data/effects"

  vendor_ffmpeg_tools

  log "Vendored:"
  ls "${NOOBS_ROOT}/Frameworks" | sed 's/^/  Frameworks\//'
  ls "${NOOBS_ROOT}/PlugIns"   | sed 's/^/  PlugIns\//'
}

main() {
  clone_or_update_obs
  apply_patches
  configure_obs
  build_target libobs
  build_target libobs-opengl
  build_target obs-ffmpeg-mux
  for p in "${PLUGINS[@]}"; do build_target "${p}"; done
  build_ffmpeg_tools
  vendor_artifacts
  log "Done. Run \`npm run build\` next."
}

main "$@"
