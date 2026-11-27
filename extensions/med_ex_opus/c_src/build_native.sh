#!/bin/sh
# Concrete pinned libopus build. All generated state stays under MIX_APP_PATH.
set -eu
set -f
mode=${1:?missing native target}
: "${MIX_APP_PATH:?MIX_APP_PATH is required}"
case "$MIX_APP_PATH" in /*) ;; *) echo 'MIX_APP_PATH must be absolute' >&2; exit 1 ;; esac
case "$MIX_APP_PATH" in *' '*|*'	'*|*'
'*) echo 'MIX_APP_PATH cannot contain whitespace' >&2; exit 1 ;; esac
app=$MIX_APP_PATH
build=$app/opus_build
bin=$app/priv/opus_encoder
pin=c_src/vendor/SHA256SUMS
opus=opus-1.5.2
cc=${CC:-cc}
mkdir -p "$app"
[ ! -L "$app" ] || { echo 'Build directory cannot be a symlink' >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo 'Native build requires Linux flock' >&2; exit 1; }
exec 9>"$app/.opus-build.lock"
flock -x 9
work=
input=
download=
binary_temp=
success=0
cleanup() {
  [ -z "$work" ] || rm -rf "$work"
  [ -z "$input" ] || rm -rf "$input"
  [ -z "$download" ] || rm -f "$download"
  [ -z "$binary_temp" ] || rm -f "$binary_temp"
  if [ "$success" != 1 ] && [ "$mode" != clean ]; then
    rm -f "$bin" "$build/.library-key" "$build/.encoder-key"
  fi
}
trap cleanup EXIT HUP INT TERM
if [ "$mode" = clean ]; then
  rm -rf "$build"
  rm -f "$bin"
  success=1
  exit 0
fi
case "$mode" in library|encoder) ;; *) echo 'Unknown native target' >&2; exit 1 ;; esac
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo 'SHA-256 utility is required' >&2
    return 1
  fi
}
expected=$(awk 'NF == 2 && $2 == "opus-1.5.2.tar.gz" {print $1}' "$pin")
case "$expected" in *[!0-9a-f]*|'') echo 'Invalid pinned SHA-256' >&2; exit 1 ;; esac
[ "${#expected}" = 64 ] || { echo 'Invalid pinned SHA-256' >&2; exit 1; }
verify() {
  [ -f "$1" ] && [ -r "$1" ] && [ ! -L "$1" ] || { echo 'Native archive must be a readable regular file' >&2; return 1; }
  actual=$(hash_file "$1")
  [ "$actual" = "$expected" ] || { echo 'SHA-256 mismatch for native archive' >&2; return 1; }
}
if [ -n "${MED_EX_OPUS_TARBALL:-}" ]; then
  archive=$MED_EX_OPUS_TARBALL
  case "$archive" in /*) ;; *) echo 'MED_EX_OPUS_TARBALL must be an absolute path' >&2; exit 1 ;; esac
  [ -f "$archive" ] && [ -r "$archive" ] && [ ! -L "$archive" ] || {
    echo 'MED_EX_OPUS_TARBALL is not a readable regular file' >&2; exit 1;
  }
else
  cache=${XDG_CACHE_HOME:-${HOME:?}/.cache}/med_ex_opus
  archive=$cache/$opus.tar.gz
  if [ ! -e "$archive" ] && [ ! -L "$archive" ]; then
    mkdir -p "$cache"
    download=$(mktemp "$cache/.opus-download.XXXXXX")
    if ! (curl -fsSL -o "$download" "https://downloads.xiph.org/releases/opus/$opus.tar.gz" && verify "$download"); then
      rm -f "$download"
      download=$(mktemp "$cache/.opus-download.XXXXXX")
      curl -fsSL -o "$download" "https://github.com/xiph/opus/releases/download/v1.5.2/$opus.tar.gz"
      verify "$download"
    fi
    mv "$download" "$archive"
    download=
  fi
fi
verify "$archive"
input=$(mktemp -d "$app/.opus-input.XXXXXX")
cp "$archive" "$input/archive.tar.gz"
verify "$input/archive.tar.gz"
# The exact verified snapshot, never an unchecked path, is extracted below.
tar -tzf "$input/archive.tar.gz" > "$input/members"
awk 'BEGIN {bad=0} /^\// || /(^|\/)\.\.(\/|$)/ || !/^opus-1\.5\.2(\/|$)/ {bad=1} END {exit bad}' "$input/members" || {
  echo 'Unsafe native archive member' >&2; exit 1;
}
tar -tvzf "$input/archive.tar.gz" > "$input/types"
awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END {exit bad}' "$input/types" || {
  echo 'Native archive links or special files are refused' >&2; exit 1;
}
command -v "$cc" >/dev/null 2>&1 || { echo 'C compiler unavailable' >&2; exit 1; }
{
  printf '%s\n' "$expected" "$(hash_file "$input/archive.tar.gz")" "$(hash_file "$pin")"
  printf '%s\n' "$(hash_file Makefile)" "$(hash_file c_src/build_native.sh)"
  printf '%s\n' "$cc" "${CFLAGS:-}" "${CPPFLAGS:-}" "${LDFLAGS:-}" "${AR:-}" "${RANLIB:-}" "${MED_EX_OPUS_CONFIGURE_FLAGS:-}"
  "$cc" --version
  "$cc" -dumpmachine
  printf '%s\n' '--disable-shared --enable-static --with-pic --disable-doc --disable-extra-programs'
} > "$input/library-identity"
library_key=$(hash_file "$input/library-identity")
reuse=0
if [ -f "$build/.library-key" ] && [ ! -L "$build/.library-key" ] &&
   [ -f "$build/install/lib/libopus.a" ] && [ ! -L "$build/install/lib/libopus.a" ] &&
   [ "$(cat "$build/.library-key")" = "$library_key" ]; then reuse=1; fi
if [ "$reuse" = 0 ]; then
  rm -f "$bin" "$build/.library-key" "$build/.encoder-key"
  work=$(mktemp -d "$app/.opus-work.XXXXXX")
  mkdir -p "$work/src"
  tar -xzf "$input/archive.tar.gz" -C "$work/src" --no-same-owner --no-same-permissions
  (
    cd "$work/src/$opus"
    ./configure --prefix="$work/install" --disable-shared --enable-static --with-pic --disable-doc --disable-extra-programs ${MED_EX_OPUS_CONFIGURE_FLAGS:-}
    make install
  )
  [ -f "$work/install/lib/libopus.a" ] && [ ! -L "$work/install/lib/libopus.a" ]
  printf '%s\n' "$library_key" > "$work/.library-key"
  rm -rf "$build"
  mv "$work" "$build"
  work=
fi
if [ "$mode" = encoder ]; then
  printf '%s\n' "$library_key" "$(hash_file c_src/opus_encoder.c)" > "$input/encoder-identity"
  encoder_key=$(hash_file "$input/encoder-identity")
  if [ ! -f "$build/.encoder-key" ] || [ -L "$build/.encoder-key" ] ||
     [ ! -x "$bin" ] || [ -L "$bin" ] || [ "$(cat "$build/.encoder-key")" != "$encoder_key" ]; then
    rm -f "$bin" "$build/.encoder-key"
    mkdir -p "$app/priv"
    binary_temp=$(mktemp "$app/priv/.opus-encoder.XXXXXX")
    "$cc" ${CPPFLAGS:-} ${CFLAGS:-} -std=c11 -O2 -Wall -Wextra -Werror -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
      -I"$build/install/include/opus" -o "$binary_temp" c_src/opus_encoder.c "$build/install/lib/libopus.a" ${LDFLAGS:-} -lm
    chmod 755 "$binary_temp"
    mv "$binary_temp" "$bin"
    binary_temp=
    printf '%s\n' "$encoder_key" > "$build/.encoder-key.next"
    mv "$build/.encoder-key.next" "$build/.encoder-key"
  fi
fi
success=1
