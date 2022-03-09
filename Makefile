#
# Basic usage:
#   Run `playbook.yml` in env `<env>`:
#     $ make <env>`
#
# Advanced usage:
#   Run `<PLAYBOOK>.yml` with `--tags=<TAGS>` and `--limit=<LIMIT>` in env `<env>`:
#     $ make TAGS=<tag[,tag ...]> LIMIT=<host_or_group[,host_or_group ...]> PLAYBOOK=<basename> <env>

ifneq ($(strip $(TAGS)),)
TAGS_ARG="--tags=$(TAGS)"
endif
ifneq ($(strip $(LIMIT)),)
LIMIT_ARG="--limit=$(LIMIT)"
endif
PLAYBOOK := playbook


galaxy tacc jsiu jstacc js2:
	ansible-playbook -i env/$@/inventory env/$@/$(PLAYBOOK).yml --diff $(TAGS_ARG) $(LIMIT_ARG)

usegalaxy-node-image:
	ansible-playbook -i env/js2/inventory env/js2/image.yml --limit=usegalaxy-node
	openstack server stop usegalaxy-node
	openstack image set --name usegalaxy-node-$(shell openstack image show usegalaxy-node -f value -c created_at | cut -d'T' -f 1) usegalaxy-node
	while [ "$$(openstack server show -f value -c status usegalaxy-node)" != "SHUTOFF" ]; do echo "Waiting for instance shutdown"; sleep 3; done
	openstack server image create --name usegalaxy-node --wait usegalaxy-node
	openstack server delete usegalaxy-node

.PHONY: galaxy tacc jsiu jstacc js2 usegalaxy-node-image
