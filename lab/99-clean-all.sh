#!/bin/bash
set -e

export KARPENTER_NAMESPACE="kube-system"
export KARPENTER_VERSION="1.0.6"
export K8S_VERSION="1.31"

export AWS_PARTITION="aws" # if you are not using standard partitions, you may need to configure to aws-cn / aws-us-gov
export CLUSTER_NAME="cluster-with-karpenter"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

echo "[INFO] Starting to remove resources."

kubectl delete -f https://raw.githubusercontent.com/aws-containers/retail-store-sample-app/main/dist/kubernetes/deploy.yaml --wait

kubectl delete nodepool default --wait

kubectl delete ec2nodeclaim default --wait

helm uninstall karpenter --namespace "${KARPENTER_NAMESPACE}" --wait

eksctl delete cluster --name "${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}"

aws cloudformation delete-stack --stack-name "Karpenter-${CLUSTER_NAME}"

echo "[INFO] Remove done."
