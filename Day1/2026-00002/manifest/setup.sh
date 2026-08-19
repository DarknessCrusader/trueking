#!/bin/bash
set -euo pipefail

export HOME=/root
export PATH=$PATH:/usr/local/bin

LOG_HOME="/home/${SUDO_USER:-cloudshell-user}"
if [ ! -d "$LOG_HOME" ]; then
  LOG_HOME="/home/cloudshell-user"
fi
if [ ! -d "$LOG_HOME" ]; then
  LOG_HOME="$HOME"
fi
LOG_FILE="${SETUP_LOG_FILE:-$LOG_HOME/wskorea26-setup-$(date -u +%Y%m%d-%H%M%S).log}"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

set -x
echo "Setup log: $LOG_FILE"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2
ECR=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com

aws configure set region $REGION
aws configure set cli_pager ""
export AWS_PAGER=""
grep -q AWS_PAGER ~/.bashrc || echo 'export AWS_PAGER=""' >> ~/.bashrc

BUCKET=$(aws s3 ls | awk '/wskorea26-manifest-/ {print $3; exit}')

upload_log() {
  local status=$?
  set +e
  echo "Setup exit code: $status"
  echo "Local log: $LOG_FILE"
  if [ -n "${BUCKET:-}" ]; then
    aws s3 cp "$LOG_FILE" "s3://$BUCKET/logs/$(basename "$LOG_FILE")" >/dev/null 2>&1
    echo "S3 log: s3://$BUCKET/logs/$(basename "$LOG_FILE")"
  fi
  exit $status
}
trap upload_log EXIT

mkdir -p /tmp/wskorea26 && cd /tmp/wskorea26
aws s3 cp s3://$BUCKET/ . --recursive
# Manifests are authored on Windows (CRLF). Strip carriage returns so eksctl,
# kubectl and the sub-scripts parse the freshly downloaded copies correctly.
sed -i 's/\r$//' *.sh *.yaml *.yml 2>/dev/null || true

sudo yum install -y docker jq
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl
if command -v systemctl >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1; then
  sudo systemctl enable --now docker
else
  sudo service docker start 2>/dev/null || true
fi

sudo usermod -aG docker ec2-user 2>/dev/null || true
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin/eksctl

aws ecr get-login-password --region $REGION | sudo docker login --username AWS --password-stdin $ECR
chmod +x book
aws ecr batch-delete-image --repository-name wskorea26-book-repo --image-ids imageTag=stable 2>/dev/null || true
sudo docker build --no-cache -t $ECR/wskorea26-book-repo:stable .
sudo docker push $ECR/wskorea26-book-repo:stable
# Let scan-on-push finish so grading 3-1 doesn't hit ScanNotFound mid-progress.
# (No Critical/High findings -> empty output, which is the correct/pass state.)
aws ecr wait image-scan-complete --repository-name wskorea26-book-repo --image-id imageTag=stable 2>/dev/null || true
sudo docker image rm $ECR/wskorea26-book-repo:stable 2>/dev/null || true
sudo docker system prune -af 2>/dev/null || true

VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=wskorea26-vpc --query "Vpcs[0].VpcId" --output text)
SUBNET_C=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=wskorea26-priv-subnet-c --query "Subnets[0].SubnetId" --output text)
SUBNET_D=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=wskorea26-priv-subnet-d --query "Subnets[0].SubnetId" --output text)
EKS_KEY_ARN=$(aws kms describe-key --key-id alias/wskorea26-eks-key --query "KeyMetadata.Arn" --output text)
sed -i "s|VPC_ID|$VPC_ID|g; s|SUBNET_C|$SUBNET_C|g; s|SUBNET_D|$SUBNET_D|g; s|EKS_KEY_ARN|$EKS_KEY_ARN|g" cluster.yaml

eksctl create cluster -f cluster.yaml || true

aws eks wait cluster-active --name wskorea26-cluster
aws eks wait nodegroup-active --cluster-name wskorea26-cluster --nodegroup-name wskorea26-addon-ng
aws eks wait nodegroup-active --cluster-name wskorea26-cluster --nodegroup-name wskorea26-app-ng

