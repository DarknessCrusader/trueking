#!/bin/bash
# 실패 지점 파악을 위해 set -e 제거(비핵심 단계에서 전체 중단 방지) + 로그를 S3로 업로드.
set -x
exec > /var/log/skills-setup.log 2>&1

# cloud-init 실행 컨텍스트는 $HOME가 비어 있어 kubectl/helm이 kubeconfig(/root/.kube/config)를
# 찾지 못하고 localhost:8080 으로 접속해 전부 실패한다. HOME/KUBECONFIG를 명시적으로 고정.
export HOME=/root
export KUBECONFIG=/root/.kube/config

REGION="${region}"
CLUSTER="${cluster}"
ECR_REPO="${ecr_repo_url}"
SQS_URL="${sqs_url}"
S3_BUCKET="${s3_bucket}"

# 종료 시(성공/실패 무관) 로그를 S3에 업로드 → SSH 없이 원인 파악 가능
upload_log() {
  aws s3 cp /var/log/skills-setup.log "s3://$S3_BUCKET/log/module4-setup.log" --region "$REGION" || true
}
trap upload_log EXIT

# n회 재시도 헬퍼
retry() {
  local n=$1; shift
  local i=0
  until "$@"; do
    i=$((i+1))
    if [ "$i" -ge "$n" ]; then echo "retry exhausted: $*"; return 1; fi
    echo "retry $i/$n: $*"; sleep 15
  done
}

# CRD가 Established 될 때까지 대기(KEDA/Karpenter CR 적용 전 필수)
wait_crd() {
  local crd=$1
  for i in $(seq 1 60); do
    kubectl get crd "$crd" >/dev/null 2>&1 && \
      kubectl wait --for=condition=Established "crd/$crd" --timeout=10s >/dev/null 2>&1 && return 0
    echo "waiting crd $crd ($i/60)"; sleep 10
  done
  return 1
}

# ── 도구 설치 (docker / kubectl / helm) ────────────────────────────────────
retry 5 dnf install -y docker git tar gzip
systemctl enable --now docker

EKS_VER=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query 'cluster.version' --output text)
# kubectl: EKS 마이너 버전에 맞는 최신 stable 패치를 사용(vX.Y.0 고정 시 없는 패치일 수 있음)
KVER=$(curl -fsSL "https://dl.k8s.io/release/stable-$${EKS_VER}.txt" || echo "v$${EKS_VER}.0")
retry 5 curl -fL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$${KVER}/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

retry 5 bash -c 'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash'

# ── kubeconfig ─────────────────────────────────────────────────────────────
retry 10 aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
# 접근권한/네트워크 확인(권한 전파 지연 대비)
retry 20 kubectl get ns

# ── Namespaces (가장 먼저 생성: 부분 실패해도 채점 대상 네임스페이스는 존재) ──
for ns in keda karpenter skills-sqs; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - || true
done

# ── CoreDNS를 Fargate에서 실행하도록 패치 ──────────────────────────────────
for i in $(seq 1 30); do
  kubectl get deployment coredns -n kube-system >/dev/null 2>&1 && break
  sleep 10
done
kubectl patch deployment coredns -n kube-system --type=json \
  -p='[{"op":"remove","path":"/spec/template/metadata/annotations/eks.amazonaws.com~1compute-type"}]' || true
kubectl rollout restart deployment coredns -n kube-system || true
kubectl rollout status deployment coredns -n kube-system --timeout=300s || true

# ── Worker 이미지 빌드/푸시 ────────────────────────────────────────────────
mkdir -p /root/worker && cd /root/worker
for f in Dockerfile worker.py requirements.txt; do
  retry 5 aws s3 cp "s3://$S3_BUCKET/app/module4/$f" "./$f" --region "$REGION"
done
retry 5 bash -c "aws ecr get-login-password --region '$REGION' | docker login --username AWS --password-stdin '${ecr_repo_url}'"
retry 3 docker build -t skills-sqs-worker .
docker tag skills-sqs-worker:latest "${ecr_repo_url}:latest"
retry 5 docker push "${ecr_repo_url}:latest"

# IRSA 파드는 리전 STS 엔드포인트(sts.us-west-2)로 AssumeRoleWithWebIdentity 하는데,
# 이 계정은 us-west-2 STS가 비활성(RegionDisabledException 403)이라 크래시한다.
# aws-sdk-go-v2(Karpenter/KEDA)는 AWS_STS_REGIONAL_ENDPOINTS를 web-identity 자격증명
# 공급자에 반영하지 않으므로, 글로벌 엔드포인트를 명시적으로 지정하는 AWS_ENDPOINT_URL_STS를 사용한다.
set_global_sts() { # $1=deploy $2=namespace
  for i in $(seq 1 40); do kubectl get deploy "$1" -n "$2" >/dev/null 2>&1 && break; sleep 5; done
  kubectl set env deployment/"$1" -n "$2" AWS_ENDPOINT_URL_STS=https://sts.amazonaws.com || true
  kubectl rollout status deployment/"$1" -n "$2" --timeout=600s || true
}

