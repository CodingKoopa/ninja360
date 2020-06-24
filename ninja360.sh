#!/bin/bash
# Disable some variable messages, because the axis/button mappings trigger false
# positives.
# shellcheck disable=SC2034,SC2037

set -e

readonly reset=$(tput sgr0)
readonly white=$(tput setaf 7)
readonly bold=$(tput bold)
readonly red=$(tput setaf 1)
readonly green=$(tput setaf 2)
readonly magenta=$(tput setaf 5)
readonly blue=$(tput setaf 4)

# Prints a section message.
# Arguments:
#   - Name of the section.
# Outputs:
#   - The section message.
function section() {
  printf "[${white}Section${reset}] ${bold}%s${reset}\n" "$*"
}

# Prints an info message.
# Arguments:
#   - Info to be printed.
# Outputs:
#   - The info message.
function info() {
  printf "[${green}Info${reset}] %s\n" "$*"
}

# Prints an error message.
# Arguments:
#   - Error to be printed.
# Outputs:
#   - The error message.
function error() {
  printf "[${red}Error${reset}] %s\n" "$*"
}

# Prints a verbose message.
# Globals Read:
#   - (Optional) VERBOSE: Whether to print verbose info, out of true or false. Default false.
# Arguments:
#   - Verbose info to be printed.
# Outputs:
#   - The verbose message.
function verbose() {
  if [[ $DEBUG = true || $VERBOSE = true ]]; then
    printf "[${magenta}Verbose${reset}] %s\n" "$*"
  fi
}

# Prints a debug message.
# Globals Read:
#   - (Optional) DEBUG: Whether to print debug info, out of true or false. Default false.
# Arguments:
#   - Debug info to be printed.
# Outputs:
#   - The debug message.
function debug() {
  if [[ $DEBUG = true ]]; then
    printf "[${blue}Debug${NORMAL}] %s\n" "$*"
  fi
}

# Resolves a symlink to an evdev.
# Arguments:
#   The ID of the evdev, as it is in "/dev/input/by-id/", without the "-event-joystick" suffix.
# Outputs:
#   The real path to the character device, or an error if failed.
# Returns:
#   - 0 on success.
#   - 1 on invalid/nonexistent input symlink.
#   - 2 on issues with resolving the symlink.
function resolve_evdev_symlink() {
  local -r symlink=/dev/input/by-id/$1-event-joystick

  if [[ ! -L $symlink ]]; then
    echo "Symlink \"$symlink\" doesn't exist/isn't a symlink."
    return 1
  fi
  if ! realpath=$(realpath "$symlink"); then
    echo "$realpath"
    return 2
  fi
  if [[ ! -c $realpath ]]; then
    echo "$realpath doesn't exist/isn't a character device."
    return 2
  fi
  echo "$realpath"
  return 0
}

function ninja_360() {
  # Convert to all lowercase.
  local -r configuration="${1,,}"

  if [[ -z $configuration || $configuration = "-h" || $configuration = "--help" ]]; then
    info "Usage: $(basename "$0") { restore | configuration }, where configuration is a preset to 
use."
    exit 0
  fi

  if [[ $configuration == "restore" ]]; then
    section "Restoring original controller evdevs."

    info "Killing xboxdrv."
    killall -q xboxdrv || true
    # Ninja360 makes symlinks to the remapped evdevs, named as the original. For example, if we
    # remapped /dev/input/evdev21 to /dev/input/evdev91, then /run/user/$(id -u)/ninja360/evdev21
    # will exist as a symlink to /dev/input/evdev91. "restore" removes the symlink, and moves
    # /dev/input/evdev91 back to /dev/input/evdev21, effectively restoring the original state.
    info "Restoring original inputs."
    local -r rundir=/run/user/$(id -u)/ninja360
    if [[ -d $rundir ]]; then
      for evdev_remap_symlink in "$rundir"/evdev*; do
        if [[ ! -L $evdev_remap_symlink ]]; then
          error "Symlink \"$evdev_remap_symlink\" doesn't exist/isn't a symlink."
          continue
        fi
        if ! realpath=$(realpath "$evdev_remap_symlink"); then
          continue
        fi
        if [[ ! -c $realpath ]]; then
          error "$realpath doesn't exist/isn't a character device."
          continue
        fi
        sudo mv "$realpath" /dev/input/"$(basename "$evdev_remap_symlink")" || true
        rm "$evdev_remap_symlink"
      done
    fi
    exit 0
  fi

  section "Obtaining controller configuration and device paths."

  case $configuration in
  "mayflash")
    local -r controller_config="Mayflash.conf"

    info "Searching for Mayflash 2-port adapter."
    if ! port_1_evdev_path=$(resolve_evdev_symlink \
      "usb-mayflash_limited_MAYFLASH_GameCube_Controller_Adapter"); then
      error "Couldn't resolve first port controller: $port_1_evdev_path"
      exit 1
    fi
    if ! port_2_evdev_path=$(resolve_evdev_symlink \
      "usb-mayflash_limited_MAYFLASH_GameCube_Controller_Adapter-if01"); then
      error "Couldn't resolve second port controller: $port_2_evdev_path"
      exit 1
    fi
    info "Controller evdev ports resolved to $port_1_evdev_path and $port_2_evdev_path."
    ;;
  *)
    error "Configuration $configuration not found in Ninja360."
    exit 1
    ;;
  esac

  section "Checking configuration files."

  verbose "Checking main config file."
  local -r main_config="Ninja360.conf"
  if [[ ! -f $main_config ]]; then
    error "Main config file $main_config not found."
    exit 1
  fi
  verbose "Checking controller config file."
  if [[ ! -f $controller_config ]]; then
    error "Controller config file $controller_config not found."
    exit 1
  fi

  section "Relocating devices and starting xboxdrv."

  verbose "Killing any existing xboxdrv processes."
  killall -q xboxdrv || true

  # xboxdrv's daemon feature doesn't seem to work for us because that daemon is used for launching
  # new threads to handle new controllers as they are plugged in. This clashes with this script's
  # model of launching xboxdrv once, and clearly making a certain number of new devices.

  local -r rundir=/run/user/$(id -u)/ninja360
  mkdir -p "$rundir"
  local -r user=$(whoami)
  local -r common_args=(--config "$main_config" --alt-config "$controller_config")

  verbose "Remapping and executing."
  if [[ -c $port_1_evdev_path ]]; then
    local -r port_1_evdev_remap_path=/dev/input/evdev91
    # Move the evdev device out of /dev/input/ so that games do not try to use it.
    sudo mv "$port_1_evdev_path" "$port_1_evdev_remap_path"
    # Make a link including the original evdev name so that it can be restored.
    ln -s "$port_1_evdev_remap_path" "$rundir"/"$(basename "$port_1_evdev_path")"
    nohup xboxdrv "${common_args[@]}" --evdev "$port_1_evdev_remap_path" >xboxdrv.0.log &
  fi
  if [[ -c $port_2_evdev_path ]]; then
    local -r port_2_evdev_remap_path=/dev/input/evdev92
    sudo mv "$port_2_evdev_path" "$port_2_evdev_remap_path"
    ln -s "$port_2_evdev_remap_path" "$rundir"/"$(basename "$port_2_evdev_path")"
    nohup xboxdrv "${common_args[@]}" --evdev "$port_2_evdev_remap_path" >xboxdrv.1.log &
  fi
}

ninja_360 "$@"
