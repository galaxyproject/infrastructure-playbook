Set up a Slurm cluster for use by Galaxy Main on the Jetstream cloud.

The overarching architecture of this setup is that Galaxy Main uses a Slurm
cluster composed of multiple sub-clusters. Each sub-cluster runs a Slurm control
process and any number of workers to run the jobs. Sub-cluster controllers
also run Pulsar that is used for data staging.

Elastic scaling cluster setup
=============================
This playbook can be used to build an elastic Slurm cluster that, based on the
job load, acquires and subsequently releases worker instances. The playbook has
been tailored for use with Galaxy Main server and Jetstream IU region.

### Setup the cloud account
Before the playbook can be run, is is necessary to create a suitable cloud
environment for it. Start by importing the public portion of a key pair
`files/elasticity/elasticity_kp.pub` from this repo into your account. Next,
create a security group called `gxy-workers-sg` with a rule to allow all
communication amongst instances belonging to the same security group. Also
create a public network called `gxy-slurm-net`. Add a subnet and attach it to a
public network via a router.  Finally, create an empty volume that will be used
as a NFS-shared cluster file system. Names of all these resources can be found
and changed in `launch.yml`.

### Launch a controller instance
We'll next launch an instance that will serve as the controller for this cluster. This instance needs to belong to `gxy-workers-sg` security group. You probably
want to create another security group that allows ssh connections and associate the instance
with it as well.  You can reuse the `elasticity_kp` key pair but note that by
default, the playbook will override `authorized_keys` file on the instance and
place the set of keys available in `secret_group_vars/controllers.yml` for
`centos`, so make sure your key is included in the file or you will get locked
out of the instance. You can  override this setting by defining a key via
`authorized_key_users` variable. Name the instance `jetstream-iu-slurm-
controller`. After launching the instance, associate a public IP address with it
and attach the earlier created volume (as device `/dev/sdb`).

### Run the playbook
Well, before running the playbook, edit `group_vars/all.yml` and
`group_vars/galaxynodes.yml` to update the IP address of the controller
instance and specify its private IP address. Also, update `inventory` file to include the public IP of the instance under `jetstream-iu0.galaxyproject.org` variable:
```
jetstream-iu0.galaxyproject.org ansible_ssh_host="149.165.XXX.XXX" ansible_ssh_user="centos" ansible_ssh_private_key_file="kp" ansible_ssh_common_args='-o StrictHostKeyChecking=no -o CheckHostIP=no -o "UserKnownHostsFile /dev/null"'
```

Elastic scaling of worker nodes is handled by an Ansible playbook that Slurm calls on (to do so, Slurm calls a script available in `files/slurm/launch`). With that, Ansible needs to know about the credentials for the target cloud; these need to be made available in a a file called `clouds.yaml` in the root directory of this repo. The contents of the file should look like the following:
```
clouds:
  jetstream_iu:
    auth:
      username: 'username'
      password: 'pwd'
      project_name: 'project_name'
      user_domain_name: 'tacc'
      project_domain_name: 'tacc'
      auth_url: 'https://jblb.jetstream-cloud.org:35357/v3'
```

 Then, run the playbook with:
```
ansible-playbook -i jetstreamiuenv/inventory jetstreamiuenv/playbook.yml --limit=controllers
```

On average, the playbook takes 4-5 minutes to run.

### Verify it works
To verify the controller instance and the elastic scaling work, ssh to the instance and run a test job. A sample job script is included in the repo as `test_slurm.sh`. If using this job script, first create a directory for its output on the NFS file system:
```
sudo mkdir /jetstream/scratch0/jobs
sudo chown centos:centos /jetstream/scratch0/jobs
```
As `centos` user, submit the job script with
```
sbatch /opt/slurm_cloud_provision/infrastructure-playbook/jetstreamiuenv/test_slurm.sh
```
In a couple of minutes, job output should be available in `/jetstream/scratch0/jobs`.

Log file for the Slurm controller process is available in `/var/log/slurm/slurmctld.log` . Logs for the elastic launch/terminate process are available in `/var/log/slurm/launch/`.

### Elasticity config options
There are some configuration options that can be changed for the cluster elasticity parameters. Instance type to be launched is supplied in `group_vars/all.yml` as `worker_instance_type`. `worker_image_id` can also be updated there. The amount of time Slurm will keep an idle instance around can be defined in `templates/slurm/slurm.conf.elastic.j2` under `SuspendTime` (value is in seconds). For other `slurm.conf` options, see [*slurm.conf* docs](http://slurm.schedmd.com/slurm.conf.html).

Static cluster setup
====================
*TODO*
