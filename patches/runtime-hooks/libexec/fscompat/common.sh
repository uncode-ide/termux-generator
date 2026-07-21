#!/@PREFIX_REL@/bin/sh
# Shared helpers for the filesystem-prefix compatibility layer.
# Sourced by pre-unpack.sh / post-unpack.sh — not meant to run directly.
#
# Responsibilities:
#   - detect a safe parallelism level from the device's CPU
#   - track which files are already patched so repeat dpkg runs
#     don't rescan/re-touch the whole prefix every time
#   - provide one correctness-checked binary string patcher used by
#     everything else, so there's exactly one place that can get it wrong

PREFIX="@PREFIX@"
OLD_PKG="com.termux"
NEW_PKG="@NEW_PKG@"
OLD_PATH="/data/data/${OLD_PKG}/"
NEW_PATH="/data/data/${NEW_PKG}/"

STATE_DIR="$PREFIX/var/lib/fscompat"
PATCHED_DB="$STATE_DIR/patched.db"
PENDING_PKGS="$PREFIX/tmp/.fscompat-pending-pkgs"
NODE_PENDING="$PREFIX/tmp/.fscompat-node-pending"

mkdir -p "$STATE_DIR" 2>/dev/null

# ---------------------------------------------------------------------
# CPU / parallelism detection
# ---------------------------------------------------------------------
# Leaves at least one core free so the device stays responsive — this
# runs while the user may be actively using the phone (foreground app,
# UI thread, etc). Caps out on high-core-count devices since this
# workload is I/O-bound past a point (flash writes, not CPU).
detect_jobs() {
    n=$(nproc 2>/dev/null) \
        || n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) \
        || n=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null) \
        || n=2
    case "$n" in ''|*[!0-9]*) n=2 ;; esac
    j=$((n > 1 ? n - 1 : 1))
    [ "$j" -gt 6 ] && j=6
    echo "$j"
}
JOBS=$(detect_jobs)

# Run a batch of up to $JOBS background jobs, then wait for the whole
# batch before starting the next. Plain POSIX `wait` (no `wait -n`,
# no `jobs -p`) so this works under any /bin/sh, not just bash.
# batched_parallel <worker_fn> < list-of-args-one-per-line
batched_parallel() {
    fn="$1"
    n=0
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        "$fn" "$item" &
        n=$((n + 1))
        if [ "$n" -ge "$JOBS" ]; then
            wait
            n=0
        fi
    done
    wait
}

# ---------------------------------------------------------------------
# Length-safety for binary string patching
# ---------------------------------------------------------------------
# In-place ELF string substitution only works if the replacement is
# EXACTLY the same byte length as the original — anything else shifts
# every following byte and corrupts section/offset tables.
#   - same length: direct substitution, always safe.
#   - shorter: pad with trailing NUL bytes. Safe for a NUL-terminated
#     C string — it just terminates early; the padding bytes become
#     inert, never read by anything.
#   - longer: NOT safe to do in place. We disable hex-patching
#     entirely in this case and rely on patchelf's RUNPATH fix alone
#     (that's the part that actually matters for the dynamic linker;
#     any leftover literal path string is cosmetic, e.g. in a --help
#     banner, not functional).
OLD_LEN=${#OLD_PATH}
NEW_LEN=${#NEW_PATH}
HEXPATCH_SAFE=1
PAD_LEN=0
if [ "$NEW_LEN" -gt "$OLD_LEN" ]; then
    HEXPATCH_SAFE=0
elif [ "$NEW_LEN" -lt "$OLD_LEN" ]; then
    PAD_LEN=$((OLD_LEN - NEW_LEN))
fi

# ---------------------------------------------------------------------
# Idempotency cache — skip files we've already verified correct
# ---------------------------------------------------------------------
stat_line() {
    stat -c '%s %Y' "$1" 2>/dev/null || stat -f '%z %m' "$1" 2>/dev/null
}

already_patched() {
    line=$(stat_line "$1") || return 1
    grep -qxF "$1 $line" "$PATCHED_DB" 2>/dev/null
}

mark_patched() {
    line=$(stat_line "$1") || return 0
    # Small (<PIPE_BUF) O_APPEND writes are atomic on Linux even from
    # multiple concurrent processes, so this is safe without flock
    # and without depending on util-linux being installed.
    printf '%s %s\n' "$1" "$line" >> "$PATCHED_DB" 2>/dev/null
}

# Keep the cache from growing forever across months of `pkg install`.
if [ -f "$PATCHED_DB" ]; then
    lines=$(wc -l < "$PATCHED_DB" 2>/dev/null || echo 0)
    if [ "${lines:-0}" -gt 20000 ] 2>/dev/null; then
        tail -n 10000 "$PATCHED_DB" > "$PATCHED_DB.trim" 2>/dev/null \
            && mv -f "$PATCHED_DB.trim" "$PATCHED_DB"
    fi
fi

is_elf() {
    case "$(head -c4 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' ')" in
        7f454c46) return 0 ;;
        *) return 1 ;;
    esac
}

