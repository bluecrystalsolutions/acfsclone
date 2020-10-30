**SYNOPSIS**

    Script to clone Oracle database     

**DESCRIPTION**

    The script clones Oracle database using ACFS snapshot
    
**PARAMETER** $1

    ORACLE_SID of source instance
    
**PARAMETER** $2

    ORACLE_SID of clone instance
    
**PARAMETER** $3

    ACFS filesystem
    
**EXAMPLE**

    acfsclone.sh db1 db2 /u02/oradata
