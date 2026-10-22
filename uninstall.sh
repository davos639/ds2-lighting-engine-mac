#!/bin/bash
# DS2 Lighting Engine on Mac: undoes everything install.sh changed, from its backups.
# https://github.com/davos639/ds2-lighting-engine-mac
#
#   "$HOME/Library/Application Support/ds2le-mac/uninstall.sh"
#
# Options:
#   --remove-mod   also delete the Lighting Engine files that install.sh copied into the game
#                  and put back the game files they replaced
#   --bottle NAME  the bottle's new name, if you renamed it in CrossOver after installing
#   --forget       the bottle is gone for good: just remove the launcher and the backups
#   --yes          don't ask
set -u
export LC_ALL=en_US.UTF-8

HOME_DIR="$HOME/Library/Application Support/ds2le-mac"
BOTTLES="$HOME/Library/Application Support/CrossOver/Bottles"
BUNDLE_ID="io.github.davos639.ds2-lighting-engine-mac"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

step() { printf '\n\033[1;34m==>\033[0;1m %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33mWarning:\033[0m %s\n' "$*"; }
die() {
  printf '\n\033[31mError:\033[0m %s\n' "$*" >&2
  exit 1
}

REMOVE_MOD=0 YES=0 NEW_BOTTLE="" FORGET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --remove-mod) REMOVE_MOD=1 ;;
    --bottle) NEW_BOTTLE=${2:-}; shift ;;
    --forget) FORGET=1 ;;
    --yes | -y) YES=1 ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[ -f "$HOME_DIR/config.sh" ] || die "DS2 Lighting Engine on Mac is not installed (no $HOME_DIR/config.sh)."
. "$HOME_DIR/config.sh"
# CrossOver may have moved since the install.
if [ ! -x "$CX_APP/Contents/SharedSupport/CrossOver/bin/wine" ]; then
  for a in /Applications/CrossOver.app "$HOME/Applications/CrossOver.app" \
    "$(mdfind "kMDItemCFBundleIdentifier == 'com.codeweavers.CrossOver'" 2>/dev/null | head -1)"; do
    [ -n "$a" ] && [ -x "$a/Contents/SharedSupport/CrossOver/bin/wine" ] && { CX_APP=$a; break; }
  done
fi
CX="$CX_APP/Contents/SharedSupport/CrossOver"
BK="$HOME_DIR/backup/$BOTTLE"
# A renamed bottle: the backups keep the old name, the files are under the new one.
if [ -n "$NEW_BOTTLE" ] && [ "$NEW_BOTTLE" != "$BOTTLE" ]; then
  GAME_DIR="$BOTTLES/$NEW_BOTTLE/${GAME_DIR#"$BOTTLES/$BOTTLE/"}"
  BOTTLE=$NEW_BOTTLE
fi
BOTTLE_DIR="$BOTTLES/$BOTTLE"
CONF="$BOTTLE_DIR/cxbottle.conf"
D3D11="$BOTTLE_DIR/drive_c/windows/system32/d3d11.dll"
APPDATA_USER="$BOTTLE_DIR/drive_c/users/crossover"
[ -d "$APPDATA_USER" ] || APPDATA_USER=$(find "$BOTTLE_DIR/drive_c/users" -mindepth 1 -maxdepth 1 -type d ! -name Public 2>/dev/null | head -1)
GFX="$APPDATA_USER/AppData/Roaming/DarkSoulsII/GraphicsConfig_SOFS.xml"
[ -d "$BK" ] || die "no backups found in $BK"

if [ "$YES" = 0 ] && [ -r /dev/tty ]; then
  printf 'Undo the DS2 Lighting Engine setup of the "%s" bottle? [y/N] ' "$BOTTLE" >/dev/tty
  read -r reply </dev/tty
  case "$reply" in [Yy]*) ;; *) echo "Nothing changed."; exit 0 ;; esac
fi

# Is a wineserver running for $BOTTLE? (see install.sh)
bottle_running() {
  ps -E -x -o command= | B="$BOTTLE" awk '
    index($0, "/bin/wineserver") {
      k = " CX_BOTTLE=" ENVIRON["B"]; i = index($0, k)
      if (i) { r = substr($0, i + length(k)); if (r == "" || r ~ /^ [A-Za-z_][A-Za-z0-9_]*=/) { f = 1; exit } }
    }
    END { exit !f }'
}
if [ ! -d "$BOTTLE_DIR" ] && [ "$FORGET" = 0 ]; then
  die "the \"$BOTTLE\" bottle isn't there any more. If you renamed it in CrossOver, run this again with
       --bottle \"NEW NAME\". If you deleted it, run it with --forget to remove the rest."
