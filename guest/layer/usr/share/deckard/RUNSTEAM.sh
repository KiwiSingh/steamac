#!/bin/bash
# steamac: the Frame's /usr/share/deckard/RUNSTEAM.sh (deckard-steamvr-session).
# steam.service copies this file over ~/.local/share/Steam/RUNSTEAM.sh on every
# start (cp -f, so it also replaces the copy unpacked from steam.tar.zst).
#
# Client choice (FX Steam Launcher: Settings > Advanced "Steam client", the
# Create SteamOS Disk sheet, the first-run alert, `--steam-client`), passed on
# every boot as kernel cmdline steamac.steam_client=frame|deck|deckbeta:
# - frame (and absent: older launchers, a custom --cmdline): the stock Frame
#   client. Once a Steam account is remembered this is byte-for-byte stock
#   behaviour — stock flags (-deckard, -vrgamepadui) and the stock client branch
#   from package/beta (the Frame tarball ships linux_arm64_beta_<hash>, the
#   Steam Frame client beta; running Proton games works with it in the VM).
#   Before that: sign-in mode (below).
# - deck / deckbeta: the public arm64 Steam Deck client, branch steamdeck_stable
#   / steamdeck_publicbeta (client-update.steamstatic.com/
#   steam_client_<branch>_linuxarm64). The branch is written to package/beta
#   before every launch (the bootstrapper downloads/installs that client, shown
#   by the FX boot overlay) and the Frame-only flags -deckard (Steam Frame client
#   personality) and -vrgamepadui (VR gamepad UI) are dropped. Same flags as the
#   hashtagbasit/SteamOS-ARM-Handhelds handheld RUNSTEAM.sh. No sign-in mode.
# Manual opt-in: /etc/steamac/steam-client-branch (first word, any client
# branch; lives on the /etc overlay of var-X) acts like deck with that branch
# when the cmdline says frame or nothing; cmdline deck/deckbeta win over it.
# Back to the Frame client: frame (and no file); with -deckard the bootstrapper
# switches package/beta back to the Frame client beta itself.
#
# Sign-in mode: while no Steam account is remembered (config/loginusers.vdf has
# no user with "AutoLogin"/"AllowAutoLogin" "1": fresh disk, signed out, or
# signed in without "Remember me") and the client CDN is reachable, Steam starts
# without -deckard/-vrgamepadui. The Frame client's sign-in screen (ON_FRAME)
# only offers headset flows that cannot work in a VM: "Tap to confirm" pairs
# with the phone over Bluetooth LE, "Scan QR code" opens a VR popup (fails with
# "no VRPooledPopupStore"), leaving only the password form. Without -deckard
# the bootstrapper itself switches package/beta to steamdeck_stable (the public
# arm64 Steam Deck client), whose sign-in screen shows an on-screen QR code next
# to the password form. Once an account is remembered, a watcher restarts
# steam.service; that start has the stock flags again and -deckard makes the
# bootstrapper switch back to the Frame client beta (one client download each
# way, shown by the FX boot overlay).

# verbose
#export PS4='${LINENO}: '
#set -x

set -euo pipefail
STEAMROOT="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# steamac: Steam client choice (see header).
STEAMAC_CLIENT=""
read -r -a _cmdline < /proc/cmdline || true
for _w in "${_cmdline[@]}"; do
  case "${_w}" in steamac.steam_client=*) STEAMAC_CLIENT="${_w#steamac.steam_client=}" ;; esac
done
STEAMAC_BRANCH=""
STEAMAC_BRANCH_SOURCE="steamac.steam_client=${STEAMAC_CLIENT}"
case "${STEAMAC_CLIENT}" in
  deck) STEAMAC_BRANCH=steamdeck_stable ;;
  deckbeta) STEAMAC_BRANCH=steamdeck_publicbeta ;;
  frame|"") ;;
  *) echo "steamac: ignoring unknown steamac.steam_client='${STEAMAC_CLIENT}'" >&2 ;;
esac
STEAMAC_BRANCH_CONF=/etc/steamac/steam-client-branch
if [[ -z "${STEAMAC_BRANCH}" && -r "${STEAMAC_BRANCH_CONF}" ]]; then
  read -r _branch _ < "${STEAMAC_BRANCH_CONF}" || true
  if [[ "${_branch:-}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    STEAMAC_BRANCH="${_branch}"
    STEAMAC_BRANCH_SOURCE="${STEAMAC_BRANCH_CONF}"
  else
    echo "steamac: ignoring invalid branch '${_branch:-}' in ${STEAMAC_BRANCH_CONF}" >&2
  fi
fi
STEAMAC_DECKARD_ARG=(-deckard)
STEAMAC_VRUI_ARG=(-vrgamepadui)
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

# steamac: sign-in mode (see header).
STEAMAC_SIGNIN=0
steamac_account_remembered() {
  grep -Eqs '"(Allow)?AutoLogin"[[:space:]]+"1"' "${STEAMROOT}/config/loginusers.vdf"
}
if [[ "${IS_SIDELOAD}" == "0" && -z "${STEAMAC_BRANCH}" ]] && ! steamac_account_remembered; then
  if curl -fsS -m 5 -o /dev/null --head https://client-update.steamstatic.com/steam_client_steamdeck_stable_linuxarm64; then
    echo "steamac: no remembered Steam account: sign-in mode (Steam Deck client, on-screen QR code)"
    STEAMAC_SIGNIN=1
    STEAMAC_DECKARD_ARG=()
    STEAMAC_VRUI_ARG=()
  else
    echo "steamac: no remembered Steam account, but client-update.steamstatic.com is unreachable: Frame client" >&2
  fi
fi

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

# steamac: Steam Deck client branch (see header).
if [[ "${IS_SIDELOAD}" == "0" && -n "${STEAMAC_BRANCH}" ]]; then
  _beta_file="${STEAMROOT}/package/beta"
  _current="$(head -n1 "${_beta_file}" 2>/dev/null || true)"
  if [[ "${_current}" != "${STEAMAC_BRANCH}" ]]; then
    echo "steamac: Steam client branch '${_current:-<none>}' -> '${STEAMAC_BRANCH}' (${STEAMAC_BRANCH_SOURCE})"
    mkdir -p "${STEAMROOT}/package"
    printf '%s\n' "${STEAMAC_BRANCH}" > "${_beta_file}"
  fi
fi

# steamac: sign-in mode (see header). Only under steam.service (INVOCATION_ID),
# which restarts Steam with the stock flags; the watcher ends with Steam ($$ is
# Steam's PID after the exec below).
if [[ "${STEAMAC_SIGNIN}" == "1" && -n "${INVOCATION_ID:-}" ]]; then
  (
    while kill -0 $$ 2>/dev/null; do
      if steamac_account_remembered; then
        sleep 5 # let Steam finish writing its config
        kill -0 $$ 2>/dev/null || exit 0
        echo "steamac: Steam account remembered: restarting Steam with the Steam Frame client" >&2
        exec systemctl --user --no-block restart steam.service
      fi
      sleep 3
    done
  ) </dev/null >/dev/null &
fi

exec "${STEAM_COMMAND[@]}" >"${HOME}/.local/share/Steam/logs/steam_output.log" 2>&1
