#!/bin/bash
#SBATCH -n 1
#SBATCH --partition=multi
#SBATCH -J test_job_name
#SBATCH -o /jetstream/scratch0/jobs/%N_%j.out
echo "Running a test job..."
sleep 5
echo `ls /jetstream/scratch0/jobs/`
echo `date`
