#!/bin/sh
# Installs the Cadastre CLI (`cadastre`).
#
#   curl -fsSL https://raw.githubusercontent.com/waratuman/cadastre-cli/main/install.sh | sh
#
# Downloads come from the GitHub releases of waratuman/cadastre-cli. To install
# from elsewhere, set CADASTRE_RELEASES_URL to a directory (https:// or file://)
# holding the release tarballs (`zig build release` writes them to
# zig-out/release/).
#
# Options (environment):
#   CADASTRE_INSTALL_DIR   where to put the binary (default ~/.local/bin, or
#                          /usr/local/bin when run as root)
#   CADASTRE_VERSION       a release tag such as v0.1.0 (default: the latest)
#   CADASTRE_RELEASES_URL  where the tarballs are (overrides the two above's URL)
#
# It detects the OS and CPU, downloads cadastre-<arch>-<os>.tar.gz and its
# .sha256, verifies the checksum, and installs one static binary. Nothing else
# is changed: no shell profile is edited and nothing runs as root unless you
# run it as root.
set -eu

REPO="https://github.com/waratuman/cadastre-cli"

say() { printf '%s\n' "$*"; }
err() { printf 'cadastre install: %s\n' "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

os=$(uname -s)
arch=$(uname -m)
case "$os" in
  Linux) os=linux-musl ;;
  Darwin) os=macos ;;
  MINGW* | MSYS* | CYGWIN*) err "on Windows, download cadastre-x86_64-windows.tar.gz from $REPO/releases" ;;
  *) err "unsupported OS: $os" ;;
esac
case "$arch" in
  x86_64 | amd64) arch=x86_64 ;;
  arm64 | aarch64) arch=aarch64 ;;
  *) err "unsupported CPU: $arch" ;;
esac
# A shell running under Rosetta on an Apple silicon Mac reports x86_64.
if [ "$os" = macos ] && [ "$arch" = x86_64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
  arch=aarch64
fi

name="cadastre-$arch-$os.tar.gz"
if [ -n "${CADASTRE_RELEASES_URL:-}" ]; then
  base=${CADASTRE_RELEASES_URL%/}
elif [ -n "${CADASTRE_VERSION:-}" ]; then
  base="$REPO/releases/download/$CADASTRE_VERSION"
else
  base="$REPO/releases/latest/download"
fi

if [ -n "${CADASTRE_INSTALL_DIR:-}" ]; then
  dir=$CADASTRE_INSTALL_DIR
elif [ "$(id -u)" = 0 ]; then
  dir=/usr/local/bin
else
  dir="$HOME/.local/bin"
fi

download() { # url file
  if has curl; then
    curl -fsSL --proto '=https,file' --tlsv1.2 -o "$2" "$1"
  elif has wget; then
    case "$1" in file://*) cp "${1#file://}" "$2" ;; *) wget -q --https-only -O "$2" "$1" ;; esac
  else
    err "curl or wget is needed"
  fi
}

sha256() {
  if has sha256sum; then
    sha256sum "$1" | cut -d ' ' -f 1
  elif has shasum; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  elif has openssl; then
    openssl dgst -sha256 "$1" | sed 's/.*= //'
  else
    err "sha256sum, shasum or openssl is needed to verify the download"
  fi
}

tmp=$(mktemp -d 2>/dev/null || mktemp -d -t cadastre)
trap 'rm -rf "$tmp"' EXIT INT TERM

say "Downloading $name"
download "$base/$name" "$tmp/$name" || err "could not download $base/$name"
download "$base/$name.sha256" "$tmp/$name.sha256" || err "could not download $base/$name.sha256"

expected=$(cut -d ' ' -f 1 <"$tmp/$name.sha256")
actual=$(sha256 "$tmp/$name")
[ -n "$expected" ] && [ "$expected" = "$actual" ] || err "checksum mismatch for $name (expected $expected, got $actual)"
say "Verified sha256 $actual"

tar -xzf "$tmp/$name" -C "$tmp" || err "could not unpack $name"
[ -f "$tmp/cadastre/cadastre" ] || err "the archive does not hold cadastre/cadastre"

mkdir -p "$dir" || err "could not create $dir (set CADASTRE_INSTALL_DIR)"
# Into place in one rename, so a running cadastre is never half-written.
cp "$tmp/cadastre/cadastre" "$dir/.cadastre.new" && chmod 755 "$dir/.cadastre.new" && mv -f "$dir/.cadastre.new" "$dir/cadastre" ||
  err "could not write $dir/cadastre (set CADASTRE_INSTALL_DIR, or run with sudo for /usr/local/bin)"

say "Installed $("$dir/cadastre" version 2>/dev/null || echo cadastre) to $dir/cadastre"
case ":$PATH:" in
  *":$dir:"*) ;;
  *) say "" && say "$dir is not on your PATH. Add it, e.g.:" && say "  echo 'export PATH=\"$dir:\$PATH\"' >> ~/.profile" ;;
esac

say ""
say "Next:"
say "  cadastre login                 # sign in through your browser (--device on a server)"
say "  cadastre mcp add claude-code   # connect Claude Code (also codex, cursor, vscode)"
say "  cadastre help"
