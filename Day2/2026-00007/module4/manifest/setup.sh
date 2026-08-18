#!/bin/bash
set -e

REGION="ap-northeast-1"
CLUSTER="o11y-cluster"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/o11y-log-generator"
S3_BUCKET="o11y-setup-${ACCOUNT_ID}"
number=${COMPETITOR_NUMBER}

echo "=== Creating EKS Cluster via eksctl ==="
VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=o11y-vpc --query "Vpcs[0].VpcId" --output text --region $REGION)
SUBNET_A=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=o11y-pub-a --query "Subnets[0].SubnetId" --output text --region $REGION)
SUBNET_C=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=o11y-pub-c --query "Subnets[0].SubnetId" --output text --region $REGION)
EKS_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=o11y-eks-sg --region $REGION --query "SecurityGroups[0].GroupId" --output text)

if aws eks describe-cluster --name $CLUSTER --region $REGION &>/dev/null; then
  echo "Cluster $CLUSTER already exists, skipping creation"
  aws eks update-kubeconfig --name $CLUSTER --region $REGION
else

cat > /tmp/cluster.yaml <<CLUSTEREOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER}
  region: ${REGION}
  version: "1.35"
vpc:
  id: ${VPC_ID}
  securityGroup: ${EKS_SG}
  subnets:
    public:
      ap-northeast-1a: { id: ${SUBNET_A} }
      ap-northeast-1c: { id: ${SUBNET_C} }
  clusterEndpoints:
    publicAccess: true
    privateAccess: true
managedNodeGroups:
  - name: o11y-cluster-ng
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 2
    maxSize: 2
    iam:
      withAddonPolicies:
        ebs: true
    preBootstrapCommands:
      - "timedatectl set-timezone Asia/Seoul"
addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: eks-pod-identity-agent
  - name: aws-ebs-csi-driver
iam:
  withOIDC: true
CLUSTEREOF

eksctl create cluster -f /tmp/cluster.yaml
fi

# Access Entry for root
aws eks create-access-entry --cluster-name $CLUSTER --principal-arn arn:aws:iam::${ACCOUNT_ID}:root --type STANDARD --region $REGION 2>/dev/null || true
aws eks associate-access-policy --cluster-name $CLUSTER --principal-arn arn:aws:iam::${ACCOUNT_ID}:root --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster --region $REGION 2>/dev/null || true

# EKS SG already open via Terraform
CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $CLUSTER_SG --protocol -1 --port -1 --cidr 0.0.0.0/0 --region $REGION 2>/dev/null || true

echo "=== Downloading files from S3 ==="
aws s3 cp s3://${S3_BUCKET}/app.py /tmp/app.py --region $REGION
aws s3 cp s3://${S3_BUCKET}/Dockerfile /tmp/Dockerfile --region $REGION

echo "=== Building and pushing Docker image ==="
aws ecr create-repository --repository-name o11y-log-generator --region $REGION 2>/dev/null || true
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com
cd /tmp
docker build -t ${ECR_REPO}:latest .
docker push ${ECR_REPO}:latest

echo "=== Fix StorageClass ==="
kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true

echo "=== Installing Helm ==="
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "=== Installing Helm charts ==="
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

# ALB Controller
OIDC_ID=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.identity.oidc.issuer" --output text | grep -oP 'id/\K.*')
cat > /tmp/alb-trust.json <<TRUSTEOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
        "oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
TRUSTEOF

aws iam create-role --role-name o11y-alb-controller-role --assume-role-policy-document file:///tmp/alb-trust.json 2>/dev/null || \
aws iam update-assume-role-policy --role-name o11y-alb-controller-role --policy-document file:///tmp/alb-trust.json
aws iam attach-role-policy --role-name o11y-alb-controller-role --policy-arn arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess 2>/dev/null || true
aws iam put-role-policy --role-name o11y-alb-controller-role --policy-name o11y-alb-controller-extra --policy-document '{
  "Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["ec2:Describe*","ec2:CreateSecurityGroup","ec2:CreateTags","ec2:DeleteTags","ec2:AuthorizeSecurityGroupIngress","ec2:RevokeSecurityGroupIngress","ec2:DeleteSecurityGroup","elasticloadbalancing:*","cognito-idp:DescribeUserPoolClient","acm:ListCertificates","acm:DescribeCertificate","iam:ListServerCertificates","iam:GetServerCertificate","waf-regional:*","wafv2:*","shield:*","tag:GetResources","tag:TagResources"],"Resource":"*"}]
}'

