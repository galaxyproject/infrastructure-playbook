#!/usr/bin/env python
##
## This file is maintained by Ansible - CHANGES WILL BE OVERWRITTEN
##

import datetime
import glob
import os
import socket
import subprocess

taskdirs = glob.glob('/sys/fs/cgroup/*/slurm/uid_*/job_*/step_*/task_*')
running = subprocess.check_output(('squeue', '-w', socket.gethostname().split('.')[0], '-o', '%i', '-h')).splitlines()

print datetime.datetime.now().isoformat()

for d in taskdirs:
    elems = d.split('/')
    controller = elems[4]
    jobid = elems[7].split('_')[1]
    if jobid in running:
        print 'skipping controller %s for running job %s' % (controller, jobid)
        continue
    task_d = d
    step_d = task_d.rsplit('/', 1)[0]
    job_d = step_d.rsplit('/', 1)[0]
    for d in (task_d, step_d, job_d):
        try:
            os.rmdir(d)
            print 'removed %s' % d
        except (IOError, OSError) as exc:
            print 'rmdir %s failed: %s' % (d, exc)
