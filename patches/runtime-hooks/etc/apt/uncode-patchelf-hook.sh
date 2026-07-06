#!/@PREFIX_REL@/bin/sh
# APT Post-Invoke hook: patches ELF binaries installed by dpkg.
#   1. patchelf --set-rpath to fix DT_RUNPATH
#   2. hex-patch com.termux → @NEW_PKG@ in ELF rodata
# Uses -cmin (not -mmin) because dpkg preserves .deb's original mtime;
# ctime updates when dpkg chmods the file post-extract.
set -u
PREFIX=@PREFIX@
WANT="$PREFIX/lib"
OLD_PKG=com.termux
NEW_PKG=@NEW_PKG@

# ── patchelf (RUNPATH fix) ───────────────────────────────────────────
PATCHELF=""
if [ -x "$PREFIX/bin/patchelf" ]; then
    PATCHELF="$PREFIX/bin/patchelf"
fi

maybe_patchelf() {
    [ -n "$PATCHELF" ] || return 0
    # Skip files whose RUNPATH is already correct — touching bootstrap
    # libs risks patchelf section-layout corruption.
    current=$("$PATCHELF" --print-rpath "$1" 2>/dev/null) || return 0
    [ "$current" = "$WANT" ] && return 0
    # If hex-patch already fixed RUNPATH (NEW_PKG present), leave it.
    case "$current" in *${NEW_PKG}*) return 0 ;; esac
    # NO --force-rpath: it converts DT_RUNPATH→DT_RPATH and on some
    # libs corrupts the file by truncating its dynamic section.
    "$PATCHELF" --set-rpath "$WANT" "$1" 2>/dev/null || true
}

# ── hex-patch (rodata string replacement) ────────────────────────────
maybe_hex_patch() {
    # Skip files that don't contain the old path at all
    grep -q -a -- "/data/data/${OLD_PKG}/" "$1" 2>/dev/null || return 0

    # Prefer perl for precise binary patching (offset-safe, NUL-safe)
    if [ -x "$PREFIX/bin/perl" ]; then
        "$PREFIX/bin/perl" -e '
            my $path = $ARGV[0];
            open my $fh, "+<:raw", $path or exit 0;
            my $data = do { local $/; <$fh> };
            my $count = 0;
            while ($data =~ m{/data/data/com\.termux/}g) {
                my $offset = $-[0];
                seek $fh, $offset, 0;
                print $fh "/data/data/'"$NEW_PKG"'/";
                $count++;
            }
            close $fh;
        ' "$1" 2>/dev/null
    else
        # Fallback: GNU sed with LC_ALL=C for binary-safe operation.
        # Same-length substitution (22==22 bytes) so offsets don't shift.
        LC_ALL=C sed -i "s|/data/data/${OLD_PKG}/|/data/data/${NEW_PKG}/|g" "$1" 2>/dev/null || true
    fi
}

# ── scan recently installed files ────────────────────────────────────
for dir in "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/libexec"; do
    [ -d "$dir" ] || continue
    if [ "$dir" = "$PREFIX/lib" ]; then
        find "$dir" -type f -cmin -10 -name '*.so*' 2>/dev/null | while IFS= read -r f; do
            maybe_hex_patch "$f"
            maybe_patchelf "$f"
        done
    else
        find "$dir" -type f -cmin -10 2>/dev/null | while IFS= read -r f; do
            # Skip non-ELF files (check for \x7fELF magic)
            case "$(head -c4 "$f" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' ')" in
                7f454c46) ;; *) continue ;; esac
            maybe_hex_patch "$f"
            maybe_patchelf "$f"
        done
    fi
done
exit 0