ALB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/o11y-alb-controller-role"
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$ALB_ROLE_ARN \
  --set vpcId=$VPC_ID \
  --wait --timeout 5m

# Loki with OTLP ingestion enabled
helm upgrade --install o11y-loki grafana/loki -n monitoring --create-namespace \
  --set deploymentMode=SingleBinary \
  --set singleBinary.replicas=1 \
  --set singleBinary.persistence.enabled=true \
  --set singleBinary.persistence.size=10Gi \
  --set loki.auth_enabled=false \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set loki.limits_config.allow_structured_metadata=true \
  --set 'loki.schemaConfig.configs[0].from=2024-01-01' \
  --set 'loki.schemaConfig.configs[0].store=tsdb' \
  --set 'loki.schemaConfig.configs[0].object_store=filesystem' \
  --set 'loki.schemaConfig.configs[0].schema=v13' \
  --set 'loki.schemaConfig.configs[0].index.prefix=index_' \
  --set 'loki.schemaConfig.configs[0].index.period=24h' \
  --set chunksCache.enabled=false \
  --set resultsCache.enabled=false \
  --set backend.replicas=0 \
  --set read.replicas=0 \
  --set write.replicas=0 \
  --set gateway.enabled=false \
  --set 'loki.limits_config.otlp_config.resource_attributes.attributes_config[0].action=index_label' \
  --set 'loki.limits_config.otlp_config.resource_attributes.attributes_config[0].attributes[0]=k8s.namespace.name' \
  --set 'loki.limits_config.otlp_config.resource_attributes.attributes_config[1].action=index_label' \
  --set 'loki.limits_config.otlp_config.resource_attributes.attributes_config[1].attributes[0]=k8s.pod.name' \
  --timeout 10m

# Grafana
helm upgrade --install o11y-grafana grafana/grafana -n monitoring --create-namespace \
  --set adminUser="skills${number}" \
  --set adminPassword="GoodJob!Skills${number}^^" \
  --set service.type=ClusterIP \
  --set 'datasources.datasources\.yaml.apiVersion=1' \
  --set 'datasources.datasources\.yaml.datasources[0].name=Loki' \
  --set 'datasources.datasources\.yaml.datasources[0].type=loki' \
  --set 'datasources.datasources\.yaml.datasources[0].url=http://o11y-loki:3100' \
  --set 'datasources.datasources\.yaml.datasources[0].access=proxy' \
  --set 'datasources.datasources\.yaml.datasources[0].isDefault=true' \
  --wait --timeout 5m

echo "=== Creating namespaces ==="
kubectl create namespace o11y --dry-run=client -o yaml | kubectl apply -f -

echo "=== Deploying log-generator app ==="
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: log-generator
  namespace: o11y
spec:
  replicas: 2
  selector:
    matchLabels:
      app: log-generator
  template:
    metadata:
      labels:
        app: log-generator
    spec:
      containers:
        - name: log-generator
          image: ${ECR_REPO}:latest
          ports:
            - containerPort: 8080
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: log-generator
  namespace: o11y
spec:
  selector:
    app: log-generator
  ports:
    - port: 8080
      targetPort: 8080
  type: ClusterIP
EOF

echo "=== Deploying TargetGroupBindings ==="
APP_TG_ARN=$(aws elbv2 describe-target-groups --names o11y-app-tg --region $REGION --query "TargetGroups[0].TargetGroupArn" --output text)
GRAFANA_TG_ARN=$(aws elbv2 describe-target-groups --names o11y-grafana-tg --region $REGION --query "TargetGroups[0].TargetGroupArn" --output text)

