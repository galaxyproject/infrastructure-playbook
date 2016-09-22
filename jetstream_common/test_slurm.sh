#!/bin/bash
#SBATCH -n 1
#SBATCH --partition=multi
#SBATCH -J test_job_name
hn=`hostname`
of="/jetstream/scratch0/jobs/sample_$hn.out"
sleep 5
ls ~ > $of
date >> $of
