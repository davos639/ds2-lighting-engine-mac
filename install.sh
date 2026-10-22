#!/bin/bash
# DS2 Lighting Engine on Mac: installer.
# https://github.com/davos639/ds2-lighting-engine-mac
#
# Sets up a CrossOver bottle that already contains Dark Souls II: Scholar of the First Sin so the
# DS2 Lighting Engine mod renders correctly, and adds a "DS2 Lighting Engine" app that starts the
# game full screen. Every change is backed up; uninstall.sh restores them.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/davos639/ds2-lighting-engine-mac/main/install.sh)"
#   (to pass options, add them after a "_":  /bin/bash -c "$(curl ...)" _ --upscaling off)
#
# Options:
#   --bottle NAME        use this CrossOver bottle
#   --game DIR           the game's Game folder (the one with DarkSoulsII.exe)
#   --mod PATH           install the Lighting Engine from this download (.zip, .7z, .rar or folder)
#   --resolution WxH     render resolution: 2560x1440 or 1920x1080 (default depends on the GPU)
#   --upscaling dlss|off dlss (the default): the Lighting Engine renders smaller and Apple's MetalFX
#                        scales it up, through DXMT's DLSS support; off: leave the mod's settings alone
#   --yes                don't ask, use the defaults
#   --build-from-source  compile the helper with swiftc instead of using bin/ds2mac
set -u
# Arrays and process substitution need bash, not sh (which is bash in POSIX mode on macOS).
if [ -z "${BASH_VERSION:-}" ] || (shopt -qo posix) 2>/dev/null; then exec /bin/bash "$0" "$@"; fi

REPO="davos639/ds2-lighting-engine-mac"
REF="main"
VERSION="1.0.0"
HOME_DIR="$HOME/Library/Application Support/ds2le-mac"
BOTTLES="$HOME/Library/Application Support/CrossOver/Bottles"
BUNDLE_ID="io.github.davos639.ds2-lighting-engine-mac"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
export LC_ALL=en_US.UTF-8

