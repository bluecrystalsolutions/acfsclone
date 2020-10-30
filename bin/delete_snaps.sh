#!/bin/bash

# SYNOPSIS
#     
# DESCRIPTION
#     The script deletes all snapshots on selected ACFS file system. Use with care
# PARAMETER $1
#     ACFS filesystem
# NOTES
#     Version:        1.0
#     Author:         Eugene Bobkov
#     Creation Date:  14/10/2019
# EXAMPLE
#     delete_snaps.sh /u02/oradata


if [ -z $1 ]; then
    SNAPFS="/u02/oradata"
fi

for i in `acfsutil snap info ${SNAPFS} | awk '!/delete in progress/&&/snapshot name:/{print $3}'`; do 
    acfsutil snap delete $i ${SNAPFS} 
done

acfsutil snap info ${SNAPFS}
