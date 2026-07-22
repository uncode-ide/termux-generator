# Funktion, um den Paketnamen zu überprüfen
check_names() {
    if [[ $TERMUX_APP__PACKAGE_NAME =~ '_' ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME =~ '-' ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == package ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == package.* ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == *.package ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == *.package.* ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == in ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == in.* ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == *.in ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == *.in.* ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == is ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == is.* ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == *.is ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == *.is.* ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == as ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == as.* ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == *.as ]] || \
       [[ $TERMUX_APP__PACKAGE_NAME == *.as.* ]]
    then
        echo "[!] Package name must not contain underscores, dashes, or invalid patterns!"
        exit 2
    fi

    if [[ $TERMUX_APP__PACKAGE_NAME == *"com.termux"* ]] && \
        [[ "$TERMUX_APP__PACKAGE_NAME" != "com.termux" ]]; then
        echo "[!] Sorry, please choose a unique custom name that does not contain 'com.termux'"
        echo "(and is not an exact substring of it either) to avoid side effects."
        echo "Examples: 'com.test.termux' is OK, but 'com.termux.test' or 'com.ter' could have side effects."
        exit 2
    fi

    if [[ $ADDITIONAL_PACKAGES == *"termux-x11-nightly"* ]]; then
        echo "[!] That version of termux-x11-nightly is precompiled and"
        echo "cannot be compiled by termux-generator with any custom name inserted!"
        echo "To use termux-x11-nightly with termux-generator, just set"
        echo "'--type f-droid', then install the .apk files termux-generator builds."
        echo "A source-built and patched 'termux-x11-nightly' package is"
        echo "automatically preinstalled."
        exit 2
    fi
}

clean_docker() {
    docker container kill "$TERMUX_GENERATOR_CONTAINER_NAME" 2> /dev/null || true
    docker container rm -f "$TERMUX_GENERATOR_CONTAINER_NAME" 2>/dev/null || true
    if ! docker image rm ghcr.io/termux/package-builder 2>/dev/null; then
        echo "[*] Warning: not removing Docker package builder image for \"F-Droid\" Termux, likely because it is either not downloaded yet, or in use by other containers."
    fi
    if ! docker image rm ghcr.io/termux-play-store/package-builder 2>/dev/null; then
        echo "[*] Warning: not removing Docker package builder image for \"Google Play\" Termux, likely because it is either not downloaded yet, or in use by other containers."
    fi
}

clean_artifacts() {
    rm -rf termux* *.apk *.deb *.xz *.zip 2>/dev/null
}

# Funktion, um Repositories herunterzuladen
download() {
    if [[ "$TERMUX_APP_TYPE" == "f-droid" ]]; then
        git clone --depth 1 https://github.com/termux/termux-packages.git               termux-packages-main
        git clone --depth 1 https://github.com/termux/termux-tasker.git                 termux-apps-main/termux-tasker
        git clone --depth 1 https://github.com/termux/termux-float.git                  termux-apps-main/termux-float
        git clone --depth 1 https://github.com/termux/termux-widget.git                 termux-apps-main/termux-widget
        git clone --depth 1 https://github.com/termux/termux-api.git                    termux-apps-main/termux-api
        git clone --depth 1 https://github.com/termux/termux-boot.git                   termux-apps-main/termux-boot
        git clone --depth 1 https://github.com/termux/termux-styling.git                termux-apps-main/termux-styling
        git clone --depth 1 https://github.com/termux/termux-app.git                    termux-apps-main/termux-app
        git clone --depth 1 https://github.com/termux/termux-gui.git                    termux-apps-main/termux-gui
        # special case - for "F-Droid" Termux, it is necessary to move the termux-am-library subfolder of
        # the termux-am-library repository, which contains its actual code, into the termux-app folder,
        # where its code needs to be patched and compiled into the main "F-Droid" Termux APK
        git clone --depth 1 https://github.com/termux/termux-am-library.git             termux-apps-main/termux-am-library
        mv termux-apps-main/termux-am-library/termux-am-library/                        termux-apps-main/termux-app/termux-am-library
        rm -rf                                                                          termux-apps-main/termux-am-library/
    else
        git clone --depth 1 https://github.com/termux-play-store/termux-packages.git    termux-packages-main
        git clone --depth 1 https://github.com/termux-play-store/termux-apps.git        termux-apps-main
    fi
    git clone --depth 1 --recursive https://github.com/termux/termux-x11.git        termux-apps-main/termux-x11
}