# ── KEDA (--wait 제거: 불건전 파드에서 블로킹 방지, 대신 STS 패치 후 rollout 대기) ──
retry 5 helm repo add kedacore https://kedacore.github.io/charts
retry 5 helm repo update
retry 3 helm upgrade --install keda kedacore/keda --namespace keda --timeout 15m \
  --set serviceAccount.operator.annotations."eks\.amazonaws\.com/role-arn"="${keda_role_arn}"
set_global_sts keda-operator keda

# ── Karpenter ──────────────────────────────────────────────────────────────
retry 3 helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.4.0 --namespace karpenter --timeout 15m \
  --set "settings.clusterName=$CLUSTER" \
  --set "settings.clusterEndpoint=${cluster_endpoint}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${karpenter_role_arn}"
set_global_sts karpenter karpenter

# ── Worker ServiceAccount ──────────────────────────────────────────────────
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sqs-worker-sa
  namespace: skills-sqs
  annotations:
    eks.amazonaws.com/role-arn: "${worker_role_arn}"
EOF

# ── Worker Deployment ──────────────────────────────────────────────────────
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sqs-worker
  namespace: skills-sqs
spec:
  replicas: 0
  selector:
    matchLabels:
      app: sqs-worker
  template:
    metadata:
      labels:
        app: sqs-worker
    spec:
      serviceAccountName: sqs-worker-sa
      nodeSelector:
        karpenter.sh/nodepool: skills-sqs-nodepool
        skills-nodepool: event-worker
      containers:
      - name: worker
        image: ${ecr_repo_url}:latest
        env:
        - name: SQS_QUEUE_URL
          value: "${sqs_url}"
        - name: AWS_REGION
          value: "${region}"
        - name: PROCESSING_SECONDS
          value: "5"
        - name: AWS_ENDPOINT_URL_STS
          value: "https://sts.amazonaws.com"
EOF

# ── KEDA CR 적용 (CRD Established 대기 후) ─────────────────────────────────
wait_crd triggerauthentications.keda.sh
wait_crd scaledobjects.keda.sh

kubectl apply -f - <<'EOF'
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: sqs-worker-trigger-auth
  namespace: skills-sqs
spec:
  podIdentity:
    provider: aws-eks
EOF

retry 5 kubectl apply -f - <<'EOF'
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: sqs-worker-scaledobject
  namespace: skills-sqs
spec:
  scaleTargetRef:
    name: sqs-worker
  pollingInterval: 15
  cooldownPeriod: 30
  minReplicaCount: 0
  maxReplicaCount: 6
  triggers:
  - type: aws-sqs-queue
    authenticationRef:
      name: sqs-worker-trigger-auth
    metadata:
      queueURL: "${sqs_url}"
      queueLength: "2"
      awsRegion: "${region}"
EOF

# ── Karpenter CR 적용 (CRD Established 대기 후) ────────────────────────────
wait_crd ec2nodeclasses.karpenter.k8s.aws
wait_crd nodepools.karpenter.sh

retry 5 kubectl apply -f - <<'EOF'
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: skills-sqs-nodeclass
spec:
  amiSelectorTerms:
  - alias: al2023@latest
  role: "${node_role_name}"
  subnetSelectorTerms:
  - tags:
      kubernetes.io/cluster/${cluster}: owned
  securityGroupSelectorTerms:
  - tags:
      kubernetes.io/cluster/${cluster}: owned
EOF

retry 5 kubectl apply -f - <<'EOF'
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: skills-sqs-nodepool
spec:
  template:
    metadata:
      labels:
        skills-nodepool: event-worker
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: skills-sqs-nodeclass
      requirements:
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["on-demand"]
      - key: node.kubernetes.io/instance-type
        operator: In
        values: ["t3.medium", "t3.large"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
  limits:
    cpu: 100
EOF

# ── Karpenter 서브넷 태깅 ──────────────────────────────────────────────────
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query cluster.resourcesVpcConfig.vpcId --output text)
for subnet in $(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text); do
  aws ec2 create-tags --region "$REGION" --resources "$subnet" --tags Key=kubernetes.io/cluster/$CLUSTER,Value=owned || true
done

# ── 배포 검증 후 완료 마커 (핵심 오브젝트가 모두 존재할 때만) ──────────────
if kubectl get scaledobject sqs-worker-scaledobject -n skills-sqs >/dev/null 2>&1 \
   && kubectl get nodepool skills-sqs-nodepool >/dev/null 2>&1 \
   && kubectl get deployment sqs-worker -n skills-sqs >/dev/null 2>&1; then
  echo done | aws s3 cp - "s3://$S3_BUCKET/done/module4" --region "$REGION"
else
  echo "FAILED: 핵심 오브젝트 누락 — s3://$S3_BUCKET/log/module4-setup.log 확인"
fi