CLUSTER_SG=$(aws eks describe-cluster --name wskorea26-cluster --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $CLUSTER_SG --protocol -1 --port -1 --cidr 0.0.0.0/0 2>/dev/null || true

BASTION_ROLE_ARN=$(aws sts get-caller-identity --query Arn --output text | sed 's|assumed-role/\(.*\)/.*|role/\1|; s|:sts::|:iam::|')
aws eks create-access-entry --cluster-name wskorea26-cluster --principal-arn $BASTION_ROLE_ARN --type STANDARD 2>/dev/null || true
aws eks associate-access-policy --cluster-name wskorea26-cluster --principal-arn $BASTION_ROLE_ARN \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster 2>/dev/null || true
# EKS access entries are per-principal (an ":root" entry is NOT an account-wide
# wildcard). Grant cluster-admin to every IAM user in the account so that
# whichever IAM identity is used in CloudShell for grading (kubectl, section 5-4)
# works without any manual access-entry registration.
for user_arn in $(aws iam list-users --query 'Users[].Arn' --output text); do
  aws eks create-access-entry --cluster-name wskorea26-cluster --principal-arn "$user_arn" --type STANDARD 2>/dev/null || true
  aws eks associate-access-policy --cluster-name wskorea26-cluster --principal-arn "$user_arn" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster 2>/dev/null || true
done
rm -f ~/.kube/config
aws eks update-kubeconfig --name wskorea26-cluster --region $REGION

# Wait for access entry propagation
sleep 30

sed -i "s|ACCOUNT_ID|$ACCOUNT|g" deployment.yaml
sed -i "s|ACCOUNT_ID|$ACCOUNT|g" grafana-values.yaml
# IRSA: Get OIDC provider info and update IAM roles
BOOK_APP_ROLE=$(aws iam list-roles --output json | jq -r '[.Roles[] | select(.RoleName | startswith("wskorea26-book-app-role-"))] | sort_by(.CreateDate) | last | .RoleName')
OIDC_ISSUER=$(aws eks describe-cluster --name wskorea26-cluster --query 'cluster.identity.oidc.issuer' --output text)
OIDC_ID=$(echo $OIDC_ISSUER | awk -F'/' '{print $NF}')
OIDC_PROVIDER="oidc.eks.ap-northeast-2.amazonaws.com/id/$OIDC_ID"

aws iam update-assume-role-policy --role-name $BOOK_APP_ROLE --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": { \"Federated\": \"arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC_PROVIDER}\" },
    \"Action\": \"sts:AssumeRoleWithWebIdentity\",
    \"Condition\": {
      \"StringEquals\": {
        \"${OIDC_PROVIDER}:sub\": \"system:serviceaccount:wskorea26:book-sa\",
        \"${OIDC_PROVIDER}:aud\": \"sts.amazonaws.com\"
      }
    }
  }]
}"

aws iam create-role --role-name wskorea26-fluentbit-role \
  --assume-role-policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": { \"Federated\": \"arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC_PROVIDER}\" },
    \"Action\": \"sts:AssumeRoleWithWebIdentity\",
    \"Condition\": {
      \"StringEquals\": {
        \"${OIDC_PROVIDER}:sub\": \"system:serviceaccount:logging:fluentbit-sa\",
        \"${OIDC_PROVIDER}:aud\": \"sts.amazonaws.com\"
      }
    }
  }]
}" 2>/dev/null || aws iam update-assume-role-policy --role-name wskorea26-fluentbit-role --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": { \"Federated\": \"arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC_PROVIDER}\" },
    \"Action\": \"sts:AssumeRoleWithWebIdentity\",
    \"Condition\": {
      \"StringEquals\": {
        \"${OIDC_PROVIDER}:sub\": \"system:serviceaccount:logging:fluentbit-sa\",
        \"${OIDC_PROVIDER}:aud\": \"sts.amazonaws.com\"
      }
    }
  }]
}"
aws iam put-role-policy --role-name wskorea26-fluentbit-role --policy-name logs-policy \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogGroups","logs:DescribeLogStreams"],"Resource":"*"}]}'