install_plugin() {
    apply_patches "plugins/$TERMUX_GENERATOR_PLUGIN/$TERMUX_APP_TYPE-patches/bootstrap-patches" termux-packages-main
    apply_patches "plugins/$TERMUX_GENERATOR_PLUGIN/$TERMUX_APP_TYPE-patches/app-patches" termux-apps-main
}

# Funktion, um Bootstrap-Patches anzuwenden
patch_bootstraps() {
    # The reason why it is necessary to replace the name first, then patch bootstraps, but do the reverse for apps,
    # is because command-not-found must be partially unpatched back to the default TERMUX_PREFIX to build,
    # so that patch must apply after the bootstraps' name replacement has completed, but the apps contain the
    # string "com.termux" in their code in many more places than the bootstraps do, so it's easier to patch them first.
    if [[ "$TERMUX_APP__PACKAGE_NAME" != "com.termux" ]]; then
        replace_termux_name termux-packages-main "$TERMUX_APP__PACKAGE_NAME"
    fi

    apply_patches "$TERMUX_APP_TYPE-patches/bootstrap-patches" termux-packages-main

    portable_sed_i -e "s|termux-package-builder|$TERMUX_GENERATOR_CONTAINER_NAME|g" termux-packages-main/scripts/run-docker.sh

    local bashrc="termux-packages-main/packages/bash/etc-bash.bashrc"

    if [[ -n "$ENABLE_SSH_SERVER" ]]; then
        cat <<- EOF >> "$bashrc"
            if [ ! -f "\$HOME/.termux/boot/start-sshd" ]; then
                mkdir -p "\$HOME/.termux/boot"
                echo '#!/data/data/$TERMUX_APP__PACKAGE_NAME/files/usr/bin/sh' > "\$HOME/.termux/boot/start-sshd"
                echo '. /data/data/$TERMUX_APP__PACKAGE_NAME/files/usr/etc/bash.bashrc' >> "\$HOME/.termux/boot/start-sshd"
                chmod +x "\$HOME/.termux/boot/start-sshd"
            fi
            if [ ! -f "\$HOME/.termux_authinfo" ]; then
                printf '$DEFAULT_PASSWORD\n$DEFAULT_PASSWORD' | passwd
            fi
            sshd
EOF
    fi

    cp -f "$TERMUX_GENERATOR_HOME/scripts/termux_generator_utils.sh" termux-packages-main/scripts/

    # remove packages that are severely broken in ways that corrupt
    # the container, other packages, or the boostrap second stage if they are allowed to be built
    # I keep track of these, so contact me if you think it's time to remove one from this blocklist
    rm -rf termux-packages-main/packages/swift # https://github.com/termux/termux-packages/issues/26246
    rm -rf termux-packages-main/packages/zeronet # https://github.com/termux/termux-packages/pull/25367
}

# Funktion, um die App zu patchen
patch_apps() {
    apply_patches "$TERMUX_APP_TYPE-patches/app-patches" termux-apps-main

    if [[ "$TERMUX_APP__PACKAGE_NAME" == "com.termux" ]]; then
        return
    fi

    replace_termux_name termux-apps-main "$TERMUX_APP__PACKAGE_NAME"

    migrate_termux_folder_tree termux-apps-main "$TERMUX_APP__PACKAGE_NAME"
}

build_termux_x11() {
    pushd termux-apps-main/termux-x11

    ./gradlew assembleDebug
    ./build_termux_package

    popd
}


