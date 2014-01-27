#!/bin/bash
set -o errexit -o nounset -o pipefail
function -h {
cat <<USAGE
 Install Aurora on a Mesos cluster. Currently only supports a single Aurora
 Scheduler Master.

 USAGE: accp.bash < <cluster_config_file>
        accp.bash master
        accp.bash slave
        accp.bash build

  Cluster config input example:

    # Mesos Master IP (external)   Mesos Master IP (internal)
    54.168.1.10                    192.168.1.10

    # Master and Slave sections must be seperated by a newline.
    # Leading and trailing blanks are okay.
    # Comments are from '#' to end-of-line.
    # Mesos Slave IP's (external)
    54.168.1.11
    54.168.1.12
    54.168.1.13

USAGE
}; function --help { -h ;}                 # A nice way to handle -h and --help

function main {
  cluster "$@"
}

function globals {
  export LC_ALL=en_US.UTF-8                  # A locale that works consistently
  export LANG="$LC_ALL"
  mesos_release=0.15.0
  aurora_repo=https://github.com/apache/incubator-aurora.git
  aurora_release=0.4.3
  aurora_tarball="aurora_${aurora_release}-${mesos_release}.tgz"
  aurora_fetch="http://downloads.mesosphere.io/aurora/${aurora_tarball}"
}; globals

################################################################ Configurations

# Args are the Mesos master internal IP addresses
function master {
  msg "master: Installing Aurora Scheduler on $(hostname -f)"
  install_aurora_master "$@"
}

function slave {
  msg "slave: Install Aurora on $(hostname -f)"
  install_aurora_slave
}

function build {
  msg "Building Aurora..."
  build_prereqs
  checkout_aurora
  build_aurora
  create_tarball
}

function cluster {
  read_cluster_spec
  ssh_options "$@"
  local n=0
  for server in "${slaves[@]:+${slaves[@]}}"
  do
    msg "-- $server"
    local ssh=()
    [[ ! ${ssh_key:-} ]] || ssh+=( -i "$ssh_key" )
    [[ ${ssh_user:-}  ]] && ssh+=( "$ssh_user@$server" ) || ssh+=( "$server" )
    if remote "${ssh[@]}" -- slave
    then msg "++ $server" 
    else msg "!! $server"
    fi
  done
  for server in "${masters[@]:+${masters[@]}}"
  do
    msg "-- $server (${masters_internal[$n]})"
    local ssh=()
    [[ ! ${ssh_key:-} ]] || ssh+=( -i "$ssh_key" )
    [[ ${ssh_user:-}  ]] && ssh+=( "$ssh_user@$server" ) || ssh+=( "$server" )
    if remote "${ssh[@]}" -- master "${masters_internal[@]}"
    then msg "++ $server" 
    else msg "!! $server"
    fi
    n=$(( $n+1 ))
  done
}

# Initialize global arrays which describe the cluster by parsing STDIN.
function read_cluster_spec {
  slaves=()                                    # List of slave IPs or hostnames
  masters=()                                  # List of master IPs or hostnames
  masters_internal=()                 # Might be needed for configuration files
  local pushing=masters                                          # Parser state
  while read -r line
  do    # TODO: Recognize and report invalid lines instead of just erroring out
    case "$line" in
      '#'*) : ;;                                                # Skip comments
      '') [[ ${#masters[@]} -le 0 ]] || pushing=slaves ;;        # Switch modes
      *)  set -- $line
          case "$pushing" in
            masters) masters+=( "$1" ) ; masters_internal+=( "$2" ) ;;
            slaves)  slaves+=( "$1" ) ;;
            *)       err "Invalid parsing mode: '$pushing'. This is a bug." ;;
          esac ;;
    esac
  done
}

# Initialize global SSH options from arguments.
function ssh_options {
  ssh_key=""
  ssh_user=""
  while [[ ${1:+isset} ]]
  do
    case "$1" in
      --ssh-key)  ssh_key="$2" ; shift ;;
      --ssh-user) ssh_user="$2" ; shift ;;
      --*)        err "No such option: $1" ;;
    esac
    shift
  done
}

