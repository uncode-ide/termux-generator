#!/@PREFIX_REL@/bin/sh
# APT Pre-Install-Pkgs hook: rewrites com.termux paths inside incoming
# .deb packages before dpkg --unpack runs. Handles:
#   1. Text files (shebangs, maintainer scripts, configs) via grep -I
#      which skips binary files — safe for any package.
#   2. Maintainer-script chmod (dpkg-deb -R extracts at 0644).
# NOTE: Directory rename NOT needed — termux-generator builds with the
# custom package name already baked in, so .deb data/ paths are correct.
# We only need to fix scripts that still carry com.termux shebangs from
# the CI build pipeline that occasionally misses them.
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
        if [ -n "$matches" ]; then
            printf '%s\n' "$matches" | while IFS= read -r f; do
                sed -i "s|/data/data/${OLD_PKG}/|/data/data/${NEW_PKG}/|g" "$f" 2>/dev/null || true
            done
            # dpkg-deb -R extracts maintainer scripts at 0644;
            # dpkg-deb -b refuses to rebuild unless they're 0555..0775.
            for s in preinst postinst prerm postrm; do
                [ -f "$tmp/DEBIAN/$s" ] && chmod 0755 "$tmp/DEBIAN/$s" 2>/dev/null
            done
            "$PREFIX/bin/dpkg-deb" -b "$tmp" "$deb" >/dev/null 2>&1 || true
        fi
    fi
    rm -rf "$tmp"
done
exit 0
