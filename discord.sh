#!/bin/bash

read -ra SOCAT_ARGS <<<"${SOCAT_ARGS}"

FLATPAK_ID=${FLATPAK_ID:-"com.discordapp.Discord"}
OUR_SOCKET="${XDG_RUNTIME_DIR}/app/${FLATPAK_ID}/discord-ipc-0"
DISCORD_SOCKET="${XDG_RUNTIME_DIR}/discord-ipc-0"

invoke_socat=true
# Check if our socket already exists.
if [ -S "${OUR_SOCKET}" ]
then
    # Check if socat is listening on it.
    if socat "${SOCAT_ARGS[@]}" -u OPEN:/dev/null "UNIX-CONNECT:${OUR_SOCKET}"
    then
        # socat is still listening on it, make sure not to invoke it again.
        invoke_socat=false
    else
        # Socket exists but socat is not listening on it (for whatever reason), delete it so we can invoke socat again.
        rm -f "${OUR_SOCKET}"
    fi
fi

if [ "${invoke_socat}" = true ]
then
    socat "${SOCAT_ARGS[@]}" "UNIX-LISTEN:${OUR_SOCKET},forever,fork" "UNIX-CONNECT:${DISCORD_SOCKET}" &
    socat_pid=$!
fi

if [ -f "${XDG_CONFIG_HOME}/discord-flags.conf" ]
then
    mapfile -t FLAGS <<< "$(grep -Ev '^\s*$|^#' "${XDG_CONFIG_HOME}/discord-flags.conf")"
fi

# Disable auto-updates for Discord and its modules.
disable-breaking-updates.py

# MediaPipe selfie segmentation resolves model paths via
# dladdr(realpath(discord_voice.node)) + basename, then opens sibling
# .tflite files with O_RDWR. Flatpak mounts /app read-only, so opens of
# /app/discord/modules/discord_voice/*.tflite fail with EACCES and camera
# backgrounds go black. Point localModulesRoot at writable per-app data,
# symlink other modules back to /app (they are opened O_RDONLY), and keep a
# real writable copy of discord_voice so realpath() lands on a writable fs.
# See: https://github.com/flathub/com.discordapp.Discord/issues/650
src_modules=/app/discord/modules
dst_modules=/var/data/discord/modules
mkdir -p "${dst_modules}"

for module_path in "${src_modules}"/*; do
    [ -d "${module_path}" ] || continue
    module=$(basename "${module_path}")
    [ "${module}" = "discord_voice" ] && continue

    target="${dst_modules}/${module}"
    if [ -e "${target}" ] || [ -L "${target}" ]; then
        if [ ! -L "${target}" ] || [ "$(readlink "${target}")" != "${module_path}" ]; then
            rm -rf "${target}"
        fi
    fi
    ln -sfn "${module_path}" "${target}"
done

voice_src="${src_modules}/discord_voice"
voice_dst="${dst_modules}/discord_voice"
stamp_file="${dst_modules}/.discord_voice.stamp"
# Hash the packaged app version metadata plus discord_voice module manifests.
# Avoid jq here: it is used at build time but not guaranteed in the runtime.
expected_stamp="$(
    {
        cat /app/discord/resources/build_info.json
        cksum "${voice_src}/manifest.json" "${voice_src}/package.json"
    } | sha256sum | awk '{print $1}'
)"
current_stamp=""
if [ -f "${stamp_file}" ]; then
    current_stamp=$(cat "${stamp_file}")
fi

if [ ! -d "${voice_dst}" ] || [ -L "${voice_dst}" ] || [ "${current_stamp}" != "${expected_stamp}" ]; then
    tmp=$(mktemp -d "${dst_modules}/.discord_voice.XXXXXX")
    if cp -a "${voice_src}/." "${tmp}/" && chmod -R u+rw "${tmp}"; then
        rm -rf "${voice_dst}"
        mv "${tmp}" "${voice_dst}"
        printf '%s\n' "${expected_stamp}" > "${stamp_file}"
    else
        rm -rf "${tmp}"
    fi
fi

env TMPDIR="${XDG_CACHE_HOME}" zypak-wrapper /app/discord/Discord "${FLAGS[@]}" "$@"

if [ "${invoke_socat}" = true ]
then
    kill -SIGTERM "${socat_pid}"
fi
