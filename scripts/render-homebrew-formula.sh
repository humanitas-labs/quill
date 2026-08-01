#!/bin/sh
set -eu

usage() {
    echo "usage: $0 <version> <owner/repository> <manifest-sha256> <arm64-sha256> <x86_64-sha256> [output]" >&2
    exit 64
}

[ "$#" -ge 5 ] && [ "$#" -le 6 ] || usage

version=$1
repository=$2
manifest_sha256=$3
arm64_sha256=$4
x86_64_sha256=$5
output=${6:-Formula/quill.rb}

if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
    echo "version must be a semantic version such as 0.1.0" >&2
    exit 64
fi

if ! printf '%s\n' "$repository" | grep -Eq '^[0-9A-Za-z_.-]+/[0-9A-Za-z_.-]+$'; then
    echo "repository must be owner/name" >&2
    exit 64
fi

case "$manifest_sha256:$arm64_sha256:$x86_64_sha256" in
    *[!0-9a-f:]*|*:|:*) echo "checksums must be lowercase hexadecimal" >&2; exit 64 ;;
esac

[ "${#manifest_sha256}" -eq 64 ] && \
    [ "${#arm64_sha256}" -eq 64 ] && \
    [ "${#x86_64_sha256}" -eq 64 ] || {
    echo "checksums must contain 64 characters" >&2
    exit 64
}

mkdir -p "$(dirname "$output")"
sed \
    -e "s|@VERSION@|$version|g" \
    -e "s|@REPOSITORY@|$repository|g" \
    -e "s|@MANIFEST_SHA256@|$manifest_sha256|g" \
    -e "s|@ARM64_SHA256@|$arm64_sha256|g" \
    -e "s|@X86_64_SHA256@|$x86_64_sha256|g" \
    packaging/homebrew/quill.rb.template > "$output"

echo "$output"
