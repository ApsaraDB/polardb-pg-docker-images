#!/bin/bash

#------------------------------------------------------------------------------
# Utilities
#------------------------------------------------------------------------------
IC="" WC="" EC="" DC="" NC=""
COLORS=$(tput colors 2> /dev/null)
if [ $? = 0 ] && [ $COLORS -gt 2 ]; then
  IC='\033[0;32m' WC='\033[1;35m' EC='\033[1;31m' DC='\033[0;34m' NC='\033[0m'
fi
function info()  { echo -e ${IC}${@}${NC}; }
function warn()  { echo -e ${WC}${@}${NC}; }
function error() { echo -e ${EC}${@}${NC}; }
function debug() { echo -e ${DC}${@}${NC}; }

set -euo pipefail

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

polar_data_dir=${POLARDB_DATA_DIR}
sudo mkdir -p ${polar_data_dir}
sudo chmod a+wr ${polar_data_dir}
sudo chown -R postgres:postgres ${polar_data_dir}

primary_datadir="$polar_data_dir/primary_datadir"
replica_datadir="$polar_data_dir/replica_datadir"
shared_datadir="$polar_data_dir/shared_datadir"

initdb_flag="-k -A trust"

replica_num=1

function init_primary() {
    primary_dir=$1
    data_dir=$2
    port=$3

    initdb_flag+=" -D $primary_dir --wal-segsize=16 ${extra_initdb_flag-}"
    info "Begin initdb, flag: $initdb_flag"
    eval "initdb $initdb_flag"
    cat /u01/polardb_pg/share/postgresql/polardb.conf.sample >> $primary_dir/postgresql.conf
    echo "port = $port" >> $primary_dir/postgresql.conf
    echo "polar_datadir = 'file-dio://$data_dir'" >> $primary_dir/postgresql.conf

    # avoid problem if huge page is not enough.
    echo "huge_pages = off" >> $primary_dir/postgresql.conf

    echo "host all all 0.0.0.0/0 md5" >> $primary_dir/pg_hba.conf
    mkdir -p $data_dir
    polar-initdb.sh $primary_dir/ $data_dir/ primary localfs
    pg_ctl -D $primary_dir start -c -o --cluster-name="${cluster_name-}primary"
    connstr+="psql -h127.0.0.1 -p$port postgres #primary\n"
}

function init_follower() {
    follower_type=$1
    primary_dir=$2
    data_dir=$3
    follower_num=$4
    follower_dir_prefix=$5
    primary_port=$6

    for i in `seq 1 $follower_num`; do
        slot_name=$follower_type$i
        follower_dir=$follower_dir_prefix$i
        follower_port=$(($primary_port + $i))
        if [[ $follower_type == "standby" ]]; then
            follower_data_dir=$7$i
            pg_basebackup -h127.0.0.1 -p$port -D$follower_dir --polardata=$follower_data_dir -X stream -v
            echo "polar_datadir = 'file-dio://${follower_data_dir}'" >> $follower_dir/postgresql.conf
        else
            mkdir -m 700 -p $follower_dir
            polar-initdb.sh $follower_dir/ $data_dir/ replica localfs
            cp $primary_dir/*.conf $follower_dir/
        fi
        psql -h127.0.0.1 -p$port postgres -c "SELECT pg_create_physical_replication_slot('$slot_name')"
        echo "port = $follower_port" >> $follower_dir/postgresql.conf
        echo "primary_conninfo = 'host=127.0.0.1 port=$port dbname=postgres application_name=$slot_name'" >> $follower_dir/postgresql.conf
        echo "primary_slot_name = $slot_name" >> $follower_dir/postgresql.conf
        touch $follower_dir/$follower_type.signal
        pg_ctl -D $follower_dir start -c -o --cluster-name="${cluster_name-}$slot_name"
        connstr+="psql -h127.0.0.1 -p$follower_port postgres #$slot_name\n"
    done
}

polardb_init() {
    primary_port=${POLARDB_PORT:-5432}
    export PGPORT=$primary_port

    # private dir and shared dir
    rm -rf ${primary_datadir}
    rm -rf ${replica_datadir}*
    rm -rf ${shared_datadir}

    init_primary ${primary_datadir} ${shared_datadir} ${primary_port}
    init_follower replica ${primary_datadir} ${shared_datadir} ${replica_num} ${replica_datadir} ${primary_port}

    # create default user with password, if specified
    if [[ ${POLARDB_USER} == "postgres" ]];
    then
        if [[ -n ${POLARDB_PASSWORD} ]];
        then
            psql -p $primary_port -d postgres -c "ALTER ROLE ${POLARDB_USER} PASSWORD '${POLARDB_PASSWORD}'"
        fi
    elif [[ -n ${POLARDB_USER} ]];
    then
        if [[ -n ${POLARDB_PASSWORD} ]];
        then
            psql -p $primary_port -d postgres -c "CREATE ROLE ${POLARDB_USER} PASSWORD '${POLARDB_PASSWORD}' SUPERUSER LOGIN"
        fi
    fi

    # perform a checkpoint
    psql -p $primary_port -d postgres -c "CHECKPOINT"

    # stop nodes
    for i in $(seq 1 $replica_num)
    do
        dir=${replica_datadir}${i}
        pg_ctl -D ${dir} stop
    done
    pg_ctl -D ${primary_datadir} stop
}

# If the data volume is empty, we will try to initdb here.
if [ -z "$(ls -A $polar_data_dir)" ];
then
   polardb_init
fi

# Start-up PolarDB-PG.
pg_ctl -D ${primary_datadir} start
for i in $(seq 1 $replica_num)
do
    dir=${replica_datadir}${i}
    pg_ctl -D ${dir} start
done

# If the command line is postgres, we will keep this process running.
# Else, we will execute the command line instrctions.
if [ $1 == "postgres" ];
then
    tail -f /dev/null
else
    eval ${@:1}
fi

# Stop PolarDB-PG.
if [ ! $(pg_ctl -D ${primary_datadir} status | grep -q "server is running") ];
then
    pg_ctl -D ${primary_datadir} stop
fi

for i in $(seq 1 $replica_num)
do
    dir=${replica_datadir}${i}
    if [ ! $(pg_ctl -D ${dir} status | grep -q "server is running") ];
    then
        pg_ctl -D ${dir} stop
    fi
done
