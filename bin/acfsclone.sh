#!/bin/bash

# SYNOPSIS
#     Script to clone Oracle database     
# DESCRIPTION
#     The script clones Oracle database using ACFS snapshot
# PARAMETER $1
#     ORACLE_SID of source instance
# PARAMETER $2
#     ORACLE_SID of clone instance
# PARAMETER $3
#     ACFS filesystem
# NOTES
#     Version:        1.0
#     Author:         Eugene Bobkov
#     Creation Date:  14/10/2019
# EXAMPLE
#     acfsclone.sh db1 db2 /u02/oradata

if [[ "$1" = '-h' || "$1" = '--help' || -z "$1" ]]; then
    echo " 
The following parameters are expected    
    $0 original_database target_database mountpoint [snapshot_name]

Example:
    acfsclone.sh db1 db2 /u02/oradata

    "
    exit 0
fi

# root directory for the applications's structure (where bin, log and others folders located)
ROOTDIR=$(dirname `cd $(dirname ${0}); pwd`)

RUNDIR=${ROOTDIR}/run
test ! -d ${RUNDIR} && mkdir ${RUNDIR}

LOGDIR=${ROOTDIR}/log
test ! -d ${LOGDIR} && mkdir ${LOGDIR}

TIMEDATE=`date '+%Y%m%d_%H%M%S'`

echo "Initializing, checking parameters"

ORIGIN_SID=${1}
if [ -z "${ORIGIN_SID}" ]; then
    echo "ERROR: Origin database name was not provided, aborting"
    exit 1
fi

CLONE_SID=${2}
if [ -z "${CLONE_SID}" ]; then
    echo "ERROR: Clone database name was not provided, aborting"
    exit 1
fi

LOGFILE=${LOGDIR}/out.${ORIGIN_SID}.${CLONE_SID}.${TIMEDATE}
ERRFILE=${LOGDIR}/err.${ORIGIN_SID}.${CLONE_SID}.${TIMEDATE}
RECOVERY_LCKFILE=${RUNDIR}/recovery.lock.${ORIGIN_SID}

if [ `ps -ef | grep -c "ora_smon_${CLONE_SID}$"` -eq 1 ]; then
    echo "ERROR: Origin database is already running, aborting"
    exit 1
fi

MOUNTPOINT=${3}
if [ -z "${MOUNTPOINT}" ]; then
    echo "ERROR: Mount point was not provided, aborting"
    exit 1
fi

if [ "${ORIGIN_SID}" = "${CLONE_SID}" ]; then
    echo "ERROR: databases names are identical, aborting"
    exit 1
fi

# check if ORIGIN name is in oratab
if [ `egrep -c "^${ORIGIN_SID}:" /etc/oratab` -ne 1 ]; then
    echo "ERROR: origin database is not in oratab, aborting"
    exit 1
fi

# check if CLONE name is in oratab
if [ `egrep -c "^${CLONE_SID}:" /etc/oratab` -ne 1 ]; then
    echo "adding clone database in oratab"
    echo "${CLONE_SID}:$(awk -F":" '/^'${ORIGIN_SID}':/{print $2}' /etc/oratab):N" >> /etc/oratab
fi

SNAP_NAME=${4}
if [ -z "${SNAP_NAME}" ]; then
    SNAP_NAME=${ORIGIN_SID}_${CLONE_SID}_${TIMEDATE}
fi

export PATH=/usr/local/bin:${PATH}
export ORAENV_ASK=NO
export ORACLE_SID=${ORIGIN_SID}

. /usr/local/bin/oraenv > /dev/null

# create ACFS snapshot

# check if origin database is standby, if yes - stop recovery
# TODO: dgmgrl?
if [ "`echo 'select controlfile_type from v$database;' | sqlplus -s / as sysdba | tail -2 | head -1`" = 'STANDBY' ]; then
    # check if any other processes are already running for this origin database
    if [ -f ${RECOVERY_LCKFILE} ]; then
        # file exists, check if it's stale
        if [ $(ps -p `cat ${RECOVERY_LCKFILE}` | grep -c `cat ${RECOVERY_LCKFILE}`) -eq 0 ]; then
            # stale file, not required
            echo "Stale recovery lock file detected, removed"
            rm ${RECOVERY_LCKFILE}
        else
            # another process is already running
            echo "ERROR: Another cloning process is in progress, aborting.." 
            exit 1
        fi
    fi
    
    # stop recovery
    echo "Stopping standby recovery for ${ORIGIN_SID}"
    sqlplus -s / as sysdba 1>> ${LOGFILE} 2>> ${ERRFILE} <<EOF
        ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
EOF
    RECOVERY_STOPPED="YES"
  
    # create lock file to prevent other processes to interfere with recovery
    echo $$ > ${RECOVERY_LCKFILE}
fi

# TODO: check if it's snap of FS or snap of snap
# assuming that current user(oracle) has permissions to run acfsutil, if not - sudo required
# TODO: all done around /u02/oradata being ACFS, it should be revised for different filesystem name and structure
/usr/sbin/acfsutil snap create -w ${SNAP_NAME} ${MOUNTPOINT}

