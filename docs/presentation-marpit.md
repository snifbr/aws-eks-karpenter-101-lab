---
marp: true
author: Danilo Figueiredo Rocha
theme: gaia
_class: lead
paginate: true
backgroundColor: #fff
backgroundImage: url('https://marp.app/assets/hero-background.svg')
---

## **Como obter/medir economia no Amazon Elastic Kubernetes Service usando Karpenter e arquiteturas multiarch**

#### Autor: Danilo Figueiredo Rocha
![w:30 h:30](https://www.svgrepo.com/download/452213/gmail.svg) drocha.figueiredo (a) gmail com
![w:30 h:30](https://www.svgrepo.com/download/512317/github-142.svg) https://github.com/snifbr
![w:35 h:35](https://www.svgrepo.com/download/448234/linkedin.svg) https://www.linkedin.com/in/danilo-figueiredo-rocha/

---
<!-- 
_class: lead
-->

# **1. Introdução**

---
<!--
_header: 'Introdução'
-->

# **Quem sou eu**

- Um apaixonado por tecnologia, jogos e mangás desde que me conheço por gente.
- Esposo da Márcia.
- Meio mineiro, meio paulista do interior.
- Desde 2002 no mercado de TI.
- E muito grato as iniciativas open source e ao projeto do linux.

---
<!--
_header: 'Introdução'
-->

# **Visão Geral do Karpenter**

Dizeres do projeto >> "Just-in-time Nodes for Any Kubernetes Cluster".

Karpenter simplifica a infraestrutura do Kubernetes com os nós certos na hora certa. Karpenter lança automaticamente os recursos de computação corretos para lidar com as aplicações do seu cluster.

Ele é projetado para permitir que você aproveite ao máximo a nuvem com provisionamento de computação rápido e simples para clusters Kubernetes.

---
<!--
_header: 'Introdução'
-->

# **Minha interpretação**

Mais um *Controller* open source do *Kubernetes* para adicionar ou substituir o papel de *Auto Scaler* de nós de trabalho (*Worker Nodes*), porém o Karpenter tem 3 pilares bem distintos:
- Disponibilidade aprimorada em relação ao cluster-autoscaler.
- Focado em baixo custo operacional, pois tem suporte a API de preços do provider.
- Minimizar a sobrecarga operacional dos clusters admins, através de um conceito centrado na aplicação.

---
<!--
_header: 'Introdução'
-->

# **Karpenter VS Cluster Autoscaler**

![bg center 100%](https://static.us-east-1.prod.workshops.aws/public/cf425bff-cc37-4948-a98f-82a36575fff0/static/images/karpenter/grouplessvsnodegroups.png)

---
<!--
_class: lead
-->

# **2. Pré-requisitos**

---
<!--
_header: 'Pré-requisitos'
-->

## **Requisitos para executar esse lab**

- `aws` (>=2.15) - [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-linux.html)
- `kubectl` (-/+1 cluster version) - [the Kubernetes CLI](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)
- `eksctl` (>= v0.191.0) - [the CLI for AWS EKS](https://docs.aws.amazon.com/eks/latest/userguide/eksctl.html)
- `helm` (>=3.11) - [the package manager for Kubernetes](https://helm.sh/docs/intro/install/)

---
<!--
_header: 'Pré-requisitos'
_class: prereq
style: |
  section.prereq p,ol {
    font-size: 26px;
  }
-->

## **Requisitos para instalar o karpenter**

1. Uma ***IAM Role*** para usar com ***Pod Identity***, com uma ***IAM Policy*** para o *Karpenter Controller*.

2. Associar o ***Pod Identity*** para conceder acesso ao ***Karpenter Controller*** fornecido pela ***IAM Role***.

3. Uma ***IAM Role*** para os *Nodes* que o Karpenter criará, anexando esta no ***InstanceProfile*** do *Node*, para que os *Nodes* recebam permissões IAM.

4. Um ***Access Entry*** para o ***IAM Role*** dos *Nodes* para permitir que os *Nodes* se juntem ao cluster.

5. Uma fila ***SQS*** e regras de evento do ***EventBridge*** para o Karpenter utilizar no *Spot Termination Handling*, re-balanceamento de capacidade, etc.

OBS: Podemos trocar *Pod Identity* por *IRSA* e o *Access Entry* pelo *ConfigMap* de *aws-auth*, lembrando que tanto IRSA quanto o aws-auth já são consideradas técnicas ultrapassadas.

---
<!--
_class: lead
-->

# **3. Instalação do Karpenter**

---
<!--
_header: 'Instalação'
-->

## **Instalação do Karpenter**

```bash
echo "[INFO] Create environment variables."
export KARPENTER_NAMESPACE="kube-system"
export KARPENTER_VERSION="1.0.6"
export K8S_VERSION="1.31"
export AWS_PARTITION="aws"
export CLUSTER_NAME="cluster-with-karpenter"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export TEMPOUT_DIR="$(mktemp -d)"
export ARM_AMI_ID="$(aws ssm get-parameter \
  --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/arm64/standard/recommended/image_id \
  --query Parameter.Value \
  --output text)"
export AMD_AMI_ID="$(aws ssm get-parameter \
  --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id \
  --query Parameter.Value \
  --output text)"
export GPU_AMI_ID="$(aws ssm get-parameter \
  --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/nvidia/recommended/image_id \
  --query Parameter.Value \
  --output text)"
export ALIAS_AL2023_LATEST="$(aws ssm get-parameters-by-path \
  --path "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/" \
  --recursive \
    | jq -cr '.Parameters[].Name' \
      | grep -v "recommended" \
        | awk -F '/' '{print $10}' \
          | sed -r 's/.*(v[[:digit:]]+)$/\1/' \
            | sort | uniq | tail -n1)"
```

---
<!--
_header: 'Instalação'
-->

## **Instalação do Karpenter**

```bash
echo "[INFO] Create karpenter pre-requirements."
curl -fsSL \
  https://raw.githubusercontent.com/.../v"${KARPENTER_VERSION}"/.../getting-started/ getting-started-with-karpenter/cloudformation.yaml  \
  > "${TEMPOUT_DIR}/run-all-cloudformation.yaml" \
&& aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "${TEMPOUT_DIR}/run-all-cloudformation.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}"
```

---
<!--
_header: 'Instalação'
-->

## **Instalação do Karpenter**

```bash
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
...
```

---
<!--
_header: 'Instalação'
-->

## **Instalação do Karpenter**

```bash
...
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
...
```

---
<!--
_header: 'Instalação'
-->

## **Instalação do Karpenter**

```bash
...
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
...
```

---
<!--
_header: 'Instalação'
-->

## **Instalação do Karpenter**

```bash
...
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
```

---
<!--
_header: 'Instalação'
-->

## **Instalação do Karpenter**

```bash
echo "[INFO] Installing karpenter helm chart."
# create/update .kube/config
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}"

# Logout of helm registry to perform an unauthenticated pull against the public ECR
helm registry logout public.ecr.aws || true

helm upgrade \
  --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait
```

---
<!--
_header: 'Instalação'
-->

## **Instalação do Karpenter**

```bash
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
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
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
...
```

---
<!--
_header: 'Instalação'
-->

## **Instalação do Karpenter**

```bash
...
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
```

---
<!--
_header: 'Instalação'
-->

## **Instalação do Karpenter**

```bash
echo "[INFO] Deploying sample application stack."
# From: https://github.com/aws-containers/retail-store-sample-app
kubectl apply -f https://raw.githubusercontent.com/aws-containers/retail-store-sample-app/main/dist/kubernetes/deploy.yaml --wait
while true ; do
  if kubectl wait --for=condition=available deployments --all ; then
    break
  fi
done

kubectl get svc ui
```

---
<!--
_class: lead
-->

# **4. Configuração de EC2NodeClass e NodePools**

---
<!--
_header: 'Configuração'
_class: conf
style: |
  section.conf p,ul,ol {
    font-size: 26px;
  }
-->

## **Explicando o NodePool**

O *CustomResource* ***NodePool*** é o que vai configurar como o Karpenter vai provisionar/escalar um novo *worker node* caso não haja recursos para um determinado pod. Em nosso lab já configuramos por padrão um *NodePool* default que pode ser visto com o comando abaixo:

```bash
kubectl get NodePool default -o yaml
```

Se ele ainda estiver usando os valores padrões do lab ele será um NodePool que ira buscar a instância EC2 mais barata de geração 2 ou superior, que não sejam nano, micro ou small, do tipo SPOT, que usem linux e seja da arquitetura amd64 que se encaixar com a necessidade de carga apresentada para o kubernetes.

---
<!--
_header: 'Configuração'
_class: conf
-->

## **Explicando o processo de Scheduling**

Se os seus pods não tem requerimentos de como ou onde rodar, você pode deixar o Karpenter escolher os workers nodes da lista completa de recursos descrito no _NodePool_. Entretanto, podemos tirar vantagens do modelo de restrições em camadas do Karpenter, assim você pode ter certeza que precisamente o tipo e quantidade de recursos necessários estarão disponíveis para seus pods.

Podemos elencar alguns motivos para usar restrições ao subir um determinado pod:

- Necessidade de executar em zonas de disponibilidade específicas por conta de recursos específicos ou por conta de Storage persistente.
- Necessidade de usar certos tipos específicos de processadores ou outros hardwares.
- Desejo de usar técnicas como topologySpread para ajudar a garantir alta disponbilidade.


---
<!--
_header: 'Configuração'
_class: conf
-->

## **Explicando o processo de Scheduling**


E podemos usar esses tipos de restrições em pods que serão interpretáveis pelo Karpenter:

- **Resource requests**: Solicite que uma certa quantidade de memória ou CPU esteja disponível.
- **Node selection**: Escolha executar em um Node que tenha uma label específica (`nodeSelector`).
- **Node affinity**: Atrai um pod para executar em Nodes com atributos específicos (`affinity`).
- **Topology spread**: Use a distribuição de topologia para ajudar a garantir a disponibilidade da aplicação.
- **Pod affinity/anti-affinity**: Atrai pods ou afasta pods de regras de topologia com base na configuração de outros pods.

---
<!--
_header: 'Configuração'
-->

## **Scheduling: Restrições complementares**

![h:580](scheduling-01.png)

---
<!--
_header: 'Configuração'
-->

## **Scheduling: Restrições de negação**

![h:580](scheduling-02.png)

---
<!--
_header: 'Configuração'
-->

# **Explicando o EC2NodeClass**

***EC2NodeClasses*** habilitam a configuração de parâmetros dos ***EC2 Nodes*** específicos da AWS. Cada ***NodePool*** referência um ***EC2NodeClass*** e múltiplos ***NodePools*** podem apontar para o mesmo ***EC2NodeClass***.

---
<!--
_header: 'Configuração'
-->

## **Explicando o EC2NodeClass**

As configurações mais notáveis são:
- **customizar o kubelet**.
- **Seletor de AMI**
- **seletor de Subnet**
- **Seletor de IAM Role para os Nodes**
- **Seletor de SecurityGroups**
- **customizar o IMDS**
- **customizar o blockDeviceMappings**
- **customizar o userData**
- **habilitar o Monitoramento Detalhado do Node**
- **habilitar a associação de IP Público ao Node**
- **configuração de Tags dos Nodes**.

---
<!--
_header: 'Configuração'
-->

# **Exemplos Práticos**

https://github.com/aws-samples/karpenter-blueprints?tab=readme-ov-file#deploying-a-blueprint

- Split Ratio On-demand/Spot: https://github.com/aws-samples/karpenter-blueprints/blob/main/blueprints/od-spot-split
- Trabalhando com instâncias ARM64: https://github.com/aws-samples/karpenter-blueprints/blob/main/blueprints/graviton

---
<!--
_class: lead
-->

# **5. Uso e Benefícios**

---
<!--
_header: 'Uso'
-->

# **eks-node-viewer**

Mostrar como usar o eks-node-viewer e escalar o aws-sample-application ou o inflate.

---
<!--
_header: 'Uso'
-->

# **Grafana Dashboard**

Mostrar os dashboard do Grafana.

---
<!--
_header: 'Uso'
-->

# **Cost-Explorer: Antes/Depois**

![w:1000](cost-explorer-01.png)

---
<!--
_header: 'Uso'
-->

# **Cost-Explorer: Antes/Depois**

![w:700](cost-explorer-02.png)

---
<!--
_header: 'Uso'
-->

# **Casos de Uso**

- Cenários centrados na aplicação.
- Isolamento de Nodes em um cluster EKS compartilhado.
- etc

---
<!--
_class: lead
-->

# **6. Encerramento**

---
<!--
_header: 'Agradecimentos'
-->

# **Muito Obrigado!**

---
<!--
_header: 'Perguntas'
-->

# **Perguntas e Respostas**