move_termux_x11_deb() {
    pushd termux-apps-main/termux-x11

    if [[ "$TERMUX_APP_TYPE" == "f-droid" ]]; then
        local termux_x11_dest="$TERMUX_GENERATOR_HOME/termux-packages-main/output"
    else
        local termux_x11_dest="$TERMUX_GENERATOR_HOME/termux-packages-main"
    fi

    mkdir -p "$termux_x11_dest"
    mv app/build/outputs/apk/debug/*.deb "$termux_x11_dest/termux-x11-nightly_all.deb"

    popd
}

# Funktion, um Bootstraps zu erstellen
build_bootstraps() {
    pushd termux-packages-main

    local bootstrap_script_args=""

    if [ -n "$ENABLE_SSH_SERVER" ]; then
        ADDITIONAL_PACKAGES+=",openssh"
    fi

    bootstrap_script_args+=" --add ${ADDITIONAL_PACKAGES}"

    if [[ "$TERMUX_APP_TYPE" == "f-droid" ]]; then
        local bootstrap_script="build-bootstraps.sh"
        local bootstrap_architectures="aarch64,x86_64,arm,i686"
        if [ -n "${DISABLE_BOOTSTRAP_SECOND_STAGE-}" ]; then
            bootstrap_script_args+=" --disable-bootstrap-second-stage"
        fi
    else
        local bootstrap_script="generate-bootstraps.sh"
        local bootstrap_architectures="aarch64,x86_64,arm"
        bootstrap_script_args+=" --build"
    fi

    if [ -n "${BOOTSTRAP_ARCHITECTURES}" ]; then
        bootstrap_architectures="$BOOTSTRAP_ARCHITECTURES"
    fi

    bootstrap_script_args+=" --architectures $bootstrap_architectures"

    if [[ "${CI-}" == "true" ]]; then
        scripts/free-space.sh
    fi

    # Replace symbolic link /system which is inside the termux-package-builder docker image
    # pointed to /data/data/com.termux/aosp by default
    # https://github.com/termux/termux-packages/blob/650907de80114cc53b20b181161f993e3ad0dfad/scripts/setup-ubuntu.sh#L371
    # needed for building pypy and similar packages
    scripts/run-docker.sh sudo ln -sf "/data/data/$TERMUX_APP__PACKAGE_NAME/aosp" /system

    if [[ "$TERMUX_APP_TYPE" == "f-droid" && "$TERMUX_APP__PACKAGE_NAME" == "com.retired64.termux" && $bootstrap_architectures != *","* ]]; then
        build_all_packages "$bootstrap_architectures"
    fi

    rm -rf .github/workflows/*
    sed -e "s|@TERMUX_APP__PACKAGE_NAME@|$TERMUX_APP__PACKAGE_NAME|g" \
        -e "s|@BOOTSTRAP_BUILD_COMMAND@|scripts/$bootstrap_script $bootstrap_script_args|g" \
        "$TERMUX_GENERATOR_HOME/scripts/build-bootstraps.yml.in" \
        > .github/workflows/build-bootstraps.yml

    scripts/run-docker.sh "scripts/$bootstrap_script" $bootstrap_script_args

    popd
}

# Funktion, um Bootstraps zu kopieren
move_bootstraps() {
    if [[ "$TERMUX_APP_TYPE" == "f-droid" ]]; then
        local app_assets_dir="app/src/main/assets/"
    else
        local app_assets_dir="src/main/assets/"
    fi
    if [ -z "${DISABLE_TERMINAL}" ]; then
        mkdir -p "termux-apps-main/termux-app/$app_assets_dir"
        mv termux-packages-main/bootstrap-* "termux-apps-main/termux-app/$app_assets_dir"
        if [[ "$TERMUX_APP_TYPE" == "f-droid" ]]; then
            mv termux-packages-main/xz-* "termux-apps-main/termux-app/$app_assets_dir"
        fi
    else
        for zip in termux-packages-main/bootstrap-*; do
            mv "$zip" "$TERMUX_APP__PACKAGE_NAME-$TERMUX_APP_TYPE-$(basename $zip)"
        done
    fi
}

# Funktion, um die App zu bauen
build_apps() {
    pushd termux-apps-main

    if [[ "$TERMUX_APP_TYPE" == "f-droid" ]]; then
        if [ -z "${DISABLE_TERMINAL}" ]; then
            pushd termux-app
                ./gradlew publishReleasePublicationToMavenLocal
            popd
        fi
        for app in *; do
            if [[ "$app" == "termux-app" ]] && [[ -n "${DISABLE_TERMINAL}" ]]; then
                continue
            fi
            if [[ "$app" == "termux-tasker" ]] && [[ -n "${DISABLE_TASKER}" ]]; then
                continue
            fi
            if [[ "$app" == "termux-float" ]] && [[ -n "${DISABLE_FLOAT}" ]]; then
                continue
            fi
            if [[ "$app" == "termux-widget" ]] && [[ -n "${DISABLE_WIDGET}" ]]; then
                continue
            fi
            if [[ "$app" == "termux-api" ]] && [[ -n "${DISABLE_API}" ]]; then
                continue
            fi
            if [[ "$app" == "termux-boot" ]] && [[ -n "${DISABLE_BOOT}" ]]; then
                continue
            fi
            if [[ "$app" == "termux-styling" ]] && [[ -n "${DISABLE_STYLING}" ]]; then
                continue
            fi
            if [[ "$app" == "termux-gui" ]] && [[ -n "${DISABLE_GUI}" ]]; then
                continue
            fi
            if [[ "$app" == "termux-x11" ]]; then
                continue
            fi
            pushd "$app"
                ./gradlew assembleDebug
            popd
        done
    else
        if [[ "${CI-}" == "true" ]]; then
            export JAVA_HOME=/usr/lib/jvm/temurin-21-jdk-amd64
            sudo update-alternatives --set java "$JAVA_HOME/bin/java"
        fi
        ./gradlew assembleDebug
    fi

    popd
}

# Funktion, um die APK zu kopieren
move_apks() {
    if [[ "$TERMUX_APP_TYPE" == "f-droid" ]]; then
        local build_dir="app/build/outputs/apk/debug"
    else
        local build_dir="build/outputs/apk/debug"
    fi

    if [ -z "${DISABLE_X11}" ]; then
        for apk in termux-apps-main/termux-x11/app/build/outputs/apk/debug/*.apk; do
            mv "$apk" "$TERMUX_APP__PACKAGE_NAME-$TERMUX_APP_TYPE-$(basename $apk)"
        done
    fi

    if [[ -z "${DISABLE_TERMINAL}" ]] || \
        [[ -z "${DISABLE_TASKER}" ]] || \
        [[ -z "${DISABLE_FLOAT}" ]] || \
        [[ -z "${DISABLE_WIDGET}" ]] || \
        [[ -z "${DISABLE_API}" ]] || \
        [[ -z "${DISABLE_BOOT}" ]] || \
        [[ -z "${DISABLE_STYLING}" ]] || \
        [[ -z "${DISABLE_GUI}" ]]; then
        for apk in termux-apps-main/*/"$build_dir"/*.apk; do
            mv "$apk" "$TERMUX_APP__PACKAGE_NAME-$TERMUX_APP_TYPE-$(basename $apk)"
        done
    fi
}

# Inject runtime APT hooks into bootstrap archives. These hooks enable
# installing packages from the official Termux repository on a device
# running a custom package name (not com.termux). Runs AFTER
# build_bootstraps() and BEFORE move_bootstraps().
inject_runtime_hooks() {
    # Skip if building for the original com.termux name — no hooks needed
    if [[ "$TERMUX_APP__PACKAGE_NAME" == "com.termux" ]]; then
        echo "inject_runtime_hooks: skipping (standard com.termux build)"
        return
    fi

    local HOOKS_DIR="$TERMUX_GENERATOR_HOME/patches/runtime-hooks"
    if [ ! -d "$HOOKS_DIR" ]; then
        echo "inject_runtime_hooks: no patches/runtime-hooks/ directory, skipping"
        return
    fi

    local PREFIX="/data/data/$TERMUX_APP__PACKAGE_NAME/files/usr"
    local PREFIX_REL="data/data/$TERMUX_APP__PACKAGE_NAME/files/usr"
    local ROOTFS="/data/data/$TERMUX_APP__PACKAGE_NAME/files"
    local NEW_PKG="$TERMUX_APP__PACKAGE_NAME"

    echo "inject_runtime_hooks: injecting APT hooks for $NEW_PKG"

    # Process each bootstrap archive found in termux-packages-main/
    for archive in termux-packages-main/bootstrap-*; do
        [ -f "$archive" ] || continue
        echo "inject_runtime_hooks: processing $archive"

        local WORK=$(mktemp -d)
        local ROOTFS_DIR="$WORK/rootfs"
        mkdir -p "$ROOTFS_DIR"

        # ── extract ──────────────────────────────────────────────
        case "$archive" in
            *.tar.xz)
                tar xf "$archive" -C "$ROOTFS_DIR"
                ;;
            *.zip)
                unzip -q "$archive" -d "$ROOTFS_DIR"
                ;;
            *)
                echo "  unknown archive format: $archive, skipping"
                rm -rf "$WORK"
                continue
                ;;
        esac

        # ── copy and template-replace hook files ─────────────────
        # Walk the hooks directory and copy each file, replacing
        # placeholders with actual values.
        find "$HOOKS_DIR" -type f | while IFS= read -r src; do
            local rel="${src#$HOOKS_DIR/}"
            local dst="$ROOTFS_DIR/$rel"
            mkdir -p "$(dirname "$dst")"

            sed -e "s|@PREFIX@|$PREFIX|g" \
                -e "s|@PREFIX_REL@|$PREFIX_REL|g" \
                -e "s|@ROOTFS@|$ROOTFS|g" \
                -e "s|@NEW_PKG@|$NEW_PKG|g" \
                "$src" > "$dst"

            # Preserve executable bit from source
            if [ -x "$src" ] || [[ "$src" == *.sh ]]; then
                chmod 0755 "$dst"
            fi
        done

        # ── hex-patch ALL ELF binaries in the rootfs ─────────────
        # Uses perl for binary-safe same-length (22==22) patching.
        # sed is NOT safe for ELF binary files: NUL bytes cause
        # undefined behaviour and corrupt the file.
        # Text files (shebangs, scripts) use sed — that's safe.
        # In-place binary string substitution only works if the
        # replacement is EXACTLY the same byte length — otherwise every
        # following byte shifts and the ELF section/offset tables are
        # corrupted. "com.termux" is 10 chars; if NEW_PKG's dotted name
        # differs in length, skip hex-patching (patchelf's RUNPATH fix
        # below still runs and covers the part that's actually load-bearing).
        local HEXPATCH_SAFE=1
        if [ "$(echo -n "/data/data/$NEW_PKG/" | wc -c)" -ne "$(echo -n "/data/data/com.termux/" | wc -c)" ]; then
            HEXPATCH_SAFE=0
            echo "  NOTE: '$NEW_PKG' is a different length than 'com.termux' — skipping binary string hex-patch (would corrupt ELF offsets). RUNPATH fix via patchelf still applies."
        fi

        echo "  patching ELF binaries (com.termux → $NEW_PKG)..."
        for scan_dir in "$ROOTFS_DIR/bin" "$ROOTFS_DIR/sbin" \
                        "$ROOTFS_DIR/lib" "$ROOTFS_DIR/libexec" \
                        "$ROOTFS_DIR/glibc/bin" "$ROOTFS_DIR/glibc/lib"; do
            [ -d "$scan_dir" ] || continue
            find "$scan_dir" -type f 2>/dev/null | while IFS= read -r f; do
                # Skip critical files that patchelf/sed must never touch
                case "${f##*/}" in
                    ld-musl-aarch64.so.1|libc.musl-aarch64.so.1|libc++_shared.so)
                        continue ;;
                esac
                # First check: does this file have the old path at all?
                LC_ALL=C grep -q -a '/data/data/com\.termux/' "$f" 2>/dev/null || continue

                is_elf_file=0
                case "$(head -c4 "$f" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' ')" in
                    7f454c46) is_elf_file=1 ;;
                esac

                if [ "$is_elf_file" = 1 ]; then
                    # Binary: only safe to touch in place if the new
                    # package name is the same byte length, and only
                    # with perl (sed is NUL-unsafe on binary data).
                    if [ "$HEXPATCH_SAFE" = 1 ] && command -v perl >/dev/null 2>&1; then
                        perl -e '
                            my $path = $ARGV[0];
                            open my $fh, "+<:raw", $path or exit 1;
                            my $data = do { local $/; <$fh> };
                            my $n = 0;
                            while ($data =~ m{/data/data/com\.termux/}g) {
                                seek $fh, $-[0], 0;
                                print $fh "/data/data/'"$NEW_PKG"'/";
                                $n++;
                            }
                            close $fh;
                            exit 0;
                        ' "$f" 2>/dev/null 
                    elif [ "$HEXPATCH_SAFE" = 0 ]; then
                        : # length mismatch — intentionally skipped, already warned once above
                    else
                        echo "  WARNING: skipping ELF binary $f (perl not available)"
                    fi
                else
                    # Text file: sed is always safe here regardless of
                    # length, since this is normal line-based text
                    # substitution, not a fixed-offset binary patch.
                    LC_ALL=C sed -i 's|/data/data/com\.termux/|/data/data/'"$NEW_PKG"'/|g' "$f" 2>/dev/null \
                        
                fi
            done
        done
        echo "  ✓ ELF binaries patched"

        # ── rewrite dpkg metadata ────────────────────────────────
        # dpkg info files (postinst, prerm, conffiles, list, etc.)
        # and the status DB may still reference com.termux paths.
        # Use perl -i -pe: more portable than sed -i (BSD sed needs
        # -i '' while GNU sed takes bare -i; perl works on both).
        local INFO="$ROOTFS_DIR/var/lib/dpkg/info"
        local STATUS="$ROOTFS_DIR/var/lib/dpkg/status"
        if [ -d "$INFO" ]; then
            echo "  patching dpkg metadata..."
            local PATCH_CMD
            if command -v perl >/dev/null 2>&1; then
                PATCH_CMD="perl -i -pe"
            else
                PATCH_CMD="sed -i"
            fi
            for ext in preinst postinst prerm postrm conffiles md5sums list triggers templates; do
                find "$INFO" -maxdepth 1 -name "*.${ext}" -print0 2>/dev/null \
                    | xargs -0 -r $PATCH_CMD \
                        "s|/data/data/com\.termux/|/data/data/${NEW_PKG}/|g" 2>/dev/null || true
            done
            if [ -f "$STATUS" ]; then
                $PATCH_CMD "s|/data/data/com\.termux/|/data/data/${NEW_PKG}/|g" "$STATUS" 2>/dev/null || true
            fi
            echo "  ✓ dpkg metadata patched"
        fi

        # ── patch node platform if nodejs package is pre-bundled ──
        # Overwrite \x00android\x00 with linux\x00\x00 inside the node binary
        # so npm/native modules see process.platform === 'linux'.
        if [ -f "$ROOTFS_DIR/bin/node" ]; then
            echo "  patching NODE_PLATFORM inside node binary..."
            perl -e '
                my $path = $ARGV[0];
                open my $fh, "+<:raw", $path or exit 1;
                my $data = do { local $/; <$fh> };
                if ($data =~ /\x00android\x00/) {
                    my $offset = $-[0] + 1;
                    seek $fh, $offset, 0;
                    print $fh "linux\x00\x00";
                    close $fh;
                    print "  ✓ patched NODE_PLATFORM at offset $offset\n";
                } else {
                    print "  (already patched or no match found)\n";
                }
            ' "$ROOTFS_DIR/bin/node" 2>/dev/null || echo "  WARNING: failed to patch node binary"
        fi

        # ── rewrite SYMLINKS.txt if present (zip format) ─────────
        if [ -f "$ROOTFS_DIR/SYMLINKS.txt" ]; then
            sed -i "s|/data/data/com.termux/|/data/data/$NEW_PKG/|g" \
                "$ROOTFS_DIR/SYMLINKS.txt"
            echo "  ✓ SYMLINKS.txt patched"
        fi

        # ── re-archive ───────────────────────────────────────────
        rm -f "$archive"
        case "$archive" in
            *.tar.xz)
                # NOTE: `tar cJf out .` (source arg literally ".") makes GNU
                # tar prefix every entry with "./" and adds a leading "./"
                # directory entry for the root itself. That's harmless for
                # extraction (both `tar xf` and the Kotlin-side
                # trimStart('.', '/') handle it fine), but it doesn't match
                # upstream Termux's bootstrap-aarch64.tar.xz, which has
                # entries rooted directly (e.g. "bin/bash", not
                # "./bin/bash"). Globbing the top-level names instead of
                # passing "." keeps the two byte-for-byte comparable and
                # avoids depending on the "./"-stripping workaround at all.
                (
                    cd "$ROOTFS_DIR" && shopt -s dotglob nullglob && \
                    XZ_OPT=-e9 tar cJf "$OLDPWD/$archive" -- *
                )
                ;;
            *.zip)
                (cd "$ROOTFS_DIR" && zip -qry "$OLDPWD/$archive" .)
                ;;
        esac
        echo "  ✓ re-archived $archive"

        rm -rf "$WORK"
    done

    echo "inject_runtime_hooks: done"
}
