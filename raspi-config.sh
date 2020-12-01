#!/bin/sh
# Part of raspi-config https://github.com/RPi-Distro/raspi-config
# See LICENSE file for copyright and license details
INTERACTIVE=True
ASK_TO_REBOOT=0
BLACKLIST=/etc/modprobe.d/raspi-blacklist.conf
CONFIG=/boot/config.txt

USER=${SUDO_USER:-$(who -m | awk '{ print $1 }')}

is_pi () {
  ARCH=$(dpkg --print-architecture)
  if [ "$ARCH" = "armhf" ] || [ "$ARCH" = "arm64" ] ; then
    return 0
  else
    return 1
  fi
}

if is_pi ; then
  CMDLINE=/boot/cmdline.txt
else
  CMDLINE=/proc/cmdline
fi

is_pione() {
   if grep -q "^Revision\s*:\s*00[0-9a-fA-F][0-9a-fA-F]$" /proc/cpuinfo; then
      return 0
   elif grep -q "^Revision\s*:\s*[ 123][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]0[0-36][0-9a-fA-F]$" /proc/cpuinfo ; then
      return 0
   else
      return 1
   fi
}

is_pitwo() {
   grep -q "^Revision\s*:\s*[ 123][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]04[0-9a-fA-F]$" /proc/cpuinfo
   return $?
}

is_pizero() {
   grep -q "^Revision\s*:\s*[ 123][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]0[9cC][0-9a-fA-F]$" /proc/cpuinfo
   return $?
}

is_pifour() {
   grep -q "^Revision\s*:\s*[ 123][0-9a-fA-F][0-9a-fA-F]3[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$" /proc/cpuinfo
   return $?
}

get_pi_type() {
   if is_pione; then
      echo 1
   elif is_pitwo; then
      echo 2
   else
      echo 0
   fi
}

is_live() {
    grep -q "boot=live" $CMDLINE
    return $?
}

is_ssh() {
  if pstree -p | egrep --quiet --extended-regexp ".*sshd.*\($$\)"; then
    return 0
  else
    return 1
  fi
}

is_fkms() {
  if grep -s -q okay /proc/device-tree/soc/v3d@7ec00000/status \
                     /proc/device-tree/soc/firmwarekms@7e600000/status \
                     /proc/device-tree/v3dbus/v3d@7ec04000/status; then
    return 0
  else
    return 1
  fi
}

is_pulseaudio() {
  PS=$(ps ax)
  echo "$PS" | grep -q pulseaudio
  return $?
}

has_analog() {
  if [ $(get_leds) -eq -1 ] ; then
    return 0
  else
    return 1
  fi
}

is_installed() {
    if [ "$(dpkg -l "$1" 2> /dev/null | tail -n 1 | cut -d ' ' -f 1)" != "ii" ]; then
      return 1
    else
      return 0
    fi
}

deb_ver () {
  ver=`cat /etc/debian_version | cut -d . -f 1`
  echo $ver
}

calc_wt_size() {
  # NOTE: it's tempting to redirect stderr to /dev/null, so supress error 
  # output from tput. However in this case, tput detects neither stdout or 
  # stderr is a tty and so only gives default 80, 24 values
  WT_HEIGHT=18
  WT_WIDTH=$(tput cols)

  if [ -z "$WT_WIDTH" ] || [ "$WT_WIDTH" -lt 60 ]; then
    WT_WIDTH=80
  fi
  if [ "$WT_WIDTH" -gt 178 ]; then
    WT_WIDTH=120
  fi
  WT_MENU_HEIGHT=$(($WT_HEIGHT-7))
}

do_about() {
  whiptail --msgbox "\
This tool provides a straightforward way of doing initial
configuration of the Raspberry Pi. Although it can be run
at any time, some of the options may have difficulties if
you have heavily customised your installation.\
" 20 70 1
}

get_can_expand() {
  ROOT_PART="$(findmnt / -o source -n)"
  ROOT_DEV="/dev/$(lsblk -no pkname "$ROOT_PART")"

  PART_NUM="$(echo "$ROOT_PART" | grep -o "[[:digit:]]*$")"

  if [ "$PART_NUM" -ne 2 ]; then
    echo 1
    exit
  fi

  LAST_PART_NUM=$(parted "$ROOT_DEV" -ms unit s p | tail -n 1 | cut -f 1 -d:)
  if [ "$LAST_PART_NUM" -ne "$PART_NUM" ]; then
    echo 1
    exit
  fi
  echo 0
}

do_expand_rootfs() {
  ROOT_PART="$(findmnt / -o source -n)"
  ROOT_DEV="/dev/$(lsblk -no pkname "$ROOT_PART")"

  PART_NUM="$(echo "$ROOT_PART" | grep -o "[[:digit:]]*$")"

  # NOTE: the NOOBS partition layout confuses parted. For now, let's only 
  # agree to work with a sufficiently simple partition layout
  if [ "$PART_NUM" -ne 2 ]; then
    whiptail --msgbox "Your partition layout is not currently supported by this tool. You are probably using NOOBS, in which case your root filesystem is already expanded anyway." 20 60 2
    return 0
  fi

  LAST_PART_NUM=$(parted "$ROOT_DEV" -ms unit s p | tail -n 1 | cut -f 1 -d:)
  if [ $LAST_PART_NUM -ne $PART_NUM ]; then
    whiptail --msgbox "$ROOT_PART is not the last partition. Don't know how to expand" 20 60 2
    return 0
  fi

  # Get the starting offset of the root partition
  PART_START=$(parted "$ROOT_DEV" -ms unit s p | grep "^${PART_NUM}" | cut -f 2 -d: | sed 's/[^0-9]//g')
  [ "$PART_START" ] || return 1
  # Return value will likely be error for fdisk as it fails to reload the
  # partition table because the root fs is mounted
  fdisk "$ROOT_DEV" <<EOF
p
d
$PART_NUM
n
p
$PART_NUM
$PART_START

p
w
EOF
  ASK_TO_REBOOT=1

  # now set up an init.d script
cat <<EOF > /etc/init.d/resize2fs_once &&
#!/bin/sh
### BEGIN INIT INFO
# Provides:          resize2fs_once
# Required-Start:
# Required-Stop:
# Default-Start: 3
# Default-Stop:
# Short-Description: Resize the root filesystem to fill partition
# Description:
### END INIT INFO

. /lib/lsb/init-functions

case "\$1" in
  start)
    log_daemon_msg "Starting resize2fs_once" &&
    resize2fs "$ROOT_PART" &&
    update-rc.d resize2fs_once remove &&
    rm /etc/init.d/resize2fs_once &&
    log_end_msg \$?
    ;;
  *)
    echo "Usage: \$0 start" >&2
    exit 3
    ;;
esac
EOF
  chmod +x /etc/init.d/resize2fs_once &&
  update-rc.d resize2fs_once defaults &&
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "Root partition has been resized.\nThe filesystem will be enlarged upon the next reboot" 20 60 2
  fi
}

set_config_var() {
  lua - "$1" "$2" "$3" <<EOF > "$3.bak"
local key=assert(arg[1])
local value=assert(arg[2])
local fn=assert(arg[3])
local file=assert(io.open(fn))
local made_change=false
for line in file:lines() do
  if line:match("^#?%s*"..key.."=.*$") then
    line=key.."="..value
    made_change=true
  end
  print(line)
end

if not made_change then
  print(key.."="..value)
end
EOF
mv "$3.bak" "$3"
}

clear_config_var() {
  lua - "$1" "$2" <<EOF > "$2.bak"
local key=assert(arg[1])
local fn=assert(arg[2])
local file=assert(io.open(fn))
for line in file:lines() do
  if line:match("^%s*"..key.."=.*$") then
    line="#"..line
  end
  print(line)
end
EOF
mv "$2.bak" "$2"
}

get_config_var() {
  lua - "$1" "$2" <<EOF
local key=assert(arg[1])
local fn=assert(arg[2])
local file=assert(io.open(fn))
local found=false
for line in file:lines() do
  local val = line:match("^%s*"..key.."=(.*)$")
  if (val ~= nil) then
    print(val)
    found=true
    break
  end
end
if not found then
   print(0)
end
EOF
}

get_overscan() {
  OVS=$(get_config_var disable_overscan $CONFIG)
  if [ $OVS -eq 1 ]; then
    echo 1
  else
    echo 0
  fi
}

do_overscan() {
  DEFAULT=--defaultno
  CURRENT=0
  if [ $(get_overscan) -eq 0 ]; then
      DEFAULT=
      CURRENT=1
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like to enable compensation for displays with overscan?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq $CURRENT ]; then
    ASK_TO_REBOOT=1
  fi
  if [ $RET -eq 0 ] ; then
    set_config_var disable_overscan 0 $CONFIG
    STATUS=enabled
  elif [ $RET -eq 1 ]; then
    sed $CONFIG -i -e "s/^overscan_/#overscan_/"
    set_config_var disable_overscan 1 $CONFIG
    STATUS=disabled
  else
    return $RET
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "Display overscan compensation is $STATUS" 20 60 1
  fi
}

get_blanking() {
  if ! [ -f "/etc/X11/xorg.conf.d/10-blanking.conf" ]; then
    echo 0
  else
    echo 1
  fi
}

# shellcheck disable=SC2120
do_blanking() {
  DEFAULT=--defaultno
  CURRENT=0
  if [ "$(get_blanking)" -eq 0 ]; then
      DEFAULT=
      CURRENT=1
  fi
  if [ "$INTERACTIVE" = True ]; then
    if [ "$(dpkg -l xscreensaver | tail -n 1 | cut -d ' ' -f 1)" = "ii" ]; then
      whiptail --msgbox "Warning: xscreensaver is installed may override raspi-config settings" 20 60 2
    fi
    whiptail --yesno "Would you like to enable screen blanking?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ "$RET" -eq "$CURRENT" ]; then
    ASK_TO_REBOOT=1
  fi
  rm -f /etc/X11/xorg.conf.d/10-blanking.conf
  sed -i '/^\o033/d' /etc/issue
  if [ "$RET" -eq 0 ] ; then
    STATUS=enabled
  elif [ "$RET" -eq 1 ]; then
    mkdir -p /etc/X11/xorg.conf.d/
    cp /usr/share/raspi-config/10-blanking.conf /etc/X11/xorg.conf.d/
    printf "\\033[9;0]" >> /etc/issue
    STATUS=disabled
  else
    return "$RET"
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "Screen blanking is $STATUS" 20 60 1
  fi
}

get_pixdub() {
  if is_pi && ! is_fkms; then
    FBW=$(get_config_var framebuffer_width $CONFIG)
    if [ $FBW -eq 0 ]; then
      echo 1
    else
      echo 0
    fi
  else
    if grep -q 'scale 0.5x0.5' /usr/share/dispsetup.sh ; then
      echo 0
    else
      echo 1
    fi
  fi
}

