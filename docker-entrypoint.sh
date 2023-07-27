#!/bin/bash

polar_data_dir=${POLARDB_DATA_DIR}
sudo mkdir -p ${polar_data_dir}
sudo chmod a+wr ${polar_data_dir}
sudo chown -R postgres:postgres ${polar_data_dir}

primary_datadir="$polar_data_dir/primary_datadir"
replica_datadir="$polar_data_dir/replica_datadir"
shared_datadir="$polar_data_dir/shared_datadir"

polardb_init() {
    repnum=2
    primary_port=$PGPORT

    rm -rf ${primary_datadir}
    rm -rf ${shared_datadir}
    mkdir -p ${primary_datadir}
    mkdir -p ${shared_datadir}

    initdb -k -U postgres -D ${primary_datadir}

    echo "polar_enable_shared_storage_mode = on
    polar_hostid = 1
    max_connections = 100
    polar_wal_pipeline_enable = true
    polar_create_table_with_full_replica_identity = off
    logging_collector = on
    log_directory = 'pg_log'

    unix_socket_directories='.'
    shared_buffers = 128MB
    synchronous_commit = on
    full_page_writes = off
    #random_page_cost = 1.1
    autovacuum_naptime = 10min
    max_worker_processes = 32
    polar_use_statistical_relpages = off
    polar_enable_persisted_buffer_pool = off
    polar_nblocks_cache_mode = 'all'
    polar_enable_replica_use_smgr_cache = on
    polar_enable_standby_use_smgr_cache = on
    polar_enable_flashback_log = on" >> ${primary_datadir}/postgresql.conf

    disk_name=`echo ${shared_datadir} | cut -d '/' -f2`
    echo "polar_vfs.localfs_mode = true
    polar_enable_localfs_test_mode = on
    polar_enable_shared_storage_mode = on
    listen_addresses = '*'
    polar_disk_name = '$disk_name'
    polar_datadir = 'file-dio://$shared_datadir'" >> ${primary_datadir}/postgresql.conf

    echo "shared_preload_libraries = '\$libdir/polar_px,\$libdir/polar_vfs,\$libdir/polar_worker,\$libdir/pg_stat_statements,\$libdir/auth_delay,\$libdir/auto_explain,\$libdir/polar_monitor_preload,\$libdir/polar_stat_sql'" >> ${primary_datadir}/postgresql.conf && \
    polar-initdb.sh ${primary_datadir}/ ${shared_datadir}/ localfs

    echo "host all all 0.0.0.0/0 md5" >> ${primary_datadir}/pg_hba.conf

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

    echo "port = $primary_port
        polar_hostid = 100
        full_page_writes = off" >> $primary_datadir/postgresql.conf

    echo "polar_enable_px=0" >> $primary_datadir/postgresql.conf
    echo "polar_px_enable_check_workers=0" >> $primary_datadir/postgresql.conf
    echo "polar_px_enable_replay_wait=1" >> $primary_datadir/postgresql.conf
    echo "polar_px_dop_per_node=3" >> $primary_datadir/postgresql.conf
    echo "polar_px_max_workers_number=0" >> $primary_datadir/postgresql.conf
    echo "polar_px_enable_cte_shared_scan=1" >> $primary_datadir/postgresql.conf
    echo "polar_px_enable_partition=1" >> $primary_datadir/postgresql.conf
    echo "polar_px_enable_left_index_nestloop_join=1" >> $primary_datadir/postgresql.conf
    echo "polar_px_wait_lock_timeout=1800000" >> $primary_datadir/postgresql.conf
    echo "polar_px_enable_partitionwise_join=1" >> $primary_datadir/postgresql.conf
    echo "polar_px_optimizer_multilevel_partitioning=1" >> $primary_datadir/postgresql.conf
    echo "polar_px_max_slices=1000000" >> $primary_datadir/postgresql.conf
    echo "polar_px_enable_adps=1" >> $primary_datadir/postgresql.conf
    echo "polar_px_enable_adps_explain_analyze=1" >> $primary_datadir/postgresql.conf
    echo "polar_trace_heap_scan_flow=1" >> $primary_datadir/postgresql.conf
    echo "polar_px_enable_spi_read_all_namespaces=1" >> $primary_datadir/postgresql.conf

    pg_ctl -D ${primary_datadir} start
    for i in $(seq 1 $repnum)
    do
        psql -h 127.0.0.1 -d postgres -c "SELECT * FROM pg_create_physical_replication_slot('replica${i}')"
    done
    pg_ctl -D ${primary_datadir} stop
}

# If the data dir in empty, we will try to initdb here.
if [ -z "$(ls -A $polar_data_dir)" ];
then
   polardb_init
fi

# Start the database.
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
