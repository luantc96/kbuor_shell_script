#!/bin/bash

# Clear the screen before displaying anything
clear

# Function to install packages based on the OS type
install_packages() {
    echo 'Installing required package.'
    echo
    if [ -f /etc/redhat-release ]; then
        # Red Hat/CentOS
        sudo yum install -y gdisk parted > /dev/null
    elif [ -f /etc/lsb-release ] || [ -f /etc/debian_version ]; then
        # Ubuntu/Debian
        sudo apt update > /dev/null
        sudo apt install -y gdisk parted > /dev/null
    else
        echo "Unsupported operating system. Please install gdisk and parted manually."
        exit 1
    fi
}

# Run the package installation function
install_packages

# Display a warning message to the user to backup their data
echo
echo 'WARNING: BACKUP YOUR DATA BEFORE RUNNING THIS SCRIPT FOR SAFETY FIRST!!!!'
echo

# Rescan all disks to update their capacity
echo 'Rescan all disk...'
echo

# Loop through each disk's rescan file and echo '1' to it to trigger a rescan
for var_disk in /sys/class/block/sd*/device/rescan; do
    echo 1 > "$var_disk"
done

partprobe

# Display disk information: name, size, and model
lsblk -d -n -o NAME,SIZE,MODEL
echo

# Get the list of disks (sd*, vd*, hd* types) using lsblk and filter out disk names
DISKS=($(lsblk -d -n -o NAME,MODEL | grep -E '^(sd|hd|vd)' | awk '{print $1}'))

# Set the PS3 prompt message for the select menu
PS3="Select disk to process: "

