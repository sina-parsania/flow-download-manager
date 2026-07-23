#!/usr/bin/env bash
# Build a reproducible static arm64 libcurl stack into VendorBuild/prefix/arm64.
# Does not use Homebrew/system curl. Pins and SHA-256 come from manifests/libcurl.json.
#
# Autotools/libtool cannot install into paths that contain whitespace. The project
# root may live on a volume like "/Volumes/T7 Shield/…", so configure/make install
# always run under a space-free cache directory, then the finished prefix is
# copied into VendorBuild/prefix/arm64.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$ROOT/VendorBuild/manifests/libcurl.json"
PREFIX_FINAL="$ROOT/VendorBuild/prefix/arm64"
SRC_CACHE="${HOME}/Library/Caches/DownloadManager/vendor/src"
# Space-free build tree (libtool breaks on whitespace in pwd).
WORK="${HOME}/Library/Caches/DownloadManager/vendor/work-arm64"
PREFIX="$WORK/prefix"
BUILD_ROOT="$WORK/build"
STAMP="$PREFIX_FINAL/.build-stamp"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: VendorBuild requires Apple Silicon (arm64); got $(uname -m)" >&2
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "error: missing manifest $MANIFEST" >&2
  exit 1
fi

EXPECTED_STAMP="$(
  python3 - <<'PY' "$MANIFEST"
import hashlib, json, sys
doc = json.load(open(sys.argv[1]))
h = hashlib.sha256()
h.update(json.dumps(doc, sort_keys=True, separators=(",", ":")).encode())
print(h.hexdigest())
PY
)"

if [[ -f "$STAMP" ]] && [[ "$(cat "$STAMP")" == "$EXPECTED_STAMP" ]] \
  && [[ -f "$PREFIX_FINAL/lib/libcurl.a" ]] \
  && [[ -f "$PREFIX_FINAL/include/curl/curl.h" ]]; then
  echo "vendor-libcurl: up to date ($PREFIX_FINAL)"
  exit 0
fi

mkdir -p "$SRC_CACHE" "$BUILD_ROOT" "$PREFIX" "$PREFIX_FINAL"

fetch() {
  local name="$1" url="$2" sha="$3"
  local dest="$SRC_CACHE/$name"
  if [[ -f "$dest" ]]; then
    local got
    got="$(shasum -a 256 "$dest" | awk '{print $1}')"
    if [[ "$got" == "$sha" ]]; then
      echo "cached $name"
      return 0
    fi
    echo "hash mismatch for cached $name; re-downloading"
    rm -f "$dest"
  fi
  echo "fetching $name"
  /usr/bin/curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
  local got
  got="$(shasum -a 256 "$dest" | awk '{print $1}')"
  if [[ "$got" != "$sha" ]]; then
    echo "error: SHA-256 mismatch for $name" >&2
    echo "  expected: $sha" >&2
    echo "  got:      $got" >&2
    exit 1
  fi
}

extract() {
  local archive="$1" dest="$2"
  rm -rf "$dest"
  mkdir -p "$dest"
  case "$archive" in
    *.tar.xz) tar -xJf "$archive" -C "$dest" --strip-components=1 ;;
    *.tar.gz) tar -xzf "$archive" -C "$dest" --strip-components=1 ;;
    *) echo "error: unsupported archive $archive" >&2; exit 1 ;;
  esac
}

NCPU="$(sysctl -n hw.ncpu)"
export MACOSX_DEPLOYMENT_TARGET=14.0
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC="$(xcrun --find clang)"
export CXX="$(xcrun --find clang++)"
COMMON_CFLAGS="-arch arm64 -isysroot ${SDKROOT} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
export CFLAGS="$COMMON_CFLAGS"
export CXXFLAGS="$COMMON_CFLAGS"
export LDFLAGS="-arch arm64 -isysroot ${SDKROOT} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
export CPPFLAGS="-isysroot ${SDKROOT}"

rm -rf "$PREFIX"
mkdir -p "$PREFIX"

