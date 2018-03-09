# expand-ec2-disk
Completes all steps to add space to an existing logical volume on the current AWS EC2 Linux instance.  Steps include:
1) Create encrypted volume tagged with Tier
2) Determine next available block device
3) Attach volume
4) Determine filesystem (ext4 or xfs)
5) Add device to logical volume
6) Extend filesystem

# Usage
Execute on the target instance where the additional storage is required.
./expand-ec2-disk.sh [ -s additional space ]

By default, the new volume will be created 20% * the current total size of the logical volume.  A custom size can be provided with the -s flag as an integer in GB.

# Configuration
Determine the path of your logical volume with lvdisplay and set the 'lvm' variable.

Determine the KMS Key ID of your EBS encryption key and set the 'enckey' variable.

If facter is not installed or does not provide ec2_placement_availability_zone, set the 'az' variable.

This script automatically tags new volumes with a Tier derived from the hostname (app-tier-#.dom.tld).  'tier=$()' can be modified to derive the Tier tag however you'd like.  To disable tags, delete the '--tag-specifications' flag and value from the 'create-volume' command.

# Notes
Only supports the gp2 volume type.  Only supports ext4 and xfs file systems.
