#!/bin/bash

##############################################
# Allocates more disk space to the defined
# LVM on the current EC2 instance.  Default 
# is 20% bigger. Only supports the gp2 volume
# type. Expects local block devices to be in 
# /dev/xvd* format. Only supports ext4 and 
# xfs filesystems.
#
# 2018 - Don Scarpelli
##############################################

# Set name of logical volume to expand
lvm="/dev/volgrp/logvol"
# Set AWS EBS encryption key ID
enckey="kms-key-id-goes-here"
# Set default % increase (1.00 = 100%)
default=0.20
voltype="gp2"

# If facter cannot provide AZ, manually set here
az=$(facter ec2_placement_availability_zone || echo "us-east-1d")

red="\033[31m"
cyan="\033[36m"
grn="\033[32m"
clr="\033[0m"

source ~/.profile

usage() {
  echo "Usage: $0 [-s <additional_space>]"
  exit 1
}

# Used for tags, tier is determined from hostname (app-tier-#.dom.tld)
tier=$(uname -n | awk -F"." '{ print $1 }' | awk -F"-" '{ print $2 }')
if [[ "$tier" == "int" ]]; then
  tier="internal"
fi

while getopts "s:h" opt; do
  case $opt in
    s)
      addsize=$OPTARG
    ;;
    h)
      usage
    ;;
    *)
      usage
    ;;
  esac
done

instance=$(wget -q -O - http://169.254.169.254/latest/meta-data/instance-id)

if [[ -z $addsize ]]; then
  # Sum all attached encrypted volumes
  oldsize=$(/usr/local/bin/aws ec2 describe-volumes --filters Name=attachment.instance-id,Values=${instance} Name=encrypted,Values=true --output json 2>/dev/null | grep -oP "(?<=\"Size\": )\d*(?=$)" | awk '{i+=$1} END {print i}')
  if [[ -z "$oldsize" ]]; then
    echo "${red}API call failed or no encrypted volumes found, aborting.${clr}"
    exit 1
  fi
  addsize=$(echo $oldsize \* $default | bc)
  addsize=${addsize%.*}
fi

echo -en "${cyan}Creating new ${grn}${addsize}${cyan} GB volume and attaching in 10 seconds, Ctrl+C to abort...${clr}"
sleep 10

# Create volume
return=$(/usr/local/bin/aws ec2 create-volume \
        --availability-zone $az \
        --encrypted \
        --kms-key-id $enckey \
        --size $addsize \
        --volume-type $voltype \
        --tag-specifications "ResourceType=volume,Tags=[{Key=Tier,Value=${tier}}]" || echo failed)

if [[ $return == failed ]]; then
  echo -e "${red}FAILED${clr}"
  echo "CloudTrail may provide insight."
  exit 1
fi

echo -e "${grn}OK${clr}"

volid=$(echo "$return" | awk '{ print $8 }')

echo -en "${cyan}Waiting for ${grn}${volid}${cyan} to become available...${clr}"

while true; do
  status=$(/usr/local/bin/aws ec2 describe-volumes --volume-ids $volid --output json | /usr/bin/python -c "import sys, json; print json.load(sys.stdin)['Volumes'][0]['State']")
  if [[ "$status" == "available" ]]; then
    echo -e "${grn}OK${clr}"
    break
  fi
  sleep 5
  echo -en "${cyan}.${clr}"
done

# Determine next available block device
lastdev=$(lsblk -o KNAME | grep -P xvd.$ | sort | tail -1)
increment=$(echo $lastdev | cut -c4 | tr "a-z" "b-za")
if [[ $increment == a ]]; then
  echo "Looks like /dev/xvd[a-z] are exhausted.  Consolidate the volumes before trying again."
  exit 1
fi
newblk="xvd${increment}"
newdev="/dev/${newblk}"

echo -en "${cyan}Attaching ${grn}${volid}${cyan} as ${grn}${newdev}${cyan}...${clr}"

# Attach volume
return=$(/usr/local/bin/aws ec2 attach-volume \
  --volume-id $volid \
  --instance-id $instance \
  --device $newblk || echo "failed")

if [[ $return == failed ]]; then
  echo -e "${red}FAILED${clr}"
  echo "CloudTrail may provide insight."
  exit 1
fi

while true; do
  status=$(/usr/local/bin/aws ec2 describe-volumes --volume-ids $volid --output json | /usr/bin/python -c "import sys, json; print json.load(sys.stdin)['Volumes'][0]['Attachments'][0]['State']")
  if [[ "$status" == "attached" ]]; then
    echo -e "${grn}OK${clr}"
    break
  fi
  sleep 5
  echo -en "${cyan}.${clr}"
done

echo -en "${cyan}Verifying LVM ${grn}${lvm}${cyan}...${clr}"
checklv=$(blkid $lvm -s TYPE)
if [[ "$checklv" =~ "ext4" ]]; then
  fsys="ext4"
  echo -e "${grn}EXT4${clr}"
elif [[ "$checklv" =~ "xfs" ]]; then
  fsys="xfs"
  echo -e "${grn}XFS${clr}"
else
  echo -e "${red}FAILED${clr}"
  echo "LVM $lvm does not exist or is not a supported file system (ext4/xfs)"
  exit 1
fi

echo -en "${cyan}Adding ${grn}${newdev}${cyan} to LVM ${grn}${lvm}${cyan}...${clr}"
pvcreate $newdev >/dev/null
vgextend vgdata $newdev >/dev/null
lvextend -l 100%VG $lvm $newdev >/dev/null
echo -e "${grn}OK${clr}"

echo -en "${cyan}Resizing ${grn}${fsys}${cyan} filesystem...${clr}"
if [[ "$fsys" == "ext4" ]]; then
  resize2fs $lvm >/dev/null
elif [[ "$fsys" == "xfs" ]]; then
  xfs_growfs $lvm >/dev/null
else
  echo -e "${red}FAILED${clr}"
  exit 1
fi

echo -e "${grn}OK${clr}"
exit 0
