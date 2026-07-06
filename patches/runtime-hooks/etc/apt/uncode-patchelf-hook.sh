#!/@PREFIX_REL@/bin/sh
# APT Post-Invoke hook: patches ELF binaries installed by dpkg.
#   1. patchelf --set-rpath to fix DT_RUNPATH
#   2. hex-patch com.termux → @NEW_PKG@ in ELF rodata (perl only,
#      sed is NOT safe for binary patching due to NUL byte issues)
#
# Critical correctness invariants (learned from zdroid-bootstrap):
# 1. NO --force-rpath. Converts DT_RUNPATH→DT_RPATH and corrupts
#    some libs (e.g. libandroid-support.so) by truncating dynamic section.
# 2. Skip critical bootstrap libs: ld-musl, libc++_shared. patchelf
#    on these adds sections, shifts offsets, breaks apt on next invoke.
# 3. -cmin -10 (status change time, NOT -mmin). dpkg preserves the .deb's
#    original mtime on extract; ctime updates when dpkg chmods the file.
# 4. Hex-patch skipped if perl missing — sed is unsafe on binary files.
# 5. Check RUNPATH before patching — skip if already correct or already
#    contains NEW_PKG (hex-patch handled it, correct RUNPATH already set).
set -u
PREFIX=@PREFIX@
WANT="$PREFIX/lib"
OLD_PKG=com.termux
NEW_PKG=@NEW_PKG@

# ── patchelf (RUNPATH fix) ───────────────────────────────────────────
PATCHELF=""
if [ -x "$PREFIX/bin/patchelf" ]; then
    PATCHELF="$PREFIX/bin/patchelf"
elif [ -x "$PREFIX/glibc/bin/patchelf" ]; then
    PATCHELF="$PREFIX/glibc/bin/patchelf"
fi

maybe_patchelf() {
    [ -n "$PATCHELF" ] || return 0
    # Skip critical files — patchelf adds/grows sections, which shifts
    # offsets in libs the dynamic linker must load before any patching
    # infrastructure is available.
    case "${1##*/}" in
        ld-musl-aarch64.so.1|libc.musl-aarch64.so.1|libc++_shared.so) return 0 ;;
    esac
    current=$("$PATCHELF" --print-rpath "$1" 2>/dev/null) || return 0
    [ "$current" = "$WANT" ] && return 0
    # If hex-patch already fixed RUNPATH (NEW_PKG present), leave it —
    # for glibc-stack libs the correct RUNPATH is $PREFIX/glibc/lib
    # not $PREFIX/lib, so patchelf would clobber the correct value.
    case "$current" in *${NEW_PKG}*) return 0 ;; esac
    # NO --force-rpath: corrupts some libs by truncating dynamic section.
    "$PATCHELF" --set-rpath "$WANT" "$1" 2>/dev/null || true
}

# ── hex-patch (rodata string replacement) ────────────────────────────
maybe_hex_patch() {
    # sed is NOT safe for binary files (NUL bytes cause undefined
    # behaviour). Only run if perl is available.
    [ -x "$PREFIX/bin/perl" ] || return 0
    grep -q -a -- "/data/data/${OLD_PKG}/" "$1" 2>/dev/null || return 0

    "$PREFIX/bin/perl" -e '
        my $path = $ARGV[0];
        open my $fh, "+<:raw", $path or exit 0;
        my $data = do { local $/; <$fh> };
        my $count = 0;
        # Same-length (22==22) in-place substitution — byte offsets
        # in PT_LOAD/section tables do not shift.
        while ($data =~ m{/data/data/com\.termux/}g) {
            my $offset = $-[0];
            seek $fh, $offset, 0;
            print $fh "/data/data/'"$NEW_PKG"'/";
            $count++;
        }
        close $fh;
        print STDERR "uncode-patchelf: $count com.termux patch(es) in $path\n" if $count > 0;
    ' "$1" 2>&1
}

# ── scan recently installed files ────────────────────────────────────
# bin/sbin/libexec: all file types, ELF only (skip scripts)
for dir in "$PREFIX/bin" "$PREFIX/sbin" "$PREFIX/libexec" \
           "$PREFIX/glibc/bin" "$PREFIX/glibc/sbin" "$PREFIX/glibc/libexec"; do
    [ -d "$dir" ] || continue
    find "$dir" -type f -cmin -10 2>/dev/null | while IFS= read -r f; do
        # Skip non-ELF via magic bytes — od is universally available
        case "$(head -c4 "$f" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' ')" in
            7f454c46) ;;
            *) continue ;;
        esac
        maybe_hex_patch "$f"
        maybe_patchelf "$f"
    done
done

# lib: only .so* files
for dir in "$PREFIX/lib" "$PREFIX/glibc/lib"; do
    [ -d "$dir" ] || continue
    find "$dir" -type f -cmin -10 -name '*.so*' 2>/dev/null | while IFS= read -r f; do
        maybe_hex_patch "$f"
        maybe_patchelf "$f"
    done
done

exit 0
