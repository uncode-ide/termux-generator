# Runtime environment bootstrap for shells. Evaluated on interactive
# and non-interactive bash -l logins. Ensures PREFIX, PATH, HOME,
# TMPDIR, and LANG are set even for subprocesses (adb run-as, ssh, etc.)
if [ -z "$PREFIX" ]; then
    export PREFIX="@PREFIX@"
fi
if [ -z "$TERMUX__PREFIX" ]; then
    export TERMUX__PREFIX="$PREFIX"
fi
if [ -z "$TERMUX__ROOTFS" ]; then
    export TERMUX__ROOTFS="@ROOTFS@"
fi
# Override HOME only if it is empty or does not point to the termux home directory layout.
# This prevents overriding /data/user/0/com.uncode/files/home to /data/data/com.uncode/files/home
# (or vice versa), which causes prompt layout issues (e.g. showing absolute path instead of '~').
case "$HOME" in
    *"/files/home"|*"/files/home/"*) ;;  # already correct (matches either data/data or data/user/0 prefix)
    *) export HOME="$TERMUX__ROOTFS/home" ;;
esac
if [ -z "$TMPDIR" ]; then
    export TMPDIR="$PREFIX/tmp"
fi
if [ -z "$LANG" ]; then
    export LANG="en_US.UTF-8"
fi
case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) export PATH="$PREFIX/bin:$PATH" ;;
esac
