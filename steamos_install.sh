#!/bin/bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
#
# A collection of functions to repair and modify a Steam Deck installation.
# This makes a number of assumptions about the target device and will be
# destructive if you have modified the expected partition layout.
#

set -eu

DISK=""
DISK_SUFFIX=""
DOPARTVERIFY=1
writePartitionTable=1
writeOS=1
writeHome=1

die() { echo >&2 "!! $*"; exit 1; }
readvar() { IFS= read -r -d '' "$1" || true; }
diskpart() { echo "$DISK$DISK_SUFFIX$1"; }


# Partition table, sfdisk format
readvar PARTITION_TABLE <<END_PARTITION_TABLE
  label: gpt
  ${DISK}${DISK_SUFFIX}1: name="esp",      size=    64MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
  ${DISK}${DISK_SUFFIX}2: name="efi-A",    size=    32MiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
  ${DISK}${DISK_SUFFIX}3: name="efi-B",    size=    32MiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
  ${DISK}${DISK_SUFFIX}4: name="rootfs-A", size=  5120MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
  ${DISK}${DISK_SUFFIX}5: name="rootfs-B", size=  5120MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
  ${DISK}${DISK_SUFFIX}6: name="var-A",    size=   256MiB, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
  ${DISK}${DISK_SUFFIX}7: name="var-B",    size=   256MiB, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
  ${DISK}${DISK_SUFFIX}8: name="home",                     type=933AC7E1-2EB4-4F13-B844-0E14E2AEF915
END_PARTITION_TABLE

# Partition numbers on ideal target device, by index
FS_ESP=1
FS_EFI_A=2
FS_EFI_B=3
FS_ROOT_A=4
FS_ROOT_B=5
FS_VAR_A=6
FS_VAR_B=7
FS_HOME=8

# Update script to prompt user to select disk instead of only using nvme0n1
prompt_for_disk() {
  disk=""
  disks=$(lsblk -o KNAME,TYPE,SIZE,MODEL | grep disk)
  echo "Available disks for installation:"
  echo "$disks"
  echo
  read -p "Enter disk to install SteamOS: " disk

  if ! test -e /dev/$disk ; then
    echo "$disk does not exist"
    exit 1
  else
    parts=$(lsblk -o KNAME,TYPE,SIZE,FSTYPE,PARTLABEL | grep part | grep $disk)
    echo "$disk contains following data:"
    echo "$parts"
    read -p "Are you sure you want to continue? [y/n] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Starting SteamOS install ..."
        DISK="/dev/$disk"
        # NVMe partitions traditionally use p
        if [[ $disk == "nvme*" ]]; then
          DISK_SUFFIX="p"
        fi
    else
        exit 0
    fi
fi
}

# The recovery image may have auto mounted some partitons so unmount them if so
unmount_parts() {
  # Get the mounts for the specific disk
  mounts=$(cat /proc/mounts | grep $DISK | awk '{print $2}')

  # Loop through each mount point and unmount it
  for mount in $mounts
  do
    echo "Unmounting $mount"
    umount $mount
  done

  echo 
}


##
## Util colors and such
##

err() {
  echo >&2
  eerr "Imaging error occured, see above and restart process."
  sleep infinity
}
trap err ERR

_sh_c_colors=0
[[ -n $TERM && -t 1 && ${TERM,,} != dumb ]] && _sh_c_colors="$(tput colors 2>/dev/null || echo 0)"
sh_c() { [[ $_sh_c_colors -le 0 ]] || ( IFS=\; && echo -n $'\e['"${*:-0}m"; ); }

sh_quote() { echo "${@@Q}"; }
estat()    { echo >&2 "$(sh_c 32 1)::$(sh_c) $*"; }
emsg()     { echo >&2 "$(sh_c 34 1)::$(sh_c) $*"; }
ewarn()    { echo >&2 "$(sh_c 33 1);;$(sh_c) $*"; }
einfo()    { echo >&2 "$(sh_c 30 1)::$(sh_c) $*"; }
eerr()     { echo >&2 "$(sh_c 31 1)!!$(sh_c) $*"; }
die() { local msg="$*"; [[ -n $msg ]] || msg="script terminated"; eerr "$msg"; exit 1; }
showcmd() { showcmd_unquoted "${@@Q}"; }
showcmd_unquoted() { echo >&2 "$(sh_c 30 1)+$(sh_c) $*"; }
cmd() { showcmd "$@"; "$@"; }

