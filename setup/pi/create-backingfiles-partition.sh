#!/bin/bash -eu

function setup_progress () {
  local setup_logfile=/boot/teslausb-headless-setup.log
  local headless_setup=${HEADLESS_SETUP:-false}
  if [ $headless_setup = "true" ]
  then
    echo "$( date ) : $1" >> "$setup_logfile"
  fi
  echo $1
}

# install XFS tools if needed
if ! hash mkfs.xfs
then
  apt-get -y --force-yes install xfsprogs
fi

# Will check for USB Drive before running sd card
if [ ! -z "$usb_drive" ]
then
  setup_progress "usb_drive is set to $usb_drive"
  # Check if backingfiles and mutable partitions exist
  if [ /dev/disk/by-label/backingfiles -ef /dev/sda2 -a /dev/disk/by-label/mutable -ef /dev/sda1 ]
  then
    setup_progress "Looks like backingfiles and mutable partitions already exist. Skipping partition creation."
  else
    setup_progress "WARNING !!! This will delete EVERYTHING in $usb_drive."
    wipefs -afq $usb_drive
    parted $usb_drive --script mktable gpt
    setup_progress "$usb_drive fully erased. Creating partitions..."
    parted -a optimal -m /dev/sda mkpart primary ext4 '0%' 2GB
    parted -a optimal -m /dev/sda mkpart primary ext4 2GB '100%'
    setup_progress "Backing files and mutable partitions created."

    setup_progress "Formatting new partitions..."
    # Force creation of filesystems even if previous filesystem appears to exist
    mkfs.ext4 -F -L mutable /dev/sda1
    mkfs.xfs -f -m reflink=1 -L backingfiles /dev/sda2
  fi
    
  BACKINGFILES_MOUNTPOINT="$1"
  MUTABLE_MOUNTPOINT="$2"
  if grep -q backingfiles /etc/fstab
  then
    setup_progress "backingfiles already defined in /etc/fstab. Not modifying /etc/fstab."
  else
    echo "LABEL=backingfiles $BACKINGFILES_MOUNTPOINT xfs auto,rw,noatime 0 2" >> /etc/fstab
  fi
  if grep -q 'mutable' /etc/fstab
  then
    setup_progress "mutable already defined in /etc/fstab. Not modifying /etc/fstab."
  else
    echo "LABEL=mutable $MUTABLE_MOUNTPOINT ext4 auto,rw 0 2" >> /etc/fstab
  fi
  setup_progress "Done."
  exit 0
else
  echo "usb_drive not set. Proceeding to SD card setup"
fi

# If partition 3 is the backingfiles partition, type xfs, and
# partition 4 the mutable partition, type ext4, then return early.
if [ /dev/disk/by-label/backingfiles -ef /dev/mmcblk0p3 -a \
    /dev/disk/by-label/mutable -ef /dev/mmcblk0p4 ] && \
    blkid /dev/mmcblk0p4 | grep -q 'TYPE="ext4"'
then
  if blkid /dev/mmcblk0p3 | grep -q 'TYPE="xfs"'
  then
    # assume these were either created previously by the setup scripts,
    # or manually by the user, and that they're big enough
    setup_progress "using existing backingfiles and mutable partitions"
    return &> /dev/null || exit 0
  elif blkid /dev/mmcblk0p3 | grep -q 'TYPE="ext4"'
  then
    # special case: convert existing backingfiles from ext4 to xfs
    setup_progress "reformatting existing backingfiles as xfs"
    killall archiveloop || true
    modprobe -r g_mass_storage
    if mount | grep -qw "/mnt/cam"
    then
      if ! umount /mnt/cam
      then
        setup_progress "STOP: couldn't unmount /mnt/cam"
        exit 1
      fi
    fi
    if mount | grep -qw "/backingfiles"
    then
      if ! umount /backingfiles
      then
        setup_progress "STOP: couldn't unmount /backingfiles"
        exit 1
      fi
    fi
    mkfs.xfs -f -m reflink=1 -L backingfiles /dev/mmcblk0p3

    # update /etc/fstab
    sed -i 's/LABEL=backingfiles .*/LABEL=backingfiles \/backingfiles xfs auto,rw,noatime 0 2/' /etc/fstab
    mount /backingfiles
    setup_progress "backingfiles converted to xfs and mounted"
    return &> /dev/null || exit 0
  fi