elif [ -d "$BOTTLE_DIR" ] && bottle_running; then
  echo "Something is running in the \"$BOTTLE\" bottle. Quit the game and Steam. Waiting up to 2 minutes..."
  for _ in $(seq 120); do bottle_running || break; sleep 1; done
  bottle_running && die "the bottle is still running. Quit everything in it and run this again."
fi

failed=0
[ "$FORGET" = 0 ] && step "Restoring the \"$BOTTLE\" bottle"
if [ "$FORGET" = 1 ]; then
  info "--forget: the bottle is left alone"
elif [ ! -x "$CX/bin/wine" ]; then
  warn "CrossOver was not found. It's needed to restore the bottle, so reinstall it and run this again."
  failed=1
else
# set_env NAME VALUE: a variable in the bottle's [EnvironmentVariables]; "-" removes it (see install.sh).
set_env() {
  NAME=$1 VALUE=$2 awk '
    function add() { if (ENVIRON["VALUE"] != "-") print "\"" ENVIRON["NAME"] "\" = \"" ENVIRON["VALUE"] "\""; done = 1 }
    /^\[EnvironmentVariables\]/ { print; add(); next }
    index($0, "\"" ENVIRON["NAME"] "\"") == 1 && /^"[^"]*"[[:space:]]*=/ { next }
    { print }
    END { if (!done && ENVIRON["VALUE"] != "-") { print ""; print "[EnvironmentVariables]"; add() } }' "$CONF" >"$CONF.ds2le-tmp" &&
    mv "$CONF.ds2le-tmp" "$CONF"
}
if [ -f "$BK/backend.orig" ] && [ -f "$CONF" ]; then
  set_env CX_GRAPHICS_BACKEND "$(cat "$BK/backend.orig")" &&
    info "graphics backend: $(sed 's/^-$/CrossOver default/' "$BK/backend.orig")" ||
    { warn "could not restore $CONF"; failed=1; }
fi
if [ -f "$BK/nvext.orig" ] && [ -f "$CONF" ]; then
  set_env DXMT_ENABLE_NVEXT "$(cat "$BK/nvext.orig")" && info "DXMT's DLSS support as before" ||
    { warn "could not restore $CONF"; failed=1; }
fi
if [ -f "$BK/d3d11.dll.orig" ]; then
  cp -p "$BK/d3d11.dll.orig" "$D3D11" && info "original system32/d3d11.dll" || { warn "could not restore $D3D11"; failed=1; }
elif [ -e "$BK/d3d11.dll.absent" ]; then
  rm -f "$D3D11" && info "removed system32/d3d11.dll"
fi
if [ -f "$BK/registry-restore.reg" ]; then
  # DXMT writes these when DXMT_ENABLE_NVEXT is on, and removes them only when it runs without it.
  {
    cat "$BK/registry-restore.reg"
    if [ "$(cat "$BK/nvext.orig" 2>/dev/null)" = - ]; then
      printf '%s\r\n' "" \
        '[HKEY_LOCAL_MACHINE\SOFTWARE\NVIDIA Corporation\Global]' '"{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}"=-' "" \
        '[HKEY_LOCAL_MACHINE\SOFTWARE\NVIDIA Corporation\Global\NGXCore]' '"FullPath"=-' "" \
        '[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\nvlddmkm]' '"{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}"=-'
    fi
  } >"$BOTTLE_DIR/drive_c/ds2le-mac.reg" &&
    "$CX/bin/wine" --bottle "$BOTTLE" reg import 'C:\ds2le-mac.reg' >/dev/null 2>&1 &&
    info "registry: DLL overrides, Retina mode and window edge colors as before" ||
    { warn "could not restore the registry"; failed=1; }
  rm -f "$BOTTLE_DIR/drive_c/ds2le-mac.reg"
  for _ in $(seq 60); do bottle_running || break; sleep 1; done
fi
# Only the settings install.sh and the launcher manage; the rest stays as the player set it.
if [ -f "$BK/GraphicsConfig_SOFS.xml.orig" ]; then
  "$HOME_DIR/ds2mac" graphics-config "$GFX" --from "$BK/GraphicsConfig_SOFS.xml.orig" >/dev/null &&
    info "game resolution and window mode as before" || { warn "could not restore $GFX"; failed=1; }
elif [ -e "$BK/GraphicsConfig_SOFS.xml.absent" ]; then
  rm -f "$GFX"
fi
# The launcher may have changed the game's list of window sizes in DarkSoulsII.exe.
EXE="$GAME_DIR/DarkSoulsII.exe"
if [ ! -f "$EXE" ]; then
  warn "the game isn't at $GAME_DIR any more, so its list of window sizes and the mod files were left alone"
  failed=1