is_number() {
  case $1 in
    ''|*[!0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

do_pixdub() {
  DEFAULT=--defaultno
  CURRENT=0
  if [ $(get_pixdub) -eq 0 ]; then
      DEFAULT=
      CURRENT=1
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like to enable pixel doubling?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if is_pi && ! is_fkms; then
    if [ $RET -eq 0 ] ; then
	  XVAL=$(xrandr 2>&1 | grep current | cut -f2 -d, | cut -f3 -d' ')
	  YVAL=$(xrandr 2>&1 | grep current | cut -f2 -d, | cut -f5 -d' ')
	  if is_number $XVAL || is_number $YVAL ; then
        if [ "$INTERACTIVE" = True ]; then
          whiptail --msgbox "Could not read current screen dimensions - unable to enable pixel doubling" 20 60 1
        fi
	    return 1
	  fi
	  NEWX=`expr $XVAL / 2`
	  NEWY=`expr $YVAL / 2`
      set_config_var framebuffer_width $NEWX $CONFIG
      set_config_var framebuffer_height $NEWY $CONFIG
      set_config_var scaling_kernel 8 $CONFIG
      STATUS=enabled
    elif [ $RET -eq 1 ]; then
      clear_config_var framebuffer_width $CONFIG
      clear_config_var framebuffer_height $CONFIG
      clear_config_var scaling_kernel $CONFIG
      STATUS=disabled
    else
      return $RET
    fi
  else
    if [ $RET -eq 0 ] ; then
      if [ -e /usr/share/dispsetup.sh ] ; then
        rm /usr/share/dispsetup.sh
      fi
      echo '#!/bin/sh' > /usr/share/dispsetup.sh
      DEV=$(xrandr | grep -w connected | cut -f1 -d' ')
      for item in $DEV
      do
        echo xrandr --output $item --scale 0.5x0.5 --filter nearest >> /usr/share/dispsetup.sh
      done
      STATUS=enabled
    elif [ $RET -eq 1 ]; then
      if [ -e /usr/share/dispsetup.sh ] ; then
        rm /usr/share/dispsetup.sh
      fi
      echo '#!/bin/sh' > /usr/share/dispsetup.sh
      echo 'exit 0' >> /usr/share/dispsetup.sh
      STATUS=disabled
    else
      return $RET
    fi
    chmod a+x /usr/share/dispsetup.sh
  fi
  if [ $RET -eq $CURRENT ]; then
    ASK_TO_REBOOT=1
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "Pixel doubling is $STATUS" 20 60 1
  fi
}

do_change_pass() {
  whiptail --msgbox "You will now be asked to enter a new password for the $USER user" 20 60 1
  passwd $USER &&
  whiptail --msgbox "Password changed successfully" 20 60 1
}

do_configure_keyboard() {
  printf "Reloading keymap. This may take a short while\n"
  if [ "$INTERACTIVE" = True ]; then
    dpkg-reconfigure keyboard-configuration
  else
    local KEYMAP="$1"
    sed -i /etc/default/keyboard -e "s/^XKBLAYOUT.*/XKBLAYOUT=\"$KEYMAP\"/"
    dpkg-reconfigure -f noninteractive keyboard-configuration
  fi
  invoke-rc.d keyboard-setup start
  setsid sh -c 'exec setupcon -k --force <> /dev/tty1 >&0 2>&1'
  udevadm trigger --subsystem-match=input --action=change
  return 0
}

do_change_locale() {
  if [ "$INTERACTIVE" = True ]; then
    dpkg-reconfigure locales
  else
    local LOCALE="$1"
    if ! LOCALE_LINE="$(grep "^$LOCALE " /usr/share/i18n/SUPPORTED)"; then
      return 1
    fi
    local ENCODING="$(echo $LOCALE_LINE | cut -f2 -d " ")"
    echo "$LOCALE $ENCODING" > /etc/locale.gen
    sed -i "s/^\s*LANG=\S*/LANG=$LOCALE/" /etc/default/locale
    dpkg-reconfigure -f noninteractive locales
  fi
}

do_change_timezone() {
  if [ "$INTERACTIVE" = True ]; then
    dpkg-reconfigure tzdata
  else
    local TIMEZONE="$1"
    if [ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
      return 1;
    fi
    rm /etc/localtime
    echo "$TIMEZONE" > /etc/timezone
    dpkg-reconfigure -f noninteractive tzdata
  fi
}

get_wifi_country() {
  CODE=${1:-0}
  IFACE="$(list_wlan_interfaces | head -n 1)"
  if [ -z "$IFACE" ]; then
    if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "No wireless interface found" 20 60
    fi
    return 1
  fi
  if ! wpa_cli -i "$IFACE" status > /dev/null 2>&1; then
    if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "Could not communicate with wpa_supplicant" 20 60
    fi
    return 1
  fi
  wpa_cli -i "$IFACE" save_config > /dev/null 2>&1
  COUNTRY="$(wpa_cli -i "$IFACE" get country)"
  if [ "$COUNTRY" = "FAIL" ]; then
    return 1
  fi
  if [ $CODE = 0 ]; then
    echo "$COUNTRY"
  fi
  return 0
}

do_wifi_country() {
  IFACE="$(list_wlan_interfaces | head -n 1)"
  if [ -z "$IFACE" ]; then
    if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "No wireless interface found" 20 60
    fi
    return 1
  fi

  if ! wpa_cli -i "$IFACE" status > /dev/null 2>&1; then
    if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "Could not communicate with wpa_supplicant" 20 60
    fi
    return 1
  fi

  oIFS="$IFS"
  if [ "$INTERACTIVE" = True ]; then
    value=$(cat /usr/share/zoneinfo/iso3166.tab | tail -n +26 | tr '\t' '/' | tr '\n' '/')
    IFS="/"
    COUNTRY=$(whiptail --menu "Select the country in which the Pi is to be used" 20 60 10 ${value} 3>&1 1>&2 2>&3)
  else
    COUNTRY=$1
    true
  fi
  if [ $? -eq 0 ];then
    wpa_cli -i "$IFACE" set country "$COUNTRY"
    wpa_cli -i "$IFACE" save_config > /dev/null 2>&1
    if iw reg set "$COUNTRY" 2> /dev/null; then
        ASK_TO_REBOOT=1
    fi
    if hash rfkill 2> /dev/null; then
      rfkill unblock wifi
      if is_pi ; then
        for filename in /var/lib/systemd/rfkill/*:wlan ; do
          echo 0 > $filename
        done
      fi
    fi
    if [ "$INTERACTIVE" = True ]; then
        whiptail --msgbox "Wireless LAN country set to $COUNTRY" 20 60 1
    fi
  fi
  IFS=$oIFS
}

get_hostname() {
    cat /etc/hostname | tr -d " \t\n\r"
}

do_hostname() {
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "\
Please note: RFCs mandate that a hostname's labels \
may contain only the ASCII letters 'a' through 'z' (case-insensitive), 
the digits '0' through '9', and the hyphen.
Hostname labels cannot begin or end with a hyphen. 
No other symbols, punctuation characters, or blank spaces are permitted.\
" 20 70 1
  fi
  CURRENT_HOSTNAME=`cat /etc/hostname | tr -d " \t\n\r"`
  if [ "$INTERACTIVE" = True ]; then
    NEW_HOSTNAME=$(whiptail --inputbox "Please enter a hostname" 20 60 "$CURRENT_HOSTNAME" 3>&1 1>&2 2>&3)
  else
    NEW_HOSTNAME=$1
    true
  fi
  if [ $? -eq 0 ]; then
    echo $NEW_HOSTNAME > /etc/hostname
    sed -i "s/127.0.1.1.*$CURRENT_HOSTNAME/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
    ASK_TO_REBOOT=1
  fi
}

do_memory_split() { # Memory Split
  if [ -e /boot/start_cd.elf ]; then
    # New-style memory split setting
    ## get current memory split from /boot/config.txt
    arm=$(vcgencmd get_mem arm | cut -d '=' -f 2 | cut -d 'M' -f 1)
    gpu=$(vcgencmd get_mem gpu | cut -d '=' -f 2 | cut -d 'M' -f 1)
    tot=$(($arm+$gpu))
    if [ $tot -gt 512 ]; then
      CUR_GPU_MEM=$(get_config_var gpu_mem_1024 $CONFIG)
    elif [ $tot -gt 256 ]; then
      CUR_GPU_MEM=$(get_config_var gpu_mem_512 $CONFIG)
    else
      CUR_GPU_MEM=$(get_config_var gpu_mem_256 $CONFIG)
    fi
    if [ -z "$CUR_GPU_MEM" ] || [ $CUR_GPU_MEM = "0" ]; then
      CUR_GPU_MEM=$(get_config_var gpu_mem $CONFIG)
    fi
    [ -z "$CUR_GPU_MEM" ] || [ $CUR_GPU_MEM = "0" ] && CUR_GPU_MEM=64
    ## ask users what gpu_mem they want
    if [ "$INTERACTIVE" = True ]; then
      NEW_GPU_MEM=$(whiptail --inputbox "How much memory (MB) should the GPU have?  e.g. 16/32/64/128/256" \
        20 70 -- "$CUR_GPU_MEM" 3>&1 1>&2 2>&3)
    else
      NEW_GPU_MEM=$1
      true
    fi
    if [ $? -eq 0 ]; then
      if [ $(get_config_var gpu_mem_1024 $CONFIG) != "0" ] || [ $(get_config_var gpu_mem_512 $CONFIG) != "0" ] || [ $(get_config_var gpu_mem_256 $CONFIG) != "0" ]; then
        if [ "$INTERACTIVE" = True ]; then
          whiptail --msgbox "Device-specific memory settings were found. These have been cleared." 20 60 2
        fi
        clear_config_var gpu_mem_1024 $CONFIG
        clear_config_var gpu_mem_512 $CONFIG
        clear_config_var gpu_mem_256 $CONFIG
      fi
      set_config_var gpu_mem "$NEW_GPU_MEM" $CONFIG
      ASK_TO_REBOOT=1
    fi
  else # Old firmware so do start.elf renaming
    get_current_memory_split
    MEMSPLIT=$(whiptail --menu "Set memory split.\n$MEMSPLIT_DESCRIPTION" 20 60 10 \
      "240" "240MiB for ARM, 16MiB for VideoCore" \
      "224" "224MiB for ARM, 32MiB for VideoCore" \
      "192" "192MiB for ARM, 64MiB for VideoCore" \
      "128" "128MiB for ARM, 128MiB for VideoCore" \
      3>&1 1>&2 2>&3)
    if [ $? -eq 0 ]; then
      set_memory_split ${MEMSPLIT}
      ASK_TO_REBOOT=1
    fi
  fi
}

get_current_memory_split() {
  AVAILABLE_SPLITS="128 192 224 240"
  MEMSPLIT_DESCRIPTION=""
  for SPLIT in $AVAILABLE_SPLITS;do
    if [ -e /boot/arm${SPLIT}_start.elf ] && cmp /boot/arm${SPLIT}_start.elf /boot/start.elf >/dev/null 2>&1;then
      CURRENT_MEMSPLIT=$SPLIT
      MEMSPLIT_DESCRIPTION="Current: ${CURRENT_MEMSPLIT}MiB for ARM, $((256 - $CURRENT_MEMSPLIT))MiB for VideoCore"
      break
    fi
  done
}

set_memory_split() {
  cp -a /boot/arm${1}_start.elf /boot/start.elf
  sync
}

do_overclock() {
  if ! is_pione && ! is_pitwo && ! is_pifour; then
    whiptail --msgbox "Only Pi 1, Pi 2, or Pi 4 can be overclocked with this tool." 20 60 2
    return 1
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "\
Be aware that overclocking may reduce the lifetime of your
Raspberry Pi. If overclocking at a certain level causes
system instability, try a more modest overclock. Hold down
shift during boot to temporarily disable overclock.
See https://www.raspberrypi.org/documentation/configuration/config-txt/overclocking.md for more information.\
" 20 70 1
   if is_pione; then
    OVERCLOCK=$(whiptail --menu "Choose overclock preset" 20 60 10 \
      "None" "700MHz ARM, 250MHz core, 400MHz SDRAM, 0 overvolt" \
      "Modest" "800MHz ARM, 250MHz core, 400MHz SDRAM, 0 overvolt" \
      "Medium" "900MHz ARM, 250MHz core, 450MHz SDRAM, 2 overvolt" \
      "High" "950MHz ARM, 250MHz core, 450MHz SDRAM, 6 overvolt" \
      "Turbo" "1000MHz ARM, 500MHz core, 600MHz SDRAM, 6 overvolt" \
      3>&1 1>&2 2>&3)
   elif is_pitwo; then
    OVERCLOCK=$(whiptail --menu "Choose overclock preset" 20 60 10 \
      "None" "900MHz ARM, 250MHz core, 450MHz SDRAM, 0 overvolt" \
      "High" "1000MHz ARM, 500MHz core, 500MHz SDRAM, 2 overvolt" \
      3>&1 1>&2 2>&3)
    elif is_pifour; then
        OVERCLOCK=$(whiptail --menu "Choose overclock preset" 20 60 10 \
            "None" "1500MHz ARM, 500MHz core, 3200MHz SDRAM, 0 overvolt" \
            "High" "1700MHz ARM, 600MHz core, 3200MHz SDRAM, 0 overvolt" \
            "Turbo" "2000MHz ARM, 700MHz core, 3200MHz SDRAM, 6 overvolt" \
        3>&1 1>&2 2>&3)
   fi
  else
    OVERCLOCK=$1
    true
  fi
  if [ $? -eq 0 ]; then
    case "$OVERCLOCK" in
      None)
        clear_overclock
        ;;
      Modest)
        set_overclock Modest 800 250 400 0
        ;;
      Medium)
        set_overclock Medium 900 250 450 2
        ;;
      High)
        if is_pione; then
          set_overclock High 950 250 450 6
        elif is_pitwo;
          set_overclock High 1000 500 500 2
          elif is_pifour;
          set_overclock High 1700 600 3200
        fi
        ;;
      Turbo)
      if is_pione; then
        set_overclock Turbo 1000 500 600 6
        elif is_pifour;
        set_overclock Turbo 2000 700 3200 6
        fi
        ;;
      *)
        whiptail --msgbox "Programmer error, unrecognised overclock preset" 20 60 2
        return 1
        ;;
    esac
    ASK_TO_REBOOT=1
  fi
}

set_overclock() {
  set_config_var arm_freq $2 $CONFIG &&
  set_config_var core_freq $3 $CONFIG &&
  set_config_var sdram_freq $4 $CONFIG &&
  set_config_var over_voltage $5 $CONFIG &&
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "Set overclock to preset '$1'" 20 60 2
  fi
}

clear_overclock () {
  clear_config_var arm_freq $CONFIG &&
  clear_config_var core_freq $CONFIG &&
  clear_config_var sdram_freq $CONFIG &&
  clear_config_var over_voltage $CONFIG &&
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "Set overclock to preset 'None'" 20 60 2
  fi
}

get_ssh() {
  if service ssh status | grep -q inactive; then
    echo 1
  else
    echo 0
  fi
}

do_ssh() {
  if [ -e /var/log/regen_ssh_keys.log ] && ! grep -q "^finished" /var/log/regen_ssh_keys.log; then
    whiptail --msgbox "Initial ssh key generation still running. Please wait and try again." 20 60 2
    return 1
  fi
  DEFAULT=--defaultno
  if [ $(get_ssh) -eq 0 ]; then
    DEFAULT=
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno \
      "Would you like the SSH server to be enabled?\n\nCaution: Default and weak passwords are a security risk when SSH is enabled!" \
      $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq 0 ]; then
    ssh-keygen -A &&
    update-rc.d ssh enable &&
    invoke-rc.d ssh start &&
    STATUS=enabled
  elif [ $RET -eq 1 ]; then
    update-rc.d ssh disable &&
    invoke-rc.d ssh stop &&
    STATUS=disabled
  else
    return $RET
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "The SSH server is $STATUS" 20 60 1
  fi
}

get_vnc() {
  if systemctl status vncserver-x11-serviced.service  | grep -q -w active; then
    echo 0
  else
    echo 1
  fi
}

do_vnc() {
  DEFAULT=--defaultno
  if [ $(get_vnc) -eq 0 ]; then
    DEFAULT=
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like the VNC Server to be enabled?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq 0 ]; then
    if is_installed realvnc-vnc-server || apt-get install realvnc-vnc-server; then
      systemctl enable vncserver-x11-serviced.service &&
      systemctl start vncserver-x11-serviced.service &&
      STATUS=enabled
    else
      return 1
    fi
  elif [ $RET -eq 1 ]; then
    if is_installed realvnc-vnc-server; then
        systemctl disable vncserver-x11-serviced.service
        systemctl stop vncserver-x11-serviced.service
    fi
    STATUS=disabled
  else
    return $RET
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "The VNC Server is $STATUS" 20 60 1
  fi
}

get_spi() {
  if grep -q -E "^(device_tree_param|dtparam)=([^,]*,)*spi(=(on|true|yes|1))?(,.*)?$" $CONFIG; then
    echo 0
  else
    echo 1
  fi
}

do_spi() {
  DEFAULT=--defaultno
  if [ $(get_spi) -eq 0 ]; then
    DEFAULT=
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like the SPI interface to be enabled?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq 0 ]; then
    SETTING=on
    STATUS=enabled
  elif [ $RET -eq 1 ]; then
    SETTING=off
    STATUS=disabled
  else
    return $RET
  fi

  set_config_var dtparam=spi $SETTING $CONFIG &&
  if ! [ -e $BLACKLIST ]; then
    touch $BLACKLIST
  fi
  sed $BLACKLIST -i -e "s/^\(blacklist[[:space:]]*spi[-_]bcm2708\)/#\1/"
  dtparam spi=$SETTING

  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "The SPI interface is $STATUS" 20 60 1
  fi
}

get_i2c() {
  if grep -q -E "^(device_tree_param|dtparam)=([^,]*,)*i2c(_arm)?(=(on|true|yes|1))?(,.*)?$" $CONFIG; then
    echo 0
  else
    echo 1
  fi
}

do_i2c() {
  DEFAULT=--defaultno
  if [ $(get_i2c) -eq 0 ]; then
    DEFAULT=
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like the ARM I2C interface to be enabled?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq 0 ]; then
    SETTING=on
    STATUS=enabled
  elif [ $RET -eq 1 ]; then
    SETTING=off
    STATUS=disabled
  else
    return $RET
  fi

  set_config_var dtparam=i2c_arm $SETTING $CONFIG &&
  if ! [ -e $BLACKLIST ]; then
    touch $BLACKLIST
  fi
  sed $BLACKLIST -i -e "s/^\(blacklist[[:space:]]*i2c[-_]bcm2708\)/#\1/"
  sed /etc/modules -i -e "s/^#[[:space:]]*\(i2c[-_]dev\)/\1/"
  if ! grep -q "^i2c[-_]dev" /etc/modules; then
    printf "i2c-dev\n" >> /etc/modules
  fi
  dtparam i2c_arm=$SETTING
  modprobe i2c-dev

  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "The ARM I2C interface is $STATUS" 20 60 1
  fi
}

get_serial() {
  if grep -q -E "console=(serial0|ttyAMA0|ttyS0)" $CMDLINE ; then
    echo 0
  else
    echo 1
  fi
}

get_serial_hw() {
  if grep -q -E "^enable_uart=1" $CONFIG ; then
    echo 0
  elif grep -q -E "^enable_uart=0" $CONFIG ; then
    echo 1
  elif [ -e /dev/serial0 ] ; then
    echo 0
  else
    echo 1
  fi
}

do_serial() {
  DEFAULTS=--defaultno
  DEFAULTH=--defaultno
  CURRENTS=0
  CURRENTH=0
  if [ $(get_serial) -eq 0 ]; then
      DEFAULTS=
      CURRENTS=1
  fi
  if [ $(get_serial_hw) -eq 0 ]; then
      DEFAULTH=
      CURRENTH=1
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like a login shell to be accessible over serial?" $DEFAULTS 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq $CURRENTS ]; then
    ASK_TO_REBOOT=1
  fi
  if [ $RET -eq 0 ]; then
    if grep -q "console=ttyAMA0" $CMDLINE ; then
      if [ -e /proc/device-tree/aliases/serial0 ]; then
        sed -i $CMDLINE -e "s/console=ttyAMA0/console=serial0/"
      fi
    elif ! grep -q "console=ttyAMA0" $CMDLINE && ! grep -q "console=serial0" $CMDLINE ; then
      if [ -e /proc/device-tree/aliases/serial0 ]; then
        sed -i $CMDLINE -e "s/root=/console=serial0,115200 root=/"
      else
        sed -i $CMDLINE -e "s/root=/console=ttyAMA0,115200 root=/"
      fi
    fi
    set_config_var enable_uart 1 $CONFIG
    SSTATUS=enabled
    HSTATUS=enabled
  elif [ $RET -eq 1 ] || [ $RET -eq 2 ]; then
    sed -i $CMDLINE -e "s/console=ttyAMA0,[0-9]\+ //"
    sed -i $CMDLINE -e "s/console=serial0,[0-9]\+ //"
    SSTATUS=disabled
    if [ "$INTERACTIVE" = True ]; then
      whiptail --yesno "Would you like the serial port hardware to be enabled?" $DEFAULTH 20 60 2
      RET=$?
    else
      RET=$((2-$RET))
    fi
    if [ $RET -eq $CURRENTH ]; then
     ASK_TO_REBOOT=1
    fi
    if [ $RET -eq 0 ]; then
      set_config_var enable_uart 1 $CONFIG
      HSTATUS=enabled
    elif [ $RET -eq 1 ]; then
      set_config_var enable_uart 0 $CONFIG
      HSTATUS=disabled
    else
      return $RET
    fi
  else
    return $RET
  fi
  if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "The serial login shell is $SSTATUS\nThe serial interface is $HSTATUS" 20 60 1
  fi
}

disable_raspi_config_at_boot() {
  if [ -e /etc/profile.d/raspi-config.sh ]; then
    rm -f /etc/profile.d/raspi-config.sh
    if [ -e /etc/systemd/system/getty@tty1.service.d/raspi-config-override.conf ]; then
      rm /etc/systemd/system/getty@tty1.service.d/raspi-config-override.conf
    fi
    telinit q
  fi
}

get_boot_cli() {
  if systemctl get-default | grep -q multi-user ; then
    echo 0
  else
    echo 1
  fi
}

get_autologin() {
  if [ $(get_boot_cli) -eq 0 ]; then
    # booting to CLI
    # stretch or buster - is there an autologin conf file?
    if [ -e /etc/systemd/system/getty@tty1.service.d/autologin.conf ] ; then
      echo 0
    else
      # stretch or earlier - check the getty service symlink for autologin
      if [ $(deb_ver) -le 9 ] && grep -q autologin /etc/systemd/system/getty.target.wants/getty@tty1.service ; then
        echo 0
      else
        echo 1
      fi
    fi
  else
    # booting to desktop - check the autologin for lightdm
    if grep -q "^autologin-user=" /etc/lightdm/lightdm.conf ; then
      echo 0
    else
      echo 1
    fi
  fi
}

get_pi4video () {
  if grep -q "^hdmi_enable_4kp60=1" $CONFIG ; then
    echo 1
  elif grep -q "^enable_tvout=1" $CONFIG ; then
    echo 2
  else
    echo 0
  fi
}

do_pi4video() {
  if ! is_pifour ; then
    if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "This option can only be used on a Pi 4" 20 60 1
    fi
    return 1
  fi
  CURRENT=$(get_pi4video)
  if [ "$INTERACTIVE" = True ]; then
    VIDOPT=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Pi 4 Video Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
      "V1 Enable 4Kp60 HDMI" "Enable 4Kp60 resolution on HDMI0 (disables analog)" \
      "V2 Enable analog TV output" "Enable composite video output (disables 4Kp60)" \
      "V3 Disable both 4Kp60 and analog" "Disable 4Kp60 HDMI and composite video" \
      3>&1 1>&2 2>&3)
  else
    VIDOPT=$1
    true
  fi
  if [ $? -eq 0 ]; then
    case "$VIDOPT" in
      V1*)
        sed $CONFIG -i -e "s/^#\?hdmi_enable_4kp60=.*/hdmi_enable_4kp60=1/"
        sed $CONFIG -i -e "s/^enable_tvout=/#enable_tvout=/"
        if ! grep -q "hdmi_enable_4kp60" $CONFIG ; then
            sed $CONFIG -i -e "\$ahdmi_enable_4kp60=1"
        fi
        STATUS="4Kp60 HDMI enabled"
        OPT=1
        ;;
      V2*)
        sed $CONFIG -i -e "s/^#\?enable_tvout=.*/enable_tvout=1/"
        sed $CONFIG -i -e "s/^hdmi_enable_4kp60=/#hdmi_enable_4kp60=/"
        if ! grep -q "enable_tvout" $CONFIG ; then
            sed $CONFIG -i -e "\$aenable_tvout=1"
        fi
        STATUS="analog TV enabled"
        OPT=2
        ;;
      V3*)
        sed $CONFIG -i -e "s/^hdmi_enable_4kp60=/#hdmi_enable_4kp60=/"
        sed $CONFIG -i -e "s/^enable_tvout=/#enable_tvout=/"
        STATUS="4K and analog disabled"
        OPT=0
        ;;
      *)
        whiptail --msgbox "Programmer error, unrecognised video option" 20 60 2
        return 1
        ;;
    esac
    if [ $OPT -ne $CURRENT ]; then
      ASK_TO_REBOOT=1
    fi
    if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "Pi 4 video output option is $STATUS" 20 60 1
    fi
  fi
}

