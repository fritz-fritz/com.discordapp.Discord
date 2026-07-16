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

# Seed writable copies of MediaPipe *.tflite models (symlinked from /app at build;
# see com.discordapp.Discord.yaml).
# Destination matches the build-time symlink target (/var/data == $XDG_DATA_HOME here).
# See: https://github.com/flathub/com.discordapp.Discord/issues/650
mediapipe_store=/app/discord/mediapipe_models
mediapipe_models="${XDG_DATA_HOME:-/var/data}/mediapipe_models"
if [ ! -d "${mediapipe_models}" ]
then
    mkdir -p "${mediapipe_models}"
fi
for model in "${mediapipe_store}"/*.tflite
do
    if ! cmp -s "${model}" "${mediapipe_models}/${model##*/}"
    then
        cp "${model}" "${mediapipe_models}"
    fi
done

env TMPDIR="${XDG_CACHE_HOME}" zypak-wrapper /app/discord/Discord "${FLAGS[@]}" "$@"

if [ "${invoke_socat}" = true ]
then
    kill -SIGTERM "${socat_pid}"
fi