else
  "$HOME_DIR/ds2mac" res-table "$EXE" --show >/dev/null 2>&1
  case $? in
    0)
      if [ -s "$BK/res-table.orig" ]; then
        "$HOME_DIR/ds2mac" res-table "$EXE" --list "$(cat "$BK/res-table.orig")" >/dev/null 2>&1
      else
        "$HOME_DIR/ds2mac" res-table "$EXE" --restore >/dev/null 2>&1
      fi && info "the game's list of window sizes as before" ||
        { warn "could not restore the list of window sizes in $EXE"; failed=1; }
      ;;
    4) ;; # this exe has no list we know, so nothing was changed
    *) warn "could not read $EXE"; failed=1 ;;
  esac
  # The frame limiter, if it was as shipped before (the launcher may have set it since).
  if [ "$(cat "$BK/frame-limiter.orig" 2>/dev/null)" = off ]; then
    "$HOME_DIR/ds2mac" frame-limiter "$EXE" off >/dev/null 2>&1
    case $? in
      0) info "the game's frame limiter as before" ;;
      4) ;; # a different exe now (a game update), so there's nothing of ours in it
      *) warn "could not restore the frame limiter in $EXE"; failed=1 ;;
    esac
  fi
fi
# The Lighting Engine settings install.sh changed for upscaling; anything else stays as the player set it.
MOD_INI="$GAME_DIR/ds2le_user_settings.ini"
if [ -f "$BK/mod-settings.orig" ] && [ -f "$MOD_INI" ]; then
  ok=1
  while IFS='|' read -r section key value; do
    [ -z "$key" ] && continue
    "$HOME_DIR/ds2mac" ini "$MOD_INI" "$section" "$key" "$value" || ok=0
  done <"$BK/mod-settings.orig"
  if [ "$ok" = 1 ]; then info "Lighting Engine upscaling settings as before"; else warn "could not restore $MOD_INI"; failed=1; fi
  # A file install.sh created that now holds only section names.
  [ -e "$BK/mod-settings.absent" ] && ! grep -q '=' "$MOD_INI" && rm -f "$MOD_INI"
fi

if [ -f "$BK/mod-files.txt" ] && [ -f "$EXE" ]; then
  if [ "$REMOVE_MOD" = 0 ] && [ "$YES" = 0 ] && [ -r /dev/tty ]; then
    printf '    Also remove the Lighting Engine files from the game folder? [y/N] ' >/dev/tty
    read -r reply </dev/tty
    case "$reply" in [Yy]*) REMOVE_MOD=1 ;; esac
  fi
  if [ "$REMOVE_MOD" = 1 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && rm -f "$GAME_DIR/$f"
    done <"$BK/mod-files.txt"
    if [ -d "$BK/game" ]; then
      ditto "$BK/game" "$GAME_DIR" || { warn "could not put back the game files in $BK/game"; failed=1; }
    fi
    # Folders the mod added are empty now; rmdir leaves the game's own folders alone.
    while IFS= read -r f; do
      d=$(dirname "$f")
      while [ "$d" != . ] && [ "$d" != / ]; do echo "$d"; d=$(dirname "$d"); done
    done <"$BK/mod-files.txt" | sort -ru | while IFS= read -r d; do rmdir "$GAME_DIR/$d" 2>/dev/null; done
    [ -e "$BK/mod-settings.absent" ] && rm -f "$MOD_INI"
    info "removed the Lighting Engine and put back the game files it replaced"
  else
    info "the Lighting Engine stays in the game folder. To remove it later, delete dxgi.dll and the"
    info "ds2le_* files, then verify the game files in Steam (Properties > Installed Files)."
  fi
elif [ "$REMOVE_MOD" = 1 ]; then
  info "the Lighting Engine was installed by hand, so remove its files yourself"
  info "(for the Steam version: delete dxgi.dll and the ds2le_* files, then verify the game files in Steam)"
fi

fi

step "Removing the launcher"
# Only the app install.sh made: same path and our bundle identifier.
app=$(cat "$HOME_DIR/app-path" 2>/dev/null)
if [ -n "$app" ] && [ -d "$app" ] &&
  [ "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ]; then
  "$LSREGISTER" -u "$app" >/dev/null 2>&1
  rm -rf "$app" && info "removed $app"
fi

if [ "$failed" = 0 ]; then
  rm -rf "$BK"
  rmdir "$HOME_DIR/backup" 2>/dev/null && rm -rf "$HOME_DIR"
  step "Done. Everything is back as it was."
else
  warn "some steps failed, so the backups stay in $BK"
  exit 1
fi
