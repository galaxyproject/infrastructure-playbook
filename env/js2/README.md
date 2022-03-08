Instantiate controller with:

```
$ ansible-playbook -i env/js2/inventory env/js2/playbook.yml --limit=jetstream2.galaxyproject.org
```

Create node image with:

```
$ ansible-playbook -i env/js2/inventory env/js2/image.yml --limit=js2image
$ openstack server stop js2image
$ openstack image set --name usegalaxy-node-$(openstack image show usegalaxy-node -f value -c created_at | cut -d'T' -f 1) usegalaxy-node
$ openstack server image create --wait --name usegalaxy-node js2image
$ openstack server delete js2image
```
