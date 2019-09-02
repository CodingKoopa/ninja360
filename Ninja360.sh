#!/bin/bash
# Disable some variable messages, because the axis/button mappings trigger false
# positives.
# shellcheck disable=SC2034,SC2037

set -e

check_devices()
{
  # First, check if the paths are even set.
  if [[ -z "$PORT_1_EVDEV_PATH" ]] || [[ -z "$PORT_2_EVDEV_PATH" ]]; then
    return 1
  # Then, check if the ID matches the path, because that means realpath couldn't resolve the name,
  # so the symlink doesn't exist.
  elif [[ $PORT_1_EVDEV_ID = "$PORT_1_EVDEV_PATH" ]] || \
       [[ $PORT_2_EVDEV_ID = "$PORT_2_EVDEV_PATH" ]]; then
    return 1
  fi
  return 0
}

search_for_mayflash()
{
  MAYFLASH_SYMLINK_PATH="/dev/input/by-id/usb-mayflash_limited_MAYFLASH_GameCube_Controller_Adapter"
  EVDEV_SUFFIX="-event-joystick"

  # Resolve the symlinks from the by-id folder.
  PORT_1_EVDEV_ID=$MAYFLASH_SYMLINK_PATH$EVDEV_SUFFIX
  PORT_1_EVDEV_PATH=$(realpath    $PORT_1_EVDEV_ID)
  PORT_2_EVDEV_ID="$MAYFLASH_SYMLINK_PATH-if01$EVDEV_SUFFIX"
  PORT_2_EVDEV_PATH=$(realpath    $PORT_2_EVDEV_ID)

  check_devices
  return $?
}


