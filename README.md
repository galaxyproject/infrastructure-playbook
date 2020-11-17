# infrastructure-playbook

Ansible playbook for managing Galaxy infrastructure. For the playbook managing Galaxy itself, see
[galaxyproject/usegalaxy-playbook](https://github.com/galaxyproject/usegalaxy-playbook/).

Be sure to clone recursively, this repo uses submodules for Galaxy's generalized trivial roles in
[ansible-common-roles](https://github.com/galaxyproject/ansible-common-roles/).

## To run

Set up `pass` and get the `ansible-env` function as documented on the [usegalaxy-playbook
wiki](https://github.com/galaxyproject/usegalaxy-playbook/wiki/Getting-Set-Up-At-TACC), then:

```shell
% ansible-galaxy role install -p roles -r requirements.yml
% ansible-galaxy collection install -p collections -r requirements.yml
% ansible-env <env> <playbook>
```
