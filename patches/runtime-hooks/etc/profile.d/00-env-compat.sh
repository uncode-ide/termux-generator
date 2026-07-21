#!/@PREFIX_REL@/bin/sh
# Ensures PREFIX/HOME/PATH/LANG are set correctly on login-shell paths
# that don't go through the app's normal JNI-based launch (SSH, ADB
# shell, run-as, Termux:Boot), where these are otherwise unset or
# point at the wrong data directory.

if [ -z "$PREFIX" ]; then
    export PREFIX="@PREFIX@"
fi

if [ -z "$TMPDIR" ]; then
    export TMPDIR="$PREFIX/tmp"
fi

if [ -z "$LANG" ]; then
    export LANG="en_US.UTF-8"
fi

case "$HOME" in
    "@ROOTFS@/home"|"@ROOTFS@/home/"*) ;;
    ""|/data/user/0/*|/data/data/*) export HOME="@ROOTFS@/home" ;;
esac

case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) export PATH="$PREFIX/bin:$PATH" ;;
esac
