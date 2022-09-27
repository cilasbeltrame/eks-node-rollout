#!/usr/bin/env bash

# This script is useful when you need to rotate eks nodes, such as bump k8s version, changing node types, sizes etc
#
# This program is free software: you can redistribute it and/or modify

set -o pipefail

REGION="us-east-1"
ASG_NAME=${ASG_NAME:="$1-eks-nodes"}
CLUSTER_NAME="$1"

if echo $CLUSTER_NAME | grep -i prod || echo $CLUSTER_NAME | grep production; then
    export AWS_PROFILE="prod"
else
    export AWS_PROFILE="nonprod"
fi
export AWS_PAGER=""

kubectl config use-context $CLUSTER_NAME
wait

OLD_INSTANCES=$(kubectl get nodes --no-headers | awk '{print $1}')
NUMBER_CURRENT_WORKER_NODES=$(kubectl get nodes --no-headers | grep Ready | wc -l)
OVERRIDE_SCALE=$NUMBER_CURRENT_WORKER_NODES
echo $OLD_INSTANCES >debug-instances.txt

# enabling or desabling eks cluster auto scaler prevents new nodes joining the cluster and you lost control over the rollout
enable_k8s_cluster_auto_scaler() {
    asg_tags=$(aws autoscaling describe-auto-scaling-groups \
        --region $REGION \
        --auto-scaling-group-name $ASG_NAME \
        --query "AutoScalingGroups[].Tags[].{ResourceId:ResourceId,ResourceType:ResourceType,Key:Key,Value:Value,PropagateAtLaunch:PropagateAtLaunch}" |
        jq -c '.[] | select(.Key | contains("k8s.io/cluster-autoscaler/enabled") or contains("k8s.io/cluster-autoscaler/disabled"))' |
        jq -r '.ResourceId, .ResourceType, .Key, .Value, .PropagateAtLaunch')

    rm_new_line=$(echo $asg_tags | tr '\n' ' ')
    read -r RESOURCEID RESOURCETYPE KEY VALUE PROPAGATEATLAUNCH <<<$rm_new_line

    echo "RESOURCEID: $RESOURCEID"
    echo "RESOURCETYPE: $RESOURCETYPE"
    echo "KEY: $KEY"
    echo "VALUE: $VALUE"
    echo "PROPAGATEATLAUNCH: $PROPAGATEATLAUNCH"

    if [ "$1" = "true" ]; then
        echo "enabling kubernetes auto scaling on asg group $RESOURCEID"
        aws autoscaling delete-tags --region "$REGION" --tags ResourceId=$RESOURCEID,ResourceType=$RESOURCETYPE,Key="k8s.io/cluster-autoscaler/disabled",Value="1",PropagateAtLaunch=true
        aws autoscaling create-or-update-tags --region "$REGION" --tags ResourceId=$RESOURCEID,ResourceType=$RESOURCETYPE,Key="k8s.io/cluster-autoscaler/enabled",Value="1",PropagateAtLaunch=true
    else
        echo "disabling kubernetes auto scaling on asg group $RESOURCEID"
        aws autoscaling delete-tags --region "$REGION" --tags ResourceId=$RESOURCEID,ResourceType=$RESOURCETYPE,Key="k8s.io/cluster-autoscaler/enabled",Value="1",PropagateAtLaunch=true
        aws autoscaling create-or-update-tags --region "$REGION" --tags ResourceId=$RESOURCEID,ResourceType=$RESOURCETYPE,Key="k8s.io/cluster-autoscaler/disabled",Value="1",PropagateAtLaunch=true
    fi
}

# scales k8s to double of the current nodes, so you can move the workload to the new nodes
scale_asg() {
    read -r DESIRED_CAPACITY MAX_SIZE MIN_SIZE <<<$(
        aws autoscaling describe-auto-scaling-groups \
            --region "$REGION" \
            --auto-scaling-group-name $ASG_NAME \
            --query "AutoScalingGroups[].{MinSize:MinSize,MaxSize:MaxSize,DesiredCapacity:DesiredCapacity}" \
            --output text
    )

    echo "Current Disered capacity $DESIRED_CAPACITY"

    if ((DESIRED_CAPACITY + $1 <= MAX_SIZE)); then
        aws autoscaling update-auto-scaling-group \
            --region "$REGION" \
            --auto-scaling-group-name $ASG_NAME \
            --desired-capacity $((DESIRED_CAPACITY + $1)) \
            --max-size $MAX_SIZE \
            --min-size $MIN_SIZE
    else
        aws autoscaling update-auto-scaling-group \
            --region "$REGION" \
            --auto-scaling-group-name "$ASG_NAME" \
            --desired-capacity $((DESIRED_CAPACITY + $1)) \
            --max-size $((DESIRED_CAPACITY + $1)) \
            --min-size $MIN_SIZE
    fi

    read -r NEW_DESIRED_CAPACITY MAX_SIZE MIN_SIZE <<<$(
        aws autoscaling describe-auto-scaling-groups \
            --region "$REGION" \
            --auto-scaling-group-name "$ASG_NAME" \
            --query "AutoScalingGroups[].{MinSize:MinSize,MaxSize:MaxSize,DesiredCapacity:DesiredCapacity}" \
            --output text
    )

    echo "Updated Disered capacity $NEW_DESIRED_CAPACITY"
    echo "Validating kubernetes cluster size increase"
    check_increased_asg_count
}

# This function checks whether all nodes are in a ready state
check_increased_asg_count() {
    i=0
    while ((i < 300)); do
        echo "current number of nodes: $(kubectl get nodes --no-headers | grep Ready | wc -l)"
        if [[ $(kubectl get nodes --no-headers | grep Ready | wc -l) == $NEW_DESIRED_CAPACITY ]]; then
            echo "Cluster increased successfully"
            echo
            break
            ((i++))
        fi
    done
    sleep 10
}

# Move the workload to the new loads
drain_k8s_node() {
    for instance in $(cat debug-instances.txt); do
        kubectl drain $instance --ignore-daemonsets --force --delete-emptydir-data
        instance_id=$(aws ec2 describe-instances --filters "Name=private-dns-name,Values=$instance" | jq -r .Reservations[0].Instances[0].InstanceId)
        terminate_worker_node $instance_id
        echo "$instance_id killed"
    done

    sleep 10
}

# Terminate the old ec2 instances
terminate_worker_node() {
    aws autoscaling terminate-instance-in-auto-scaling-group \
        --region "$REGION" \
        --instance-id $1 \
        --should-decrement-desired-capacity \
        --output text
}

# Restore the max size of the auto scaling group, since just the desired is auto adjusted by the script
restore_asg_max_size() {
    read -r OLD_DESIRED_CAPACITY MAX_SIZE MIN_SIZE <<<$(
        aws autoscaling describe-auto-scaling-groups \
            --region "$REGION" \
            --auto-scaling-group-name $ASG_NAME \
            --query "AutoScalingGroups[].{MinSize:MinSize,MaxSize:MaxSize,DesiredCapacity:DesiredCapacity}" \
            --output text
    )

    aws autoscaling update-auto-scaling-group \
        --region "$REGION" \
        --auto-scaling-group-name $ASG_NAME \
        --desired-capacity $OLD_DESIRED_CAPACITY \
        --max-size $OLD_DESIRED_CAPACITY \
        --min-size $MIN_SIZE \
        --output text
    echo "$ASG_NAME has been restored to original settings"
}

enable_k8s_cluster_auto_scaler "false"
scale_asg $OVERRIDE_SCALE
drain_k8s_node $INSTANCE_IDS
restore_asg_max_size
enable_k8s_cluster_auto_scaler "true"