echo "Snapshot ${SNAP_NAME} on ${MOUNTPOINT} has been created"

# enable recovery if it was stopped
if [ "${RECOVERY_STOPPED}" = 'YES' ]; then
    echo "Starting standby recovery for ${ORIGIN_SID}"
    sqlplus -s / as sysdba 1>> ${LOGFILE} 2>> ${ERRFILE} <<EOF
        ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT NODELAY;
EOF
    # remove lock file
    rm ${RECOVERY_LCKFILE}
fi

# configure environment for new database
echo "Copy password file"
# copy password file
if [ ! -e ${ORACLE_HOME}/dbs/orapw${CLONE_SID} ]; then
    cp ${ORACLE_HOME}/dbs/orapw${ORIGIN_SID} ${ORACLE_HOME}/dbs/orapw${CLONE_SID}
fi

echo "Generate new configuration file"
# create pfile for new database, is check for it's existance required?
# create new pfile
PFILE=${RUNDIR}/init${CLONE_SID}.ora.${SNAP_NAME}.${TIMEDATE}
${ORACLE_HOME}/bin/sqlplus -s / as sysdba 1>> ${LOGFILE} 2>> ${ERRFILE} <<EOF
    set echo on feedback on
    create pfile='${PFILE}' from spfile;
EOF

if [ $? -eq 0 ]; then
    echo "${PFILE} has been created"
else
    echo "could not create pfile ${PFILE}, aborting"
    exit 1
fi

echo "Update parameters for clone database"
echo "Remove dynamic settings"
# all parameters with ${ORIGIN_SID}.__ has to go
sed -i "/^${ORIGIN_SID}\.__/d;" ${PFILE}

# remove standby related settings as it will break standby
sed -i "/\.archive_lag_target/d; \
/\.data_guard_sync_latency/d; \
/\.dg_broker_config_file1/d; \
/\.dg_broker_config_file2/d; \
/\.dg_broker_start/d; \
/\.log_archive_format/d; \
/\.fal_server/d; \
/\.log_archive_config/d; \
/\.log_archive_dest_1/d; \
/\.log_archive_dest_2/d; \
/\.log_archive_dest_state_2/d; \
/\.log_archive_max_processes/d; \
/\.log_archive_min_succeed_dest/d; \
/\.log_archive_trace/d;" ${PFILE}


echo "Modify controlfile parameter to point to snap location"
# create array of control files
ORIG_IFS=${IFS}
IFS=',' read -ra CTRLFLS <<< `awk '/^\*\.control_files/{gsub(/\*\.control_files=/,"",$0); print}' ${PFILE}`
IFS=${ORIG_IFS}

# find first control file located on target acfs mount point
# it's location modified to reflect ACFS snap and only this file is used for database start, all others ignored
# this approach is good enought for now, however
# TODO: if required - modify and add more files
for ctlf in ${CTRLFLS[@]}; do
    if [ `echo "${ctlf}" | grep -c "^'${MOUNTPOINT}/"` -gt 0 ]; then
        ctlf=`echo "${ctlf}" | sed "s#${MOUNTPOINT}/#${MOUNTPOINT}/.ACFS/snaps/${SNAP_NAME}/#"`
        # stop processing controlfiles and update init file
        sed -i "s#^\*\.control_files=.*#*.control_files=${ctlf}#" ${PFILE}
        break
    fi
done

echo "Update audit location for clone database"
# update audit location and created directory if it doesn't exist
orig_audparm=`awk -F"audit_file_dest=" '/\*\.audit_file_dest=/{print $2}' ${PFILE}`
clone_audparm=`echo ${orig_audparm} | sed "s/${ORIGIN_SID}/${CLONE_SID}/"`
sed -i "s#${orig_audparm}#${clone_audparm}#" ${PFILE}

if [ ! -e $(echo ${clone_audparm} | sed "s/'//g") ]; then
    mkdir -p $(echo ${clone_audparm} | sed "s/'//g")
fi

echo "Update XDB dispatchers"
# update XDB service
orig_xdb=`awk -F"dispatchers=" '/\*\.dispatchers=/{print $2}' ${PFILE}`
clone_xdb=`echo ${orig_xdb} | sed "s/${ORIGIN_SID}/${CLONE_SID}/"`
sed -i "s#${orig_xdb}#${clone_xdb}#" ${PFILE}

echo "Add unique name for clone"
# add db_unique_name
echo "*.db_unique_name='${CLONE_SID}'" >> ${PFILE}
 
echo "Starting clone database with new settings, but in mount mode only"

# start new database using pfile 
export ORACLE_SID=${CLONE_SID}
. /usr/local/bin/oraenv > /dev/null

# start clone in mount mode
${ORACLE_HOME}/bin/sqlplus / as sysdba 1>> ${LOGFILE} 2>>${ERRFILE} << EOF
    set serveroutput on echo on feedback on;
    set lines 10000
    startup mount force pfile='${PFILE}';
