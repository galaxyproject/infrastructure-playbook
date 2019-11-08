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


galaxy tacc:
	ansible-playbook -i env/$@/inventory env/$@/$(PLAYBOOK).yml $(TAGS_ARG) $(LIMIT_ARG)


.PHONY: galaxy tacc