# --- OpenSSL (libcurl TLS + libssh2 crypto) ---
fetch openssl-3.5.1.tar.gz \
  "https://github.com/openssl/openssl/releases/download/openssl-3.5.1/openssl-3.5.1.tar.gz" \
  "529043b15cffa5f36077a4d0af83f3de399807181d607441d734196d889b641f"
extract "$SRC_CACHE/openssl-3.5.1.tar.gz" "$BUILD_ROOT/openssl"
(
  cd "$BUILD_ROOT/openssl"
  ./Configure darwin64-arm64-cc no-shared no-tests --prefix="$PREFIX" --openssldir="$PREFIX/ssl"
  make -j"$NCPU"
  make install_sw
)

# --- nghttp2 ---
fetch nghttp2-1.66.0.tar.xz \
  "https://github.com/nghttp2/nghttp2/releases/download/v1.66.0/nghttp2-1.66.0.tar.xz" \
  "00ba1bdf0ba2c74b2a4fe6c8b1069dc9d82f82608af24442d430df97c6f9e631"
extract "$SRC_CACHE/nghttp2-1.66.0.tar.xz" "$BUILD_ROOT/nghttp2"
(
  cd "$BUILD_ROOT/nghttp2"
  ./configure \
    --prefix="$PREFIX" \
    --disable-shared \
    --enable-static \
    --enable-lib-only \
    --disable-examples
  make -j"$NCPU"
  make install
)

# --- libssh2 ---
fetch libssh2-1.11.1.tar.gz \
  "https://www.libssh2.org/download/libssh2-1.11.1.tar.gz" \
  "d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7"
extract "$SRC_CACHE/libssh2-1.11.1.tar.gz" "$BUILD_ROOT/libssh2"
(
  cd "$BUILD_ROOT/libssh2"
  ./configure \
    --prefix="$PREFIX" \
    --disable-shared \
    --enable-static \
    --with-crypto=openssl \
    --with-libssl-prefix="$PREFIX" \
    CPPFLAGS="$CPPFLAGS -I$PREFIX/include" \
    LDFLAGS="$LDFLAGS -L$PREFIX/lib"
  make -j"$NCPU"
  make install
)

# --- curl / libcurl ---
fetch curl-8.21.0.tar.xz \
  "https://curl.se/download/curl-8.21.0.tar.xz" \
  "aa1b66a70eace83dc624508745646c08ae561de512ab403adffb93ac87fc72e6"
extract "$SRC_CACHE/curl-8.21.0.tar.xz" "$BUILD_ROOT/curl"
(
  cd "$BUILD_ROOT/curl"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  ./configure \
    --prefix="$PREFIX" \
    --host=arm64-apple-darwin \
    --disable-shared \
    --enable-static \
    --enable-ipv6 \
    --with-openssl="$PREFIX" \
    --with-nghttp2="$PREFIX" \
    --with-libssh2="$PREFIX" \
    --with-zlib \
    --with-apple-sectrust \
    --without-libpsl \
    --without-brotli \
    --without-zstd \
    --without-libidn2 \
    --disable-ldap \
    --disable-ldaps \
    --disable-manual \
    --disable-docs \
    CPPFLAGS="$CPPFLAGS -I$PREFIX/include" \
    LDFLAGS="$LDFLAGS -L$PREFIX/lib"
  make -j"$NCPU"
  make install
)

"$PREFIX/bin/curl-config" --features >"$PREFIX/curl-features.txt"
"$PREFIX/bin/curl-config" --protocols >"$PREFIX/curl-protocols.txt"
"$PREFIX/bin/curl" --version >"$PREFIX/curl-version.txt" || true

# Publish into the repository prefix (may contain spaces; only rsync touches it).
rm -rf "$PREFIX_FINAL"
mkdir -p "$(dirname "$PREFIX_FINAL")"
/usr/bin/ditto "$PREFIX" "$PREFIX_FINAL"
printf '%s\n' "$EXPECTED_STAMP" >"$STAMP"

echo "vendor-libcurl: built $PREFIX_FINAL"
cat "$PREFIX_FINAL/curl-version.txt" || true
