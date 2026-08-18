#!/bin/bash
# setup.sh — Bastion에서 수동 실행: sudo bash /home/ec2-user/setup.sh
# EKS에 KEDA, Karpenter, order-processor를 배포한다.
set -x
set -e

export HOME=/home/ec2-user
export KUBECONFIG=/home/ec2-user/.kube/config

REGION="${region}"
CLUSTER="${cluster}"
ACCOUNT_ID="${account_id}"
ECR_REPO="${ecr_repo_url}"
CLUSTER_ENDPOINT="${cluster_endpoint}"
KEDA_ROLE_ARN="${keda_role_arn}"
KARPENTER_ROLE_ARN="${karpenter_role_arn}"
APP_ROLE_ARN="${app_role_arn}"
NODE_ROLE_NAME="${node_role_name}"
SQS_URL="${sqs_url}"
S3_BUCKET="${s3_bucket}"
DISCOVERY_TAG="${discovery_tag}"

retry() {
  local n=$1; shift
  local i=0
  until "$@"; do
    i=$((i+1))
    if [ "$i" -ge "$n" ]; then echo "retry exhausted: $*"; return 1; fi
    echo "retry $i/$n: $*"; sleep 15
  done
}

wait_crd() {
  local crd=$1
  for i in $(seq 1 60); do
    kubectl get crd "$crd" >/dev/null 2>&1 && \
      kubectl wait --for=condition=Established "crd/$crd" --timeout=10s >/dev/null 2>&1 && return 0
    echo "waiting crd $crd ($i/60)"; sleep 10
  done
  return 1
}

set_global_sts() {
  for i in $(seq 1 40); do kubectl get deploy "$1" -n "$2" >/dev/null 2>&1 && break; sleep 5; done
  kubectl set env deployment/"$1" -n "$2" AWS_ENDPOINT_URL_STS=https://sts.amazonaws.com || true
  kubectl rollout status deployment/"$1" -n "$2" --timeout=600s || true
}

# ── Namespaces ─────────────────────────────────────────────────────────────
for ns in keda skillsmkt; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - || true
done

# addon-ng 노드가 Ready 될 때까지 대기
for i in $(seq 1 40); do
  kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready " && break
  echo "waiting for addon-ng node ($i/40)"; sleep 15
done

# ── App 이미지 빌드/푸시 ───────────────────────────────────────────────────
mkdir -p /home/ec2-user/app && cd /home/ec2-user/app
for f in Dockerfile app.py requirements.txt; do
  retry 5 aws s3 cp "s3://$S3_BUCKET/app/$f" "./$f" --region "$REGION"
done
retry 5 bash -c "aws ecr get-login-password --region '$REGION' | sudo docker login --username AWS --password-stdin '$ECR_REPO'"
retry 3 sudo docker build -t skm-order-processor .
sudo docker tag skm-order-processor:latest "$ECR_REPO:latest"
retry 5 sudo docker push "$ECR_REPO:latest"

# ── KEDA (namespace keda, addon-ng taint tolerate) ─────────────────────────
retry 5 helm repo add kedacore https://kedacore.github.io/charts
retry 5 helm repo update
retry 3 helm upgrade --install keda kedacore/keda --namespace keda --timeout 15m \
  --set serviceAccount.operator.annotations."eks\.amazonaws\.com/role-arn"="$KEDA_ROLE_ARN" \
  --set "tolerations[0].operator=Exists"
set_global_sts keda-operator keda

# ── Karpenter (namespace kube-system) ──────────────────────────────────────
retry 3 helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "1.4.0" \
  --namespace kube-system --timeout 15m \
  --set "settings.clusterName=$CLUSTER" \
  --set "settings.clusterEndpoint=$CLUSTER_ENDPOINT" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$KARPENTER_ROLE_ARN" \
  --set "controller.resources.requests.cpu=200m" \
  --set "replicas=1" \
  --set "tolerations[0].operator=Exists"
set_global_sts karpenter kube-system

# ── Karpenter CR (EC2NodeClass / NodePool) ─────────────────────────────────
wait_crd ec2nodeclasses.karpenter.k8s.aws
wait_crd nodepools.karpenter.sh

retry 5 kubectl apply -f - <<EOF
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: skm-app-nodeclass
spec:
  amiFamily: AL2023
  amiSelectorTerms:
  - id: ami-01b998eedd699318c
  role: "$NODE_ROLE_NAME"
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 2
    httpTokens: required
  subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: $DISCOVERY_TAG
  securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: $DISCOVERY_TAG
EOF

retry 5 kubectl apply -f - <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: skm-app-nodepool
spec:
  template:
    spec:
      taints:
      - key: dedicated
        value: app
        effect: NoSchedule
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: skm-app-nodeclass
      requirements:
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["on-demand"]
      - key: node.kubernetes.io/instance-type
        operator: In
        values: ["t3.small", "t3.medium"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 60s
  limits:
    cpu: 100
EOF

# ── order-processor ServiceAccount(IRSA) ───────────────────────────────────
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: order-processor-sa
  namespace: skillsmkt
  annotations:
    eks.amazonaws.com/role-arn: "$APP_ROLE_ARN"
EOF

# ── order-processor Deployment ─────────────────────────────────────────────
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-processor
  namespace: skillsmkt
spec:
  replicas: 1
  selector:
    matchLabels:
      app: order-processor
  template:
    metadata:
      labels:
        app: order-processor
    spec:
      serviceAccountName: order-processor-sa
      nodeSelector:
        karpenter.sh/nodepool: skm-app-nodepool
      tolerations:
      - key: dedicated
        value: app
        effect: NoSchedule
      containers:
      - name: order-processor
        image: $ECR_REPO:latest
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
        env:
        - name: AWS_REGION
          value: "$REGION"
        - name: SQS_QUEUE_URL
          value: "$SQS_URL"
        - name: PROCESSING_TIME
          value: "3"
EOF

# ── KEDA ScaledObject (order-scaler) ───────────────────────────────────────
wait_crd triggerauthentications.keda.sh
wait_crd scaledobjects.keda.sh

kubectl apply -f - <<EOF
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: order-scaler-auth
  namespace: skillsmkt
spec:
  podIdentity:
    provider: aws
EOF

retry 5 kubectl apply -f - <<EOF
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: order-scaler
  namespace: skillsmkt
spec:
  scaleTargetRef:
    name: order-processor
  pollingInterval: 15
  cooldownPeriod: 30
  minReplicaCount: 1
  maxReplicaCount: 5
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 0
          policies:
          - type: Pods
            value: 5
            periodSeconds: 15
        scaleDown:
          stabilizationWindowSeconds: 15
          policies:
          - type: Percent
            value: 100
            periodSeconds: 15
  triggers:
  - type: aws-sqs-queue
    authenticationRef:
      name: order-scaler-auth
    metadata:
      queueURL: "$SQS_URL"
      queueLength: "5"
      awsRegion: "$REGION"
EOF

# ── 완료 ───────────────────────────────────────────────────────────────────
echo "=== Deploy complete ==="
kubectl get pods -A