###################################################### Aurora Install Utilities

# This code was taken mostly verbatim from the Aurora provisioning examples
# for Vagrant. In particular:
#   - examples/vagrant/provision-dev-environment.sh
#   - examples/vagrant/provision-aurora-scheduler.sh
#   - examples/vagrant/provision-mesos-slave.sh

function fetch_aurora {
  msg "Downloading and extracting Aurora tarball"
  curl -sSfLO "$aurora_fetch"
  tar xzf "$aurora_tarball"
}

function install_aurora_slave {
  fetch_aurora
  sudo dd of=/usr/local/bin/thermos_observer.sh >/dev/null 2>&1 <<\EOF
#!/usr/bin/env bash
(
  while true
  do
    /usr/local/bin/thermos_observer \
         --root=/var/run/thermos \
         --port=1338 \
         --log_to_disk=NONE \
         --log_to_stderr=google:INFO
    echo "Observer exited with $?, restarting."
    sleep 10
  done
) & disown
EOF
  sudo chmod +x /usr/local/bin/thermos_observer.sh

  # TODO: Replace with public and versioned URLs.
  for pex in gc_executor thermos_executor thermos_observer
  do sudo install -m 755 aurora/dist/"$pex".pex /usr/local/bin/"$pex"
  done

  sudo dd of=/etc/rc.local >/dev/null 2>&1 <<EOF
/usr/local/bin/thermos_observer.sh >/var/log/thermos-observer.log 2>&1
EOF
  sudo chmod +x /etc/rc.local
  sudo /etc/rc.local
}

# Args are the Mesos master internal IP addresses
# depends on an aurora tarball extract into aurora/dist/...
function install_aurora_master {
  fetch_aurora
  local aurora_scheduler_home=/usr/local/aurora-scheduler
  sudo tar xvf aurora/dist/distributions/aurora-scheduler*.tar -C /usr/local
  sudo ln -nfs "$(ls -dt /usr/local/aurora-scheduler-* | head -1)" \
    "$aurora_scheduler_home"

  sudo install -m 755 aurora/dist/aurora_client.pex /usr/local/bin/aurora
  sudo install -m 755 aurora/dist/aurora_admin.pex /usr/local/bin/aurora_admin

  sudo dd of=/usr/local/sbin/aurora-scheduler.sh >/dev/null 2>&1 <<EOF
#!/usr/bin/env bash

# Flags that control the behavior of the JVM.
JAVA_OPTS=(
  -server
  -Xmx1g
  -Xms1g

  # Location of libmesos-0.15.0.so / libmesos-0.15.0.dylib
  -Djava.library.path=/usr/local/lib
)

# Flags control the behavior of the Aurora scheduler.
# For a full list of available flags, run bin/aurora-scheduler -help
AURORA_FLAGS=(
  -cluster_name=example

  # Ports to listen on.
  -http_port=8081
  -thrift_port=8082

  -native_log_quorum_size=1

  -zk_endpoints="$1:2181"
  -mesos_master_address="zk://$1:2181/mesos"

  -serverset_path=/aurora/scheduler

  -native_log_zk_group_path=/aurora/replicated-log

  -native_log_file_path="$aurora_scheduler_home/db"
  -backup_dir="$aurora_scheduler_home/backups"

  -thermos_executor_path=/usr/local/bin/thermos_executor
  -gc_executor_path=/usr/local/bin/gc_executor

  -vlog=INFO
  -logtostderr
)

# Environment variables control the behavior of the Mesos scheduler driver
# (libmesos).
export GLOG_v=0
export LIBPROCESS_PORT=8083
export LIBPROCESS_IP="$1"

(
  while true
  do
    JAVA_OPTS="\${JAVA_OPTS[*]}" exec \\
              "$aurora_scheduler_home/bin/aurora-scheduler" \\
              "\${AURORA_FLAGS[@]}"
  done
) &
EOF
  sudo chmod +x /usr/local/sbin/aurora-scheduler.sh

  sudo mkdir -p /etc/aurora
  sudo dd of=/etc/aurora/clusters.json >/dev/null 2>&1 <<EOF
[{
  "name": "example",
  "zk": "$1",
  "scheduler_zk_path": "/aurora/scheduler",
  "auth_mechanism": "UNAUTHENTICATED"
}]
EOF

  sudo dd of=/etc/rc.local >/dev/null 2>&1 <<EOF
/usr/local/sbin/aurora-scheduler.sh \
  1> /var/log/aurora-scheduler-stdout.log \
  2> /var/log/aurora-scheduler-stderr.log
EOF
  sudo chmod +x /etc/rc.local
  sudo /etc/rc.local
}

