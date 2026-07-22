#!/usr/bin/env bash

set -euo pipefail

repo="${MERCAT_REPO:-tawago/mercat}"
install_dir="${MERCAT_INSTALL_DIR:-$HOME/.local/bin}"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

detect_os() {
    case "$(uname -s)" in
        Linux) printf 'linux' ;;
        Darwin) printf 'darwin' ;;
        *)
            printf 'Unsupported operating system\n' >&2
            exit 1
            ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64' ;;
        arm64|aarch64) printf 'aarch64' ;;
        *)
            printf 'Unsupported architecture\n' >&2
            exit 1
            ;;
    esac
}

sha_check() {
    local file="$1"
    local checksum_file="$2"

    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -c "$checksum_file"
        return
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c "$checksum_file"
        return
    fi

    printf 'No SHA-256 verifier found (expected shasum or sha256sum)\n' >&2
    exit 1
}

need_cmd curl
need_cmd tar

os="$(detect_os)"
arch="$(detect_arch)"

artifact="mercat-${os}-${arch}.tar.gz"
download_base="https://github.com/${repo}/releases/latest/download"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

printf 'Downloading latest release from %s\n' "$repo"

download_url="${download_base}/${artifact}"
checksum_url="${download_base}/${artifact}.sha256"

printf 'Downloading %s\n' "$artifact"
curl -fsSL "$download_url" -o "$tmpdir/$artifact"
curl -fsSL "$checksum_url" -o "$tmpdir/$artifact.sha256"

(
    cd "$tmpdir"
    sha_check "$artifact" "$artifact.sha256"
)

mkdir -p "$install_dir"
tar -xzf "$tmpdir/$artifact" -C "$tmpdir"
install "$tmpdir/mercat" "$install_dir/mercat"

printf 'Installed mercat to %s/mercat\n' "$install_dir"

case ":$PATH:" in
    *":$install_dir:"*) ;;
    *) printf 'Note: %s is not currently in PATH\n' "$install_dir" ;;
esac
