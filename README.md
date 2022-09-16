# EKS node rollout

## Overview
These are the actions taken by the script:

You can pass the ASG that will be used to rollout using the environment var `ASG_NAME`
Suspend cluster-autoscaler on ASG (if present)
Double the EC2 instances to the ASG to move the workload
Wait for the new instance to be healthy
Drain an instance that is outdated
Terminate the outdated instance
Repeat until all instances are up to date

## Execution

To run the script pass the eks cluster name as first argument
`./eks-rolling-nodes.sh my-k8s-cluster`
## Pre reqs

* jq
* awscli