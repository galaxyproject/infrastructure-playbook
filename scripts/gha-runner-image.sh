#!/usr/bin/env bash
set -euo pipefail

: ${HYPERVISOR:=smart1.galaxyproject.org}

VM_ALIAS="${1:-}"

if [ -z "$VM_ALIAS" ]; then
    echo "usage: ${0##*/} <vm-alias>"
    exit 1
fi

vm_uuid() {
    { set +x; } 2>/dev/null
    local alias="$1" uuids count
    uuids="$(ssh -n "root@${HYPERVISOR}" vmadm lookup "alias=${alias}")" || true
    count="$(printf '%s' "$uuids" | grep -c . || true)"
    if [ "$count" -eq 0 ]; then
        echo "${0##*/}: alias '${alias}' does not match, assuming no old VM" >&2
        return 0
    elif [ "$count" -ne 1 ]; then
        echo "${0##*/}: alias '${alias}' matches ${count} VMs, expected exactly 1" >&2
        return 1
    fi
    printf '%s' "$uuids"
    set -x
}

set -x

OLD_UUID="$(vm_uuid "$VM_ALIAS")"
if [ -n "$OLD_UUID" ]; then
    ssh -n "root@${HYPERVISOR}" svcadm disable -st site/gha-runner-cycle
    ssh -n "root@${HYPERVISOR}" /opt/custom/sbin/gha-runner-drain.sh "${VM_ALIAS}"
    ssh -n "root@${HYPERVISOR}" vmadm destroy "${OLD_UUID}"
fi
ssh-keygen -R "${VM_ALIAS}.galaxyproject.org"
ansible-playbook -i inventory/galaxyproject.yaml --limit="${HYPERVISOR}" playbook-smartos-hypervisor.yaml
while !  ssh-keyscan -q ${VM_ALIAS}.galaxyproject.org >> ~/.ssh/known_hosts ; do sleep 5 ; done
ansible-playbook -i inventory/galaxyproject.yaml --limit="${VM_ALIAS}.galaxyproject.org" playbook-bootstrap.yaml
ansible-playbook -i inventory/galaxyproject.yaml --limit="${VM_ALIAS}.galaxyproject.org" playbook-general.yaml
ansible-playbook -i inventory/galaxyproject.yaml --limit="${VM_ALIAS}.galaxyproject.org" playbook-github-self-hosted-runners.yaml
NEW_UUID="$(vm_uuid "$VM_ALIAS")"
ssh -n "root@${HYPERVISOR}" vmadm stop "${NEW_UUID}"
ssh -n "root@${HYPERVISOR}" "uuid=${NEW_UUID}; "'until [ "$(vmadm list -H -o state uuid="$uuid")" = stopped ]; do sleep 2; done'
ssh -n "root@${HYPERVISOR}" zfs set quota=none "zones/${NEW_UUID}"
ssh -n "root@${HYPERVISOR}" zfs snapshot "zones/${NEW_UUID}/disk0@golden"
ssh "root@${HYPERVISOR}" svcadm enable site/gha-runner-cycle
