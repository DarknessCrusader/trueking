#!/bin/bash
set -x
exec > /var/log/skills-setup.log 2>&1

export HOME=/root
export KUBECONFIG=/root/.kube/config

REGION="${region}"
CLUSTER="${cluster}"
S3_BUCKET="${s3_bucket}"

retry() {
  local n=$1; shift
  local i=0
  until "$@"; do
    i=$((i+1))
    if [ "$i" -ge "$n" ]; then echo "retry exhausted: $*"; return 1; fi
    echo "retry $i/$n: $*"; sleep 15
  done
}

# ── 도구 설치 ──────────────────────────────────────────────────────────────
retry 5 dnf install -y docker git tar gzip
systemctl enable --now docker

EKS_VER=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query 'cluster.version' --output text)
KVER=$(curl -fsSL "https://dl.k8s.io/release/stable-$${EKS_VER}.txt" || echo "v$${EKS_VER}.0")
retry 5 curl -fL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$${KVER}/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl
retry 5 bash -c 'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash'

# ── kubeconfig ─────────────────────────────────────────────────────────────
retry 10 aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
retry 20 kubectl get ns

# ec2-user용 kubeconfig도 설정
mkdir -p /home/ec2-user/.kube
cp /root/.kube/config /home/ec2-user/.kube/config
chown -R ec2-user:ec2-user /home/ec2-user/.kube

# ── setup.sh 다운로드 ─────────────────────────────────────────────────────
retry 5 aws s3 cp "s3://$S3_BUCKET/scripts/setup.sh" /home/ec2-user/setup.sh --region "$REGION"
chmod +x /home/ec2-user/setup.sh
chown ec2-user:ec2-user /home/ec2-user/setup.sh

echo "=== user_data complete. Run: sudo bash /home/ec2-user/setup.sh ==="