EOF

if [ $? -ne 0 ]; then
    echo "ERROR: Was not able to mount clone before reconfiguration"
    exit 1
fi

echo "Identify logs required for recovery"
# get logs required for recovery, on snapshot
recovery_logs=$(sqlplus -s / as sysdba <<EOF
set pages 0 lines 1000 feedback off
select log 
  from  (
         select log
           from (
                  -- logfiles if database is primary
                  select '${MOUNTPOINT}/.ACFS/snaps/${SNAP_NAME}' || substr(member,length('${MOUNTPOINT}')+1) log
                       , SEQUENCE#
                    from v\$log l
                       , v\$logfile m 
                   where l.status not in ('INACTIVE','UNUSED','UNASSIGNED')
                     and l.group# = m.group# 
                     and substr(member,1,length('${MOUNTPOINT}')) = '${MOUNTPOINT}'
                     and (select controlfile_type from v\$database) = 'CURRENT'
                  union 
                  -- standby log if database is standby
                  select name
                       , SEQUENCE#
                    from v\$archived_log
                   where FIRST_CHANGE# > (select current_scn from v\$database)
                     and (select controlfile_type from v\$database) = 'STANDBY'
                  ) rlogs
          order by SEQUENCE#
         )
 union
-- incomplete recover for standby database
select 'CANCEL'
  from dual
 where (select controlfile_type from v\$database) = 'STANDBY';
EOF
)

RECOVERY_FILE=${RUNDIR}/recover.${SNAP_NAME}.${TIMEDATE}.sql

for log in ${recovery_logs}; do
    echo ${log} >> ${RECOVERY_FILE}
done

echo "Generate list of datafiles"
# get list of datafiles
datafiles=$(sqlplus -s / as sysdba << EOF
set pages 0 lines 1000 feedback off
select '''${MOUNTPOINT}/.ACFS/snaps/${SNAP_NAME}' || substr(name,length('${MOUNTPOINT}')+1) ||''''
  from v\$datafile;
EOF
)

# set counter
cnt=0
# variable to keep file names
dbfiles=''
for dbf in ${datafiles}; do
    if [ ${cnt} -eq 0 ]; then
        # first row
        dbfiles=${dbf}
        cnt=1
    else
        # not first row
        dbfiles="${dbfiles}, ${dbf}"
    fi
done

echo "After gathering of all required information - update db_name"
# update db_name
orig_db_name=`awk -F"db_name=" '/\*\.db_name=/{print $2}' ${PFILE}`
clone_db_name=`echo ${orig_db_name} | sed "s/${orig_db_name}/${CLONE_SID}/"`
sed -i "s#${orig_db_name}#${clone_db_name}#" ${PFILE}

echo "Remove control files line from pfile"
#remove control files line
sed -i "/^*.control_files=/d;" ${PFILE}

echo "Create spfile from pfile, shutdown/startup instance"
echo "New control files, datafiles and logs pointed to snap location"
echo "Create new control file and recover to point of snap using logfile"
echo "Add tempfile"

${ORACLE_HOME}/bin/sqlplus / as sysdba 1>> ${LOGFILE} 2>>${ERRFILE} <<EOF
    set serveroutput on echo on feedback on;
    set lines 10000
    -- whenever sqlerror exit 1

    create spfile='?/dbs/spfile${CLONE_SID}.ora' from pfile='${PFILE}';

    startup nomount force;

    alter system set db_create_file_dest='${MOUNTPOINT}/.ACFS/snaps/${SNAP_NAME}' scope=both;
    alter system set db_create_online_log_dest_1='${MOUNTPOINT}/.ACFS/snaps/${SNAP_NAME}' scope=both;
    alter system set db_create_online_log_dest_2='${MOUNTPOINT}/.ACFS/snaps/${SNAP_NAME}' scope=both;

    CREATE CONTROLFILE SET DATABASE "${CLONE_SID}" RESETLOGS  ARCHIVELOG
        MAXLOGFILES 16
        MAXLOGMEMBERS 3
        MAXDATAFILES 100
        MAXINSTANCES 8
        MAXLOGHISTORY 292
    LOGFILE
      GROUP 1 SIZE 50M BLOCKSIZE 512,
      GROUP 2 SIZE 50M BLOCKSIZE 512,
      GROUP 3 SIZE 50M BLOCKSIZE 512
    DATAFILE
    ${dbfiles}
    CHARACTER SET AL32UTF8;

    recover database until cancel using backup controlfile;
`cat ${RECOVERY_FILE}`

    alter database open resetlogs;

    alter tablespace temp add tempfile size 50M autoextend on next 10M maxsize unlimited;

    -- update memory setting and restart the instance
    alter system set sga_target=3G scope=spfile;
    alter system set pga_aggregate_target=1G scope=spfile;
    shutdown immediate;
    startup;
EOF

RC=$?

#if [ "${RC}" -ne 0 ]; then
#    echo "ERROR: Some issues detected during reconfiguration phase, aborting"
#    exit 1
#fi