get_leds () {
  if grep -q "\\[actpwr\\]" /sys/class/leds/led0/trigger ; then
    echo 0
  elif grep -q "\\[default-on\\]" /sys/class/leds/led0/trigger ; then
    echo 1
  else
    echo -1
  fi
}

do_leds() {
  CURRENT=$(get_leds)
  if [ $CURRENT -eq -1 ] ; then
    if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "The LED behaviour cannot be changed on this model of Raspberry Pi" 20 60 1
    fi
    return 1
  fi
  DEFAULT=--defaultno
  if [ $CURRENT -eq 0 ]; then
    DEFAULT=
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like the power LED to flash during disk activity?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq 0 ]; then
    LEDSET="actpwr"
    STATUS="flash for disk activity"
  elif [ $RET -eq 1 ]; then
    LEDSET="default-on"
    STATUS="be on constantly"
  else
    return $RET
  fi
  sed $CONFIG -i -e "s/dtparam=act_led_trigger=.*/dtparam=act_led_trigger=$LEDSET/"
  if ! grep -q "dtparam=act_led_trigger" $CONFIG ; then
    sed $CONFIG -i -e "\$adtparam=act_led_trigger=$LEDSET"
  fi
  echo $LEDSET | tee /sys/class/leds/led0/trigger > /dev/null
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "The power LED will $STATUS" 20 60 1
  fi
}

