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
    *)
        # Only replace HOME if it's genuinely missing or doesn't exist —
        # never clobber an already-valid value just because it's in the
        # /data/user/0 alias form instead of /data/data. Android resolves
        # /data/data as a bind-mount of /data/user/0, and $PWD is set from
        # the kernel's canonical (physical) path — whichever form the app
        # actually passed in is the one that will match $PWD, so forcing
        # a specific literal form here breaks bash's "\w" -> "~" prompt
        # substitution (PWD and HOME stop matching as strings even though
        # they point at the same real directory), which is what produced
        # the truncated ".../files/home" prompt instead of "~".
        if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then
            export HOME="@ROOTFS@/home"
        fi
        ;;
esac

case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) export PATH="$PREFIX/bin:$PATH" ;;
esac