UNDO_HINT=""
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;34m==>\033[0;1m %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33mWarning:\033[0m %s\n' "$*"; }
die() {
  printf '\n\033[31mError:\033[0m %s\n' "$*" >&2
  [ -n "$UNDO_HINT" ] && printf '\nTo undo the changes made so far:  %s\n' "$UNDO_HINT" >&2
  exit 1
}

# --- bootstrap: when run through curl, fetch the whole repository first ---------------------------
SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi
if [ -z "$SELF_DIR" ] || [ ! -f "$SELF_DIR/launcher/ds2le-launch.sh" ]; then
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ds2le-mac.XXXXXX") || die "cannot create a temporary folder"
  echo "Downloading $REPO..."
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$REF" | tar -xz -C "$tmp" ||
    die "download failed. Check your internet connection."
  exec /bin/bash "$tmp"/*/install.sh "$@"
fi

# --- options ---------------------------------------------------------------------------------------
OPT_BOTTLE="" OPT_GAME="" OPT_MOD="" OPT_RES="" OPT_UPSCALING="" YES=0 BUILD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bottle) OPT_BOTTLE=${2:-}; shift ;;
    --game) OPT_GAME=${2:-}; shift ;;
    --mod) OPT_MOD=${2:-}; shift ;;
    --resolution) OPT_RES=${2:-}; shift ;;
    --upscaling) OPT_UPSCALING=${2:-}; shift ;;
    --yes | -y) YES=1 ;;
    --build-from-source) BUILD=1 ;;
    -h | --help) sed -n '2,20p' "$SELF_DIR/install.sh" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

# ask "question" default -> answer (the default with --yes or without a terminal)
ask() {
  local reply=""
  if [ "$YES" = 0 ] && [ -r /dev/tty ]; then
    printf '%s ' "$1" >/dev/tty
    IFS= read -r reply </dev/tty || reply=""
  fi
  printf '%s' "${reply:-$2}"
}
confirm() {
  case "$(ask "$1 [Y/n]" y)" in [Nn]*) return 1 ;; *) return 0 ;; esac
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# A path dragged into Terminal arrives quoted or with backslash escapes.
clean_path() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    -e "s/^'\(.*\)'\$/\1/" -e 's/^"\(.*\)"$/\1/' -e 's/\\\(.\)/\1/g'
}
win_path() { printf 'C:\\%s' "$(printf '%s' "$1" | tr '/' '\\')"; }
# Is a wineserver running for $BOTTLE? Its environment (ps -E) holds CX_BOTTLE=<name>, followed by
# the next variable or the end of the line, so "Steam" doesn't match a bottle called "Steam 2".
bottle_running() {
  ps -E -x -o command= | B="$BOTTLE" awk '
    index($0, "/bin/wineserver") {
      k = " CX_BOTTLE=" ENVIRON["B"]; i = index($0, k)
      if (i) { r = substr($0, i + length(k)); if (r == "" || r ~ /^ [A-Za-z_][A-Za-z0-9_]*=/) { f = 1; exit } }
    }
    END { exit !f }'
}
has_ds2le_files() { find "$1" -maxdepth 1 -iname 'ds2le_*' 2>/dev/null | grep -q .; }

bold "DS2 Lighting Engine on Mac $VERSION"
echo "This sets up Dark Souls II: Scholar of the First Sin with the DS2 Lighting Engine in CrossOver."
echo "Nothing is downloaded except this project; every change is backed up and can be undone with uninstall.sh."

# --- 1. this Mac ------------------------------------------------------------------------------------
step "Checking this Mac"
[ "$(uname -s)" = Darwin ] || die "this only works on macOS."
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] ||
  die "this needs a Mac with Apple Silicon (M1 or newer). DXMT, the graphics layer this relies on, doesn't support Intel Macs well."
os=$(sw_vers -productVersion)
[ "${os%%.*}" -ge 14 ] || die "this needs macOS 14 Sonoma or newer (you have $os)."
info "macOS $os on $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"

DS2MAC="$SELF_DIR/bin/ds2mac"
if [ "$BUILD" = 1 ] || [ ! -x "$DS2MAC" ]; then
  xcode-select -p >/dev/null 2>&1 && xcrun --find swiftc >/dev/null 2>&1 ||
    die "building the helper needs the Xcode Command Line Tools. Run  xcode-select --install  and try again."
  info "building the helper from source..."
  /bin/bash "$SELF_DIR/src/build.sh" >/dev/null || die "could not build src/ds2mac.swift"
fi
# Downloaded through a browser, the files carry a quarantine flag that would block the helper.
xattr -dr com.apple.quarantine "$SELF_DIR" 2>/dev/null
"$DS2MAC" --version >/dev/null 2>&1 ||
  die "the helper bin/ds2mac does not run on this Mac. Try the option --build-from-source (with the curl command, after a \"_\")."

# --- 2. CrossOver -----------------------------------------------------------------------------------
step "Looking for CrossOver"
CX_APP=""
for app in /Applications/CrossOver.app "$HOME/Applications/CrossOver.app"; do
  [ -d "$app" ] && { CX_APP=$app; break; }
done
[ -n "$CX_APP" ] || CX_APP=$(mdfind "kMDItemCFBundleIdentifier == 'com.codeweavers.CrossOver'" 2>/dev/null | head -1)
[ -n "$CX_APP" ] && [ -d "$CX_APP" ] ||
  die "CrossOver is not installed. Get it (14-day free trial) from https://www.codeweavers.com/crossover"
CX="$CX_APP/Contents/SharedSupport/CrossOver"
cx_version=$(defaults read "$CX_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
info "CrossOver $cx_version at $CX_APP"
DXMT_DLL="$CX/lib/dxmt/x86_64-windows/d3d11.dll"
[ -f "$DXMT_DLL" ] || die "this CrossOver has no DXMT. Update CrossOver to version 26 or newer."
[ "${cx_version%%.*}" -ge 26 ] 2>/dev/null || warn "tested with CrossOver 26.0. Older versions may not work."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ds2le-work.XXXXXX") || die "cannot create a temporary folder"
"$DS2MAC" patch-d3d11 "$DXMT_DLL" "$WORK/d3d11.dll" >/dev/null ||
  die "this CrossOver's DXMT is different from the one this was made for, so it can't be patched.
       See https://github.com/$REPO/blob/main/docs/HOW-IT-WORKS.md#2-the-patched-d3d11dll"
info "patched a copy of CrossOver's DXMT d3d11.dll"

# --- 3. the game ------------------------------------------------------------------------------------
step "Looking for Dark Souls II: Scholar of the First Sin"
candidates=()
if [ -n "$OPT_GAME" ]; then
  OPT_GAME=$(clean_path "$OPT_GAME")
  [ -f "$OPT_GAME/DarkSoulsII.exe" ] || die "no DarkSoulsII.exe in $OPT_GAME"
  candidates=("$(cd "$OPT_GAME" && pwd)/DarkSoulsII.exe")
else
  search="$BOTTLES"
  [ -n "$OPT_BOTTLE" ] && search="$BOTTLES/$OPT_BOTTLE"
  [ -d "$search" ] || die "no CrossOver bottles found in $search"
  while IFS= read -r exe; do
    [ "$("$DS2MAC" exe-arch "$exe" 2>/dev/null)" = x64 ] && candidates+=("$exe")
  done < <(find "$search" -mindepth 2 -maxdepth 12 \
    \( -path '*/drive_c/windows' -o -path '*/drive_c/users' -o -path '*/dosdevices' \) -prune \
    -o -name DarkSoulsII.exe -type f -print 2>/dev/null)
fi
if [ ${#candidates[@]} -eq 0 ]; then
  die "Dark Souls II: Scholar of the First Sin was not found in any CrossOver bottle.
       Install Steam in a CrossOver bottle, install the game there, start it once, then run this again.
       (The original 32-bit Dark Souls II is not supported by the Lighting Engine.)"
fi
EXE=${candidates[0]}
if [ ${#candidates[@]} -gt 1 ]; then
  echo "    Found more than one copy:"
  i=1
  for c in "${candidates[@]}"; do echo "      $i) $c"; i=$((i + 1)); done
  n=$(ask "    Which one? [1]" 1)
  case "$n" in *[!0-9]* | "") n=1 ;; esac
  [ "$n" -ge 1 ] && [ "$n" -le ${#candidates[@]} ] || die "no such choice: $n"
  EXE=${candidates[$((n - 1))]}
fi
case "$EXE" in
  "$BOTTLES"/*/drive_c/*) ;;
  *) die "the game must be inside a CrossOver bottle ($BOTTLES), not at $EXE" ;;
esac
GAME_DIR=$(dirname "$EXE")
rest=${EXE#"$BOTTLES/"}
BOTTLE=${rest%%/*}
BOTTLE_DIR="$BOTTLES/$BOTTLE"
GAME_EXE_WIN=$(win_path "${EXE#"$BOTTLE_DIR/drive_c/"}")
STEAM=0 STEAM_EXE_WIN=""
case "$EXE" in
  */steamapps/common/*)
    steam_exe="${EXE%%/steamapps/common/*}/steam.exe"
    [ -f "$steam_exe" ] || steam_exe="$BOTTLE_DIR/drive_c/Program Files (x86)/Steam/steam.exe"
    if [ -f "$steam_exe" ]; then
      STEAM=1
      STEAM_EXE_WIN=$(win_path "${steam_exe#"$BOTTLE_DIR/drive_c/"}")
    fi
    ;;
esac
info "bottle:  $BOTTLE"
info "game:    $GAME_EXE_WIN"
# On screens without 16:9 modes (MacBooks) the launcher adds a window size to the game's list.
"$DS2MAC" res-table "$EXE" --show >/dev/null 2>&1 ||
  warn "this DarkSoulsII.exe has an unfamiliar list of window sizes. On a MacBook the launcher then uses a larger display mode (a little slower), and with the mod's flip model off the game covers about 94% of the width."
[ "$STEAM" = 1 ] && info "the launcher will start it through Steam ($STEAM_EXE_WIN)"

# One bottle at a time: config.sh and uninstall.sh know about a single bottle.
STRETCH=1 FRAME_LIMITER=1
if [ -f "$HOME_DIR/config.sh" ]; then
  prev_bottle=$(. "$HOME_DIR/config.sh" >/dev/null 2>&1; printf '%s' "${BOTTLE:-}")
  [ -z "$prev_bottle" ] || [ "$prev_bottle" = "$BOTTLE" ] ||
    die "this is already set up for the \"$prev_bottle\" bottle. Undo that first:
       \"$HOME_DIR/uninstall.sh\""
  # Keep a STRETCH and FRAME_LIMITER the user chose.
  STRETCH=$(. "$HOME_DIR/config.sh" >/dev/null 2>&1; printf '%s' "${STRETCH:-1}")
  case "$STRETCH" in 1 | auto | mirror | 0) ;; *) STRETCH=1 ;; esac
  FRAME_LIMITER=$(. "$HOME_DIR/config.sh" >/dev/null 2>&1; printf '%s' "${FRAME_LIMITER:-1}")
  [ "$FRAME_LIMITER" = 0 ] || FRAME_LIMITER=1
fi

if bottle_running; then
  echo "    Something is running in the \"$BOTTLE\" bottle (the game, Steam or another program)."
  if [ "$STEAM" = 1 ] && confirm "    Close Steam in this bottle now?"; then
    "$CX/bin/wine" --bottle "$BOTTLE" --cx-app "$STEAM_EXE_WIN" -shutdown >/dev/null 2>&1 &
  else
    echo "    Quit it (for Steam: Steam menu > Exit)."
  fi
  echo "    Waiting up to 2 minutes..."
  for _ in $(seq 120); do bottle_running || break; sleep 1; done
  bottle_running && die "the \"$BOTTLE\" bottle is still running. Quit everything in it and run this again."
fi
pgrep -xq CrossOver && warn "the CrossOver app is open. Don't change this bottle's settings in it while this runs."

# --- 4. the Lighting Engine -------------------------------------------------------------------------
step "Checking the DS2 Lighting Engine"
BK="$HOME_DIR/backup/$BOTTLE"
mkdir -p "$BK" || die "cannot create $BK"
mod_installed() { [ -f "$GAME_DIR/dxgi.dll" ] && has_ds2le_files "$GAME_DIR"; }
install_mod() { # archive or folder
  local archive=$1 x src d f
  if [ -d "$archive" ]; then
    x=$archive # a browser may have unpacked it already
  else
    [ -f "$archive" ] || die "no such file: $archive"
    x="$WORK/mod"
    mkdir -p "$x"
    info "unpacking $(basename "$archive")..."
    case "$(lower "$archive")" in
      *.zip) ditto -x -k "$archive" "$x" ;;
      *.rar) "$CX/bin/unrar" x -idq -o+ "$archive" "$x/" ;;
      *) tar -xf "$archive" -C "$x" ;;
    esac || die "could not unpack $archive. Unpack it yourself and drag the unpacked folder in instead."
  fi
  # The folder with dxgi.dll and the ds2le_* files, the shallowest one if there are several.
  src=""
  while IFS= read -r d; do
    d=$(dirname "$d")
    if has_ds2le_files "$d"; then src=$d; break; fi
  done < <(find "$x" -maxdepth 5 -iname dxgi.dll -type f 2>/dev/null |
    awk '{ print gsub("/", "/") "\t" $0 }' | sort -n | cut -f2-)
  [ -n "$src" ] || die "no dxgi.dll with ds2le_* files next to it in $archive, so it doesn't look like the DS2 Lighting Engine."
  # The player's own Lighting Engine settings win over the ones in the download.
  local keep_ini=""
  if [ -f "$GAME_DIR/ds2le_user_settings.ini" ]; then
    keep_ini="$WORK/ds2le_user_settings.ini"
    cp -p "$GAME_DIR/ds2le_user_settings.ini" "$keep_ini" || die "could not save $GAME_DIR/ds2le_user_settings.ini"
  fi
  # Keep the game's own files that the mod replaces, and remember what the mod added.
  (cd "$src" && find . -type f) | while IFS= read -r f; do
    f=${f#./}
    [ -n "$keep_ini" ] && [ "$f" = ds2le_user_settings.ini ] && continue
    if [ -e "$GAME_DIR/$f" ] && [ ! -e "$BK/game/$f" ] && ! grep -qxF "$f" "$BK/mod-files.txt" 2>/dev/null; then
      mkdir -p "$(dirname "$BK/game/$f")" && cp -p "$GAME_DIR/$f" "$BK/game/$f"
    fi
    grep -qxF "$f" "$BK/mod-files.txt" 2>/dev/null || echo "$f" >>"$BK/mod-files.txt"
  done
  ditto "$src" "$GAME_DIR" || die "could not copy the mod into $GAME_DIR"
  [ -z "$keep_ini" ] || cp -p "$keep_ini" "$GAME_DIR/ds2le_user_settings.ini" || die "could not put back $GAME_DIR/ds2le_user_settings.ini"
  info "installed the Lighting Engine into the Game folder"
}
if [ -n "$OPT_MOD" ]; then
  install_mod "$(clean_path "$OPT_MOD")"
elif mod_installed; then
  info "already installed in the Game folder"
else
  echo "    The DS2 Lighting Engine is not in the game folder yet."
  echo "    Download it from https://www.nexusmods.com/darksouls2/mods/1146 (Files tab, the main file),"
  echo "    then drag the downloaded archive (or the folder your browser unpacked it to) into this window"
  echo "    and press Enter."
  [ "$YES" = 1 ] && die "the mod is not installed (use --mod PATH)."
  archive=$(clean_path "$(ask "    Archive or folder:" "")")
  [ -n "$archive" ] || die "nothing given. You can also unpack the mod yourself into $GAME_DIR and run this again."
  install_mod "$archive"
fi
mod_installed || die "the Lighting Engine files (dxgi.dll, ds2le_*) are not in $GAME_DIR"

# --- 5. resolution ----------------------------------------------------------------------------------
step "Choosing the render resolution"
cores=$(system_profiler -json SPDisplaysDataType 2>/dev/null | awk -F'"' '/"sppci_cores"/ { print $4; exit }')
default_res=1920x1080
[ "${cores:-0}" -ge 14 ] 2>/dev/null && default_res=2560x1440
RES=$OPT_RES
if [ -z "$RES" ]; then
  info "GPU cores: ${cores:-unknown}. The Lighting Engine is heavy, so smaller Macs should use 1920x1080."
  echo "      1) 2560x1440  sharpest (Pro and Max chips)"
  echo "      2) 1920x1080  faster (base M1-M5, MacBook Air)"
  d=1
  [ "$default_res" = 1920x1080 ] && d=2
  case "$(ask "    Choose [$d]" "$d")" in 2) RES=1920x1080 ;; 1) RES=2560x1440 ;; *) RES=$default_res ;; esac
fi
case "$RES" in
  2560x1440) WINDOW=1280x720 ;;
  1920x1080) WINDOW=960x540 ;;
  *) die "unsupported resolution $RES (use 2560x1440 or 1920x1080)" ;;
esac
info "rendering at $RES (a ${WINDOW}pt window with Retina)"

# The Lighting Engine's DLSS option goes through DXMT to Apple's MetalFX temporal upscaler on any
# Apple Silicon Mac. It needs the mod's flip model, which the launcher handles. Lower settings for
# fewer GPU cores; the player can change it in the game (F1 > User settings, then Save).
UPSCALING=${OPT_UPSCALING:-dlss}
case "$UPSCALING" in dlss | off) ;; *) die "unknown --upscaling $UPSCALING (use dlss or off)" ;; esac
DLSS_QUALITY=1 DLSS_NAME="Balanced (58%)"
[ "${cores:-0}" -ge 14 ] 2>/dev/null && DLSS_QUALITY=2 DLSS_NAME="Quality (67%)"
[ "${cores:-0}" -ge 30 ] 2>/dev/null && DLSS_QUALITY=4 DLSS_NAME="Ultra Quality (77%)"

# --- 6. back up the originals (only once, so re-running keeps the very first state) ---------------
step "Backing up"
CONF="$BOTTLE_DIR/cxbottle.conf"
USERREG="$BOTTLE_DIR/user.reg"
D3D11="$BOTTLE_DIR/drive_c/windows/system32/d3d11.dll"
APPDATA_USER="$BOTTLE_DIR/drive_c/users/crossover"
[ -d "$APPDATA_USER" ] || APPDATA_USER=$(find "$BOTTLE_DIR/drive_c/users" -mindepth 1 -maxdepth 1 -type d ! -name Public 2>/dev/null | head -1)
GFX="$APPDATA_USER/AppData/Roaming/DarkSoulsII/GraphicsConfig_SOFS.xml"
[ -f "$CONF" ] && [ -f "$USERREG" ] || die "$BOTTLE_DIR doesn't look like a CrossOver bottle"

# The registry values this changes. DllOverrides load the mod's dxgi.dll and the patched d3d11.dll;
# RetinaMode gives a sharp image (1 game pixel = half a point); the four button colors are what Wine
# paints the window's 3D client edge with, a white frame around the picture otherwise.
REG_VALUES='Software\Wine\AppDefaults\DarkSoulsII.exe\DllOverrides|d3d11|"native,builtin"
Software\Wine\AppDefaults\DarkSoulsII.exe\DllOverrides|dxgi|"native,builtin"
Software\Wine\Mac Driver|RetinaMode|"y"
Control Panel\Colors|ButtonShadow|"0 0 0"
Control Panel\Colors|ButtonDkShadow|"0 0 0"
Control Panel\Colors|ButtonLight|"0 0 0"
Control Panel\Colors|ButtonHilight|"0 0 0"'

# reg_get KEY NAME: the raw value from user.reg ("text" or dword:...), fails if absent.
reg_get() {
  KEY="[$(lower "$1" | sed 's/\\/\\\\/g')]" NAME="\"$(lower "$2")\"=" awk '
    /^\[/ { insec = (index(tolower($0), ENVIRON["KEY"]) == 1); next }
    insec && index(tolower($0), ENVIRON["NAME"]) == 1 { print substr($0, length(ENVIRON["NAME"]) + 1); found = 1; exit }
    END { exit !found }' "$USERREG"
}
# reg_file VALUE-LINES: a REGEDIT4 file setting KEY|NAME|DATA lines ("-" deletes the value)
reg_file() {
  local last="" key name data
  printf 'REGEDIT4\r\n'
  while IFS='|' read -r key name data; do
    [ -n "$key" ] || continue
    [ "$key" != "$last" ] && printf '\r\n[HKEY_CURRENT_USER\\%s]\r\n' "$key" && last=$key
    printf '"%s"=%s\r\n' "$name" "$data"
  done <<<"$1"
}
reg_import() { # file
  cp "$1" "$BOTTLE_DIR/drive_c/ds2le-mac.reg" &&
    "$CX/bin/wine" --bottle "$BOTTLE" reg import 'C:\ds2le-mac.reg' >/dev/null 2>&1
  local rc=$?
  rm -f "$BOTTLE_DIR/drive_c/ds2le-mac.reg"
  # The registry is written to user.reg when the bottle's wineserver exits.
  for _ in $(seq 60); do bottle_running || break; sleep 1; done
  return $rc
}

# env_get NAME: a variable from the bottle's [EnvironmentVariables], or "-" if it isn't set.
env_get() {
  NAME=$1 awk '/^\[EnvironmentVariables\]/ { s = 1; next } /^\[/ { s = 0 }
       s && index($0, "\"" ENVIRON["NAME"] "\"") == 1 { sub(/^[^=]*=[[:space:]]*/, ""); gsub(/"/, ""); print; f = 1; exit }
       END { if (!f) print "-" }' "$CONF"
}
if [ ! -f "$BK/backend.orig" ]; then
  env_get CX_GRAPHICS_BACKEND >"$BK/backend.orig"
  cp -p "$CONF" "$BK/cxbottle.conf.orig"
fi
[ -f "$BK/nvext.orig" ] || env_get DXMT_ENABLE_NVEXT >"$BK/nvext.orig"
if [ ! -e "$BK/d3d11.dll.orig" ] && [ ! -e "$BK/d3d11.dll.absent" ]; then
  if [ -f "$D3D11" ] && [ "$("$DS2MAC" patch-d3d11 "$D3D11" "$WORK/check.dll" >/dev/null 2>&1; echo $?)" = 3 ]; then
    # Patched by hand earlier: the original is Wine's own placeholder, which CrossOver ships.
    cp -p "$CX/lib/wine/x86_64-windows/d3d11.dll" "$BK/d3d11.dll.orig"
  elif [ -f "$D3D11" ]; then
    cp -p "$D3D11" "$BK/d3d11.dll.orig"
  else
    touch "$BK/d3d11.dll.absent"
  fi
fi
if [ ! -e "$BK/GraphicsConfig_SOFS.xml.orig" ] && [ ! -e "$BK/GraphicsConfig_SOFS.xml.absent" ]; then
  if [ -f "$GFX" ]; then cp -p "$GFX" "$BK/GraphicsConfig_SOFS.xml.orig"; else touch "$BK/GraphicsConfig_SOFS.xml.absent"; fi
fi
# The game's list of window sizes, which the launcher changes on screens without 16:9 modes, and its
# frame limiter, which it sets to sleep half the wait.
if [ ! -f "$BK/res-table.orig" ]; then
  "$DS2MAC" res-table "$EXE" --show >"$BK/res-table.orig" 2>/dev/null || rm -f "$BK/res-table.orig"
fi
if [ ! -f "$BK/frame-limiter.orig" ]; then
  "$DS2MAC" frame-limiter "$EXE" --show >"$BK/frame-limiter.orig" 2>/dev/null || rm -f "$BK/frame-limiter.orig"
fi
# The Lighting Engine settings the upscaling preset changes (section|key|value, "-" = not set).
MOD_INI="$GAME_DIR/ds2le_user_settings.ini"
MOD_KEYS='UserSwapChainSettingsV2|enable_flip_model_swapchain
UserAntiAliasingSettings|antialiasing_method
UserAntiAliasingSettings|nvidia_dlss_quality'
if [ ! -f "$BK/mod-settings.orig" ]; then
  [ -f "$MOD_INI" ] || touch "$BK/mod-settings.absent"
  while IFS='|' read -r section key; do
    value=$("$DS2MAC" ini "$MOD_INI" "$section" "$key") || die "could not read $MOD_INI"
    echo "$section|$key|$value"
  done <<<"$MOD_KEYS" >"$BK/mod-settings.tmp" && mv "$BK/mod-settings.tmp" "$BK/mod-settings.orig" ||
    die "could not back up $MOD_INI"
fi
if [ ! -f "$BK/registry-restore.reg" ]; then
  restore=""
  while IFS='|' read -r key name _; do
    old=$(reg_get "$key" "$name") || old="-"
    restore="$restore$key|$name|$old"$'\n'
  done <<<"$REG_VALUES"
  reg_file "$restore" >"$BK/registry-restore.reg"
fi
info "backups in $BK"

# The uninstaller and launcher go in first, so whatever happens next can be undone.
# Copy, then rename, so a helper that is still running is never overwritten in place.
for f in "$DS2MAC" "$SELF_DIR/launcher/ds2le-launch.sh" "$SELF_DIR/uninstall.sh"; do
  cp "$f" "$HOME_DIR/.new" && chmod +x "$HOME_DIR/.new" && mv -f "$HOME_DIR/.new" "$HOME_DIR/$(basename "$f")" ||
    die "could not copy into $HOME_DIR"
done
xattr -dr com.apple.quarantine "$HOME_DIR" 2>/dev/null
{
  echo "# Written by install.sh. STRETCH: 1 = automatic, mirror, or 0 = no display change"
  echo "# (see ds2le-launch.sh). FRAME_LIMITER: 1 = steady 60 FPS, 0 = the game's own limiter."
  printf 'CX_APP=%q\nBOTTLE=%q\nGAME_DIR=%q\nGAME_EXE_WIN=%q\nGFX=%q\n' "$CX_APP" "$BOTTLE" "$GAME_DIR" "$GAME_EXE_WIN" "$GFX"
  printf 'STEAM=%s\nSTEAM_EXE_WIN=%q\nRESOLUTION=%s\nWINDOW=%s\nSTRETCH=%s\nFRAME_LIMITER=%s\n' \
    "$STEAM" "$STEAM_EXE_WIN" "$RES" "$WINDOW" "$STRETCH" "$FRAME_LIMITER"
} >"$HOME_DIR/config.sh"
UNDO_HINT="\"$HOME_DIR/uninstall.sh\""

# --- 7. apply ---------------------------------------------------------------------------------------
step "Setting up the \"$BOTTLE\" bottle"
# set_env NAME VALUE: a variable in the bottle's [EnvironmentVariables]; "-" removes it.
set_env() {
  NAME=$1 VALUE=$2 awk '
    function add() { if (ENVIRON["VALUE"] != "-") print "\"" ENVIRON["NAME"] "\" = \"" ENVIRON["VALUE"] "\""; done = 1 }
    /^\[EnvironmentVariables\]/ { print; add(); next }
    index($0, "\"" ENVIRON["NAME"] "\"") == 1 && /^"[^"]*"[[:space:]]*=/ { next }
    { print }
    END { if (!done && ENVIRON["VALUE"] != "-") { print ""; print "[EnvironmentVariables]"; add() } }' "$CONF" >"$CONF.ds2le-tmp" &&
    mv "$CONF.ds2le-tmp" "$CONF"
}
set_env CX_GRAPHICS_BACKEND dxmt || die "could not edit $CONF"
info "graphics backend: DXMT"
# DXMT's DLSS support (NVEXT), which hands the Lighting Engine's DLSS to MetalFX.
set_env DXMT_ENABLE_NVEXT 1 || die "could not edit $CONF"
mkdir -p "$(dirname "$D3D11")" && cp "$WORK/d3d11.dll" "$D3D11" || die "could not write $D3D11"
info "installed the patched d3d11.dll into the bottle's system32"
reg_file "$REG_VALUES" >"$WORK/apply.reg"
reg_import "$WORK/apply.reg" || die "could not change the bottle's registry"
while IFS='|' read -r key name data; do
  [ "$(reg_get "$key" "$name")" = "$data" ] || die "the registry value $key\\$name was not set"
done <<<"$REG_VALUES"
info "registry: DLL overrides, Retina mode, black window edge"
"$DS2MAC" graphics-config "$GFX" "$RES" >/dev/null || die "could not write $GFX"
info "game settings: windowed $RES, game's own fullscreen and antialiasing off"
if [ "$FRAME_LIMITER" = 1 ]; then
  "$DS2MAC" frame-limiter "$EXE" on >/dev/null 2>&1 && info "the game's frame limiter now holds a steady 60 FPS" ||
    warn "this DarkSoulsII.exe has an unfamiliar frame limiter, so it may run at 54-55 FPS instead of 60."
fi
# The upscaling preset goes in once, so later changes in the game's menu stay, and again whenever
# --upscaling is given. mod-preset.done remembers it (and a first --upscaling off).
if [ "$UPSCALING" = dlss ] && { [ ! -e "$BK/mod-preset.done" ] || [ -n "$OPT_UPSCALING" ]; }; then
  "$DS2MAC" ini "$MOD_INI" UserSwapChainSettingsV2 enable_flip_model_swapchain 1 &&
    "$DS2MAC" ini "$MOD_INI" UserAntiAliasingSettings antialiasing_method 2 &&
    "$DS2MAC" ini "$MOD_INI" UserAntiAliasingSettings nvidia_dlss_quality "$DLSS_QUALITY" ||
    die "could not write $MOD_INI"
  info "Lighting Engine: DLSS $DLSS_NAME, upscaled by Apple MetalFX"
fi
touch "$BK/mod-preset.done"

# --- 8. launcher app --------------------------------------------------------------------------------
step "Installing the launcher"
APPS=${DS2LE_APP_DIR:-/Applications}
[ -w "$APPS" ] || APPS="$HOME/Applications"
mkdir -p "$APPS"
APP="$APPS/DS2 Lighting Engine.app"
# Never replace someone else's app of the same name.
if [ -d "$APP" ] && [ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist" 2>/dev/null)" != "$BUNDLE_ID" ]; then
  APP="$APPS/DS2 Lighting Engine (Mac).app"
  warn "another \"DS2 Lighting Engine\" app is already in $APPS, so this one is called \"$(basename "$APP" .app)\"."
fi
rm -rf "$APP"
osacompile -o "$APP" -e "do shell script \"nohup \" & quoted form of \"$HOME_DIR/ds2le-launch.sh\" & \" >/dev/null 2>&1 &\"" 2>/dev/null ||
  die "could not create $APP"
plist="$APP/Contents/Info.plist"
# Without a bundle identifier Raycast and some launchers don't list the app.
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
# When the game starts, Wine opens the sound devices, inputs too, and macOS asks for the microphone
# on behalf of this app. The applet's stock text ("This script needs access...") explains nothing.
plutil -replace NSMicrophoneUsageDescription -string \
  "Wine opens the sound devices when Dark Souls II starts. The game doesn't use the microphone, so you can choose Don't Allow." "$plist"
# Reuse the game icon from the launcher CrossOver made for the game, if there is one.
icon=$(find "$HOME/Applications/CrossOver" -maxdepth 5 -ipath '*dark souls ii*.app/contents/resources/*.icns' \
  ! -ipath '*uninstall*' 2>/dev/null | head -1)
if [ -n "$icon" ]; then
  cp "$icon" "$APP/Contents/Resources/applet.icns"
  rm -f "$APP/Contents/Resources/Assets.car"
  plutil -remove CFBundleIconName "$plist" 2>/dev/null
fi
codesign --force --sign - "$APP" >/dev/null 2>&1
"$LSREGISTER" -f "$APP" >/dev/null 2>&1
echo "$APP" >"$HOME_DIR/app-path"
info "$APP"
rm -rf "$WORK"

# --- done -------------------------------------------------------------------------------------------
step "Done"
cat <<EOF
    1. Open "$(basename "$APP" .app)" (in $APPS, or search for it in Spotlight).
       Always start the game this way, not from Steam or CrossOver.
    2. Click the game when it appears; it doesn't load until it's the active window.
       It then fills the screen by itself. (With the Lighting Engine's flip model turned off, a
       MacBook gets a window as wide as the screen: its green button puts black around it.)

    Upscaling and the Lighting Engine's look: press F1 in the game (fn+F1 on a Mac keyboard),
    User settings, then Save.

    Play offline: set the game to start offline in its network settings.
    The mod and the changes to DarkSoulsII.exe can get you soft-banned online, also from Steam.

    While the game runs, the screen uses a lower resolution, so other windows look larger.
    It goes back to normal within a minute after you quit the game.

    The DXMT backend, Retina mode and DXMT's DLSS support (other games in the bottle see an
    NVIDIA GPU) apply to everything in the "$BOTTLE" bottle, including Steam. uninstall.sh
    switches them back.

    To undo everything:  $UNDO_HINT
EOF
