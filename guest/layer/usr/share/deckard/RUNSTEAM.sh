#!/bin/bash
# steamac: the Frame's /usr/share/deckard/RUNSTEAM.sh (deckard-steamvr-session).
# steam.service copies this file over ~/.local/share/Steam/RUNSTEAM.sh on every
# start (cp -f, so it also replaces the copy unpacked from steam.tar.zst).
#
# Default: the regular 2D gamepad interface. The Frame-only -deckard and
# -vrgamepadui flags select hidden VR texture-stream windows and must not be
# used for the VM's desktop display. STEAMAC_STEAM_VR_UI=1 restores those flags
# for explicit VR experiments (requires a working VR compositor).
#
# Optional /etc/steamac/steam-client-branch selects a public arm64 client
# channel, e.g. steamdeck_stable or steamdeck_publicbeta. That channel is
# written to package/beta before launch; public channels always use the 2D UI.

# verbose
#export PS4='${LINENO}: '
#set -x

set -euo pipefail
STEAMROOT="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# steamac: optional public client channel (see header).
STEAMAC_BRANCH_CONF=/etc/steamac/steam-client-branch
STEAMAC_BRANCH=""
if [[ -r "${STEAMAC_BRANCH_CONF}" ]]; then
  read -r _branch _ < "${STEAMAC_BRANCH_CONF}" || true
  if [[ "${_branch:-}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    STEAMAC_BRANCH="${_branch}"
  else
    echo "steamac: ignoring invalid branch '${_branch:-}' in ${STEAMAC_BRANCH_CONF}" >&2
  fi
fi
STEAMAC_DECKARD_ARG=()
STEAMAC_VRUI_ARG=()

if [[ "${STEAMAC_STEAM_VR_UI:-0}" == 1 ]]; then
  STEAMAC_DECKARD_ARG=(-deckard)
  STEAMAC_VRUI_ARG=(-vrgamepadui)
fi
if [[ -n "${STEAMAC_BRANCH}" ]]; then
  STEAMAC_DECKARD_ARG=()
  STEAMAC_VRUI_ARG=()
fi

# ==========================================================================================
# https://gitlab.steamos.cloud/deckard/tasks/-/issues/242
# custom handling of sideloaded steam client on deckard
IS_SIDELOAD=0
SIDELOADED_STEAMROOT="${HOME}/devkit-game/steam"
if [ "${STEAMROOT}" == "${SIDELOADED_STEAMROOT}" ]; then
  echo "Running sideloaded Steam client in ${STEAMROOT}"
  IS_SIDELOAD=1
  # FIXME: the injection of the overlay into the '/bin/sh -c' we use to launch titles is causing an undetermined crash atm
  # this only happens for the sideload, which is odd ..
  export SUPPRESS_STEAM_OVERLAY=1
fi
# ==========================================================================================

STEAM_RT_ARM64=steamrtarm64
STEAM_SDK_ARM64=linuxarm64

# Support older Steam distributions
if [[ ! -d "${STEAMROOT}/${STEAM_RT_ARM64}" ]]; then
  if [[ -d "${STEAMROOT}/linuxarm64" ]]; then
    STEAM_RT_ARM64="linuxarm64"
  fi
fi

# Support brief moment in time where `linuxarm64` didn't exist
if [[ ! -d "${STEAMROOT}/${STEAM_SDK_ARM64}" ]]; then
  if [[ -d "${STEAMROOT}/steamrtarm64" ]]; then
    STEAM_SDK_ARM64="steamrtarm64"
  fi
fi

# We need these libraries loadable to run Steam
# NOTE: ideally, Steam should be setting `RUNPATH` to `$ORIGIN`-relative paths so this is not needed.
export LD_LIBRARY_PATH="${STEAMROOT}/${STEAM_RT_ARM64}"

mkdir -p ~/.steam
if [[ "${IS_SIDELOAD}" == "0" ]]; then
  # Make sure `~/.steam/steam` symlink exists, we just always point to `${STEAMROOT}`
  ln -sTfn "${STEAMROOT}" ~/.steam/steam
else
  # The sideloaded client uses the OS client's steam library installation
  ln -sTfn ~/.local/share/Steam ~/.steam/steam
fi
# This one may no longer be needed, but it is safer to maintain it for now, especially for the sideloaded client setup
ln -sTfn "${STEAMROOT}" ~/.steam/root

# These symlinks allow SteamVR to find libsteam_api.so, as well as native
# linux games that are run through FEX.
ln -sTfn "${STEAMROOT}/linux32" ~/.steam/sdk32
ln -sTfn "${STEAMROOT}/linux64" ~/.steam/sdk64
ln -sTfn "${STEAMROOT}/${STEAM_SDK_ARM64}" ~/.steam/sdkarm64
ln -sTfn "${STEAMROOT}/${STEAM_RT_ARM64}" ~/.steam/binarm64
ln -sTfn "${STEAMROOT}/ubuntu12_32" ~/.steam/bin32
ln -sTfn "${STEAMROOT}/ubuntu12_64" ~/.steam/bin64

# This is required so that pressure-vessel games like Factorio can work.
# I believe that pressure-vessel _should_ be passing in a reasonable path to the scout runtime when
# launching Factorio, but that doesn't seem to be happening unless we define it here?
export STEAM_RUNTIME="$STEAMROOT/ubuntu12_32/steam-runtime"
if [ -f $STEAMROOT/steamapps/common/FEX-Emu/fex-compat-tool ]; then
  # This takes ~0.5s
  export STEAM_RUNTIME_LIBRARY_PATH=$($STEAMROOT/steamapps/common/FEX-Emu/fex-compat-tool run -- $STEAMROOT/ubuntu12_32/steam-runtime/run.sh --print-steam-runtime-library-paths)
  echo "setting STEAM_RUNTIME_LIBRARY_PATH via FEX-Emu: ${STEAM_RUNTIME_LIBRARY_PATH}"
else
  export STEAM_RUNTIME_LIBRARY_PATH=$STEAM_RUNTIME/pinned_libs_32:$STEAM_RUNTIME/pinned_libs_64:/usr/local/lib/i386-linux-gnu:/lib/i386-linux-gnu:/usr/local/lib:/usr/local/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:/lib:$STEAM_RUNTIME/lib/i386-linux-gnu:$STEAM_RUNTIME/usr/lib/i386-linux-gnu:$STEAM_RUNTIME/lib/x86_64-linux-gnu:$STEAM_RUNTIME/usr/lib/x86_64-linux-gnu:$STEAM_RUNTIME/lib:$STEAM_RUNTIME/usr/lib
  echo "setting STEAM_RUNTIME_LIBRARY_PATH copied from legacy LDLP: ${STEAM_RUNTIME_LIBRARY_PATH}"
fi

if [[ "${IS_SIDELOAD}" == "0" ]]; then
  STEAM_ARGS=(
    -cef-enable-debugging

    # NOTE: this appears to break youtube videos in the store, and also causes black flickering
    #-cef-use-vulkan
    "${STEAMAC_DECKARD_ARG[@]}"   # stock: -deckard (dropped only with a steamac branch)
    -gamepadui
    -steamdeck
    -steamos3
    "${STEAMAC_VRUI_ARG[@]}"      # stock: -vrgamepadui (dropped only with a steamac branch)

    ${STEAM_EXTRA_ARGS:-}
  )
else
  SIDELOADED_CMDLINE_ARGS_FILE="${HOME}/devkit-game/steamdeckard-argv.json"
  read -ra STEAM_ARGS <<< "$(jq -r '.[0]' "${SIDELOADED_CMDLINE_ARGS_FILE}")"
fi

STEAM_COMMAND=(
    "${STEAMROOT}/${STEAM_RT_ARM64}/steam" "${STEAM_ARGS[@]}"
)

if [[ "${IS_SIDELOAD}" == "1" ]]; then
  SIDELOADED_SETTINGS_FILE="${HOME}/devkit-game/steamdeckard-settings.json"
  if [[ "$(jq -r '.gdbserver // "0"' "${SIDELOADED_SETTINGS_FILE}")" == "1" ]]; then
    STEAM_COMMAND=(
      gdbserver 127.0.0.1:2345 "${STEAM_COMMAND[@]}"
    )
  fi
fi

cd ${STEAMROOT}
mkdir -p "${HOME}/.local/share/Steam/logs"

# steamac: optional public client channel (see header).
if [[ "${IS_SIDELOAD}" == "0" && -n "${STEAMAC_BRANCH}" ]]; then
  _beta_file="${STEAMROOT}/package/beta"
  _current="$(head -n1 "${_beta_file}" 2>/dev/null || true)"
  if [[ "${_current}" != "${STEAMAC_BRANCH}" ]]; then
    echo "steamac: Steam client branch '${_current:-<none>}' -> '${STEAMAC_BRANCH}' (${STEAMAC_BRANCH_CONF})"
    mkdir -p "${STEAMROOT}/package"
    printf '%s\n' "${STEAMAC_BRANCH}" > "${_beta_file}"
  fi
fi

exec "${STEAM_COMMAND[@]}" >"${HOME}/.local/share/Steam/logs/steam_output.log" 2>&1