cat <<EOF | kubectl apply -f -
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: o11y-app-tgb
  namespace: o11y
spec:
  serviceRef:
    name: log-generator
    port: 8080
  targetGroupARN: ${APP_TG_ARN}
  targetType: ip
---
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: o11y-grafana-tgb
  namespace: monitoring
spec:
  serviceRef:
    name: o11y-grafana
    port: 80
  targetGroupARN: ${GRAFANA_TG_ARN}
  targetType: ip
EOF

echo "=== Deploying OTel Collector ==="
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: o11y-otel-sa
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: o11y-otel-role
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: o11y-otel-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: o11y-otel-role
subjects:
  - kind: ServiceAccount
    name: o11y-otel-sa
    namespace: monitoring
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: o11y-otel-config
  namespace: monitoring
data:
  config.yaml: |
    receivers:
      filelog:
        include:
          - /var/log/pods/*/*/*.log
        include_file_path: true
        operators:
          - type: container
            id: container-parser
    processors:
      k8sattributes:
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.container.name
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.uid
          - sources:
              - from: connection
    exporters:
      otlphttp:
        endpoint: http://o11y-loki.monitoring.svc.cluster.local:3100/otlp
        tls:
          insecure: true
    service:
      pipelines:
        logs:
          receivers: [filelog]
          processors: [k8sattributes]
          exporters: [otlphttp]
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: o11y-otel
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: o11y-otel
  template:
    metadata:
      labels:
        app: o11y-otel
    spec:
      serviceAccountName: o11y-otel-sa
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:latest
          args: ["--config=/etc/otel/config.yaml"]
          volumeMounts:
            - name: config
              mountPath: /etc/otel
            - name: varlogpods
              mountPath: /var/log/pods
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: o11y-otel-config
        - name: varlogpods
          hostPath:
            path: /var/log/pods
EOF

echo "=== Creating Grafana Dashboard ==="
sleep 30
GRAFANA_ALB=$(aws elbv2 describe-load-balancers --names o11y-grafana-alb --query 'LoadBalancers[0].DNSName' --output text --region $REGION)
for i in $(seq 1 12); do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${GRAFANA_ALB}/api/health")
  [ "$HTTP" = "200" ] && break
  sleep 10
done

LOKI_UID=""
for i in $(seq 1 12); do
  LOKI_UID=$(curl -s -u "skills${number}:GoodJob!Skills${number}^^" "http://${GRAFANA_ALB}/api/datasources" | jq -r '.[] | select(.type=="loki") | .uid' 2>/dev/null | head -1)
  [ -n "$LOKI_UID" ] && break
  echo "Waiting for Loki datasource ($i/12)..."
  sleep 10
done

if [ -z "$LOKI_UID" ]; then
  echo "ERROR: Could not get Loki datasource UID"
  exit 1
fi

