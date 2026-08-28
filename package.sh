#!/bin/sh
# Build the Zig package tarball for a tag. The tarball embeds the
# submodule trees because Zig does not fetch git submodules.
#
# Usage: ./package.sh <tag>
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <tag>" >&2
    exit 2
fi
tag="$1"
name="sctp-wps-${tag}.tar.gz"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

url="$(git remote get-url origin)"
case "${url}" in
    git@github.com:*) url="https://github.com/${url#git@github.com:}" ;;
esac
echo "Cloning ${url} at ${tag} with submodules..."
GIT_TERMINAL_PROMPT=0 git \
    -c "url.https://github.com/.insteadOf=git@github.com:" \
    clone --quiet --recurse-submodules --depth 1 --branch "${tag}" \
    "${url}" "${work}/src"

tar --exclude=.git -czf "${name}" -C "${work}/src" .

# The package must contain the C sources of both submodules.
for expected in \
    usrsctp/usrsctplib/netinet/sctp_os_userspace.h \
    wavpack-stream/src/pack_utils.c
do
    if ! tar -tzf "${name}" | sed 's|^./||' | grep -qx "${expected}"; then
        echo "error: ${name} is missing ${expected}" >&2
        exit 1
    fi
done

echo "Created ${name}. Package hash:"
zig fetch "${name}"