get_fan() {
  if grep -q ^dtoverlay=gpio-fan $CONFIG ; then
    echo 0
  else
    echo 1
  fi
}

get_fan_gpio() {
  GPIO=$(grep ^dtoverlay=gpio-fan $CONFIG | cut -d, -f2 | cut -d= -f2)
  if [ -z $GPIO ]; then
    GPIO=14
  fi
  echo $GPIO
}

get_fan_temp() {
  TEMP=$(grep ^dtoverlay=gpio-fan $CONFIG | cut -d, -f3 | cut -d= -f2)
  if [ -z $TEMP ]; then
    TEMP=80000
  fi
  echo $(( $TEMP / 1000 ))
}

do_fan() {
  GNOW=$(get_fan_gpio)
  TNOW=$(get_fan_temp)
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like to enable fan temperature control?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq 0 ] ; then
    if [ "$INTERACTIVE" = True ]; then
      GPIO=$(whiptail --inputbox "To which GPIO is the fan connected?" 20 60 "$GNOW" 3>&1 1>&2 2>&3)
    else
      if [ -z $2 ]; then
        GPIO=14
      else
        GPIO=$2
      fi
    fi
    if ! [ $? -eq 0 ] ; then
      return 0
    fi
    if ! echo "$GPIO" | grep -q ^[[:digit:]]*$ ; then
      if [ "$INTERACTIVE" = True ]; then
        whiptail --msgbox "GPIO must be a number between 2 and 27" 20 60 1
      fi
      return 1
    fi
    if [ "$GPIO" -lt 2 ] || [ "$GPIO" -gt 27 ]  ; then
      if [ "$INTERACTIVE" = True ]; then
        whiptail --msgbox "GPIO must be a number between 2 and 27" 20 60 1
      fi
      return 1
    fi
    if [ "$INTERACTIVE" = True ]; then
      TIN=$(whiptail --inputbox "At what temperature in degrees should the fan turn on?" 20 60 "$TNOW" 3>&1 1>&2 2>&3)
    else
      if [ -z $3 ]; then
        TIN=80
      else
        TIN=$3
      fi
    fi
    if ! [ $? -eq 0 ] ; then
      return 0
    fi
    if ! echo "$TIN" | grep -q ^[[:digit:]]*$ ; then
      if [ "$INTERACTIVE" = True ]; then
        whiptail --msgbox "Temperature must be a number between 60 and 120" 20 60 1
      fi
      return 1
    fi
    if [ "$TIN" -lt 60 ] || [ "$TIN" -gt 120 ]  ; then
      if [ "$INTERACTIVE" = True ]; then
        whiptail --msgbox "Temperature must be a number between 60 and 120" 20 60 1
      fi
      return 1
    fi
    TEMP=$(( $TIN * 1000 ))
  fi
  if [ $RET -eq 0 ]; then
    if ! grep -q "dtoverlay=gpio-fan" $CONFIG ; then
      if ! tail -1 $CONFIG | grep -q "\\[all\\]" ; then
        sed $CONFIG -i -e "\$a[all]"
      fi
      sed $CONFIG -i -e "\$adtoverlay=gpio-fan,gpiopin=$GPIO,temp=$TEMP"
    else
      sed $CONFIG -i -e "s/^.*dtoverlay=gpio-fan.*/dtoverlay=gpio-fan,gpiopin=$GPIO,temp=$TEMP/"
    fi
    ASK_TO_REBOOT=1
    if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "The fan on GPIO $GPIO is enabled and will turn on at $TIN degrees" 20 60 1
    fi
  else
    if grep -q "^dtoverlay=gpio-fan" $CONFIG ; then
      ASK_TO_REBOOT=1
    fi
    sed $CONFIG -i -e "/^.*dtoverlay=gpio-fan.*/d"
    if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "The fan is disabled" 20 60 1
    fi
  fi
}

do_boot_behaviour() {
  if [ "$INTERACTIVE" = True ]; then
    BOOTOPT=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Boot Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
      "B1 Console" "Text console, requiring user to login" \
      "B2 Console Autologin" "Text console, automatically logged in as '$USER' user" \
      "B3 Desktop" "Desktop GUI, requiring user to login" \
      "B4 Desktop Autologin" "Desktop GUI, automatically logged in as '$USER' user" \
      3>&1 1>&2 2>&3)
  else
    BOOTOPT=$1
    true
  fi
  if [ $? -eq 0 ]; then
    case "$BOOTOPT" in
      B1*)
        systemctl set-default multi-user.target
        ln -fs /lib/systemd/system/getty@.service /etc/systemd/system/getty.target.wants/getty@tty1.service
        rm /etc/systemd/system/getty@tty1.service.d/autologin.conf
        ;;
      B2*)
        systemctl set-default multi-user.target
        ln -fs /lib/systemd/system/getty@.service /etc/systemd/system/getty.target.wants/getty@tty1.service
        cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER --noclear %I \$TERM
EOF
        ;;
      B3*)
        if [ -e /etc/init.d/lightdm ]; then
          systemctl set-default graphical.target
          ln -fs /lib/systemd/system/getty@.service /etc/systemd/system/getty.target.wants/getty@tty1.service
          rm /etc/systemd/system/getty@tty1.service.d/autologin.conf
          sed /etc/lightdm/lightdm.conf -i -e "s/^autologin-user=.*/#autologin-user=/"
          disable_raspi_config_at_boot
        else
          whiptail --msgbox "Do 'sudo apt-get install lightdm' to allow configuration of boot to desktop" 20 60 2
          return 1
        fi
        ;;
      B4*)
        if [ -e /etc/init.d/lightdm ]; then
          systemctl set-default graphical.target
          ln -fs /lib/systemd/system/getty@.service /etc/systemd/system/getty.target.wants/getty@tty1.service
          cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER --noclear %I \$TERM
EOF
          sed /etc/lightdm/lightdm.conf -i -e "s/^\(#\|\)autologin-user=.*/autologin-user=$USER/"
          disable_raspi_config_at_boot
        else
          whiptail --msgbox "Do 'sudo apt-get install lightdm' to allow configuration of boot to desktop" 20 60 2
          return 1
        fi
        ;;
      *)
        whiptail --msgbox "Programmer error, unrecognised boot option" 20 60 2
        return 1
        ;;
    esac
    ASK_TO_REBOOT=1
  fi
}

do_boot_order() {
  if [ "$INTERACTIVE" = True ]; then
    BOOTOPT=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Boot Device Order" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
      "B1 USB Boot" "Boot from USB device if SD card boot fails" \
      "B2 Network Boot" "Boot from network if SD card boot fails" \
      3>&1 1>&2 2>&3)
  else
    BOOTOPT=$1
    true
  fi
  if [ $? -eq 0 ]; then
    CURDATE=$(date -d "`vcgencmd bootloader_version |  head -n 1`" +%Y%m%d)
    FILNAME="none"
    if grep -q "stable" /etc/default/rpi-eeprom-update ; then
      EEPATH="/lib/firmware/raspberrypi/bootloader/stable/pieeprom*.bin"
    else
      EEPATH="/lib/firmware/raspberrypi/bootloader/critical/pieeprom*.bin"
    fi
    for filename in $EEPATH ; do
      FILDATE=$(date -d "`echo $filename | cut -d - -f 2- | cut -d . -f 1`" +%Y%m%d)
      if [ $FILDATE -eq $CURDATE ]; then
        FILNAME=$filename
      fi
    done
    if [ "$FILNAME" = "none" ]; then
      if [ "$INTERACTIVE" = True ]; then
        whiptail --msgbox "No EEPROM bin file found for version `date -d $CURDATE +%Y-%m-%d` - aborting" 20 60 2
      fi
      return 1
    fi
    EECFG=$(mktemp)
    vcgencmd bootloader_config > $EECFG
    sed $EECFG -i -e "/SD_BOOT_MAX_RETRIES/d"
    sed $EECFG -i -e "/NET_BOOT_MAX_RETRIES/d"
    case "$BOOTOPT" in
      B1*)
        if ! grep -q "BOOT_ORDER" $EECFG ; then
          sed $EECFG -i -e "\$a[all]\nBOOT_ORDER=0xf41"
        else
          sed $EECFG -i -e "s/^BOOT_ORDER=.*/BOOT_ORDER=0xf41/"
        fi
        STATUS="USB device"
        ;;
      B2*)
        if ! grep -q "BOOT_ORDER" $EECFG ; then
          sed $EECFG -i -e "\$a[all]\nBOOT_ORDER=0xf21"
        else
          sed $EECFG -i -e "s/^BOOT_ORDER=.*/BOOT_ORDER=0xf21/"
        fi
        STATUS="Network"
        ;;
      *)
        whiptail --msgbox "Programmer error, unrecognised boot option" 20 60 2
        return 1
        ;;
    esac
    EEBIN=$(mktemp)
    rpi-eeprom-config --config $EECFG --out $EEBIN $FILNAME
    rpi-eeprom-update -d -f $EEBIN
    ASK_TO_REBOOT=1
    if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "$STATUS is default boot device" 20 60 1
    fi
  fi
}


do_boot_rom() {
  if [ "$INTERACTIVE" = True ]; then
    BOOTOPT=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Boot ROM Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
      "E1 Latest" "Use the latest version boot ROM software" \
      "E2 Default" "Use the factory default boot ROM software" \
      3>&1 1>&2 2>&3)
  else
    BOOTOPT=$1
    true
  fi
  if [ $? -eq 0 ]; then
    case "$BOOTOPT" in
      E1*)
        sed /etc/default/rpi-eeprom-update -i -e "s/^FIRMWARE_RELEASE_STATUS.*/FIRMWARE_RELEASE_STATUS=\"stable\"/"
        EETYPE="Latest version"
        ;;
      E2*)
        sed /etc/default/rpi-eeprom-update -i -e "s/^FIRMWARE_RELEASE_STATUS.*/FIRMWARE_RELEASE_STATUS=\"critical\"/"
        EETYPE="Factory default"
        ;;
      *)
        whiptail --msgbox "Programmer error, unrecognised boot ROM option" 20 60 2
        return 1
        ;;
    esac
    if [ "$INTERACTIVE" = True ]; then
      whiptail --yesno "$EETYPE boot ROM selected - will be loaded at next reboot.\n\nReset boot ROM to defaults?" 20 60 2
      DEFAULTS=$?
     else
      DEFAULTS=$2
    fi
    if [ "$DEFAULTS" -eq 0 ]; then # yes
      if grep -q "stable" /etc/default/rpi-eeprom-update ; then
        EEPATH="/lib/firmware/raspberrypi/bootloader/stable/"
      else
        EEPATH="/lib/firmware/raspberrypi/bootloader/critical/"
      fi
      MATCH=".*/pieeprom-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].bin"
      FILNAME="$(find "${EEPATH}" -maxdepth 1 -type f -size 524288c -regex "${MATCH}" | sort -r | head -n1)"
      if [ -z "$FILNAME" ]; then
        if [ "$INTERACTIVE" = True ]; then
          whiptail --msgbox "No EEPROM bin file found - cannot reset to defaults" 20 60 2
        fi
      else
        rpi-eeprom-update -d -f $FILNAME
        if [ "$INTERACTIVE" = True ]; then
          whiptail --msgbox "Boot ROM reset to defaults" 20 60 2
        fi
      fi
    else
      rpi-eeprom-update
      if [ "$INTERACTIVE" = True ]; then
        whiptail --msgbox "Boot ROM not reset to defaults" 20 60 2
      fi
    fi
    ASK_TO_REBOOT=1
  fi
}

get_boot_wait() {
  if test -e /etc/systemd/system/dhcpcd.service.d/wait.conf; then
    echo 0
  else
    echo 1
  fi
}

do_boot_wait() {
  DEFAULT=--defaultno
  if [ $(get_boot_wait) -eq 0 ]; then
    DEFAULT=
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like boot to wait until a network connection is established?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq 0 ]; then
    mkdir -p /etc/systemd/system/dhcpcd.service.d/
    cat > /etc/systemd/system/dhcpcd.service.d/wait.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/lib/dhcpcd5/dhcpcd -q -w
EOF
    STATUS=enabled
  elif [ $RET -eq 1 ]; then
    rm -f /etc/systemd/system/dhcpcd.service.d/wait.conf
    STATUS=disabled
  else
    return $RET
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "Waiting for network on boot is $STATUS" 20 60 1
  fi
}

