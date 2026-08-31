#!/usr/bin/env bash
set -euo pipefail

: ${HYPERVISOR:=smart1.galaxyproject.org}

VM_ALIAS="${1:-}"

if [ -z "$VM_ALIAS" ]; then
    echo "usage: ${0##*/} <vm-alias>"
    exit 1
fi

set -x

OLD_UUID="$(ssh -n "root@${HYPERVISOR}" vmadm list -p "alias=${VM_ALIAS}" | awk -F: '{print $1}')"
ssh -n "root@${HYPERVISOR}" svcadm disable -st site/gha-runner-cycle
ssh -n "root@${HYPERVISOR}" /opt/custom/sbin/gha-runner-drain.sh "${VM_ALIAS}"
ssh -n "root@${HYPERVISOR}" zfs destroy "zones/${OLD_UUID}/disk0@golden"
ssh -n "root@${HYPERVISOR}" vmadm destroy "${OLD_UUID}"
ssh-keygen -R "${VM_ALIAS}.galaxyproject.org"
ansible-playbook -i inventory/galaxyproject.yaml --limit="${HYPERVISOR}" playbook-smartos-hypervisor.yaml
while !  ssh-keyscan -q ${VM_ALIAS}.galaxyproject.org >> ~/.ssh/known_hosts ; do sleep 5 ; done
ansible-playbook -i inventory/galaxyproject.yaml --limit="${VM_ALIAS}.galaxyproject.org" playbook-bootstrap.yaml
ansible-playbook -i inventory/galaxyproject.yaml --limit="${VM_ALIAS}.galaxyproject.org" playbook-general.yaml
ansible-playbook -i inventory/galaxyproject.yaml --limit="${VM_ALIAS}.galaxyproject.org" playbook-github-self-hosted-runners.yaml
NEW_UUID="$(ssh -n "root@${HYPERVISOR}" vmadm list -p "alias=${VM_ALIAS}" | awk -F: '{print $1}')"
ssh -n "root@${HYPERVISOR}" vmadm stop "${NEW_UUID}"
ssh -n "root@${HYPERVISOR}" "uuid=${NEW_UUID}; "'until [ "$(vmadm list -H -o state uuid="$uuid")" = stopped ]; do sleep 2; done'
ssh -n "root@${HYPERVISOR}" zfs set quota=none "zones/${NEW_UUID}"
ssh -n "root@${HYPERVISOR}" zfs snapshot "zones/${NEW_UUID}/disk0@golden"
ssh "root@${HYPERVISOR}" svcadm enable site/gha-runner-cycle