curl -s -X POST -H "Content-Type: application/json" \
  -u "skills${number}:GoodJob!Skills${number}^^" \
  "http://${GRAFANA_ALB}/api/dashboards/db" \
  -d "{
  \"dashboard\": {
    \"title\": \"Log Overview\",
    \"uid\": \"log-overview\",
    \"panels\": [
      {
        \"id\": 1,
        \"title\": \"Log Count Over Time\",
        \"type\": \"barchart\",
        \"gridPos\": {\"h\": 9, \"w\": 14, \"x\": 0, \"y\": 0},
        \"datasource\": {\"type\": \"loki\", \"uid\": \"${LOKI_UID}\"},
        \"targets\": [{\"expr\": \"sum by (level) (count_over_time({k8s_namespace_name=\\\"o11y\\\"} | json | level=~\\\"INFO|WARN|ERROR\\\" | __error__=\\\"\\\" [1m]))\", \"refId\": \"A\", \"legendFormat\": \"{{level}}\"}],
        \"options\": {\"stacking\": {\"mode\": \"normal\"}},
        \"fieldConfig\": {\"defaults\": {\"custom\": {\"stacking\": {\"mode\": \"normal\"}}}, \"overrides\": [{\"matcher\":{\"id\":\"byName\",\"options\":\"ERROR\"},\"properties\":[{\"id\":\"color\",\"value\":{\"mode\":\"fixed\",\"fixedColor\":\"red\"}}]},{\"matcher\":{\"id\":\"byName\",\"options\":\"WARN\"},\"properties\":[{\"id\":\"color\",\"value\":{\"mode\":\"fixed\",\"fixedColor\":\"yellow\"}}]},{\"matcher\":{\"id\":\"byName\",\"options\":\"INFO\"},\"properties\":[{\"id\":\"color\",\"value\":{\"mode\":\"fixed\",\"fixedColor\":\"green\"}}]}]}
      },
      {
        \"id\": 2,
        \"title\": \"Log Level Distribution\",
        \"type\": \"piechart\",
        \"gridPos\": {\"h\": 9, \"w\": 10, \"x\": 14, \"y\": 0},
        \"datasource\": {\"type\": \"loki\", \"uid\": \"${LOKI_UID}\"},
        \"targets\": [{\"expr\": \"sum by (level) (count_over_time({k8s_namespace_name=\\\"o11y\\\"} | json | level=~\\\"INFO|WARN|ERROR\\\" | __error__=\\\"\\\" [\$__range]))\", \"refId\": \"A\", \"legendFormat\": \"{{level}}\"}],
        \"fieldConfig\": {\"defaults\": {}, \"overrides\": [{\"matcher\":{\"id\":\"byName\",\"options\":\"ERROR\"},\"properties\":[{\"id\":\"color\",\"value\":{\"mode\":\"fixed\",\"fixedColor\":\"red\"}}]},{\"matcher\":{\"id\":\"byName\",\"options\":\"WARN\"},\"properties\":[{\"id\":\"color\",\"value\":{\"mode\":\"fixed\",\"fixedColor\":\"yellow\"}}]},{\"matcher\":{\"id\":\"byName\",\"options\":\"INFO\"},\"properties\":[{\"id\":\"color\",\"value\":{\"mode\":\"fixed\",\"fixedColor\":\"green\"}}]}]}
      },
      {
        \"id\": 3,
        \"title\": \"Recent Logs\",
        \"type\": \"logs\",
        \"gridPos\": {\"h\": 12, \"w\": 24, \"x\": 0, \"y\": 9},
        \"datasource\": {\"type\": \"loki\", \"uid\": \"${LOKI_UID}\"},
        \"targets\": [{\"expr\": \"{k8s_namespace_name=\\\"o11y\\\"} | json | level=~\\\"INFO|WARN|ERROR\\\" | __error__=\\\"\\\" | line_format \\\"{{.k8s_pod_name}} {\\\\\\\"ts\\\\\\\": \\\\\\\"{{.ts}}\\\\\\\", \\\\\\\"level\\\\\\\": \\\\\\\"{{.level}}\\\\\\\", \\\\\\\"msg\\\\\\\": \\\\\\\"{{.msg}}\\\\\\\", \\\\\\\"req_id\\\\\\\": \\\\\\\"{{.req_id}}\\\\\\\"}\\\"\", \"refId\": \"A\"}],
        \"options\": {\"showTime\": true, \"showLabels\": true, \"showCommonLabels\": false, \"wrapLogMessage\": false, \"prettifyLogMessage\": false, \"enableLogDetails\": true, \"dedupStrategy\": \"none\", \"sortOrder\": \"Descending\"}
      }
    ],
    \"schemaVersion\": 39,
    \"time\": {\"from\": \"now-1h\", \"to\": \"now\"},
    \"refresh\": \"10s\"
  },
  \"overwrite\": true
}"

echo ""
echo "=== Done! ==="
kubectl get pods -n o11y
kubectl get pods -n monitoring