get_boot_splash() {
  if is_pi ; then
    if grep -q "splash" $CMDLINE ; then
      echo 0
    else
      echo 1
    fi
  else
    if grep -q "GRUB_CMDLINE_LINUX_DEFAULT.*splash" /etc/default/grub ; then
      echo 0
    else
      echo 1
    fi
  fi
}

do_boot_splash() {
  if [ ! -e /usr/share/plymouth/themes/pix/pix.script ]; then
    if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "The splash screen is not installed so cannot be activated" 20 60 2
    fi
    return 1
  fi
  DEFAULT=--defaultno
  if [ $(get_boot_splash) -eq 0 ]; then
    DEFAULT=
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like to show the splash screen at boot?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq 0 ]; then
    if is_pi ; then
      if ! grep -q "splash" $CMDLINE ; then
        sed -i $CMDLINE -e "s/$/ quiet splash plymouth.ignore-serial-consoles/"
      fi
    else
      sed -i /etc/default/grub -e "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 quiet splash plymouth.ignore-serial-consoles\"/"
      sed -i /etc/default/grub -e "s/  \+/ /g"
      sed -i /etc/default/grub -e "s/GRUB_CMDLINE_LINUX_DEFAULT=\" /GRUB_CMDLINE_LINUX_DEFAULT=\"/"
      update-grub
    fi
    STATUS=enabled
  elif [ $RET -eq 1 ]; then
    if is_pi ; then
      if grep -q "splash" $CMDLINE ; then
        sed -i $CMDLINE -e "s/ quiet//"
        sed -i $CMDLINE -e "s/ splash//"
        sed -i $CMDLINE -e "s/ plymouth.ignore-serial-consoles//"
      fi
    else
      sed -i /etc/default/grub -e "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)quiet\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1\2\"/"
      sed -i /etc/default/grub -e "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)splash\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1\2\"/"
      sed -i /etc/default/grub -e "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)plymouth.ignore-serial-consoles\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1\2\"/"
      sed -i /etc/default/grub -e "s/  \+/ /g"
      sed -i /etc/default/grub -e "s/GRUB_CMDLINE_LINUX_DEFAULT=\" /GRUB_CMDLINE_LINUX_DEFAULT=\"/"
      update-grub
    fi
    STATUS=disabled
  else
    return $RET
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "Splash screen at boot is $STATUS" 20 60 1
  fi
}

get_rgpio() {
  if test -e /etc/systemd/system/pigpiod.service.d/public.conf; then
    echo 0
  else
    echo 1
  fi
}

do_rgpio() {
  DEFAULT=--defaultno
  if [ $(get_rgpio) -eq 0 ]; then
    DEFAULT=
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like the GPIO server to be accessible over the network?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq 0 ]; then
    mkdir -p /etc/systemd/system/pigpiod.service.d/
    cat > /etc/systemd/system/pigpiod.service.d/public.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/bin/pigpiod
EOF
    STATUS=enabled
  elif [ $RET -eq 1 ]; then
    rm -f /etc/systemd/system/pigpiod.service.d/public.conf
    STATUS=disabled
  else
    return $RET
  fi
  systemctl daemon-reload
  if systemctl -q is-enabled pigpiod ; then
    systemctl restart pigpiod
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "Remote access to the GPIO server is $STATUS" 20 60 1
  fi
}

get_camera() {
  CAM=$(get_config_var start_x $CONFIG)
  if [ $CAM -eq 1 ]; then
    echo 0
  else
    echo 1
  fi
}

do_camera() {
  if [ ! -e /boot/start_x.elf ]; then
    whiptail --msgbox "Your firmware appears to be out of date (no start_x.elf). Please update" 20 60 2
    return 1
  fi
  sed $CONFIG -i -e "s/^startx/#startx/"
  sed $CONFIG -i -e "s/^fixup_file/#fixup_file/"

  DEFAULT=--defaultno
  CURRENT=0
  if [ $(get_camera) -eq 0 ]; then
      DEFAULT=
      CURRENT=1
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like the camera interface to be enabled?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq $CURRENT ]; then
    ASK_TO_REBOOT=1
  fi
  if [ $RET -eq 0 ]; then
    set_config_var start_x 1 $CONFIG
    CUR_GPU_MEM=$(get_config_var gpu_mem $CONFIG)
    if [ -z "$CUR_GPU_MEM" ] || [ "$CUR_GPU_MEM" -lt 128 ]; then
      set_config_var gpu_mem 128 $CONFIG
    fi
    STATUS=enabled
  elif [ $RET -eq 1 ]; then
    set_config_var start_x 0 $CONFIG
    sed $CONFIG -i -e "s/^start_file/#start_file/"
    STATUS=disabled
  else
    return $RET
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "The camera interface is $STATUS" 20 60 1
  fi
}

get_onewire() {
  if grep -q -E "^dtoverlay=w1-gpio" $CONFIG; then
    echo 0
  else
    echo 1
  fi
}

do_onewire() {
  DEFAULT=--defaultno
  CURRENT=0
  if [ $(get_onewire) -eq 0 ]; then
    DEFAULT=
    CURRENT=1
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like the one-wire interface to be enabled?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq $CURRENT ]; then
    ASK_TO_REBOOT=1
  fi
  if [ $RET -eq 0 ]; then
    sed $CONFIG -i -e "s/^#dtoverlay=w1-gpio/dtoverlay=w1-gpio/"
    if ! grep -q -E "^dtoverlay=w1-gpio" $CONFIG; then
      printf "dtoverlay=w1-gpio\n" >> $CONFIG
    fi
    STATUS=enabled
  elif [ $RET -eq 1 ]; then
    sed $CONFIG -i -e "s/^dtoverlay=w1-gpio/#dtoverlay=w1-gpio/"
    STATUS=disabled
  else
    return $RET
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "The one-wire interface is $STATUS" 20 60 1
  fi
}

do_gldriver() {
  if [ ! -e /boot/overlays/vc4-kms-v3d.dtbo ]; then
    whiptail --msgbox "Driver and kernel not present on your system. Please update" 20 60 2
    return 1
  fi
  for package in gldriver-test libgl1-mesa-dri; do
    if [ "$(dpkg -l "$package" 2> /dev/null | tail -n 1 | cut -d ' ' -f 1)" != "ii" ]; then
      missing_packages="$package $missing_packages"
    fi
  done
  if [ -n "$missing_packages" ] && ! apt-get install $missing_packages; then
    whiptail --msgbox "Required packages not found, please install: ${missing_packages}" 20 60 2
    return 1
  fi
  if is_pifour ; then
  GLOPT=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "GL Driver" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
    "G1 Legacy" "Original non-GL desktop driver" \
    "G2 GL (Fake KMS)" "OpenGL desktop driver with fake KMS" \
    3>&1 1>&2 2>&3)
  else
  GLOPT=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "GL Driver" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
    "G1 Legacy" "Original non-GL desktop driver" \
    "G2 GL (Fake KMS)" "OpenGL desktop driver with fake KMS" \
    "G3 GL (Full KMS)" "OpenGL desktop driver with full KMS" \
    3>&1 1>&2 2>&3)
  fi
  if [ $? -eq 0 ]; then
    case "$GLOPT" in
      G1*)
        if is_pifour ; then
          if grep -q -E "^dtoverlay=vc4-f?kms-v3d" $CONFIG; then
            ASK_TO_REBOOT=1
          fi
        else
          if sed -n "/\[pi4\]/,/\[/ !p" $CONFIG | grep -q -E "^dtoverlay=vc4-f?kms-v3d" ; then
            ASK_TO_REBOOT=1
          fi
        fi
        sed $CONFIG -i -e "s/^dtoverlay=vc4-kms-v3d/#dtoverlay=vc4-kms-v3d/g"
        sed $CONFIG -i -e "s/^dtoverlay=vc4-fkms-v3d/#dtoverlay=vc4-fkms-v3d/g"
        STATUS="The GL driver is disabled."
        ;;
      G2*)
        if is_pifour ; then
          if ! grep -q -E "^dtoverlay=vc4-fkms-v3d" $CONFIG; then
            ASK_TO_REBOOT=1
          fi
        else
          if ! sed -n "/\[pi4\]/,/\[/ !p" $CONFIG | grep -q "^dtoverlay=vc4-fkms-v3d" ; then
            ASK_TO_REBOOT=1
          fi
        fi
        sed $CONFIG -i -e "s/^dtoverlay=vc4-kms-v3d/#dtoverlay=vc4-kms-v3d/g"
        sed $CONFIG -i -e "s/^#dtoverlay=vc4-fkms-v3d/dtoverlay=vc4-fkms-v3d/g"
        if ! sed -n "/\[pi4\]/,/\[/ !p" $CONFIG | grep -q "^dtoverlay=vc4-fkms-v3d" ; then
          printf "[all]\ndtoverlay=vc4-fkms-v3d\n" >> $CONFIG
        fi
        STATUS="The fake KMS GL driver is enabled."
        ;;
      G3*)
        if ! sed -n "/\[pi4\]/,/\[/ !p" $CONFIG | grep -q "^dtoverlay=vc4-kms-v3d" ; then
          ASK_TO_REBOOT=1
        fi
        sed $CONFIG -i -e "s/^dtoverlay=vc4-fkms-v3d/#dtoverlay=vc4-fkms-v3d/g"
        sed $CONFIG -i -e "s/^#dtoverlay=vc4-kms-v3d/dtoverlay=vc4-kms-v3d/g"
        if ! sed -n "/\[pi4\]/,/\[/ !p" $CONFIG | grep -q "^dtoverlay=vc4-kms-v3d" ; then
          printf "[all]\ndtoverlay=vc4-kms-v3d\n" >> $CONFIG
        fi
        STATUS="The full KMS GL driver is enabled."
        ;;
      *)
        whiptail --msgbox "Programmer error, unrecognised boot option" 20 60 2
        return 1
        ;;
    esac
  else
    return 0
  fi
  whiptail --msgbox "$STATUS" 20 60 1
}

do_xcompmgr() {
  DEFAULT=--defaultno
  CURRENT=0
  if [ -e /etc/xdg/autostart/xcompmgr.desktop ]; then
    DEFAULT=
    CURRENT=1
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like the xcompmgr composition manager to be enabled?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq $CURRENT ]; then
    ASK_TO_REBOOT=1
  fi
  if [ $RET -eq 0 ]; then
    if [ ! -e /usr/bin/xcompmgr ] ; then
      apt-get -y install xcompmgr
    fi
    cat << EOF > /etc/xdg/autostart/xcompmgr.desktop
[Desktop Entry]
Type=Application
Name=xcompmgr
Comment=Start xcompmgr compositor
NoDisplay=true
Exec=/usr/lib/raspi-config/cmstart.sh
EOF
    STATUS=enabled
  elif [ $RET -eq 1 ]; then
    if [ -e /etc/xdg/autostart/xcompmgr.desktop ]; then
      rm /etc/xdg/autostart/xcompmgr.desktop
    fi
    STATUS=disabled
  else
    return $RET
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "The xcompmgr composition manager is $STATUS" 20 60 1
  fi
}

get_net_names() {
  if grep -q "net.ifnames=0" $CMDLINE || [ "$(readlink -f /etc/systemd/network/99-default.link)" = "/dev/null" ] ; then
    echo 1
  else
    echo 0
  fi
}

do_net_names () {
  DEFAULT=--defaultno
  CURRENT=0
  if [ $(get_net_names) -eq 0 ]; then
    DEFAULT=
    CURRENT=1
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like to enable predictable network interface names?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq $CURRENT ]; then
    ASK_TO_REBOOT=1
  fi
  if [ $RET -eq 0 ]; then
    sed -i $CMDLINE -e "s/net.ifnames=0 *//"
    rm -f /etc/systemd/network/99-default.link
    STATUS=enabled
  elif [ $RET -eq 1 ]; then
    ln -sf /dev/null /etc/systemd/network/99-default.link
    STATUS=disabled
  else
    return $RET
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "Predictable network interface names are $STATUS" 20 60 1
  fi
 }

do_update() {
  apt-get update &&
  apt-get install raspi-config &&
  printf "Sleeping 5 seconds before reloading raspi-config\n" &&
  sleep 5 &&
  exec raspi-config
}

