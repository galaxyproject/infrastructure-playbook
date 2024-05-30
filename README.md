# infrastructure-playbook

Ansible playbook for managing Galaxy infrastructure. For the playbook managing Galaxy itself, see
[galaxyproject/usegalaxy-playbook](https://github.com/galaxyproject/usegalaxy-playbook/).

**NOTE: This playbook is a work in progress converting from the [`env` layout](env/) to a unified layout. Some things may still be managed under the old layout in the [v1 branch](https://github.com/galaxyproject/infrastructure-playbook/tree/v1). But enough progress has been made that the v2 branch is now the default (main) and anything still needing to be done from v1 should be converted over to v2.**

## To run

Set up `pass` as documented on the [usegalaxy-playbook
wiki](https://github.com/galaxyproject/usegalaxy-playbook/wiki/Getting-Set-Up-At-TACC), then:

```shell
% ansible-galaxy role install -p roles -r requirements.yml
% ansible-galaxy collection install -p collections -r requirements.yml
% ansible-playbook -i inventory/some-file.yaml playbook-example.yaml ...
```

Some common operations (such as updating Tool Sheds and their configs) are provided as make targets, see the
[Makefile](Makefile) for details.
