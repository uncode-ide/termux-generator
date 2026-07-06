#!/@PREFIX_REL@/bin/sh
# APT Pre-Install-Pkgs hook: rewrites com.termux paths inside incoming
# .deb packages before dpkg --unpack runs. Handles:
#   1. Text files (shebangs, maintainer scripts, configs)
#   2. Directory structure rename (data/data/com.termux/ → data/data/@NEW_PKG@/)
# Uses sed (not perl) because perl may not be installed yet.
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
    tmp=$(mktemp -d "$PREFIX/tmp/.uncode-deb-rewrite.XXXXXX" 2>/dev/null) || continue

    if "$PREFIX/bin/dpkg-deb" -R "$deb" "$tmp" 2>/dev/null; then
        # 1. Rewrite text files (shebangs, paths in scripts and configs)
        matches=$(grep -rlI "/data/data/${OLD_PKG}/" "$tmp" 2>/dev/null)
        if [ -n "$matches" ]; then
            printf '%s\n' "$matches" | while IFS= read -r f; do
                sed -i "s|/data/data/${OLD_PKG}/|/data/data/${NEW_PKG}/|g" "$f" 2>/dev/null || true
            done
        fi

        # 2. Rename the directory structure inside the .deb data archive
        #    Without this, dpkg tries to create /data/data/com.termux/ which
        #    Android blocks with Permission Denied.
        if [ -d "$tmp/data/data/${OLD_PKG}" ]; then
            mkdir -p "$tmp/data/data/${NEW_PKG}"
            # Use cp+rm instead of mv for cross-device safety
            cp -a "$tmp/data/data/${OLD_PKG}/." "$tmp/data/data/${NEW_PKG}/" 2>/dev/null
            rm -rf "$tmp/data/data/${OLD_PKG}"
        fi

        # 3. Fix maintainer script permissions (dpkg-deb -R extracts at 0644;
        #    dpkg-deb -b refuses to rebuild unless they're 0555..0775)
        for s in preinst postinst prerm postrm; do
            [ -f "$tmp/DEBIAN/$s" ] && chmod 0755 "$tmp/DEBIAN/$s" 2>/dev/null
        done

        # 4. Repack the modified .deb
        "$PREFIX/bin/dpkg-deb" -b "$tmp" "$deb" >/dev/null 2>&1 || true
    fi

    rm -rf "$tmp"
done
exit 0