do_audio() {
  if is_pulseaudio ; then
    oIFS="$IFS"
    if [ "$INTERACTIVE" = True ]; then
      list=$(sudo -u $SUDO_USER XDG_RUNTIME_DIR=/run/user/$SUDO_UID pacmd list-sinks | grep -e index -e alsa.name | sed s/*//g | sed s/^[' '\\t]*//g | sed s/'index: '//g | sed s/'alsa.name = '//g | sed s/'bcm2835 '//g | sed s/\"//g | tr '\n' '/')
      if ! [ -z "$list" ] ; then
        IFS="/"
        AUDIO_OUT=$(whiptail --menu "Choose the audio output" 20 60 10 ${list} 3>&1 1>&2 2>&3)
      else
        whiptail --msgbox "No internal audio devices found" 20 60 1
        return 1
      fi
    else
      AUDIO_OUT=$1
      true
    fi
    if [ $? -eq 0 ]; then
      sudo -u $SUDO_USER XDG_RUNTIME_DIR=/run/user/$SUDO_UID pactl set-default-sink $AUDIO_OUT
    fi
    IFS=$oIFS
  else
    if aplay -l | grep -q "bcm2835 ALSA"; then
      if [ "$INTERACTIVE" = True ]; then
        AUDIO_OUT=$(whiptail --menu "Choose the audio output" 20 60 10 \
          "0" "Auto" \
          "1" "Force 3.5mm ('headphone') jack" \
          "2" "Force HDMI" \
          3>&1 1>&2 2>&3)
      else
        AUDIO_OUT=$1
      fi
      if [ $? -eq 0 ]; then
        amixer cset numid=3 "$AUDIO_OUT"
      fi
    else
      ASPATH=$(getent passwd $USER | cut -d : -f 6)/.asoundrc
      if [ "$INTERACTIVE" = True ]; then
        CARD0=$(LC_ALL=C aplay -l | grep bcm2835 | grep "card 0" | cut -d [ -f 3 | cut -d ] -f 1 | cut -d ' ' -f 2-)
        CARD1=$(LC_ALL=C aplay -l | grep bcm2835 | grep "card 1" | cut -d [ -f 3 | cut -d ] -f 1 | cut -d ' ' -f 2-)
        CARD2=$(LC_ALL=C aplay -l | grep bcm2835 | grep "card 2" | cut -d [ -f 3 | cut -d ] -f 1 | cut -d ' ' -f 2-)
        if ! [ -z "$CARD2" ]; then
          AUDIO_OUT=$(whiptail --menu "Choose the audio output" 20 60 10 \
            "0" "$CARD0" \
            "1" "$CARD1" \
            "2" "$CARD2" \
            3>&1 1>&2 2>&3)
        elif ! [ -z "$CARD1" ]; then
          AUDIO_OUT=$(whiptail --menu "Choose the audio output" 20 60 10 \
            "0" "$CARD0" \
            "1" "$CARD1" \
            3>&1 1>&2 2>&3)
        elif ! [ -z "$CARD0" ]; then
          AUDIO_OUT=$(whiptail --menu "Choose the audio output" 20 60 10 \
            "0" "$CARD0" \
            3>&1 1>&2 2>&3)
        else
          whiptail --msgbox "No internal audio devices found" 20 60 1
          false
        fi
      else
        AUDIO_OUT=$1
      fi
      if [ $? -eq 0 ]; then
        cat << EOF > $ASPATH
pcm.!default {
  type asym
  playback.pcm {
    type plug
    slave.pcm "output"
  }
  capture.pcm {
    type plug
    slave.pcm "input"
  }
}

pcm.output {
  type hw
  card $AUDIO_OUT
}

ctl.!default {
  type hw
  card $AUDIO_OUT
}
EOF
      fi
    fi
  fi
}

do_resolution() {
  if [ "$INTERACTIVE" = True ]; then
    CMODE=$(get_config_var hdmi_mode $CONFIG)
    CGROUP=$(get_config_var hdmi_group $CONFIG)
    if [ $CMODE -eq 0 ] ; then
      CSET="Default"
    elif [ $CGROUP -eq 2 ] ; then
      CSET="DMT Mode "$CMODE
    else
      CSET="CEA Mode "$CMODE
    fi
    oIFS="$IFS"
    IFS="/"
    if tvservice -d /dev/null | grep -q Nothing ; then
      value="Default/720x480/DMT Mode 4/640x480 60Hz 4:3/DMT Mode 9/800x600 60Hz 4:3/DMT Mode 16/1024x768 60Hz 4:3/DMT Mode 85/1280x720 60Hz 16:9/DMT Mode 35/1280x1024 60Hz 5:4/DMT Mode 51/1600x1200 60Hz 4:3/DMT Mode 82/1920x1080 60Hz 16:9/"
    else
      value="Default/Monitor preferred resolution/"
      value=$value$(tvservice -m CEA | grep progressive | cut -b 12- | sed 's/mode \([0-9]\+\): \([0-9]\+\)x\([0-9]\+\) @ \([0-9]\+\)Hz \([0-9]\+\):\([0-9]\+\), clock:[0-9]\+MHz progressive/CEA Mode \1\/\2x\3 \4Hz \5:\6/' | tr '\n' '/')
      value=$value$(tvservice -m DMT | grep progressive | cut -b 12- | sed 's/mode \([0-9]\+\): \([0-9]\+\)x\([0-9]\+\) @ \([0-9]\+\)Hz \([0-9]\+\):\([0-9]\+\), clock:[0-9]\+MHz progressive/DMT Mode \1\/\2x\3 \4Hz \5:\6/' | tr '\n' '/')
    fi
    RES=$(whiptail --default-item $CSET --menu "Choose screen resolution" 20 60 10 ${value} 3>&1 1>&2 2>&3)
    STATUS=$?
    IFS=$oIFS
    if [ $STATUS -eq 0 ] ; then
      GRS=$(echo "$RES" | cut -d ' ' -f 1)
      MODE=$(echo "$RES" | cut -d ' ' -f 3)
      if [ $GRS = "Default" ] ; then
        MODE=0
      elif [ $GRS = "DMT" ] ; then
        GROUP=2
      else
        GROUP=1
      fi
    fi
  else
    GROUP=$1
    MODE=$2
    STATUS=0
  fi
  if [ $STATUS -eq 0 ]; then
    if [ $MODE -eq 0 ]; then
      clear_config_var hdmi_force_hotplug $CONFIG
      clear_config_var hdmi_group $CONFIG
      clear_config_var hdmi_mode $CONFIG
    else
      set_config_var hdmi_force_hotplug 1 $CONFIG
      set_config_var hdmi_group $GROUP $CONFIG
      set_config_var hdmi_mode $MODE $CONFIG
    fi
    if [ "$INTERACTIVE" = True ]; then
      if [ $MODE -eq 0 ] ; then
        whiptail --msgbox "The resolution is set to default" 20 60 1
      else
        whiptail --msgbox "The resolution is set to $GRS mode $MODE" 20 60 1
      fi
    fi
    if [ $MODE -eq 0 ] ; then
      TSET="Default"
    elif [ $GROUP -eq 2 ] ; then
      TSET="DMT Mode "$MODE
    else
      TSET="CEA Mode "$MODE
    fi
    if [ "$TSET" != "$CSET" ] ; then
      ASK_TO_REBOOT=1
    fi
  fi
}

list_wlan_interfaces() {
  for dir in /sys/class/net/*/wireless; do
    if [ -d "$dir" ]; then
      basename "$(dirname "$dir")"
    fi
  done
}

do_wifi_ssid_passphrase() {
  RET=0
  IFACE_LIST="$(list_wlan_interfaces)"
  IFACE="$(echo "$IFACE_LIST" | head -n 1)"

  if [ -z "$IFACE" ]; then
    if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "No wireless interface found" 20 60
    fi
    return 1
  fi

  if ! wpa_cli -i "$IFACE" status > /dev/null 2>&1; then
    if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "Could not communicate with wpa_supplicant" 20 60
    fi
    return 1
  fi

  if [ "$INTERACTIVE" = True ] && [ -z "$(get_wifi_country)" ]; then
    do_wifi_country
  fi

  SSID="$1"
  while [ -z "$SSID" ] && [ "$INTERACTIVE" = True ]; do
    SSID=$(whiptail --inputbox "Please enter SSID" 20 60 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
      return 0
    elif [ -z "$SSID" ]; then
      whiptail --msgbox "SSID cannot be empty. Please try again." 20 60
    fi
  done

  PASSPHRASE="$2"
  while [ "$INTERACTIVE" = True ]; do
    PASSPHRASE=$(whiptail --passwordbox "Please enter passphrase. Leave it empty if none." 20 60 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
      return 0
    else
      break
    fi
  done

  # Escape special characters for embedding in regex below
  local ssid="$(echo "$SSID" \
   | sed 's;\\;\\\\;g' \
   | sed -e 's;\.;\\\.;g' \
         -e 's;\*;\\\*;g' \
         -e 's;\+;\\\+;g' \
         -e 's;\?;\\\?;g' \
         -e 's;\^;\\\^;g' \
         -e 's;\$;\\\$;g' \
         -e 's;\/;\\\/;g' \
         -e 's;\[;\\\[;g' \
         -e 's;\];\\\];g' \
         -e 's;{;\\{;g'   \
         -e 's;};\\};g'   \
         -e 's;(;\\(;g'   \
         -e 's;);\\);g'   \
         -e 's;";\\\\\";g')"

  wpa_cli -i "$IFACE" list_networks \
   | tail -n +2 | cut -f -2 | grep -P "\t$ssid$" | cut -f1 \
   | while read ID; do
    wpa_cli -i "$IFACE" remove_network "$ID" > /dev/null 2>&1
  done

  ID="$(wpa_cli -i "$IFACE" add_network)"
  wpa_cli -i "$IFACE" set_network "$ID" ssid "\"$SSID\"" 2>&1 | grep -q "OK"
  RET=$((RET + $?))

  if [ -z "$PASSPHRASE" ]; then
    wpa_cli -i "$IFACE" set_network "$ID" key_mgmt NONE 2>&1 | grep -q "OK"
    RET=$((RET + $?))
  else
    wpa_cli -i "$IFACE" set_network "$ID" psk "\"$PASSPHRASE\"" 2>&1 | grep -q "OK"
    RET=$((RET + $?))
  fi

  if [ $RET -eq 0 ]; then
    wpa_cli -i "$IFACE" enable_network "$ID" > /dev/null 2>&1
  else
    wpa_cli -i "$IFACE" remove_network "$ID" > /dev/null 2>&1
    if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "Failed to set SSID or passphrase" 20 60
    fi
  fi
  wpa_cli -i "$IFACE" save_config > /dev/null 2>&1

  echo "$IFACE_LIST" | while read IFACE; do
    wpa_cli -i "$IFACE" reconfigure > /dev/null 2>&1
  done

  return $RET
}

do_finish() {
  disable_raspi_config_at_boot
  if [ $ASK_TO_REBOOT -eq 1 ]; then
    whiptail --yesno "Would you like to reboot now?" 20 60 2
    if [ $? -eq 0 ]; then # yes
      sync
      reboot
    fi
  fi
  exit 0
}

# $1 = filename, $2 = key name
get_json_string_val() {
  sed -n -e "s/^[[:space:]]*\"$2\"[[:space:]]*:[[:space:]]*\"\(.*\)\"[[:space:]]*,$/\1/p" $1
}

# TODO: This is probably broken
do_apply_os_config() {
  [ -e /boot/os_config.json ] || return 0
  NOOBSFLAVOUR=$(get_json_string_val /boot/os_config.json flavour)
  NOOBSLANGUAGE=$(get_json_string_val /boot/os_config.json language)
  NOOBSKEYBOARD=$(get_json_string_val /boot/os_config.json keyboard)

  if [ -n "$NOOBSFLAVOUR" ]; then
    printf "Setting flavour to %s based on os_config.json from NOOBS. May take a while\n" "$NOOBSFLAVOUR"

    printf "Unrecognised flavour. Ignoring\n"
  fi

  # TODO: currently ignores en_gb settings as we assume we are running in a 
  # first boot context, where UK English settings are default
  case "$NOOBSLANGUAGE" in
    "en")
      if [ "$NOOBSKEYBOARD" = "gb" ]; then
        DEBLANGUAGE="" # UK english is the default, so ignore
      else
        DEBLANGUAGE="en_US.UTF-8"
      fi
      ;;
    "de")
      DEBLANGUAGE="de_DE.UTF-8"
      ;;
    "fi")
      DEBLANGUAGE="fi_FI.UTF-8"
      ;;
    "fr")
      DEBLANGUAGE="fr_FR.UTF-8"
      ;;
    "hu")
      DEBLANGUAGE="hu_HU.UTF-8"
      ;;
    "ja")
      DEBLANGUAGE="ja_JP.UTF-8"
      ;;
    "nl")
      DEBLANGUAGE="nl_NL.UTF-8"
      ;;
    "pt")
      DEBLANGUAGE="pt_PT.UTF-8"
      ;;
    "ru")
      DEBLANGUAGE="ru_RU.UTF-8"
      ;;
    "zh_CN")
      DEBLANGUAGE="zh_CN.UTF-8"
      ;;
    *)
      printf "Language '%s' not handled currently. Run sudo raspi-config to set up" "$NOOBSLANGUAGE"
      ;;
  esac

  if [ -n "$DEBLANGUAGE" ]; then
    printf "Setting language to %s based on os_config.json from NOOBS. May take a while\n" "$DEBLANGUAGE"
    do_change_locale "$DEBLANGUAGE"
  fi

  if [ -n "$NOOBSKEYBOARD" -a "$NOOBSKEYBOARD" != "gb" ]; then
    printf "Setting keyboard layout to %s based on os_config.json from NOOBS. May take a while\n" "$NOOBSKEYBOARD"
    do_configure_keyboard "$NOOBSKEYBOARD"
  fi
  return 0
}

get_overlay_now() {
  grep -q "boot=overlay" /proc/cmdline
}

get_overlay_conf() {
  grep -q "boot=overlay" /boot/cmdline.txt
}

get_bootro_now() {
 findmnt /boot | grep -q " ro,"
}

get_bootro_conf() {
  grep /boot /etc/fstab | grep -q "defaults.*,ro "
}

is_uname_current() {
  test -d "/lib/modules/$(uname -r)"
  return $?
}

enable_overlayfs() {
  KERN=$(uname -r)
  INITRD=initrd.img-"$KERN"-overlay

  # mount the boot partition as writable if it isn't already
  if get_bootro_now ; then
    if ! mount -o remount,rw /boot 2>/dev/null ; then
      echo "Unable to mount boot partition as writable - cannot enable"
      return 1
    fi
    BOOTRO=yes
  else
    BOOTRO=no
  fi

  cat > /etc/initramfs-tools/scripts/overlay << 'EOF'
# Local filesystem mounting			-*- shell-script -*-

#
# This script overrides local_mount_root() in /scripts/local
# and mounts root as a read-only filesystem with a temporary (rw)
# overlay filesystem.
#

. /scripts/local

local_mount_root()
{
	local_top
	local_device_setup "${ROOT}" "root file system"
	ROOT="${DEV}"

	# Get the root filesystem type if not set
	if [ -z "${ROOTFSTYPE}" ]; then
		FSTYPE=$(get_fstype "${ROOT}")
	else
		FSTYPE=${ROOTFSTYPE}
	fi

	local_premount

	# CHANGES TO THE ORIGINAL FUNCTION BEGIN HERE
	# N.B. this code still lacks error checking

	modprobe ${FSTYPE}
	checkfs ${ROOT} root "${FSTYPE}"

	# Create directories for root and the overlay
	mkdir /lower /upper

	# Mount read-only root to /lower
	if [ "${FSTYPE}" != "unknown" ]; then
		mount -r -t ${FSTYPE} ${ROOTFLAGS} ${ROOT} /lower
	else
		mount -r ${ROOTFLAGS} ${ROOT} /lower
	fi

	modprobe overlay || insmod "/lower/lib/modules/$(uname -r)/kernel/fs/overlayfs/overlay.ko"

	# Mount a tmpfs for the overlay in /upper
	mount -t tmpfs tmpfs /upper
	mkdir /upper/data /upper/work

	# Mount the final overlay-root in $rootmnt
	mount -t overlay \
	    -olowerdir=/lower,upperdir=/upper/data,workdir=/upper/work \
	    overlay ${rootmnt}
}
EOF

  # add the overlay to the list of modules
  if ! grep overlay /etc/initramfs-tools/modules > /dev/null; then
    echo overlay >> /etc/initramfs-tools/modules
  fi

  # build the new initramfs
  update-initramfs -c -k "$KERN"

  # rename it so we know it has overlay added
  mv /boot/initrd.img-"$KERN" /boot/"$INITRD"

  # there is now a modified initramfs ready for use...

  # modify config.txt
  sed -i /boot/config.txt -e "/initramfs.*/d" 
  echo initramfs "$INITRD" >> /boot/config.txt

  # modify command line
  if ! grep -q "boot=overlay" /boot/cmdline.txt ; then
      sed -i /boot/cmdline.txt -e "s/^/boot=overlay /"
  fi

  if [ "$BOOTRO" = "yes" ] ; then
    if ! mount -o remount,ro /boot 2>/dev/null ; then
        echo "Unable to remount boot partition as read-only"
    fi
  fi
}

disable_overlayfs() {
  KERN=$(uname -r)
  # mount the boot partition as writable if it isn't already
  if get_bootro_now ; then
    if ! mount -o remount,rw /boot 2>/dev/null ; then
      echo "Unable to mount boot partition as writable - cannot disable"
      return 1
    fi
    BOOTRO=yes
  else
    BOOTRO=no
  fi

  # modify config.txt
  sed -i /boot/config.txt -e "/initramfs.*/d"
  update-initramfs -d -k "${KERN}-overlay"

  # modify command line
  sed -i /boot/cmdline.txt -e "s/\(.*\)boot=overlay \(.*\)/\1\2/"

  if [ "$BOOTRO" = "yes" ] ; then
    if ! mount -o remount,ro /boot 2>/dev/null ; then
        echo "Unable to remount boot partition as read-only"
    fi
  fi
}

enable_bootro() {
  if get_overlay_now ; then
    echo "Overlay in use; cannot update fstab"
    return 1
  fi
  sed -i /etc/fstab -e "s/\(.*\/boot.*\)defaults\(.*\)/\1defaults,ro\2/"
}

disable_bootro() {
  if get_overlay_now ; then
    echo "Overlay in use; cannot update fstab"
    return 1
  fi
  sed -i /etc/fstab -e "s/\(.*\/boot.*\)defaults,ro\(.*\)/\1defaults\2/"
}

do_overlayfs() {
  DEFAULT=--defaultno
  CURRENT=0
  STATUS="disabled"

  if [ "$INTERACTIVE" = True ] && ! is_uname_current; then
    whiptail --msgbox "Could not find modules for the running kernel ($(uname -r))." 20 60 1
    return 1
  fi

  if get_overlay_conf; then
    DEFAULT=
    CURRENT=1
    STATUS="enabled"
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --yesno "Would you like the overlay file system to be enabled?" $DEFAULT 20 60 2
    RET=$?
  else
    RET=$1
  fi
  if [ $RET -eq $CURRENT ]; then
    if [ $RET -eq 0 ]; then
      if enable_overlayfs; then
        STATUS="enabled"
        ASK_TO_REBOOT=1
      else
        STATUS="unchanged"
      fi
    elif [ $RET -eq 1 ]; then
      if disable_overlayfs; then
        STATUS="disabled"
        ASK_TO_REBOOT=1
      else
        STATUS="unchanged"
      fi
    else
      return $RET
    fi
  fi
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "The overlay file system is $STATUS." 20 60 1
  fi
  if get_overlay_now ; then
    if get_bootro_conf; then
      BPRO="read-only"
    else
      BPRO="writable"
    fi
    whiptail --msgbox "The boot partition is currently $BPRO. This cannot be changed while an overlay file system is enabled." 20 60 1
  else
    DEFAULT=--defaultno
    CURRENT=0
    STATUS="writable"
    if get_bootro_conf; then
      DEFAULT=
      CURRENT=1
      STATUS="read-only"
    fi
    if [ "$INTERACTIVE" = True ]; then
      whiptail --yesno "Would you like the boot partition to be write-protected?" $DEFAULT 20 60 2
      RET=$?
    else
      RET=$1
    fi
    if [ $RET -eq $CURRENT ]; then
      if [ $RET -eq 0 ]; then
        if enable_bootro; then
          STATUS="read-only"
          ASK_TO_REBOOT=1
        else
          STATUS="unchanged"
        fi
      elif [ $RET -eq 1 ]; then
        if disable_bootro; then
          STATUS="writable"
          ASK_TO_REBOOT=1
        else
          STATUS="unchanged"
        fi
      else
        return $RET
      fi
    fi
    if [ "$INTERACTIVE" = True ]; then
      whiptail --msgbox "The boot partition is $STATUS." 20 60 1
    fi
  fi
}

get_proxy() {
  SCHEME="$1"
  VAR_NAME="${SCHEME}_proxy"
  if [ -f /etc/profile.d/proxy.sh ]; then
    # shellcheck disable=SC1091
    . /etc/profile.d/proxy.sh
  fi
  eval "echo \$$VAR_NAME"
}

do_proxy() {
  SCHEMES="$1"
  ADDRESS="$2"
  if [ "$SCHEMES" = "all" ]; then
    CURRENT="$(get_proxy http)"
    SCHEMES="http https ftp rsync"
  else
    CURRENT="$(get_proxy "$SCHEMES")"
  fi
  if [ "$INTERACTIVE" = True ]; then
    if [ "$SCHEMES" = "no" ]; then
      STRING="Please enter a comma separated list of addresses that should be excluded from using proxy servers.\\nEg: localhost,127.0.0.1,localaddress,.localdomain.com"
    else
      STRING="Please enter proxy address.\\nEg: http://user:pass@proxy:8080"
    fi
    if ! ADDRESS="$(whiptail --inputbox "$STRING"  20 60 "$CURRENT" 3>&1 1>&2 2>&3)"; then
      return 0
    fi
  fi
  for SCHEME in $SCHEMES; do
    unset "${SCHEME}_proxy"
    CURRENT="$(get_proxy "$SCHEME")"
    if [ "$CURRENT" != "$ADDRESS" ]; then
      ASK_TO_REBOOT=1
    fi
    if [ -f /etc/profile.d/proxy.sh ]; then
      sed -i "/^export ${SCHEME}_/Id" /etc/profile.d/proxy.sh
    fi
    if [ "${SCHEME#*http}" != "$SCHEME" ]; then
      if [ -f /etc/apt/apt.conf.d/01proxy ]; then
        sed -i "/::${SCHEME}::Proxy/d" /etc/apt/apt.conf.d/01proxy
      fi
    fi
    if [ -z "$ADDRESS" ]; then
      STATUS=cleared
      continue
    fi
    STATUS=updated
    SCHEME_UPPER="$(echo "$SCHEME" | tr '[:lower:]' '[:upper:]')"
    echo "export ${SCHEME_UPPER}_PROXY=\"$ADDRESS\"" >> /etc/profile.d/proxy.sh
    if [ "$SCHEME" != "rsync" ]; then
      echo "export ${SCHEME}_proxy=\"$ADDRESS\"" >> /etc/profile.d/proxy.sh
    fi
    if [ "${SCHEME#*http}" != "$SCHEME" ]; then
      echo "Acquire::$SCHEME::Proxy \"$ADDRESS\";"  >> /etc/apt/apt.conf.d/01proxy
    fi
  done
  if [ "$INTERACTIVE" = True ]; then
    whiptail --msgbox "Proxy settings $STATUS" 20 60 1
  fi
}

nonint() {
  "$@"
}

#
# Command line options for non-interactive use
#
for i in $*
do
  case $i in
  --memory-split)
    OPT_MEMORY_SPLIT=GET
    printf "Not currently supported\n"
    exit 1
    ;;
  --memory-split=*)
    OPT_MEMORY_SPLIT=`echo $i | sed 's/[-a-zA-Z0-9]*=//'`
    printf "Not currently supported\n"
    exit 1
    ;;
  --expand-rootfs)
    INTERACTIVE=False
    do_expand_rootfs
    printf "Please reboot\n"
    exit 0
    ;;
  --apply-os-config)
    INTERACTIVE=False
    do_apply_os_config
    exit $?
    ;;
  nonint)
    INTERACTIVE=False
    "$@"
    exit $?
    ;;
  *)
    # unknown option
    ;;
  esac
