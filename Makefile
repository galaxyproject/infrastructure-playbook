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


tts:
	ansible-playbook -i inventory/galaxyproject.yaml --limit=eddie.galaxyproject.org --tags=shed playbook-tool-shed-servers.yaml

tts-update:
	ansible-playbook -i inventory/galaxyproject.yaml --limit=eddie.galaxyproject.org --tags=update playbook-tool-shed-servers.yaml

tts-config:
	ansible-playbook -i inventory/galaxyproject.yaml --limit=eddie.galaxyproject.org --tags=config playbook-tool-shed-servers.yaml

galaxy tacc jsiu jstacc js2:
	ansible-playbook -i env/$@/inventory env/$@/$(PLAYBOOK).yml --diff $(TAGS_ARG) $(LIMIT_ARG)

usegalaxy-node-image:
	ansible-playbook -i env/js2/inventory env/js2/image.yml --limit=usegalaxy-node

usegalaxy-gxit-node-image:
	ansible-playbook -i env/js2/inventory env/js2/image.yml --limit=usegalaxy-gxit-node

usegalaxy-node-images:
	ansible-playbook -i env/js2/inventory env/js2/image.yml --limit=imagehosts

js2-openstack-init:
	# sets up router, subnets, security groups, etc.
	ansible-playbook -i env/js2/inventory env/js2/jetstream.yml --limit=openstackinitialize

.PHONY: galaxy tacc jsiu jstacc js2 usegalaxy-node-image tts tts-update tts-config
