#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2014, Joyent, Inc.
#

#
# Summary:
#
# This tool is used to create additional Jenkins slaves in EMY on the Jenkins
# Rig.
#
# Usage:
#
# create-slave.sh <name> [<dataset>]
#
# default for dataset is sdc-smartos-1.6.3.
#
# IMPORTANT: this script is intended to be run on the emy-jenkins HN. It won't
# work elsewhere currently.
#

set -o errexit
set -o pipefail

export PATH=/usr/bin:/usr/sbin:/smartdc/bin:/opt/smartdc/bin:/opt/local/bin:/opt/local/sbin:/opt/smartdc/agents/bin

exec 4>>slave-create.log
echo "" >&4
echo "== Starting Create ==" >&4
export BASH_XTRACEFD=4
set -o xtrace

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
DATACENTER="emy"
DATASET="sdc-smartos-1.6.3"

name=$1
dataset=$2

if [[ -z ${name} || -n $3 ]]; then
    echo "Usage: $0 <name> [<dataset>]" >&2
    exit 2
fi

if [[ -n ${dataset} ]]; then
    DATASET=${dataset}
fi

IMAGE_UUID=$(imgadm avail -H -o uuid,name,version \
    | awk '{ print $1,$2 "-" $3 }' | grep "${DATASET}$" | cut -d' ' -f1)
if [[ -z ${IMAGE_UUID} ]]; then
    echo "Unable to find dataset '${DATASET}'" >&2
    exit 1
fi

IMAGE_VERSION=$(imgadm show ${IMAGE_UUID} | json version)
if [[ -z ${IMAGE_UUID} ]]; then
    echo "Unable to determine image version" >&2
    exit 1
fi

TEMP_FILE=/tmp/payload.$$

if [[ ! -f automation.id_rsa && -f ~/.ssh/automation.id_rsa ]]; then
    cp ~/.ssh/automation.id_rsa .
fi

for file in payload.json setup-jenkins-slave.sh automation.id_rsa jenkins.creds; do
    if [[ ! -f ${file} ]]; then
        echo "Missing ${file} in $(pwd)" >&2
        exit 1
    fi
done

/usr/vm/sbin/add-userscript setup-jenkins-slave.sh \
    < <(sed -e "s/ALIAS/${name}/" \
        -e "s/IMAGE_UUID/${IMAGE_UUID}/" \
        -e "s/IMAGE_VERSION/${IMAGE_VERSION}/" \
        -e "s/JENKINS_CREDS/$(cat jenkins.creds)/" \
        payload.json \
        | (/usr/vm/sbin/add-userscript automation.id_rsa | sed -e 's/"user-script"/"automation.id_rsa"/')) \
        > ${TEMP_FILE}

sdc-vmapi /vms -X POST -d @${TEMP_FILE} > /tmp/output.$$
vm_uuid=$(json -H vm_uuid < /tmp/output.$$)

# XXX loop until "running"
state=$(sdc-vmapi /vms/${vm_uuid} | json -H state)
while [[ ${state} == "provisioning" ]]; do
    sleep 5
    state=$(sdc-vmapi /vms/${vm_uuid} | json -H state)
done

if [[ ${state} != "running" ]]; then
    echo "FAILED: expected 'running' got '${state}' for VM ${vm_uuid}" >&2
    exit 1
fi

sdc-vmapi /vms/${vm_uuid} > /tmp/object.$$
server_uuid=$(json -H server_uuid < /tmp/object.$$)
ip=$(json -H nics.0.ip < /tmp/object.$$)

# XXX loop until "hostname" is set which indicates we rebooted
while [[ "$(${SSH} root@${ip} hostname 2>/dev/null)" != "${name}" ]]; do
    sleep 5
done

# Add the SSH keys to known_hosts replacing any existing entries since we just
# set this up, but it might reuse an IP.
cat > /var/tmp/fix_known_hosts.sh <<EOF
set -o xtrace
set -o errexit
(cat ~/.ssh/known_hosts | grep -v '${ip} '; ssh-keyscan -t rsa,dsa ${ip}) > ~/.ssh/known_hosts.new
mv ~/.ssh/known_hosts.new ~/.ssh/known_hosts
EOF
scp /var/tmp/fix_known_hosts.sh root@jenkins.joyent.us:/var/tmp/fix_known_hosts.sh
ssh root@jenkins.joyent.us bash /var/tmp/fix_known_hosts.sh

if [[ -z "${JENKINS_USER}" ]]; then
    JENKINS_USER=guest
fi

ssh -o UserKnownHostsFile=$HOME/.ssh/known_hosts.jenkins-31337 \
        -p 31337 ${JENKINS_USER}@jenkins.joyent.us create-node ${name} <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<slave>
  <name>${name}</name>
  <description>VM ${vm_uuid} on server ${server_uuid} in ${DATACENTER}</description>
  <remoteFS>/root/data/jenkins</remoteFS>
  <numExecutors>1</numExecutors>
  <mode>NORMAL</mode>
  <retentionStrategy class="hudson.slaves.RetentionStrategy\$Always"/>
  <launcher class="hudson.slaves.JNLPLauncher"/>
  <label>${DATASET} sdc ${DATACENTER} ${name} oldest_jpc_platform</label>
  <nodeProperties/>
  <userId>guest</userId>
</slave>
EOF

set +o xtrace

# output data for ~/.ssh/config
echo "# ${DATASET} / ${DATACENTER}"
echo "Host ${name}"
echo "    User root"
echo "    Hostname ${ip}"
echo ""

exit 0