# Use select to create a menu for the user to choose a disk
echo "Available disks:"
select SELECTED_DISK in "${DISKS[@]}"; do

    # Check if a valid selection was made
    if [ -n "$SELECTED_DISK" ]; then
        echo
        echo "You have selected the disk: /dev/$SELECTED_DISK"
        echo
        echo "Getting disk /dev/$SELECTED_DISK information..."
        echo

        # Show detailed information about the selected disk
        lsblk /dev/$SELECTED_DISK

        # Get the list of partitions on the selected disk
        PARTS=($(lsblk -l -n -o NAME,MODEL | awk '{print $1}' | grep -E "^$SELECTED_DISK[0-9]+$"))

        # Set the PS3 prompt message for selecting a partition
        PS3="Select partition to process: "

        echo
        echo "Available partitions:"

        # Use select to create a menu for the user to choose a partition
        select SELECTED_PART in "${PARTS[@]}"; do

            # Check if a valid partition was selected
            if [ -n "$SELECTED_PART" ]; then
                echo
                echo "You have selected the partition: /dev/$SELECTED_PART"
                echo
                echo "Getting partition /dev/$SELECTED_PART information..."
                echo

                # Show detailed information about the selected partition
                lsblk /dev/$SELECTED_PART
                echo

                # Check if the partition is an LVM (Logical Volume Manager)
                if lsblk /dev/$SELECTED_PART | grep lvm > /dev/null 2> /dev/null ; then
                    echo "  + TYPE: Logical Volume Manager (LVM)"
                    
                    # Get the mount points of the partition and remove any empty lines
                    MOUNTEDTO_LIST=($(lsblk -n -o MOUNTPOINTS /dev/$SELECTED_PART | grep -v '^$'))

                    # Loop through each mount point
                    for MOUNTEDTO in "${MOUNTEDTO_LIST[@]}"; do
                        # Only process mount points that start with /
                        if [[ $MOUNTEDTO == /* ]]; then
                            # Get the filesystem associated with the mount point
                            FS=$(df -hT | grep "$MOUNTEDTO$" | awk '{print $1}')

                            # Get LVM details: logical volume path, name, and volume group
                            exec 3>&- && exec 4>&- && exec 63>&-
                            LVPATH=$(lvdisplay "$FS" | grep "LV Path" | awk '{print $NF}')
                            LVNAME=$(lvdisplay "$FS" | grep "LV Name" | awk '{print $NF}')
                            VGNAME=$(lvdisplay "$FS" | grep "VG Name" | awk '{print $NF}')
                            
                            # Display the results for each mount point
                            echo "  + MOUNTED TO: $MOUNTEDTO"
                            echo "  + MOUNTED BY: $FS"
                            echo "  + LOGICAL VOLUME (LV): $LVNAME (PATH: $LVPATH)"
                            echo "  + VOLUME GROUP (VG): $VGNAME"
                            echo
                        fi
                    done

                    # Ask user if they want to increase the capacity of the filesystem
                    read -p "Do you want to increase capacity for $FS (yes/no): " tmp_select
                    if [[ "$tmp_select" == "yes" || "$tmp_select" == "y" ]]; then

                        # Check if the selected partition is the last partition on the disk
                        LAST_PARTITION=$(lsblk -l | grep $SELECTED_DISK | tail -n 1 | awk '{print $1}')
                        if [ "$LAST_PARTITION" == "$SELECTED_PART" ]; then

                            # Expand the last partition
                            sgdisk -e /dev/$SELECTED_DISK
                            partprobe
                            PARTNUMBER="${SELECTED_PART: -1}"
                            parted /dev/$SELECTED_DISK resizepart $PARTNUMBER 100%

                            # Resize the physical volume and extend the logical volume
                            pvresize /dev/$SELECTED_PART
                            lvextend -l +100%FREE $LVPATH

                            # Resize the filesystem based on its type
                            FS_TYPE=$(blkid -o value -s TYPE $LVPATH)
                            if [ $FS_TYPE == "xfs" ]; then
                                xfs_growfs $LVPATH
                            else
                                resize2fs $LVPATH
                            fi
                            echo "*** INCREASE CAPACITY FOR $FS SUCCESSFULLY"
                            echo
                            echo "Getting partition /dev/$SELECTED_PART information..."
                            echo
                            lsblk /dev/$SELECTED_PART
                            echo
                        else

                            # If not the last partition, add a new partition for LVM

                            CHECK_GPT=$(parted /dev/sda print | grep "Partition Table" | awk '{print $NF}')
                            echo "THIS IS NOT LAST PARTITION"
                            gdisk /dev/$SELECTED_DISK << EOF
n



8E00
w
y
y
EOF
                            partprobe

                            # Update partition information after creating a new partition
                            SELECTED_PART=$(fdisk -l | grep $SELECTED_DISK | tail -n 1 | awk '{print $1}' | awk -F / '{print $3}')
                            pvcreate /dev/$SELECTED_PART
                            vgextend $VGNAME /dev/$SELECTED_PART
                            lvextend $LVPATH -l +100%FREE

                            # Resize the filesystem
                            FS_TYPE=$(blkid -o value -s TYPE $LVPATH)
                            if [ $FS_TYPE == "xfs" ]; then
                                xfs_growfs $LVPATH
                            else
                                resize2fs $LVPATH
                            fi
                            echo "*** INCREASE CAPACITY FOR $FS SUCCESSFULLY"
                            echo
                            echo "Getting partition /dev/$SELECTED_PART information..."
                            echo
                            lsblk /dev/$SELECTED_PART
                            echo
                        fi
                    elif [[ "$tmp_select" == "no" || "$tmp_select" == "n" ]]; then

                        # If the user chooses not to increase capacity
                        echo 'BYE!!!'
                    else

                        # Invalid choice handling
                        echo 'Invalid choice!!!'
                    fi
                else

                    # If the partition is not LVM
                    echo "  + TYPE: PARTITION (PART)"
                    MOUNTEDTO=$(lsblk -n -o MOUNTPOINTS /dev/$SELECTED_PART | grep -v '^$')
                    FS=$(df -hT | grep "$MOUNTEDTO$" | awk '{print $1}')
                    echo "  + MOUNTED TO: $MOUNTEDTO"
                    echo "  + MOUNTED BY: $FS"

                    # Check if the selected partition is the last one on the disk
                    LAST_PARTITION=$(lsblk -l | grep $SELECTED_DISK | tail -n 1 | awk '{print $1}')
                    if [ "$LAST_PARTITION" == "$SELECTED_PART" ]; then

                        # Expand the partition and resize the filesystem
                        sgdisk -e /dev/$SELECTED_DISK
                        partprobe
                        PARTNUMBER="${SELECTED_PART: -1}"
                        parted /dev/$SELECTED_DISK resizepart $PARTNUMBER 100%
                        FS_TYPE=$(blkid -o value -s TYPE $FS)
                        if [ $FS_TYPE == "xfs" ]; then
                            xfs_growfs $FS
                        else
                            resize2fs $FS
                        fi
                        echo "*** INCREASE CAPACITY FOR $FS SUCCESSFULLY"
                        echo
                        echo "Getting partition /dev/$SELECTED_PART information..."
                        echo
                        lsblk /dev/$SELECTED_PART
                        echo
                    else

                        # If the selected partition is not the last one
                        echo
                        echo '!!! CANNOT INCREASE CAPACITY FOR THIS PARTITION BECAUSE THIS IS NOT THE LAST PARTITION OF DISK OR NOT RUNNING IN "LVM" MODE'
                        echo
                    fi
                fi

                # Exit the partition selection loop
                break
            else

                # If an invalid partition is selected
                echo "Invalid choice! Please select again."
            fi
        done

        # Exit the disk selection loop
        break
    else
    
        # If an invalid disk is selected
        echo "Invalid choice! Please select again."
    fi
done
