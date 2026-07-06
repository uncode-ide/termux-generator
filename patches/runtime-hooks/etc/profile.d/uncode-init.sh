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
# Override HOME if it's empty or any Android-flavored app data dir,
# but leave a custom-set HOME alone.
case "$HOME" in
    "$TERMUX__ROOTFS/home"|"$TERMUX__ROOTFS/home/"*) ;;  # already correct
    ""|/data/user/0/*|/data/data/*) export HOME="$TERMUX__ROOTFS/home" ;;
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
