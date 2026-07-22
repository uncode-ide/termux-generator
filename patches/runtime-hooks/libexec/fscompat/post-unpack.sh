#!/@PREFIX_REL@/bin/sh
# APT Post-Invoke hook. Runs after every dpkg operation.
#
# Instead of scanning the entire $PREFIX/bin, /lib, /libexec tree on
# every single invocation (slow, and gets slower as more packages
# accumulate), this targets the EXACT files that belong to packages
# installed in this transaction, via `dpkg -L`. Already-correct files
# are skipped via the idempotency cache in common.sh.
set -u
. "@PREFIX@/libexec/fscompat/common.sh"

# ---- 1. build the exact file list for this transaction only -------
TARGET_LIST="$PREFIX/tmp/.fscompat-targets.$$"
: > "$TARGET_LIST"
if [ -s "$PENDING_PKGS" ]; then
    sort -u "$PENDING_PKGS" | while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        dpkg -L "$pkg" 2>/dev/null
    done >> "$TARGET_LIST"
fi
rm -f "$PENDING_PKGS"

# ---- 2. patch ELF binaries + embedded path strings, in parallel ---
filter_and_patch() {
    while IFS= read -r f; do
        case "$f" in
            "$PREFIX"/bin/*|"$PREFIX"/sbin/*|"$PREFIX"/libexec/*| \
            "$PREFIX"/lib/*.so|"$PREFIX"/lib/*.so.*| \
            "$PREFIX"/glibc/bin/*|"$PREFIX"/glibc/sbin/*|"$PREFIX"/glibc/libexec/*| \
            "$PREFIX"/glibc/lib/*.so|"$PREFIX"/glibc/lib/*.so.*)
                printf '%s\n' "$f" ;;
        esac
    done
}
filter_and_patch < "$TARGET_LIST" | batched_parallel patch_one_file
rm -f "$TARGET_LIST"

# ---- 3. dpkg metadata rewrite --------------------------------------
# dpkg only writes/touches info files for packages in the current
# transaction, so `-newer` on our own last-run marker naturally scopes
# this to just those files without needing the package list again.
INFO="$PREFIX/var/lib/dpkg/info"
STATUS="$PREFIX/var/lib/dpkg/status"
MARKER="$STATE_DIR/.last-run"
FIRST_RUN=0
if [ ! -f "$MARKER" ]; then
    FIRST_RUN=1
    # Best-effort epoch-0 marker so '-newer' works correctly on future
    # runs regardless of whether this succeeds — either way FIRST_RUN
    # makes sure *this* run doesn't depend on it.
    touch -d '@0' "$MARKER" 2>/dev/null || : > "$MARKER"
fi

if [ -d "$INFO" ]; then
    if [ "$FIRST_RUN" = 1 ]; then
        find "$INFO" -maxdepth 1 -type f \
            \( -name '*.preinst' -o -name '*.postinst' -o -name '*.prerm' \
               -o -name '*.postrm' -o -name '*.conffiles' -o -name '*.md5sums' \
               -o -name '*.list' -o -name '*.triggers' -o -name '*.templates' \) \
            -print0 2>/dev/null
    else
        find "$INFO" -maxdepth 1 -type f -newer "$MARKER" \
            \( -name '*.preinst' -o -name '*.postinst' -o -name '*.prerm' \
               -o -name '*.postrm' -o -name '*.conffiles' -o -name '*.md5sums' \
               -o -name '*.list' -o -name '*.triggers' -o -name '*.templates' \) \
            -print0 2>/dev/null
    fi | xargs -0 -r sed -i "s|$OLD_PATH|$NEW_PATH|g" 2>/dev/null
fi
[ -f "$STATUS" ] && sed -i "s|$OLD_PATH|$NEW_PATH|g" "$STATUS" 2>/dev/null
touch "$MARKER" 2>/dev/null

# ---- 4. node platform patch — only if nodejs was actually part of
#         this transaction, not on every unrelated `pkg install` -----
if [ -f "$NODE_PENDING" ]; then
    rm -f "$NODE_PENDING"
    NODE_BIN="$PREFIX/bin/node"
    if [ -f "$NODE_BIN" ] && [ -x "$PREFIX/bin/perl" ]; then
        "$PREFIX/bin/perl" -e '
            my $path = $ARGV[0];
            open my $fh, "+<:raw", $path or exit 0;
            my $data = do { local $/; <$fh> };
            if ($data =~ /\x00android\x00/) {
                seek $fh, $-[0] + 1, 0;
                print $fh "linux\x00\x00";
            }
            close $fh;
        ' "$NODE_BIN" 2>/dev/null
    fi
fi

exit 0
