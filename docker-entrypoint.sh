#!/bin/bash

polar_data_dir=${POLARDB_DATA_DIR}
sudo mkdir -p ${polar_data_dir}
sudo chmod a+wr ${polar_data_dir}
sudo chown -R postgres:postgres ${polar_data_dir}

primary_datadir="$polar_data_dir/primary_datadir"
replica_datadir="$polar_data_dir/replica_datadir"
shared_datadir="$polar_data_dir/shared_datadir"

repnum=2

polardb_init() {
    primary_port=${POLARDB_PORT:-5432}

    # primary private dir and shared dir
    rm -rf ${primary_datadir}
    rm -rf ${shared_datadir}
    mkdir -p ${primary_datadir}
    mkdir -p ${shared_datadir}

    # initdb
    initdb -k -U postgres -D ${primary_datadir}

    # default GUCs
    echo "polar_enable_shared_storage_mode = on" >> ${primary_datadir}/postgresql.conf
    echo "polar_hostid = 1" >> ${primary_datadir}/postgresql.conf
    echo "max_connections = 100" >> ${primary_datadir}/postgresql.conf
    echo "polar_wal_pipeline_enable = true" >> ${primary_datadir}/postgresql.conf
    echo "polar_create_table_with_full_replica_identity = off" >> ${primary_datadir}/postgresql.conf
    echo "logging_collector = on" >> ${primary_datadir}/postgresql.conf
    echo "log_directory = 'pg_log'" >> ${primary_datadir}/postgresql.conf

    echo "shared_buffers = 128MB" >> ${primary_datadir}/postgresql.conf
    echo "synchronous_commit = on" >> ${primary_datadir}/postgresql.conf
    echo "full_page_writes = off" >> ${primary_datadir}/postgresql.conf
    echo "autovacuum_naptime = 10min" >> ${primary_datadir}/postgresql.conf
    echo "max_worker_processes = 32" >> ${primary_datadir}/postgresql.conf
    echo "polar_use_statistical_relpages = off" >> ${primary_datadir}/postgresql.conf
    echo "polar_enable_persisted_buffer_pool = off" >> ${primary_datadir}/postgresql.conf
    echo "polar_nblocks_cache_mode = 'all'" >> ${primary_datadir}/postgresql.conf
    echo "polar_enable_replica_use_smgr_cache = on" >> ${primary_datadir}/postgresql.conf
    echo "polar_enable_standby_use_smgr_cache = on" >> ${primary_datadir}/postgresql.conf
    echo "polar_enable_flashback_log = on" >> ${primary_datadir}/postgresql.conf
    echo "polar_enable_fast_recovery_area = on" >> ${primary_datadir}/postgresql.conf

    # storage-related GUCs
    disk_name=`echo ${shared_datadir} | cut -d '/' -f2`
    echo "polar_vfs.localfs_mode = true" >> ${primary_datadir}/postgresql.conf
    echo "polar_enable_localfs_test_mode = on" >> ${primary_datadir}/postgresql.conf
    echo "polar_enable_shared_storage_mode = on" >> ${primary_datadir}/postgresql.conf
    echo "listen_addresses = '*'" >> ${primary_datadir}/postgresql.conf
    echo "polar_disk_name = '$disk_name'" >> ${primary_datadir}/postgresql.conf
    echo "polar_datadir = 'file-dio://$shared_datadir'" >> ${primary_datadir}/postgresql.conf

    # preload extensions
    echo "shared_preload_libraries = '\$libdir/polar_px,\$libdir/polar_vfs,\$libdir/polar_worker,\$libdir/pg_stat_statements,\$libdir/auth_delay,\$libdir/auto_explain,\$libdir/polar_monitor_preload,\$libdir/polar_stat_sql'" >> ${primary_datadir}/postgresql.conf

    # shared dir initialization
    polar-initdb.sh ${primary_datadir}/ ${shared_datadir}/ localfs

    # allow external connections
    echo "host all all 0.0.0.0/0 md5" >> ${primary_datadir}/pg_hba.conf

    # replica initialization
    for i in $(seq 1 $repnum)
    do
        dir=${replica_datadir}${i}
        rm -rf $dir
        cp -frp ${primary_datadir} ${dir}

        port=$(($primary_port+$i))
        echo "port = $port
            polar_hostid = $i" >> $dir/postgresql.conf

        echo "primary_conninfo = 'host=localhost port=$primary_port user=postgres dbname=postgres application_name=replica${i}'" >> $dir/recovery.conf
        echo "primary_slot_name = 'replica${i}'" >> $dir/recovery.conf
        echo "synchronous_standby_names='replica${i}'" >> $dir/postgresql.conf
        echo "polar_replica = on" >> $dir/recovery.conf
        echo "recovery_target_timeline = 'latest'" >> $dir/recovery.conf
    done

    echo "port = $primary_port" >> ${primary_datadir}/postgresql.conf
    echo "polar_hostid = 100" >> ${primary_datadir}/postgresql.conf
    echo "full_page_writes = off" >> ${primary_datadir}/postgresql.conf

    # PX related GUCs
    echo "polar_enable_px=0" >> ${primary_datadir}/postgresql.conf
    echo "polar_px_enable_check_workers=0" >> ${primary_datadir}/postgresql.conf
    echo "polar_px_enable_replay_wait=1" >> ${primary_datadir}/postgresql.conf
    echo "polar_px_dop_per_node=3" >> ${primary_datadir}/postgresql.conf
    echo "polar_px_max_workers_number=0" >> ${primary_datadir}/postgresql.conf
    echo "polar_px_enable_cte_shared_scan=1" >> ${primary_datadir}/postgresql.conf
    echo "polar_px_enable_partition=1" >> ${primary_datadir}/postgresql.conf
    echo "polar_px_enable_left_index_nestloop_join=1" >> ${primary_datadir}/postgresql.conf
    echo "polar_px_wait_lock_timeout=1800000" >> ${primary_datadir}/postgresql.conf
    echo "polar_px_enable_partitionwise_join=1" >> ${primary_datadir}/postgresql.conf
    echo "polar_px_optimizer_multilevel_partitioning=1" >> ${primary_datadir}/postgresql.conf
    echo "polar_px_max_slices=1000000" >> ${primary_datadir}/postgresql.conf
    echo "polar_px_enable_adps=1" >> ${primary_datadir}/postgresql.conf
    echo "polar_px_enable_adps_explain_analyze=1" >> ${primary_datadir}/postgresql.conf
    echo "polar_trace_heap_scan_flow=1" >> ${primary_datadir}/postgresql.conf
    echo "polar_px_enable_spi_read_all_namespaces=1" >> ${primary_datadir}/postgresql.conf

    # Shared server GUCs
    echo "polar_enable_shared_server = on" >> ${primary_datadir}/postgresql.conf
    echo "polar_enable_shm_aset = on" >> ${primary_datadir}/postgresql.conf

    # start up primary node
    pg_ctl -D ${primary_datadir} start

    # create replication slots
    for i in $(seq 1 $repnum)
    do
        psql -h 127.0.0.1 -p $primary_port -d postgres -c "SELECT * FROM pg_create_physical_replication_slot('replica${i}')"
    done

    # create default user with password, if specified
    if [[ ${POLARDB_USER} == "postgres" ]];
    then
        if [[ -n ${POLARDB_PASSWORD} ]];
        then
            psql -h 127.0.0.1 -p $primary_port -d postgres -c "ALTER ROLE ${POLARDB_USER} PASSWORD '${POLARDB_PASSWORD}'"
        fi
    elif [[ -n ${POLARDB_USER} ]];
    then
        if [[ -n ${POLARDB_PASSWORD} ]];
        then
            psql -h 127.0.0.1 -p $primary_port -d postgres -c "CREATE ROLE ${POLARDB_USER} PASSWORD '${POLARDB_PASSWORD}' SUPERUSER LOGIN"
        fi
    fi

    # stop primary node
    pg_ctl -D ${primary_datadir} stop
}

# If the data volume is empty, we will try to initdb here.
if [ -z "$(ls -A $polar_data_dir)" ];
then
   polardb_init
fi

# Start-up PolarDB-PG.
pg_ctl -D ${primary_datadir} start
for i in $(seq 1 $repnum)
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

for i in $(seq 1 $repnum)
do
    dir=${replica_datadir}${i}
    if [ ! $(pg_ctl -D ${dir} status | grep -q "server is running") ];
    then
        pg_ctl -D ${dir} stop
    fi
done
