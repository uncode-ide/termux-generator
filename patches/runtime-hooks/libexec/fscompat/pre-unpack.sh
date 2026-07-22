#!/@PREFIX_REL@/bin/sh
# APT Pre-Install-Pkgs hook. Receives the list of incoming .deb paths
# on stdin, before dpkg --unpack touches any of them.
#
# For each .deb that actually needs it:
#   1. rewrite the old prefix path in text files (shebangs, maintainer
#      scripts, configs)
#   2. rename the data/data/<old>/ directory structure inside the
#      payload to data/data/<new>/ — without this dpkg tries to write
#      to another app's sandbox directory and Android returns
#      Permission Denied
#   3. repack, favoring speed over ratio (this is a local cache
#      rebuild, not something we ship)
#
# Packages are checked and processed in parallel, batched to the
# device's core count (see common.sh). Repacked .deb files are written
# to a temp name and renamed into place atomically, so a killed
# process can never leave apt looking at a half-written package.
set -u
. "@PREFIX@/libexec/fscompat/common.sh"

: > "$PENDING_PKGS"
rm -f "$NODE_PENDING"

process_one() {
    deb="$1"
    [ -f "$deb" ] || return 0

    pkgname=$("$PREFIX/bin/dpkg-deb" -f "$deb" Package 2>/dev/null)
    if [ -n "$pkgname" ]; then
        printf '%s\n' "$pkgname" >> "$PENDING_PKGS"
        case "$pkgname" in
            nodejs*|node) : > "$NODE_PENDING" ;;
        esac
    fi

    # Cheap precheck, in two stages so most packages short-circuit
    # after the cheaper one:
    #   1. path/name listing — catches a package that physically places
    #      files under data/data/com.termux/... even if nothing in
    #      their own content references that path textually. This is
    #      the critical case: missing it means the directory-rename
    #      step below gets skipped, and dpkg later gets a real Android
    #      Permission Denied trying to write into another app's sandbox.
    #   2. payload content — catches shebangs/configs/embedded strings
    #      that reference the old path without living under that
    #      directory structure themselves (e.g. a script at a normal
    #      location that hardcodes the old absolute path in its body).
    # Both are real, non-overlapping cases, so both are checked; only
    # packages where neither matches skip the expensive extract+repack.
    needs_patch=0
    if "$PREFIX/bin/dpkg-deb" -c "$deb" 2>/dev/null | grep -q "data/data/${OLD_PKG}"; then
        needs_patch=1
    fi
    if [ "$needs_patch" = 0 ]; then
        if "$PREFIX/bin/dpkg-deb" --fsys-tarfile "$deb" 2>/dev/null \
                | tar -xO 2>/dev/null | grep -qa -- "$OLD_PATH"; then
            needs_patch=1
        fi
    fi
    [ "$needs_patch" = 1 ] || return 0

    tmp=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/fscompat.XXXXXX") || return 0
    if ! "$PREFIX/bin/dpkg-deb" -R "$deb" "$tmp" 2>/dev/null; then
        rm -rf "$tmp"
        return 0
    fi

    matches=$(grep -rlI -- "$OLD_PATH" "$tmp" 2>/dev/null)
    if [ -n "$matches" ]; then
        printf '%s\n' "$matches" | while IFS= read -r f; do
            sed -i "s|$OLD_PATH|$NEW_PATH|g" "$f" 2>/dev/null || true
        done
    fi

    if [ -d "$tmp/data/data/${OLD_PKG}" ]; then
        parent="$tmp/data/data"
        newleaf="$parent/${NEW_PKG}"
        mkdir -p "$parent" 2>/dev/null
        # mv (rename syscall) is instant when tmp and target share a
        # filesystem, which they do here — falls back to copy only
        # if that ever isn't true.
        if ! mv "$parent/${OLD_PKG}" "$newleaf" 2>/dev/null; then
            mkdir -p "$newleaf"
            cp -a "$parent/${OLD_PKG}/." "$newleaf/" 2>/dev/null
            rm -rf "$parent/${OLD_PKG}"
        fi
    fi

    for s in preinst postinst prerm postrm; do
        [ -f "$tmp/DEBIAN/$s" ] && chmod 0755 "$tmp/DEBIAN/$s" 2>/dev/null
    done

    # -Zgzip -z1: this .deb only ever gets read back by dpkg locally
    # (apt cache), never redistributed, so ratio doesn't matter —
    # speed does. This alone is usually the single biggest win versus
    # the default xz -9 repack.
    out="${deb}.fscompat.tmp"
    if "$PREFIX/bin/dpkg-deb" -Zgzip -z1 -b "$tmp" "$out" >/dev/null 2>&1; then
        mv -f "$out" "$deb"
    else
        rm -f "$out"
    fi
    rm -rf "$tmp"
}

while IFS= read -r line; do
    case "$line" in *.deb) printf '%s\n' "$line" ;; esac
done | {
    batched_parallel process_one
}

exit 0