aws iam create-role --role-name wskorea26-grafana-role \
  --assume-role-policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": { \"Federated\": \"arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC_PROVIDER}\" },
    \"Action\": \"sts:AssumeRoleWithWebIdentity\",
    \"Condition\": {
      \"StringEquals\": {
        \"${OIDC_PROVIDER}:sub\": \"system:serviceaccount:monitoring:grafana\",
        \"${OIDC_PROVIDER}:aud\": \"sts.amazonaws.com\"
      }
    }
  }]
}" 2>/dev/null || aws iam update-assume-role-policy --role-name wskorea26-grafana-role --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": { \"Federated\": \"arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC_PROVIDER}\" },
    \"Action\": \"sts:AssumeRoleWithWebIdentity\",
    \"Condition\": {
      \"StringEquals\": {
        \"${OIDC_PROVIDER}:sub\": \"system:serviceaccount:monitoring:grafana\",
        \"${OIDC_PROVIDER}:aud\": \"sts.amazonaws.com\"
      }
    }
  }]
}"
aws iam put-role-policy --role-name wskorea26-grafana-role --policy-name cw-policy \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:*","cloudwatch:*"],"Resource":"*"}]}'

chmod +x install-aws-load-balancer-controller.sh
bash install-aws-load-balancer-controller.sh

kubectl apply -f namespace.yaml
kubectl apply -f serviceaccount.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f fluentbit.yaml

# IRSA: Annotate ServiceAccounts with IAM role ARN
kubectl annotate serviceaccount book-sa -n wskorea26 \
  eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT}:role/$BOOK_APP_ROLE --overwrite
kubectl annotate serviceaccount fluentbit-sa -n logging \
  eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT}:role/wskorea26-fluentbit-role --overwrite

for id in $(kubectl get nodes -l node-type=addon -o jsonpath='{.items[*].spec.providerID}' | grep -oP 'i-[a-z0-9]+'); do
  aws ec2 create-tags --resources "$id" --tags Key=Name,Value=wskorea26-addon-node
done
for id in $(kubectl get nodes -l node-type=app -o jsonpath='{.items[*].spec.providerID}' | grep -oP 'i-[a-z0-9]+'); do
  aws ec2 create-tags --resources "$id" --tags Key=Name,Value=wskorea26-app-node
done

kubectl rollout restart deployment book-deploy -n wskorea26
kubectl rollout restart daemonset wskorea26-fluentbit -n logging
kubectl rollout status deployment/book-deploy -n wskorea26 --timeout=300s

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

helm upgrade --install prometheus prometheus-community/prometheus \
  -n monitoring --create-namespace \
  -f prometheus-values.yaml \
  --wait --timeout 300s

helm upgrade --install grafana grafana/grafana \
  -n monitoring \
  -f grafana-values.yaml \
  --set service.type=ClusterIP \
  --set serviceAccount.create=true \
  --set serviceAccount.name=grafana \
  --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=arn:aws:iam::${ACCOUNT}:role/wskorea26-grafana-role" \
  --wait --timeout 300s

kubectl rollout restart deployment grafana -n monitoring
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=180s

LAMBDA_TG_ARN=$(aws elbv2 describe-target-groups \
  --names wskorea26-book-lambda-tg \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)
sed -i "s|LAMBDA_TARGET_GROUP_ARN|$LAMBDA_TG_ARN|g" ingress.yaml
kubectl apply -f ingress.yaml

# ---------------------------------------------------------------------------
# Wait for the AWS Load Balancer Controller to provision the Book Ingress ALB.
# It takes 1-3 minutes after the Ingress is applied, so poll until it exists.
# ---------------------------------------------------------------------------
echo "Waiting for the Book Ingress ALB (wskorea26-book-alb) to be created..."
BOOK_ALB_DNS=""
for _ in $(seq 1 60); do
  BOOK_ALB_DNS=$(aws elbv2 describe-load-balancers --names wskorea26-book-alb \
    --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || true)
  if [ -n "$BOOK_ALB_DNS" ] && [ "$BOOK_ALB_DNS" != "None" ]; then
    break
  fi
  sleep 10
done
if [ -z "$BOOK_ALB_DNS" ] || [ "$BOOK_ALB_DNS" = "None" ]; then
  echo "ERROR: Book Ingress ALB was not created in time." >&2
  kubectl describe ingress book-ingress -n wskorea26 || true
  exit 1
