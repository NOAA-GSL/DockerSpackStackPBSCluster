#!/bin/bash

set -e

cd "$(dirname "$0")"

module use /opt/spack-stack/envs/unified-env/modules/Core
module load stack-gcc
module load stack-openmpi

# Build the MPI hello world. /home/admin (and this test dir) is a shared volume
# mounted on every mom node, so the single binary we build here is visible to all
# ranks the PBS job launches.
mpif90 -o hello.exe mpi_hello.f90

# PBS batch job: request 3 chunks of 2 MPI ranks each (6 ranks total, 2 per node).
# place=scatter forces each chunk onto a distinct node so we exercise multi-node
# launch. Inside the job we re-init Lmod and reload the stack -- PBS runs the
# script as a non-login shell that won't source /etc/profile, so the `module`
# function isn't defined otherwise. `mpiexec` with no -np picks up the PBS
# allocation via OpenMPI's TM integration (schedulers=tm) and spawns all 6 ranks.
cat > hello.pbs <<'EOF'
#!/bin/bash
#PBS -N hello
#PBS -l select=3:ncpus=2:mpiprocs=2
#PBS -l place=scatter
#PBS -j oe
#PBS -o hello.pbs.log

cd "$PBS_O_WORKDIR"

source /usr/lmod/lmod/init/bash
module use /opt/spack-stack/envs/unified-env/modules/Core
module load stack-gcc
module load stack-openmpi

mpiexec ./hello.exe > hello.raw
EOF

# -W block=true makes qsub wait for the job to finish and exit with the job's
# status, so a job failure trips `set -e` instead of being silently masked.
qsub -W block=true hello.pbs

sort hello.raw > hello.out
diff hello.out hello.baseline
