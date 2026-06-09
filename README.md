[![Docker PBS](https://github.com/NOAA-GSL/DockerSpackStackPBSCluster/actions/workflows/docker.yml/badge.svg?branch=main)](https://github.com/NOAA-GSL/DockerSpackStackPBSCluster/actions/workflows/docker.yml)

# PBS Cluster with spack-stack in Ubuntu Docker images using Docker Compose

This is a fully functional OpenPBS cluster with
[spack-stack](https://spack-stack.readthedocs.io/en/latest/) installed inside a Docker container.

This work is an adaptation of an existing Dockerized scheduler cluster design,
updated for PBS and OpenPBS.

There are three containers:

* A frontend container that acts as a PBS cluster login node.
  Spack-stack is installed on the frontend in /opt/spack-stack which is mounted
  across the cluster as a shared volume using docker compose
* A server container that acts as a PBS server/controller node
* A mom container that acts as a PBS compute node

These containers are launched using Docker Compose to build
a fully functioning PBS cluster.  A `docker-compose.yml`
file defines the cluster, specifying ports and volumes to
be shared.  Multiple instances of the mom container can be
added to `docker-compose.yml` to grow the cluster: the PBS server
pre-declares nodes `pbsnode1` through `pbsnode10` (raise the cap with
the `PBS_MAX_NODES` environment variable on the server container), so
adding a `pbsnodeN` service with a matching `hostname: pbsnodeN` is all
it takes for that node to join. Declared nodes without a running
container simply appear `down` in `pbsnodes -a`.  The cluster behaves
as if it were running on multiple nodes even if the containers are all
running on the same host machine.

# Image tags and base selection

Published images are tagged by Ubuntu version + spack-stack version:

* `ubuntu-26.04-spack-stack-2.1.0` (also published as `latest`)
* `ubuntu-24.04-spack-stack-2.1.0`

Internally each variant pulls from the
[NOAA-GSL/DockerPBSCluster](https://github.com/NOAA-GSL/DockerPBSCluster)
base registry at the matching `ubuntu-<UBUNTU_VERSION>-openpbs-<OPENPBS_VERSION>` tag.
The base image's OpenPBS version is implicit -- consumers of these images interact
with the PBS tooling that came with the base, plus the spack-stack scientific
software stack layered on top.

A separate per-(ubuntu, spack-stack) OCI buildcache repo (e.g.
`ghcr.io/noaa-gsl/dockerspackstackpbscluster/buildcache-ubuntu-26.04-spack-stack-2.1.0`)
holds binary artifacts so rebuilds reuse cached packages instead of recompiling
from source. Caches are split per OS to prevent cross-OS spec contamination
during concretization.

## Configuring versions

The project root contains a `.env` file consumed by `docker compose`:

```bash
UBUNTU_VERSION=26.04
OPENPBS_VERSION=23.06.06
SPACK_STACK_VERSION=2.1.0
```

To run against the 24.04 base for one invocation without editing the file:

```bash
UBUNTU_VERSION=24.04 docker compose up -d --pull never
```

# Building the Containers

## Quickest path: docker compose

`docker compose build` reads `.env` and constructs the full set of build args
automatically. To build all three containers (frontend, server, mom) for the
default Ubuntu version:

```bash
docker compose build
```

Or just one:

```bash
docker compose build pbsfrontend
```

To build for a non-default Ubuntu version:

```bash
UBUNTU_VERSION=24.04 docker compose build pbsfrontend
```

### GitHub PAT for buildcache push

A GitHub personal access token (PAT) is only required if you want the build to
**push** newly-built spack packages back to the OCI buildcache (autopush) --
which is what CI and the original maintainer's builds do to keep the cache
populated. For most local development, where you just want to *consume*
artifacts the cache already has, no PAT is needed.

The frontend Dockerfile only configures autopush when the docker secret
`github_token` is present *and non-empty*. Compose accepts an unset or empty
`GITHUB_TOKEN` environment variable (the secret simply becomes an empty file
inside the build), so pull-only builds work without setting anything:

```bash
# Pull-only build: reads from the public buildcache, never pushes
docker compose build pbsfrontend
```

For push-capable builds, set the PAT before invoking compose:

```bash
export GITHUB_TOKEN=your_github_pat_here   # PAT with write:packages on the GHCR registry
docker compose build pbsfrontend
```

Note: this assumes the buildcache repo on GHCR is **public** (which is the
case for the upstream NOAA-GSL caches). If you maintain a fork with a private
cache, you'll need a PAT with read permission on the cache repo even for
pull-only builds.

## Direct buildx invocation

Equivalent build command for the frontend, useful when you want full control
(`--no-cache`, `--progress=plain`, custom tags) without going through compose:

```bash
export GITHUB_TOKEN=your_github_pat_here
docker buildx build \
  --progress=plain \
  --pull \
  --secret id=github_token,env=GITHUB_TOKEN \
  --build-arg SPACK_BUILD_JOBS=8 \
  --build-arg BASE_IMAGE_TAG=ubuntu-26.04-openpbs-23.06.06 \
  --build-arg UBUNTU_VERSION=26.04 \
  --build-arg SPACK_STACK_VERSION=2.1.0 \
  -t ghcr.io/noaa-gsl/dockerspackstackpbscluster/pbs-spack-stack-frontend:ubuntu-26.04-spack-stack-2.1.0 \
  -f frontend/Dockerfile \
  frontend/
```

The frontend build compiles ~356 scientific software packages and can take
many hours on first build from an empty buildcache. Subsequent builds reuse
cached packages from GHCR and finish much faster.

## Configuring Parallel Build Jobs

`SPACK_BUILD_JOBS` controls the number of parallel make jobs (`-j` flag) used
when building each package (default: 8). Match it to the CPU count of your
build machine:

```bash
docker buildx build --build-arg SPACK_BUILD_JOBS=16 ...
# or
docker compose build --build-arg SPACK_BUILD_JOBS=16
```

You can also change the default in `docker-compose.yml`:

```yaml
services:
  pbsfrontend:
    build:
      args:
        SPACK_BUILD_JOBS: 16  # Change from default 8
```

**Performance note:** higher values speed up compilation of individual
packages, especially large ones like ESMF, JEDI components, and NetCDF. On
32GB RAM systems values above 8 may cause memory pressure during compilation
of memory-intensive Fortran packages, potentially leading to swapping or OOM
errors.

# Quick Start

To start the PBS cluster environment (default Ubuntu 26.04):
```
docker compose -f docker-compose.yml up -d --pull never
```

For 24.04:
```
UBUNTU_VERSION=24.04 docker compose -f docker-compose.yml up -d --pull never
```

The frontend container takes several minutes on first launch (it populates the
shared `opt-vol` volume with the spack-stack install). Healthchecks ensure the
server and nodes wait for the frontend before starting.

### Switching `UBUNTU_VERSION` between runs

Docker named volumes are not auto-rebuilt when you change the image they're
attached to. To switch from 26.04 to 24.04 (or vice versa) on the same host,
you must explicitly remove the existing `home-vol` and `opt-vol` first:

```
docker compose down -v   # the -v flag deletes the named volumes
UBUNTU_VERSION=24.04 docker compose up -d --pull never
```

Without `-v`, the new container will mount the previous run's `/opt/spack-stack`, which
contains spack-built binaries linked against the *previous* OS's glibc. The
cluster will appear to start fine but `qsub` or other PBS job submission of any
spack-built executable will fail with `GLIBC_X.YZ not found`.

To stop the cluster:
```
docker compose -f docker-compose.yml stop
```
To check the cluster logs:
```
docker compose -f docker-compose.yml logs -f
```
(stop logs with CTRL-c)

To check status of the cluster containers:
```
docker compose -f docker-compose.yml ps
```
To check status of PBS:
```
docker exec spack-stack-frontend bash -lc "qstat"
```
To submit a simple PBS job:
```
docker exec spack-stack-frontend bash -lc "echo 'hostname' > /tmp/pbs-job.sh && qsub /tmp/pbs-job.sh"
```
To obtain an interactive shell in the container:
```
docker exec -it spack-stack-frontend bash -l
```

# Loading and using spack-stack

First, obtain a login shell in the container:
```
docker exec -it spack-stack-frontend bash -l
```

Next, load the spack-stack base environment:

```
module use /opt/spack-stack/envs/unified-env/modules/Core
module load stack-gcc
module load stack-openmpi
```

Once the basic spack-stack modules are loaded, you can choose from multiple spack-stack environments for different purposes.

For example:

* FV3:
  ```
  module load jedi-fv3-env
  ```

* MPAS
  ```
  module load jedi-mpas-env
  ```
