# infrastructure-playbook

Ansible playbook for managing Galaxy infrastructure. For the playbook managing Galaxy itself, see
[galaxyproject/usegalaxy-playbook](https://github.com/galaxyproject/usegalaxy-playbook/).

**NOTE: This playbook is a work in progress converting from the [`env` layout](env/) to a unified layout. Older TACC VMs as well as JS2 are still managed under the old layout.**

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