# Helper to format
fmt_ext4()  { [[ $# -eq 2 && -n $1 && -n $2 ]] || die; cmd sudo mkfs.ext4 -F -L "$1" "$2"; }
fmt_fat32() { [[ $# -eq 2 && -n $1 && -n $2 ]] || die; cmd sudo mkfs.vfat -n"$1" "$2"; }

##
## Prompt mechanics - currently using Zenity
##

# Give the user a choice between Proceed, or Cancel (which exits this script)
#  $1 Title
#  $2 Text
#
prompt_step()
{
  title="$1"
  msg="$2"
  if [[ ${NOPROMPT:-} ]]; then
    echo -e "$msg"
    return 0
  fi
  zenity --title "$title" --question --ok-label "Proceed" --cancel-label "Cancel" --no-wrap --text "$msg"
  [[ $? = 0 ]] || exit 1
}

prompt_reboot()
{
  prompt_step "Action Complete" "${1}\n\nChoose Proceed to reboot the Steam Deck now, or Cancel to stay in the repair image."
  [[ $? = 0 ]] || exit 1
  if [[ ${POWEROFF:-} ]]; then
    cmd systemctl poweroff
  else
    cmd systemctl reboot
  fi
}


##
## Repair functions
##

# verify partition on target disk - at least make sure the type and partlabel match what we expect.
#   $1 device
#   $2 expected type
#   $3 expected partlabel
#
verifypart()
{
  [[ $DOPARTVERIFY = 1 ]] || return 0
  TYPE="$(blkid -o value -s TYPE "$1" )"
  PARTLABEL="$(blkid -o value -s PARTLABEL "$1" )"
  if [[ ! $TYPE = "$2" ]]; then
    eerr "Device $1 is type $TYPE but expected $2 - cannot proceed. You may try full recovery."
    sleep infinity ; exit 1
  fi

  if [[ ! $PARTLABEL = $3 ]] ; then 
    eerr "Device $1 has label $PARTLABEL but expected $3 - cannot proceed. You may try full recovery."
    sleep infinity ; exit 2
  fi
}


# Replace the device rootfs (btrfs version). Source must be frozen before calling.
#   $1 source device
#   $2 target device
#
imageroot()
{
  local srcroot="$1"
  local newroot="$2"
  # copy then randomize target UUID - careful here! Duplicating btrfs ids is a problem
  cmd dd if="$srcroot" of="$newroot" bs=128M status=progress oflag=sync
  cmd btrfstune -f -u "$newroot"
  cmd btrfs check "$newroot"
}

# Set up boot configuration in the target partition set
#   $1 partset name
finalize_part()
{
  estat "Finalizing install part $1"
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$1" -- mkdir /efi/SteamOS
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$1" -- mkdir -p /esp/SteamOS/conf
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$1" -- steamos-partsets /efi/SteamOS/partsets
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$1" -- steamos-bootconf create --image "$1" --conf-dir /esp/SteamOS/conf --efi-dir /efi --set title "$1"
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$1" -- grub-mkimage
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$1" -- update-grub
}

##
## Main
##

onexit=()
exithandler() {
  for func in "${onexit[@]}"; do
    "$func"
  done
}
trap exithandler EXIT

# Reinstall a fresh SteamOS copy.
#
repair_steps()
{
  if [[ $writePartitionTable = 1 ]]; then
    estat "Write known partition table"
    echo "$PARTITION_TABLE" | sfdisk "$DISK"

  elif [[ $writeOS = 1 || $writeHome = 1 ]]; then

    # verify some partition settings to make sure we are ok to proceed with partial repairs
    # in the case we just wrote the partition table, we know we are good and the partitions
    # are unlabelled anyway
    verifypart "$(diskpart $FS_ESP)" vfat esp
    verifypart "$(diskpart $FS_EFI_A)" vfat efi-A
    verifypart "$(diskpart $FS_EFI_B)" vfat efi-B
    verifypart "$(diskpart $FS_VAR_A)" ext4 var-A
    verifypart "$(diskpart $FS_VAR_B)" ext4 var-B
    verifypart "$(diskpart $FS_HOME)" ext4 home
  fi

  # Skipped any steam deck BIOS tools/updates

  # clear the var partition (user data), but also if we are reinstalling the OS
  # a fresh system partition has problems with overlay otherwise
  if [[ $writeOS = 1 || $writeHome = 1 ]]; then
    estat "Creating var partitions"
    fmt_ext4  var  "$(diskpart $FS_VAR_A)"
    fmt_ext4  var  "$(diskpart $FS_VAR_B)"
  fi

  if [[ $writeHome = 1 ]]; then
    estat "Creating home partition..."
    cmd sudo mkfs.ext4 -F -O casefold -T huge -L home "$(diskpart $FS_HOME)"
    estat "Remove the reserved blocks on the home partition..."
    tune2fs -m 0 "$(diskpart $FS_HOME)"
  fi

  if [[ $writeOS = 1 ]]; then
    # Find rootfs
    rootdevice="$(findmnt -n -o source / )"
    if [[ -z $rootdevice || ! -e $rootdevice ]]; then
      eerr "Could not find USB installer root -- usb hub issue?"
      sleep infinity
      exit 1
    fi
  
    # Set up ESP/EFI boot partitions
    estat "Creating boot partitions"
    fmt_fat32 esp  "$(diskpart $FS_ESP)"
    fmt_fat32 efi  "$(diskpart $FS_EFI_A)"
    fmt_fat32 efi  "$(diskpart $FS_EFI_B)"

    # Freeze our rootfs
    estat "Freezing rootfs"
    unfreeze() { fsfreeze -u /; }
    onexit+=(unfreeze)
    cmd fsfreeze -f /

    estat "Imaging OS partition A"
    imageroot "$rootdevice" "$(diskpart $FS_ROOT_A)"
  
    estat "Imaging OS partition B"
    imageroot "$rootdevice" "$(diskpart $FS_ROOT_B)"
  
    estat "Finalizing boot configurations"
    finalize_part A
    finalize_part B
    estat "Finalizing EFI system partition"
    cmd steamos-chroot --no-overlay --disk "$DISK" --partset A -- steamcl-install --flags restricted --force-extra-removable
  fi
}

prompt_for_disk
unmount_parts
prompt_step "Reimage Steam Deck" "This action will reimage the Steam Deck.\nThis will permanently destroy all data on your Steam Deck and reinstall SteamOS.\n\nThis cannot be undone.\n\nChoose Proceed only if you wish to clear and reimage this device."
writePartitionTable=1
writeOS=1
writeHome=1
repair_steps
prompt_reboot "Reimaging complete."
