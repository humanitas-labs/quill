#!/bin/sh
set -eu

usage() {
    echo "usage: $0 <version> <arm64|x86_64> [output-directory]" >&2
    exit 64
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage

version=$1
architecture=$2
output_directory=${3:-dist}

if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
    echo "version must be a semantic version such as 0.1.0" >&2
    exit 64
fi

case "$architecture" in
    arm64|x86_64) ;;
    *) echo "unsupported architecture: $architecture" >&2; exit 64 ;;
esac

source_version=$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' Sources/quill/Version.swift)
plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/quill/Info.plist)

if [ "$source_version" != "$version" ] || [ "$plist_version" != "$version" ]; then
    echo "release version mismatch: requested=$version source=$source_version plist=$plist_version" >&2
    exit 65
fi

host_architecture=$(uname -m)
if [ "$host_architecture" != "$architecture" ]; then
    echo "package on a native $architecture runner (current host: $host_architecture)" >&2
    exit 69
fi

swift build --configuration release --arch "$architecture"
binary_directory=$(swift build --configuration release --arch "$architecture" --show-bin-path)
binary="$binary_directory/quill"

if [ ! -x "$binary" ]; then
    echo "release binary not found at $binary" >&2
    exit 66
fi

actual_version=$($binary --version)
if [ "$actual_version" != "$version" ]; then
    echo "binary reports $actual_version, expected $version" >&2
    exit 65
fi

if ! /usr/bin/lipo -archs "$binary" | tr ' ' '\n' | grep -qx "$architecture"; then
    echo "binary does not contain the $architecture architecture" >&2
    exit 65
fi

# Ad-hoc signing gives the standalone Mach-O a stable internal identity. A
# future Developer ID certificate can replace '-' without changing packaging.
/usr/bin/codesign --force --sign - --identifier com.digimata.quill "$binary"
/usr/bin/codesign --verify --strict "$binary"

mkdir -p "$output_directory"
stage=$(mktemp -d "${TMPDIR:-/tmp}/quill-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
archive="$output_directory/quill-macos-$architecture.tar.gz"
cp "$binary" "$stage/quill"
cp LICENSE README.md "$stage/"

rm -f "$archive"
COPYFILE_DISABLE=1 /usr/bin/tar -czf "$archive" -C "$stage" quill LICENSE README.md
echo "$archive"