done

#if [ "GET" = "${OPT_MEMORY_SPLIT:-}" ]; then
#  set -u # Fail on unset variables
#  get_current_memory_split
#  echo $CURRENT_MEMSPLIT
#  exit 0
#fi

# Everything else needs to be run as root
if [ $(id -u) -ne 0 ]; then
  printf "Script must be run as root. Try 'sudo raspi-config'\n"
  exit 1
fi

if [ -n "${OPT_MEMORY_SPLIT:-}" ]; then
  set -e # Fail when a command errors
  set_memory_split "${OPT_MEMORY_SPLIT}"
  exit 0
fi

do_system_menu() {
  if is_pi ; then
    FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "System Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Back --ok-button Select \
      "S1 Wireless LAN" "Enter SSID and passphrase" \
      "S2 Audio" "Select audio out through HDMI or 3.5mm jack" \
      "S3 Password" "Change password for the '$USER' user" \
      "S4 Hostname" "Set name for this computer on a network" \
      "S5 Boot / Auto Login" "Select boot into desktop or to command line" \
      "S6 Network at Boot" "Select wait for network connection on boot" \
      "S7 Splash Screen" "Choose graphical splash screen or text boot" \
      "S8 Power LED" "Set behaviour of power LED" \
      3>&1 1>&2 2>&3)
  elif is_live ; then 
    FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "System Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Back --ok-button Select \
      "S1 Wireless LAN" "Enter SSID and passphrase" \
      "S3 Password" "Change password for the '$USER' user" \
      "S4 Hostname" "Set name for this computer on a network" \
      "S5 Boot / Auto Login" "Select boot into desktop or to command line" \
      "S6 Network at Boot" "Select wait for network connection on boot" \
      3>&1 1>&2 2>&3)
  else
    FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "System Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Back --ok-button Select \
      "S1 Wireless LAN" "Enter SSID and passphrase" \
      "S3 Password" "Change password for the '$USER' user" \
      "S4 Hostname" "Set name for this computer on a network" \
      "S5 Boot / Auto Login" "Select boot into desktop or to command line" \
      "S6 Network at Boot" "Select wait for network connection on boot" \
      "S7 Splash Screen" "Choose graphical splash screen or text boot" \
      3>&1 1>&2 2>&3)
  fi
  RET=$?
  if [ $RET -eq 1 ]; then
    return 0
  elif [ $RET -eq 0 ]; then
    case "$FUN" in
      S1\ *) do_wifi_ssid_passphrase ;;
      S2\ *) do_audio ;;
      S3\ *) do_change_pass ;;
      S4\ *) do_hostname ;;
      S5\ *) do_boot_behaviour ;;
      S6\ *) do_boot_wait ;;
      S7\ *) do_boot_splash ;;
      S8\ *) do_leds ;;
      *) whiptail --msgbox "Programmer error: unrecognized option" 20 60 1 ;;
    esac || whiptail --msgbox "There was an error running option $FUN" 20 60 1
  fi
}