ninja-360() {
  DIVIDER="
  ====================================================================================================
  "

  # Start Rocket League. The script will still run, because
  #"RocketLeague" seems to just be a Steam bootstrap program, that launches RL and
  # exits.
  # echo "Starting Rocket League."
  # if [ -z "$(pidof RocketLeague)" ]; then
  #   ~/.steam/steam/steamapps/common/rocketleague/Binaries/Linux/RocketLeague &> /dev/null
  # else
  #   echo "Rocket League is already running, skipping."
  # fi

  echo $DIVIDER
  ### STAGE 1: Get the controller device paths.

  echo "Looking for Gamecube controller adapter."
  ADAPTER_NAME=""

  MAYFLASH_NAME="Mayflash 2-port adapter"
  echo "Trying $MAYFLASH_NAME."
  search_for_mayflash
  if [ $? -eq 0 ]; then
    echo "$MAYFLASH_NAME found."
    ADAPTER_NAME=$MAYFLASH_NAME
  else
    echo "$MAYFLASH_NAME not found."
  fi

  # This is where other controller devices would go, like so:
  # if [ -z $ADAPTER_NAME ]; then
  #   CONTROLLER=NAME="Something."
  #   echo "Trying $CONTROLLER."
  #   search_for_your_controller
  #   if [ $? -eq 0 ]; then
  # And so on.


  if [[ -z $ADAPTER_NAME ]]; then
    echo "No gamecube adapter could be found, can't continue. If using a supported adapter, make sure
    it is plugged in, and that it is working as a normal evdev controller. If your adapter is not
    supported, see this script's source for info on how to add one."
    exit 1
  fi

  set +e

  echo "Port 1 evdev path: $PORT_1_EVDEV_PATH"
  # This is a hack to see if the files are present because I couldn't get if [ -f ] to work with
  # device files.
  # TODO: check_dev()
  ls $PORT_1_EVDEV_PATH &> /dev/null
  PORT_1_FOUND=$?
  echo "Port 2 evdev path: $PORT_2_EVDEV_PATH"
  ls $PORT_2_EVDEV_PATH &> /dev/null
  PORT_2_FOUND=$?

  set -e

  echo $DIVIDER
  ### STAGE 2: Relocating the target device.
  echo "Relocating devices if necessary."
  if [[ $PORT_1_FOUND -eq 0 ]] && [[ $PORT_2_FOUND -eq 0 ]]; then
    echo "Port 1 device and port 2 device found. Moving port 1 device to port 2 path."
    sudo mv $PORT_1_EVDEV_PATH $PORT_2_EVDEV_PATH

  elif [[ $PORT_1_FOUND -eq 0 ]] && [[ $PORT_2_FOUND -ne 0 ]]; then
    echo "Port 1 device found, but port 2 device found. This shouldn't really happen, but moving port
  1 device to port 2 path anyways."
    sudo mv $PORT_1_EVDEV_PATH $PORT_2_EVDEV_PATH

  elif [[ $PORT_1_FOUND -ne 0 ]] && [[ $PORT_2_FOUND -eq 0 ]]; then
    echo "Port 1 device not found, but port 2 device found. This can be a result of running this
  script more than once without the devices being reset. Continuing."

  elif [[ $PORT_1_FOUND -ne 0 ]] && [[ $PORT_2_FOUND -ne 0 ]]; then
    echo "Port 1 and port 2 device not found. Something messed up, try unplugging your adapter and
  plugging it back in. Exiting."
    exit 1

  else
    echo "Invalid scenario reached. Exiting."
    exit 1
  fi

  echo $DIVIDER
  # STAGE 3: Make sure the config files are here.
  echo "Finding config files."

  MAIN_CONFIG="Ninja360.conf"
  echo "Checking main config file is present."
  if [ ! -f $MAIN_CONFIG ]; then
    echo "Config file \"$MAIN_CONFIG\" not found. Exiting."
    exit 1
  fi

  CONTROLLER_CONFIG=""
  echo "Checking if config file for $ADAPTER_NAME is present."
  if [ "$ADAPTER_NAME" = "$MAYFLASH_NAME" ]; then
    MAYFLASH_CONFIG="Mayflash.conf"
    if [ ! -f $MAYFLASH_CONFIG ]; then
      echo "Config file \"$MAYFLASH_CONFIG\" not found. Exiting."

      exit 1
    else
      CONTROLLER_CONFIG=$MAYFLASH_CONFIG
    fi
  # Put config checks for other adapters here.
  fi

  if [ -z $CONTROLLER_CONFIG ]; then
    echo "No controller config found. Exiting."
    exit 1
  fi

  echo $DIVIDER
  # STAGE 4: Terminate any existing xboxdrv processes.
  echo "Killing any existing xboxdrv processes if necessary."
  PROCESSES=$(pidof xboxdrv || true)
  if [ -n "$PROCESSES" ]; then
    echo "xboxdrv process(es) found, sending SIGTERM signal."
    kill -SIGTERM $PROCESSES
  else
    echo "No xboxdrv processes found. Continuing."
  fi

  echo $DIVIDER
  # STAGE 5: Run xboxdrv!
  echo "Launching xboxdrv."

  # Don't even try to add comments for these arguments. xboxdrv will eat them up
  # as an executable to run. It's a pain.

  # xboxdrv's daemon feature doesn't work for us because that daemon is used for launching new
  # threads to handle new controllers as they are plugged in. This clashes with this script's
  # model of launching xboxdrv once, and clearly making a certain number of new devices.

  # And don't try xboxdrv's built in game execution either; Steam's shenanigans
  # make xboxdrv go away before Rocket League boots.
  nohup xboxdrv --evdev "$PORT_2_EVDEV_PATH" --config $MAIN_CONFIG --alt-config $CONTROLLER_CONFIG &

  # Give it some time to set up.
  sleep 2

  echo $DIVIDER
  # STAGE 6: Fixing X-Box 360 controller path.
  echo "Fixing X-Box 360 controller path."

  # At this point, the virtual X-Box 360 controller SHOULD be on port 1, but
  # xboxdrv seems to lie about it being on that port for some reason.
  # If xboxdrv didn't put the virtual controller on port 1. (Same hack from
  # before)
  echo "Checking if Virtual X-Box 360 controller was mapped to port 1 (\"$PORT_1_EVDEV_PATH\")."
  set +e
  ls $PORT_1_EVDEV_PATH &> /dev/null
  RES=$?
  set -e
  if [ $RES -ne 0 ]; then
    echo "Virtual X-Box 360 controller not mapped to port 1, attempting to remap."
    # I couldn't find any tool to list evdev controllers, so this goes up the list of evdev devices
    # until it finds the last one. This last one is the X-Box 360 controller placed there by xboxdrv
    # due to what I feel like is a bug.
    CURRENT_DEVICE=0
    set +e
    while true; do
      EVENT_PATH=/dev/input/event$CURRENT_DEVICE
      # Skip the target path.
      if [ $EVENT_PATH = $PORT_1_EVDEV_PATH ]; then
        ((CURRENT_DEVICE++))
        continue
      fi
      ls $EVENT_PATH &> /dev/null
      # If there's no event.
      if [ $? -ne 0 ]; then
        # Now we should be at the event above the X-Box 360 controller one.
        break
      fi
      ((CURRENT_DEVICE++))
    done
    set -e
    # Go down one.
    ((CURRENT_DEVICE--))
    VIRTUAL_CONTROLLER_PATH="/dev/input/event$CURRENT_DEVICE"
    echo "Found X-Box 360 controller at $VIRTUAL_CONTROLLER_PATH, remapping to $PORT_1_EVDEV_PATH."
    sudo mv $VIRTUAL_CONTROLLER_PATH $PORT_1_EVDEV_PATH
  else
    echo "Nothing needs to be done."
  fi
  return 0

  zenity --info --text "Ninja360 started successfully! Note that it might take some time for the new mapping to take
  effect. When they kick in, you should be able to use use \"sdl2-jstest -t 0\" to test it."
}

ninja-360