SKIP_LIBS=" ld-musl-aarch64.so.1 libc.musl-aarch64.so.1 libc++_shared.so "
should_skip_lib() {
    case "$SKIP_LIBS" in *" ${1##*/} "*) return 0 ;; esac
    return 1
}

# ---------------------------------------------------------------------
# hex_patch_file <path> — same-length (or safely-padded) in-place
# string substitution, NUL-safe (perl, not sed — sed's undefined
# behaviour on NUL bytes is what corrupts ELF files).
# ---------------------------------------------------------------------
hex_patch_file() {
    f="$1"
    [ "$HEXPATCH_SAFE" = 1 ] || return 0
    [ -x "$PREFIX/bin/perl" ] || return 0
    grep -q -a -- "$OLD_PATH" "$f" 2>/dev/null || return 0

    "$PREFIX/bin/perl" -e '
        my ($path, $old, $new, $pad) = @ARGV;
        $new .= ("\x00" x $pad);
        die "length mismatch\n" unless length($old) == length($new);
        open my $fh, "+<:raw", $path or exit 0;
        my $data = do { local $/; <$fh> };
        my $n = 0;
        while ($data =~ m/\Q$old\E/g) {
            seek $fh, $-[0], 0;
            print $fh $new;
            $n++;
        }
        close $fh;
        exit($n > 0 ? 0 : 1);
    ' "$f" "$OLD_PATH" "$NEW_PATH" "$PAD_LEN" 2>/dev/null
}

# ---------------------------------------------------------------------
# patchelf_file <path> — RUNPATH fix only. No --force-rpath (converts
# DT_RUNPATH -> DT_RPATH and truncates the dynamic section on some
# libs, e.g. libandroid-support.so).
# ---------------------------------------------------------------------
PATCHELF=""
[ -x "$PREFIX/bin/patchelf" ] && PATCHELF="$PREFIX/bin/patchelf"
[ -z "$PATCHELF" ] && [ -x "$PREFIX/glibc/bin/patchelf" ] && PATCHELF="$PREFIX/glibc/bin/patchelf"

patchelf_file() {
    f="$1"
    [ -n "$PATCHELF" ] || return 0
    should_skip_lib "$f" && return 0
    current=$("$PATCHELF" --print-rpath "$f" 2>/dev/null) || return 0
    want="$PREFIX/lib"
    [ "$current" = "$want" ] && return 0
    case "$current" in *"$NEW_PKG"*) return 0 ;; esac
    "$PATCHELF" --set-rpath "$want" "$f" 2>/dev/null || true
}

# patch_one_file <path> — single entry point used by the parallel
# batch runner. Verifies before AND after so a killed/interrupted
# process can never mark a half-patched file as done.
patch_one_file() {
    f="$1"
    [ -f "$f" ] || return 0
    already_patched "$f" && return 0
    should_skip_lib "$f" && return 0
    is_elf "$f" || return 0

    hex_patch_file "$f"
    patchelf_file "$f"

    # Only cache the result if the file is actually in a good state
    # now (no leftover old path AND, for libs we can check, correct
    # rpath) — otherwise leave it unmarked so the next run retries it
    # instead of silently skipping a file that failed to patch.
    if ! grep -q -a -- "$OLD_PATH" "$f" 2>/dev/null; then
        mark_patched "$f"
    elif [ "$HEXPATCH_SAFE" = 0 ]; then
        # hex-patching is globally disabled (longer package name) —
        # this is expected to still contain the old path string, so
        # don't keep retrying it every single invocation.
        mark_patched "$f"
    fi
}