fi
BOOK_ALB_ARN=$(aws elbv2 describe-load-balancers --names wskorea26-book-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 wait load-balancer-available --load-balancer-arns "$BOOK_ALB_ARN"
echo "Book Ingress ALB ready: $BOOK_ALB_DNS"

# Also give the Grafana Ingress ALB a chance to come up (used only at grading time).
echo "Waiting for the Grafana Ingress ALB (wskorea26-grafana-alb) to be created..."
for _ in $(seq 1 60); do
  GRAFANA_ALB_DNS=$(aws elbv2 describe-load-balancers --names wskorea26-grafana-alb \
    --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || true)
  if [ -n "$GRAFANA_ALB_DNS" ] && [ "$GRAFANA_ALB_DNS" != "None" ]; then
    break
  fi
  sleep 10
done

# ---------------------------------------------------------------------------
# Finalize CloudFront: attach the ALB origin + /book* behavior via the CLI.
# This removes the need for a second `terraform apply`. Idempotent: skips if
# the ALB origin already exists. Origin order is ALB first, S3 second, to match
# the grading (mark.sh 8-2 / 8-4) exact output.
# ---------------------------------------------------------------------------
CF_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='wskorea26-concert-cf'].Id | [0]" --output text)
CF_DOMAIN=$(aws cloudfront get-distribution --id "$CF_ID" --query "Distribution.DomainName" --output text)

if aws cloudfront get-distribution-config --id "$CF_ID" \
     | jq -e '.DistributionConfig.Origins.Items[]? | select(.Id=="wskorea26-alb-origin")' >/dev/null 2>&1; then
  echo "CloudFront ALB origin already configured; skipping patch."
else
  echo "Attaching ALB origin ($BOOK_ALB_DNS) to CloudFront distribution $CF_ID..."
  CF_CFG=$(aws cloudfront get-distribution-config --id "$CF_ID")
  CF_ETAG=$(echo "$CF_CFG" | jq -r '.ETag')
  echo "$CF_CFG" | jq --arg dns "$BOOK_ALB_DNS" '
    # Build the /book* behavior from the existing default behavior so every
    # required field is present; then override the routing-specific pieces.
    (.DistributionConfig.DefaultCacheBehavior
      | .PathPattern = "/book*"
      | .TargetOriginId = "wskorea26-alb-origin"
      | .AllowedMethods = {"Quantity":7,"Items":["GET","HEAD","POST","PUT","PATCH","OPTIONS","DELETE"],"CachedMethods":{"Quantity":2,"Items":["GET","HEAD"]}}
      | .ForwardedValues = {"QueryString":true,"Cookies":{"Forward":"all"},"Headers":{"Quantity":1,"Items":["*"]},"QueryStringCacheKeys":{"Quantity":0}}
      | .MinTTL = 0 | .DefaultTTL = 0 | .MaxTTL = 0
      | .Compress = false
    ) as $bookbeh
    # Prepend the ALB origin (index 0) and keep the existing S3 origin after it.
    | .DistributionConfig.Origins.Items = ([{
        "Id":"wskorea26-alb-origin",
        "DomainName":$dns,
        "OriginPath":"/v1",
        "CustomHeaders":{"Quantity":1,"Items":[{"HeaderName":"X-Origin-Verify","HeaderValue":"wskorea26-cf"}]},
        "CustomOriginConfig":{"HTTPPort":80,"HTTPSPort":443,"OriginProtocolPolicy":"http-only","OriginSslProtocols":{"Quantity":1,"Items":["TLSv1.2"]},"OriginReadTimeout":30,"OriginKeepaliveTimeout":5},
        "ConnectionAttempts":3,
        "ConnectionTimeout":10,
        "OriginShield":{"Enabled":false}
      }] + .DistributionConfig.Origins.Items)
    | .DistributionConfig.Origins.Quantity = (.DistributionConfig.Origins.Items | length)
    | .DistributionConfig.CacheBehaviors.Items = ([$bookbeh] + (.DistributionConfig.CacheBehaviors.Items // []))
    | .DistributionConfig.CacheBehaviors.Quantity = (.DistributionConfig.CacheBehaviors.Items | length)
    | .DistributionConfig
  ' > /tmp/wskorea26/cf-config.json

  aws cloudfront update-distribution \
    --id "$CF_ID" \
    --if-match "$CF_ETAG" \
    --distribution-config "file:///tmp/wskorea26/cf-config.json" >/dev/null
  echo "CloudFront distribution updated."
fi

kubectl get ingress -A

echo "Waiting for CloudFront distribution to finish deploying (this can take several minutes)..."
aws cloudfront wait distribution-deployed --id "$CF_ID" || echo "WARN: CloudFront still deploying; re-check 'Status' before grading section 8."

echo "===== Setup Complete ====="
echo "CloudFront: $CF_DOMAIN"
echo "Book Ingress ALB: $BOOK_ALB_DNS"
echo "Grafana Ingress ALB: ${GRAFANA_ALB_DNS:-<pending>}"