######################################################## Aurora Build Utilities

function checkout_aurora {
  if [[ ! -d aurora ]]
  then
    msg "Checking out Aurora repo..."
    git clone -q -b "$aurora_release" "$aurora_repo" aurora > /dev/null 2>&1
  fi
}

function build_prereqs {
  msg "Installing prereqs..."
  sudo apt-get -qq update
  sudo apt-get -qq install \
               git automake libtool g++ default-jre default-jdk curl \
               python-dev libsasl2-dev libcurl4-openssl-dev make
}

function build_aurora {
  msg "Building Aurora..."
  pushd aurora
    mkdir -p third_party
    ( cd third_party
      wget -c "http://downloads.mesosphere.io/master/ubuntu/13.04/mesos_${mesos_release}_amd64.egg" \
           -O "mesos-${mesos_release}-py2.7-linux-x86_64.egg" )

    # build scheduler
    ./gradlew distTar

    # build clients
    msg "Building Aurora clients"
    ./pants src/main/python/apache/aurora/client/bin:aurora_admin
    ./pants src/main/python/apache/aurora/client/bin:aurora_client

    # fixup python build deps (currently hard-coded to 0.15.0-rc4)
    # this is required for the executors/observers to build
    sed -r --in-place \
      "s/(mesos-core.*)([0-9]+\.[0-9]+\.[0-9]+)+(-rc[0-9]+)?/\1${mesos_release}/g;" \
      src/main/python/apache/aurora/BUILD.thirdparty
  
    # build executors/observers
    msg "Building Aurora executors/observers"
    ./pants src/main/python/apache/aurora/executor/bin:gc_executor
    ./pants src/main/python/apache/aurora/executor/bin:thermos_executor
    ./pants src/main/python/apache/aurora/executor/bin:thermos_runner
    ./pants src/main/python/apache/thermos/observer/bin:thermos_observer
  
    # package runner w/in executor
    python <<EOF
import contextlib
import zipfile
with contextlib.closing(zipfile.ZipFile('dist/thermos_executor.pex', 'a')) as zf:
  zf.writestr('apache/aurora/executor/resources/__init__.py', '')
  zf.write('dist/thermos_runner.pex', 'apache/aurora/executor/resources/thermos_runner.pex')
EOF
  popd
}

function create_tarball {
  rm -f "$aurora_tarball"
  tar czvf "$aurora_tarball" aurora/dist/*.pex aurora/dist/distributions
}

############################################################ Remoting Utilities

# Used like this: remote <ssh options> -- <command> <arg>*
function remote {
  local ssh=( -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no )
  local shell=( bash )
  while [[ ${1:+isset} ]]
  do
    case "$1" in
      --sudo) shell=( sudo bash ) ; shift ;;
      --)     shift ; break ;;
      *)      ssh=( "${ssh[@]}" "$1" ) ; shift ;;
    esac
  done
  serialized "$@" | ssh "${ssh[@]}" "${shell[@]}"
}

# Send over local function definitions and then call the desired command.
function serialized {
  declare -f
  echo set -o errexit -o nounset -o pipefail
  echo -n 'globals &&'
  printf ' %q' "$@" ; echo
}

function msg { out "$*" >&2 ;}
function err { local x=$? ; msg "$*" ; return $(( $x == 0 ? 1 : $x )) ;}
function out { printf '%s\n' "$*" ;}

if [[ ${1:-} ]] && declare -F | cut -d' ' -f3 | fgrep -qx -- "${1:-}"
then "$@"
else main "$@"
fi

