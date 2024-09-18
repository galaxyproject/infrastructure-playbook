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

mts:
	ansible-playbook -i inventory/galaxyproject.yaml --limit=radegast.galaxyproject.org --tags=shed playbook-tool-shed-servers.yaml

mts-update:
	ansible-playbook -i inventory/galaxyproject.yaml --limit=radegast.galaxyproject.org --tags=update playbook-tool-shed-servers.yaml

mts-config:
	ansible-playbook -i inventory/galaxyproject.yaml --limit=radegast.galaxyproject.org --tags=config playbook-tool-shed-servers.yaml

js2-openstack-init:
	# sets up router, subnets, security groups, etc.
	ansible-playbook -i inventory/jetstream2.yaml playbook-openstack.yaml --limit=jetstream2_openstack_initializer

.PHONY: tts tts-update tts-config mts mts-update mts-config js2-openstack-init