fi

# partition 3 and 4 either don't exist, or are the wrong type
if [ -e /dev/mmcblk0p3 -o -e /dev/mmcblk0p4 ]
then
  setup_progress "STOP: partitions already exist, but are not as expected"
  setup_progress "please delete them and re-run setup"
  exit 1
fi

BACKINGFILES_MOUNTPOINT="$1"
MUTABLE_MOUNTPOINT="$2"

setup_progress "Checking existing partitions..."
PARTITION_TABLE=$(parted -m /dev/mmcblk0 unit B print)
DISK_LINE=$(echo "$PARTITION_TABLE" | grep -e "^/dev/mmcblk0:")
DISK_SIZE=$(echo "$DISK_LINE" | cut -d ":" -f 2 | sed 's/B//' )

ROOT_PARTITION_LINE=$(echo "$PARTITION_TABLE" | grep -e "^2:")
LAST_ROOT_PARTITION_BYTE=$(echo "$ROOT_PARTITION_LINE" | sed 's/B//g' | cut -d ":" -f 3)

FIRST_BACKINGFILES_PARTITION_BYTE="$(( $LAST_ROOT_PARTITION_BYTE + 1 ))"
LAST_BACKINGFILES_PARTITION_DESIRED_BYTE="$(( $DISK_SIZE - (100 * (2 ** 20)) - 1))"

ORIGINAL_DISK_IDENTIFIER=$( fdisk -l /dev/mmcblk0 | grep -e "^Disk identifier" | sed "s/Disk identifier: 0x//" )

setup_progress "Modifying partition table for backing files partition..."
BACKINGFILES_PARTITION_END_SPEC="$(( $LAST_BACKINGFILES_PARTITION_DESIRED_BYTE / 1000000 ))M"
parted -a optimal -m /dev/mmcblk0 unit B mkpart primary xfs "$FIRST_BACKINGFILES_PARTITION_BYTE" "$BACKINGFILES_PARTITION_END_SPEC"

setup_progress "Modifying partition table for mutable (writable) partition for script usage..."
MUTABLE_PARTITION_START_SPEC="$BACKINGFILES_PARTITION_END_SPEC"
parted  -a optimal -m /dev/mmcblk0 unit B mkpart primary ext4 "$MUTABLE_PARTITION_START_SPEC" 100%

NEW_DISK_IDENTIFIER=$( fdisk -l /dev/mmcblk0 | grep -e "^Disk identifier" | sed "s/Disk identifier: 0x//" )

setup_progress "Writing updated partitions to fstab and /boot/cmdline.txt"
sed -i "s/${ORIGINAL_DISK_IDENTIFIER}/${NEW_DISK_IDENTIFIER}/g" /etc/fstab
sed -i "s/${ORIGINAL_DISK_IDENTIFIER}/${NEW_DISK_IDENTIFIER}/" /boot/cmdline.txt

setup_progress "Formatting new partitions..."
# Force creation of filesystems even if previous filesystem appears to exist
mkfs.xfs -f -m reflink=1 -L backingfiles /dev/mmcblk0p3
mkfs.ext4 -F -L mutable /dev/mmcblk0p4

echo "LABEL=backingfiles $BACKINGFILES_MOUNTPOINT xfs auto,rw,noatime 0 2" >> /etc/fstab
echo "LABEL=mutable $MUTABLE_MOUNTPOINT ext4 auto,rw 0 2" >> /etc/fstab