do_display_menu() {
  if is_pifour ; then
    FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Display Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Back --ok-button Select \
      "D1 Resolution" "Set a specific screen resolution" \
      "D2 Underscan" "Remove black border around screen" \
      "D3 Pixel Doubling" "Enable/disable 2x2 pixel mapping" \
      "D4 Composite Video" "Video output options for Raspberry Pi 4" \
      "D5 Screen Blanking" "Enable/disable screen blanking" \
      3>&1 1>&2 2>&3)
  elif is_pi ; then
    FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Display Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Back --ok-button Select \
      "D1 Resolution" "Set a specific screen resolution" \
      "D2 Underscan" "Remove black border around screen" \
      "D3 Pixel Doubling" "Enable/disable 2x2 pixel mapping" \
      "D5 Screen Blanking" "Enable/disable screen blanking" \
      3>&1 1>&2 2>&3)
  else
    FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Display Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Back --ok-button Select \
      "D3 Pixel Doubling" "Enable/disable 2x2 pixel mapping" \
      "D5 Screen Blanking" "Enable/disable screen blanking" \
      3>&1 1>&2 2>&3)
  fi
  RET=$?
  if [ $RET -eq 1 ]; then
    return 0
  elif [ $RET -eq 0 ]; then
    case "$FUN" in
      D1\ *) do_resolution ;;
      D2\ *) do_overscan ;;
      D3\ *) do_pixdub ;;
      D4\ *) do_pi4video ;;
      D5\ *) do_blanking ;;
      *) whiptail --msgbox "Programmer error: unrecognized option" 20 60 1 ;;
    esac || whiptail --msgbox "There was an error running option $FUN" 20 60 1
  fi
}

do_interface_menu() {
  if is_pi ; then
    FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Interfacing Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Back --ok-button Select \
      "P1 Camera" "Enable/disable connection to the Raspberry Pi Camera" \
      "P2 SSH" "Enable/disable remote command line access using SSH" \
      "P3 VNC" "Enable/disable graphical remote access using RealVNC" \
      "P4 SPI" "Enable/disable automatic loading of SPI kernel module" \
      "P5 I2C" "Enable/disable automatic loading of I2C kernel module" \
      "P6 Serial Port" "Enable/disable shell messages on the serial connection" \
      "P7 1-Wire" "Enable/disable one-wire interface" \
      "P8 Remote GPIO" "Enable/disable remote access to GPIO pins" \
      3>&1 1>&2 2>&3)
  else
    FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Interfacing Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Back --ok-button Select \
      "P2 SSH" "Enable/disable remote command line access using SSH" \
      3>&1 1>&2 2>&3)
  fi
  RET=$?
  if [ $RET -eq 1 ]; then
    return 0
  elif [ $RET -eq 0 ]; then
    case "$FUN" in
      P1\ *) do_camera ;;
      P2\ *) do_ssh ;;
      P3\ *) do_vnc ;;
      P4\ *) do_spi ;;
      P5\ *) do_i2c ;;
      P6\ *) do_serial ;;
      P7\ *) do_onewire ;;
      P8\ *) do_rgpio ;;
      *) whiptail --msgbox "Programmer error: unrecognized option" 20 60 1 ;;
    esac || whiptail --msgbox "There was an error running option $FUN" 20 60 1
  fi
}

do_performance_menu() {
  FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Performance Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Back --ok-button Select \
    "P1 Overclock" "Configure CPU overclocking" \
    "P2 GPU Memory" "Change the amount of memory made available to the GPU" \
    "P3 Overlay File System" "Enable/disable read-only file system" \
    "P4 Fan" "Set behaviour of GPIO fan" \
    3>&1 1>&2 2>&3)
  RET=$?
  if [ $RET -eq 1 ]; then
    return 0
  elif [ $RET -eq 0 ]; then
    case "$FUN" in
      P1\ *) do_overclock ;;
      P2\ *) do_memory_split ;;
      P3\ *) do_overlayfs ;;
      P4\ *) do_fan ;;
      *) whiptail --msgbox "Programmer error: unrecognized option" 20 60 1 ;;
    esac || whiptail --msgbox "There was an error running option $FUN" 20 60 1
  fi
}

do_internationalisation_menu() {
  FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Localisation Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Back --ok-button Select \
    "L1 Locale" "Configure language and regional settings" \
    "L2 Timezone" "Configure time zone" \
    "L3 Keyboard" "Set keyboard layout to match your keyboard" \
    "L4 WLAN Country" "Set legal wireless channels for your country" \
    3>&1 1>&2 2>&3)
  RET=$?
  if [ $RET -eq 1 ]; then
    return 0
  elif [ $RET -eq 0 ]; then
    case "$FUN" in
      L1\ *) do_change_locale ;;
      L2\ *) do_change_timezone ;;
      L3\ *) do_configure_keyboard ;;
      L4\ *) do_wifi_country ;;
      *) whiptail --msgbox "Programmer error: unrecognized option" 20 60 1 ;;
    esac || whiptail --msgbox "There was an error running option $FUN" 20 60 1
  fi
}

do_advanced_menu() {
  if is_pifour ; then
    FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Advanced Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Back --ok-button Select \
      "A1 Expand Filesystem" "Ensures that all of the SD card is available" \
      "A2 GL Driver" "Enable/disable experimental desktop GL driver" \
      "A3 Compositor" "Enable/disable xcompmgr composition manager" \
      "A4 Network Interface Names" "Enable/disable predictable network i/f names" \
      "A5 Network Proxy Settings" "Configure network proxy settings" \
      "A6 Boot Order" "Choose network or USB device boot" \
      "A7 Bootloader Version" "Select latest or default boot ROM software" \
      3>&1 1>&2 2>&3)
  elif is_pi ; then
    FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Advanced Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Back --ok-button Select \
      "A1 Expand Filesystem" "Ensures that all of the SD card is available" \
      "A2 GL Driver" "Enable/disable experimental desktop GL driver" \
      "A3 Compositor" "Enable/disable xcompmgr composition manager" \
      "A4 Network Interface Names" "Enable/disable predictable network i/f names" \
      "A5 Network Proxy Settings" "Configure network proxy settings" \
      3>&1 1>&2 2>&3)
  else
    FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Advanced Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Back --ok-button Select \
      "A4 Network Interface Names" "Enable/disable predictable network i/f names" \
      "A5 Network Proxy Settings" "Configure network proxy settings" \
      3>&1 1>&2 2>&3)
  fi
  RET=$?
  if [ $RET -eq 1 ]; then
    return 0
  elif [ $RET -eq 0 ]; then
    case "$FUN" in
      A1\ *) do_expand_rootfs ;;
      A2\ *) do_gldriver ;;
      A3\ *) do_xcompmgr ;;
      A4\ *) do_net_names ;;
      A5\ *) do_proxy_menu ;;
      A6\ *) do_boot_order ;;
      A7\ *) do_boot_rom ;;
      *) whiptail --msgbox "Programmer error: unrecognized option" 20 60 1 ;;
    esac || whiptail --msgbox "There was an error running option $FUN" 20 60 1
  fi
}

do_proxy_menu() {
  FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Network Proxy Settings" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Back --ok-button Select \
    "P1 All" "Set the same proxy for all schemes" \
    "P2 HTTP" "Set the HTTP proxy" \
    "P3 HTTPS" "Set the HTTPS/SSL proxy" \
    "P4 FTP" "Set the FTP proxy" \
    "P5 RSYNC" "Set the RSYNC proxy" \
    "P6 Exceptions" "Set addresses for which a proxy server should not be used" \
    3>&1 1>&2 2>&3)
  RET=$?
  if [ $RET -eq 1 ]; then
    return 0
  elif [ $RET -eq 0 ]; then
    case "$FUN" in
      P1\ *) do_proxy all ;;
      P2\ *) do_proxy http ;;
      P3\ *) do_proxy https ;;
      P4\ *) do_proxy ftp ;;
      P5\ *) do_proxy rsync ;;
      P6\ *) do_proxy no;;
      *) whiptail --msgbox "Programmer error: unrecognized option" 20 60 1 ;;
    esac || whiptail --msgbox "There was an error running option $FUN" 20 60 1
  fi
}

#
# Interactive use loop
#
if [ "$INTERACTIVE" = True ]; then
  [ -e $CONFIG ] || touch $CONFIG
  calc_wt_size
  while [ "$USER" = "root" ] || [ -z "$USER" ]; do
    if ! USER=$(whiptail --inputbox "raspi-config could not determine the default user.\\n\\nWhat user should these settings apply to?" 20 60 pi 3>&1 1>&2 2>&3); then
      return 0
    fi
  done
  while true; do
    if is_pi ; then
      FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --backtitle "$(cat /proc/device-tree/model)" --menu "Setup Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Finish --ok-button Select \
        "1 System Options" "Configure system settings" \
        "2 Display Options" "Configure display settings" \
        "3 Interface Options" "Configure connections to peripherals" \
        "4 Performance Options" "Configure performance settings" \
        "5 Localisation Options" "Configure language and regional settings" \
        "6 Advanced Options" "Configure advanced settings" \
        "8 Update" "Update this tool to the latest version" \
        "9 About raspi-config" "Information about this configuration tool" \
        3>&1 1>&2 2>&3)
    else
      FUN=$(whiptail --title "Raspberry Pi Software Configuration Tool (raspi-config)" --menu "Setup Options" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT --cancel-button Finish --ok-button Select \
        "1 System Options" "Configure system settings" \
        "2 Display Options" "Configure display settings" \
        "3 Interface Options" "Configure connections to peripherals" \
        "5 Localisation Options" "Configure language and regional settings" \
        "6 Advanced Options" "Configure advanced settings" \
        "8 Update" "Update this tool to the latest version" \
        "9 About raspi-config" "Information about this configuration tool" \
        3>&1 1>&2 2>&3)
    fi
    RET=$?
    if [ $RET -eq 1 ]; then
      do_finish
    elif [ $RET -eq 0 ]; then
      case "$FUN" in
        1\ *) do_system_menu ;;
        2\ *) do_display_menu ;;
        3\ *) do_interface_menu ;;
        4\ *) do_performance_menu ;;
        5\ *) do_internationalisation_menu ;;
        6\ *) do_advanced_menu ;;
        8\ *) do_update ;;
        9\ *) do_about ;;
        *) whiptail --msgbox "Programmer error: unrecognized option" 20 60 1 ;;
      esac || whiptail --msgbox "There was an error running option $FUN" 20 60 1
    else
      exit 1
    fi
  done
fi
