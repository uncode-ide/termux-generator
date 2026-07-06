#!/@PREFIX_REL@/bin/sh
# APT Pre-Install-Pkgs hook: rewrites com.termux paths inside incoming
# .deb packages before dpkg --unpack runs. Handles:
#   1. Text files (shebangs, maintainer scripts, configs) via grep -I
#      which skips binary files — safe for any package.
#   2. Maintainer-script chmod (dpkg-deb -R extracts at 0644).
# NOTE: Directory rename IS needed because packages installed via apt
# from the official Termux repository contain the com.termux path structure
# (data/data/com.termux/files/usr/...). If we do not rename this directory
# structure inside the .deb archive to com.uncode, dpkg will attempt to write
# to /data/data/com.termux/ and fail with Permission Denied.
set -u
PREFIX=@PREFIX@
OLD_PKG=com.termux
NEW_PKG=@NEW_PKG@
export PATH="$PREFIX/bin:$PATH"
[ -x "$PREFIX/bin/dpkg-deb" ] || exit 0

while IFS= read -r line; do
    case "$line" in *.deb) ;; *) continue ;; esac
    deb="$line"
    [ -f "$deb" ] || continue
    # Use system TMPDIR (or /tmp) — simpler and always writable
    tmp=$(mktemp -d 2>/dev/null) || continue

    if "$PREFIX/bin/dpkg-deb" -R "$deb" "$tmp" 2>/dev/null; then
        # grep -lI: list text files (-I skips binary files) containing
        # the literal path — catches shebangs and config scripts.
        matches=$(grep -rlI "/data/data/${OLD_PKG}/" "$tmp" 2>/dev/null)

        # Check if there are text matches OR the directory structure is com.termux
        # (which is true for all official packages from the com.termux repository).
        if [ -n "$matches" ] || [ -d "$tmp/data/data/${OLD_PKG}" ]; then
            # 1. Rewrite text files (shebangs, paths in scripts and configs)
            if [ -n "$matches" ]; then
                printf '%s\n' "$matches" | while IFS= read -r f; do
                    sed -i "s|/data/data/${OLD_PKG}/|/data/data/${NEW_PKG}/|g" "$f" 2>/dev/null || true
                done
            fi

            # 2. Rename the directory structure inside the .deb payload
            #    Without this, dpkg tries to write to /data/data/com.termux/...
            #    which Android blocks with Permission Denied.
            if [ -d "$tmp/data/data/${OLD_PKG}" ]; then
                mkdir -p "$tmp/data/data/${NEW_PKG}"
                # Use cp + rm for safe cross-device copying
                cp -a "$tmp/data/data/${OLD_PKG}/." "$tmp/data/data/${NEW_PKG}/" 2>/dev/null
                rm -rf "$tmp/data/data/${OLD_PKG}"
            fi

            # 3. Fix maintainer script permissions (dpkg-deb -R extracts at 0644;
            #    dpkg-deb -b refuses to rebuild unless they're 0555..0775)
            for s in preinst postinst prerm postrm; do
                [ -f "$tmp/DEBIAN/$s" ] && chmod 0755 "$tmp/DEBIAN/$s" 2>/dev/null
            done

            # 4. Repack the modified .deb package
            "$PREFIX/bin/dpkg-deb" -b "$tmp" "$deb" >/dev/null 2>&1 || true
        fi
    fi
    rm -rf "$tmp"
done
exit 0
