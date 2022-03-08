#!/usr/bin/env python3
import ipaddress
import json

# This could all be in one script but that would take more Time and Effort, so this works for now:
#
# $ ansible-playbook -i env/admintraining/inventory env/admintraining/jetstream.yml
# In a venv w/ `openstack` installed:
# $ openstack server list --name 'gat-.*' -f json -c Name -c Networks --sort-column Name --sort-ascending > gat-vms.json
# $ ./route53.py
# In a venv w/ `awscli` installed:
# $ aws route53 change-resource-record-sets --hosted-zone-id Z022528316NCQCRTGOOLK --change-batch file://gat-route53.json

os_network = 'admintraining'
domain = '.us.galaxy.training.'

hosts = []
vms = json.load(open('gat-vms.json'))

for vm in vms:
    name = vm['Name']
    ip = None
    for _ip in [ipaddress.ip_address(ip) for ip in vm['Networks'][os_network]]:
        if not _ip.is_private:
            ip = str(_ip)
            break
    else:
        print(f"WARNING: No floating IP for {name}: {vm}")

    if ip:
        hosts.append((name + domain, ip))

actions = []

for fqdn, ip in hosts:
    action = {
        "Action": "UPSERT",
        "ResourceRecordSet": {
            "Name": fqdn,
            "Type": "A",
            "TTL": 7200,
            "ResourceRecords": [
                {
                    "Value": ip
                }
            ]
        }
    }
    actions.append(action)

changes = {
    "Changes": actions
}

json.dump(changes, open('gat-route53.json', 'w'))

sorted_hosts = []

for fqdn, ip in hosts:
    fqdn = fqdn.rstrip('.')
    idx = int((fqdn.split('.')[0]).split('-')[1])
    sorted_hosts.append((idx, fqdn, ip))

sorted_hosts.sort()

with open('gat-vms.tsv', 'w') as fh:
    for idx, fqdn, ip in sorted_hosts:
        fh.write(f"{fqdn}\t{ip}\n")
