# PolarDB-PG Images

## Runtime/Development Image

[`polardb/polardb_pg_devel:${tag}`](https://hub.docker.com/r/polardb/polardb_pg_devel/tags) provides runtime environment and compilation dependencies for PolarDB-PG. According to the base OS being used, it includes following tags:

- `ubuntu24.04`: use [`ubuntu:24.04`](https://hub.docker.com/_/ubuntu/tags) as base OS
- `ubuntu22.04`: use [`ubuntu:22.04`](https://hub.docker.com/_/ubuntu/tags) as base OS
- `ubuntu20.04`: use [`ubuntu:20.04`](https://hub.docker.com/_/ubuntu/tags) as base OS
- `rocky9`: use [`rockylinux:9`](https://hub.docker.com/_/rockylinux/tags) as base OS
- `rocky8`: use [`rockylinux:8`](https://hub.docker.com/_/rockylinux/tags) as base OS
- `anolis8`: use [`openanolis/anolisos:8.6`](https://hub.docker.com/r/openanolis/anolisos/tags) as base OS
- `centos7` (DEPRECATED): use [`centos:centos7`](https://hub.docker.com/_/centos/tags) as base OS

## Binary Image

[`polardb/polardb_pg_binary:${tag}`](https://hub.docker.com/r/polardb/polardb_pg_binary/tags) is based on `polardb/polardb_pg_devel:22.04`, providing latest binary built from stable branch of PolarDB-PG. This image is enough for running PolarDB-PG.

## Local Instance Image

[`polardb/polardb_pg_local_instance:${tag}`](https://hub.docker.com/r/polardb/polardb_pg_local_instance/tags) is based on `polardb/polardb_pg_binary:${tag}`, with an entrypoint for initializing and starting-up PolarDB-PG instance on local file system.

### Without Data Persistence

Simply try without persisting data directories. It will initialize database inside the container and start the database up. Override Docker `CMD` of image with `psql` to connect to the database:

```shell
$ docker run -it --rm polardb/polardb_pg_local_instance:15 psql
...
psql (PostgreSQL 15.8 (PolarDB 15.8.2.0 build unknown) on x86_64-linux-gnu)
Type "help" for help.

postgres=#
```

If you don't want to get into `psql`, simply override Docker `CMD` with other command:

```shell
$ docker run -it --rm \
    polardb/polardb_pg_local_instance:15 \
    bash
...
postgres@876f3bc68b4e:~$
```

### With Data Persistence

Use an empty local directory as a volume, and mount the volume when creating the container. The container entry point will try to initdb in this volume. `${your_data_dir}` should be empty for the first time. If the volume is not empty, the entry point will regard the volume as already been initialized, and will start-up the database instance from the volume. The volume must be mounted under `/var/polardb/` inside container:

```shell
docker run -it --rm \
    -v ${your_data_dir}:/var/polardb \
    polardb/polardb_pg_local_instance:15 \
    psql
```

### Running as Daemon

For those who want to use PolarDB-PG as a daemon service, the container can be created with `-d` option:

```shell
docker run -d \
    -v ${your_data_dir}:/var/polardb \
    polardb/polardb_pg_local_instance:15
```

### Exposing Ports

For those who want to export ports to host machine, use `POLARDB_PORT` environment variable to specify ports. Typically, PolarDB-PG needs three continuous unused ports. Use `-p` option to expose these ports, e.g. `5432-5434`:

```shell
docker run -d \
    --env POLARDB_PORT=5432 \
    -p 5432-5434:5432-5434 \
    -v ${your_data_dir}:/var/polardb \
    polardb/polardb_pg_local_instance:15
```

Or directly use `--network=host` to share network with host machine:

```shell
$ docker run -d \
    --network=host \
    --env POLARDB_PORT=5432 \
    -v ${your_data_dir}:/var/polardb \
    polardb/polardb_pg_local_instance:15
$ ...
$ psql -h 127.0.0.1 -p 5432 -U postgres
psql (PostgreSQL 15.8 (PolarDB 15.8.2.0 build unknown) on x86_64-linux-gnu)
Type "help" for help.

postgres=#
```

### Environment Variables

- `POLARDB_PORT`: the port on which primary node will be running; two replica nodes will be running at `${POLARDB_PORT}+1` and `${POLARDB_PORT}+2`
- `POLARDB_USER`: the default superuser to be created during initialization
- `POLARDB_PASSWORD`: the default password to be used by `POLARDB_USER` or `postgres`
