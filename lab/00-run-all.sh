#!/bin/bash
set -e

export KARPENTER_NAMESPACE="kube-system"
export KARPENTER_VERSION="1.0.6"
export K8S_VERSION="1.31"

export AWS_PARTITION="aws"
export CLUSTER_NAME="cluster-with-karpenter"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export TEMPOUT_DIR="$(mktemp -d)"
export ARM_AMI_ID="$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/arm64/standard/recommended/image_id --query Parameter.Value --output text)"
export AMD_AMI_ID="$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id --query Parameter.Value --output text)"
export GPU_AMI_ID="$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/nvidia/recommended/image_id --query Parameter.Value --output text)"
export ALIAS_AL2023_LATEST="$(aws ssm get-parameters-by-path --path "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/" --recursive | jq -cr '.Parameters[].Name' | grep -v "recommended" | awk -F '/' '{print $10}' | sed -r 's/.*(v[[:digit:]]+)$/\1/' | sort | uniq | tail -n1)"

echo "[INFO] Install envsubst."
sudo dnf install gettext -y

echo "[INFO] Create karpenter pre-requirements."
curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/v"${KARPENTER_VERSION}"/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml  > "${TEMPOUT_DIR}/run-all-cloudformation.yaml" \
&& aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "${TEMPOUT_DIR}/run-all-cloudformation.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}"

echo "[INFO] Creating EKS Cluster."
cat <<EOF > "${TEMPOUT_DIR}/run-all-config.yaml"
---
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: "${K8S_VERSION}"
  tags:
    karpenter.sh/discovery/${CLUSTER_NAME}: ${CLUSTER_NAME}

vpc:
  cidr: 10.42.0.0/20
  nat:
    gateway: Single

availabilityZones:
- us-east-1a
- us-east-1c

iam:
  withOIDC: true
  podIdentityAssociations:
  - namespace: "${KARPENTER_NAMESPACE}"
    serviceAccountName: karpenter
    roleName: ${CLUSTER_NAME}-karpenter
    permissionPolicyARNs:
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}

iamIdentityMappings:
- arn: "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"
  username: system:node:{{EC2PrivateDNSName}}
  groups:
  - system:bootstrappers
  - system:nodes
  ## If you intend to run Windows workloads, the kube-proxy group should be specified.
  # For more information, see https://github.com/aws/karpenter/issues/5099.
  # - eks:kube-proxy-windows

accessConfig:
  authenticationMode: API_AND_CONFIG_MAP

addonsConfig:
  autoApplyPodIdentityAssociations: true

addons:
- name: eks-pod-identity-agent
- name: vpc-cni
  configurationValues: >-
    {
      "env": {
        "ENABLE_PREFIX_DELEGATION":"true",
        "ENABLE_POD_ENI":"true",
        "POD_SECURITY_GROUP_ENFORCING_MODE":"standard"
      },
      "enableNetworkPolicy": "true",
      "nodeAgent": {
        "enablePolicyEventLogs": "true"
      }
    }
  resolveConflicts: overwrite
  version: latest

managedNodeGroups:
  - name: critical-addons-only
    amiFamily: AmazonLinux2023
    ssh:
      enableSsm: true
    spot: true
    minSize: 2
    maxSize: 3
    desiredCapacity: 2
    instanceSelector:
      vCPUs: 2
      memory: 4GiB
      cpuArchitecture: arm64
    taints:
      - key: CriticalAddonsOnly
        value: "true"
        effect: NoSchedule
EOF

eksctl create cluster -f "${TEMPOUT_DIR}/run-all-config.yaml"

export CLUSTER_ENDPOINT="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.endpoint" --output text)"
export KARPENTER_IAM_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter"

echo "${CLUSTER_ENDPOINT} ${KARPENTER_IAM_ROLE_ARN}"

#aws iam create-service-linked-role --aws-service-name spot.amazonaws.com || true
# If the role has already been successfully created, you will see:
# An error occurred (InvalidInput) when calling the CreateServiceLinkedRole operation: Service role name AWSServiceRoleForEC2Spot has been taken in this account, please try a different suffix.

echo "[INFO] Installing karpenter helm chart."
# Logout of helm registry to perform an unauthenticated pull against the public ECR
helm registry logout public.ecr.aws

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" --namespace "${KARPENTER_NAMESPACE}" --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait

echo "[INFO] Deploying default Nodepool and EC2NodeClaim."
cat <<EOF > "${TEMPOUT_DIR}/run-all-nodepool.yaml"
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    metadata:
      labels:
        intent: apps
    spec:
      requirements:
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: karpenter.k8s.aws/instance-size
          operator: NotIn
          values: [nano, micro, small]
        - key: "karpenter.k8s.aws/instance-generation"
          operator: Gt
          values: ["2"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 336h
      terminationGracePeriod: 24h
  limits:
    cpu: 16
    memory: 32Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
    budgets:
    - nodes: 50%
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:
    - alias: al2023@${ALIAS_AL2023_LATEST}
  role: "KarpenterNodeRole-${CLUSTER_NAME}"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery/${CLUSTER_NAME}: "${CLUSTER_NAME}"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery/${CLUSTER_NAME}: "${CLUSTER_NAME}"
  tags:
    Name: karpenter.sh/nodepool/default
    NodeType: cluster-with-karpenter
    IntentLabel: apps
EOF

kubectl apply -f "${TEMPOUT_DIR}/run-all-nodepool.yaml"

echo "[INFO] Track temporary files created."
echo ""
echo ${TEMPOUT_DIR}
ls ${TEMPOUT_DIR}

echo "[INFO] Deploying sample application stack."
# From: https://github.com/aws-containers/retail-store-sample-app
kubectl apply -f https://raw.githubusercontent.com/aws-containers/retail-store-sample-app/main/dist/kubernetes/deploy.yaml
kubectl wait --for=condition=available deployments --all

kubectl get svc ui
