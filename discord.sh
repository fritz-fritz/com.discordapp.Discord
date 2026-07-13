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

# MediaPipe (video backgrounds / selfie segmentation) opens the discord_voice
# *.tflite models with O_RDWR. /app is mounted read-only, so those opens fail
# with EACCES and the camera goes black. At build time the two model files are
# replaced with symlinks pointing at ${writable} below; stage writable copies
# there so the O_RDWR opens succeed. Only refresh when the deployed app changes
# (keyed on the Flatpak commit, which changes on every update).
# See: https://github.com/flathub/com.discordapp.Discord/issues/650
(
    set -eu
    store=/app/discord/discord_voice_models
    writable=/var/data/discord/discord_voice_models
    stamp_file="${writable}/.stamp"

    # Nothing to do if the read-only stash is absent (e.g. future repackaging).
    if [ ! -d "${store}" ]; then
        exit 0
    fi

    expected_stamp="$(awk -F= '/^app-commit=/{print $2; exit}' /.flatpak-info 2>/dev/null || true)"
    if [ -z "${expected_stamp}" ]; then
        expected_stamp="$(cksum "${store}"/*.tflite | sha256sum | cut -d' ' -f1)"
    fi

    current_stamp=""
    if [ -f "${stamp_file}" ]; then
        current_stamp="$(cat "${stamp_file}")"
    fi

    if [ "${current_stamp}" = "${expected_stamp}" ] && [ -d "${writable}" ]; then
        exit 0
    fi

    mkdir -p "${writable}"
    # Remove any temp dirs left behind by a previously interrupted run.
    rm -rf "${writable}"/.stage.* 2>/dev/null || true

    tmp="$(mktemp -d "${writable}/.stage.XXXXXX")"
    trap 'rm -rf "${tmp}"' EXIT
    cp "${store}"/*.tflite "${tmp}/"
    chmod u+rw "${tmp}"/*.tflite
    # Publish each model atomically so a concurrent launch never sees a partial file.
    for model in "${tmp}"/*.tflite; do
        mv -f "${model}" "${writable}/$(basename "${model}")"
    done
    printf '%s\n' "${expected_stamp}" > "${stamp_file}"
) || echo "discord.sh: warning: failed to stage MediaPipe models; video backgrounds may not work" >&2

env TMPDIR="${XDG_CACHE_HOME}" zypak-wrapper /app/discord/Discord "${FLAGS[@]}" "$@"

if [ "${invoke_socat}" = true ]
then
    kill -SIGTERM "${socat_pid}"
fi
