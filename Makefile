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

.PHONY: galaxy tacc jsiu jstacc js2 usegalaxy-node-image
