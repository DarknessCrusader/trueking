# 2026 전국기능경기대회 07 - 2과제 (Windows 실행)

각 모듈을 **Windows에서 `terraform apply` 한 번**으로 배포합니다. Docker 빌드/푸시와
Kubernetes(helm/kubectl) 작업은 Windows에서 직접 할 수 없으므로 **Bastion EC2**가
`user_data`(setup.sh)로 자동 수행합니다. 별도의 수동 SSM 접속/콘솔 작업은 없습니다.

## 사전 요구사항 (Windows)

- [Terraform](https://developer.hashicorp.com/terraform/downloads)
- [AWS CLI](https://aws.amazon.com/cli/) + 자격증명 (`aws configure`)
- Docker / kubectl / helm 은 **로컬에 설치 불필요** (Bastion이 처리)

## 배포 (모듈별 독립 실행)

```powershell
cd 07\2과제

# 모듈1: DocumentDB (서울, ~10-12분)
cd module1; terraform init; terraform apply -auto-approve; cd ..

# 모듈2: VPC Lattice (도쿄, ~3분)
cd module2; terraform init; terraform apply -auto-approve; cd ..

# 모듈3: Cloud Event Handling (싱가포르, ~3분)
cd module3; terraform init; terraform apply -auto-approve; cd ..

# 모듈4: EKS + SQS + KEDA + Karpenter (오레곤, ~18-22분)
cd module4; terraform init; terraform apply -auto-approve; cd ..
```

> 각 모듈의 `apply`는 완료 마커(S3 `done/moduleN`)를 **PowerShell로 폴링**하므로,
> `apply`가 끝나면 채점 가능한 상태입니다. (모듈4는 EKS 생성 + 이미지 빌드 + helm 배포까지 포함)

## 내부 동작 흐름

### 모듈1 (DocumentDB) — Bastion 불필요, Client EC2가 직접 수행
```
terraform apply
  ├─ VPC / Subnet / SG / KMS / DocumentDB Cluster+Instance / Secret 생성
  ├─ S3 버킷에 app/module1 파일 업로드 (GitHub 의존 제거)
  ├─ Client EC2 생성 (user_data = setup.sh.tpl)
  │    ├─ S3에서 앱 파일 다운로드
  │    ├─ venv + pip install, global-bundle.pem 다운로드
  │    ├─ systemd로 앱 상시 실행 (:8080)
  │    ├─ /v1/admin/seed 호출 (데이터 적재)
  │    ├─ Index + TTL Index 생성
  │    └─ S3에 done/module1 마커 기록
  └─ null_resource: PowerShell로 done/module1 폴링
```

### 모듈2 (VPC Lattice) / 모듈3 (Cloud Event Handling) — 완전 자동
- 모듈2: Service/Client EC2의 `user_data`에 Python 앱이 내장되어 자동 기동.
- 모듈3: Lambda는 로컬 `archive_file`로 패키징(Windows 호환). EventBridge+CloudTrail+SNS 자동 연결.

### 모듈4 (EKS + SQS) — Bastion이 docker/helm/kubectl 수행
```
terraform apply
  ├─ VPC / EKS Cluster / Fargate Profile(kube-system,keda,karpenter) 생성
  ├─ SQS / OIDC / IRSA Role(keda,karpenter,worker) / Node Role 생성
  ├─ ECR(skills-sqs-worker) + S3(app/module4) + Bastion EKS 관리자 접근 부여
  ├─ Bastion EC2 생성 (user_data = setup.sh.tpl)
  │    ├─ docker / kubectl / helm 설치
  │    ├─ Worker 이미지 build → push (ECR)
  │    ├─ kubeconfig 설정, CoreDNS를 Fargate로 패치
  │    ├─ helm: KEDA, Karpenter 설치
  │    ├─ Worker SA/Deployment, TriggerAuthentication, ScaledObject 적용
  │    ├─ NodePool / EC2NodeClass 적용, 서브넷 태깅
  │    └─ S3에 done/module4 마커 기록
  └─ null_resource: PowerShell로 done/module4 폴링
```

## 파일 구조

```
07/2과제/
├── module1/        # DocumentDB (ap-northeast-2)
│   ├── provider.tf · variables.tf · module1.tf
│   └── setup.sh.tpl          # Client EC2 user_data
├── module2/        # VPC Lattice (ap-northeast-1)
│   ├── provider.tf · module2.tf
├── module3/        # EventBridge+Lambda (ap-southeast-1)
│   ├── provider.tf · module3.tf
├── module4/        # EKS+SQS (us-west-2)
│   ├── provider.tf · module4.tf
│   ├── bastion.tf            # ECR/S3/Bastion/EKS 접근/폴링
│   └── setup.sh.tpl          # Bastion user_data (docker+helm+kubectl)
├── app/                      # 모듈별 앱 소스 (S3/user_data로 전달)
└── README.md
```

## 트러블슈팅

### 모듈4 K8s 부트스트랩(setup.sh) 재실행
`setup.sh`는 **멱등(idempotent)** 하게 재작성되어 있고, 종료 시 로그를 S3에 업로드합니다.
채점에서 4-2~4-6이 비었다면(네임스페이스/컨트롤러/ScaledObject/NodePool 부재) Bastion
부트스트랩이 중간에 실패한 것입니다. **SSM 접속 없이** 아래로 원인 확인 후 재실행합니다.

```powershell
# 1) 실패 로그 확인 (SSM 불필요 — setup.sh가 S3로 업로드)
$acct = aws sts get-caller-identity --query Account --output text
aws s3 cp "s3://skills-sqs-bastion-$acct/log/module4-setup.log" - --region us-west-2 | Select-Object -Last 60

# 2) Bastion을 재생성하여 부트스트랩 재실행 (setup.sh 변경 시 자동 재생성됨)
cd module4
terraform taint aws_instance.bastion          # 강제 재실행이 필요할 때
terraform apply -auto-approve                  # 새 Bastion이 멱등 스크립트를 재수행
```

- `setup.sh` 내용을 수정하면 `user_data_replace_on_change=true`로 **`apply` 시 Bastion이
  자동 재생성**되어 재부트스트랩됩니다(수동 taint 불필요).
- `apply` 폴링은 완료 마커 `s3://.../done/module4`를 최대 ~35분 대기하며, 타임아웃 시
  로그 마지막 40줄을 출력합니다. 완료 마커는 **핵심 오브젝트(ScaledObject/NodePool/Deployment)가
  모두 존재할 때만** 기록됩니다.

### 남은 리스크 — Karpenter 버전 ↔ EKS 버전 호환
- 채점 클러스터는 **EKS 1.36**입니다. `setup.sh`의 Karpenter helm 핀은 `--version 1.4.0`입니다.
  KEDA/네임스페이스는 정상이지만 **4-5(NodePool)/4-6(Scale Out)만 실패**한다면 Karpenter가
  1.36과 호환되지 않아 컨트롤러가 reconcile에 실패한 경우입니다.
  이때 `setup.sh`의 Karpenter `--version`을 1.36을 지원하는 최신 1.x로 올린 뒤 위 재실행 절차를
  수행하세요. (helm 로그: S3의 `log/module4-setup.log`에서 `karpenter` 검색)

### 리전 STS 비활성화(RegionDisabledException) — IRSA 파드 크래시
- 증상: Karpenter/KEDA(그리고 worker) 파드가 `AssumeRoleWithWebIdentity ... 403
  RegionDisabledException: STS is not activated in this region` 로 CrashLoopBackOff.
- 원인: 채점 계정에서 **`us-west-2` 리전 STS가 비활성**이라 IRSA가 리전 엔드포인트
  (`sts.us-west-2.amazonaws.com`)로 토큰을 교환하지 못함. IAM 콘솔에서만 활성화 가능하고
  API/Terraform으로 켤 수 없음.
- 해결: **글로벌 STS 엔드포인트를 강제**. `setup.sh`는 각 컨트롤러/워커에
  `AWS_ENDPOINT_URL_STS=https://sts.amazonaws.com` 를 주입합니다(항상 활성).
  참고: `aws-sdk-go-v2`(Karpenter/KEDA)는 `AWS_STS_REGIONAL_ENDPOINTS=legacy` 를
  web-identity 자격증명 공급자에 반영하지 않으므로 엔드포인트 URL을 명시하는 방식만 유효합니다.

### 기타
- 모듈1 폴링 타임아웃 시 `skills-nosql-client-ec2`의 `/var/log/skills-setup.log` 확인(SSM 접속).

---

## 채점 방법 (CloudShell / 채점 환경)

### 배점 (총 30점)

| 모듈 | 항목 | 배점 |
|------|------|------|
| 1 | DocumentDB based NoSQL Application | 7.5 |
| 2 | VPC Lattice | 7.5 |
| 3 | Cloud Event Handling | 7.5 |
| 4 | EKS + SQS + KEDA + Karpenter | 7.5 |

### 0. 사전 준비

```bash
# kubectl 설치 (없는 경우) — 클러스터 마이너 버전의 최신 stable 패치 사용
EKS_VERSION=$(aws eks describe-cluster --region us-west-2 --name skills-sqs-cluster --query 'cluster.version' --output text)
KVER=$(curl -fsSL "https://dl.k8s.io/release/stable-${EKS_VERSION}.txt" || echo "v${EKS_VERSION}.0")
curl -L -o /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
chmod +x /tmp/kubectl; export PATH="/tmp:$PATH"

# 채점 변수
export NOSQL_CLIENT_EC2_PUBLIC_IP=$(aws ec2 describe-instances --region ap-northeast-2 --filters Name=tag:Name,Values=skills-nosql-client-ec2 Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
export LATTICE_CLIENT_EC2_PUBLIC_IP=$(aws ec2 describe-instances --region ap-northeast-1 --filters Name=tag:Name,Values=skills-lattice-client-ec2 Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
export SERVICE_NETWORK_ID=$(aws vpc-lattice list-service-networks --region ap-northeast-1 --query "items[?name=='skills-lattice-sn'].id | [0]" --output text)
export TARGET_GROUP_ID=$(aws vpc-lattice list-target-groups --region ap-northeast-1 --query "items[?name=='skills-lattice-order-tg'].id | [0]" --output text)
export SERVICE_ID=$(aws vpc-lattice list-services --region ap-northeast-1 --query "items[?name=='skills-lattice-order-service'].id | [0]" --output text)
export QUEUE_URL=$(aws sqs get-queue-url --region us-west-2 --queue-name skills-sqs-queue --query QueueUrl --output text)
```

### 1. 모듈1: DocumentDB (1.5점 x 5)

```bash
aws docdb describe-db-clusters --region ap-northeast-2 --db-cluster-identifier skills-nosql-docdb-cluster --output table
aws kms describe-key --region ap-northeast-2 --key-id alias/skills-nosql-docdb --output table
aws secretsmanager get-secret-value --region ap-northeast-2 --secret-id skills-nosql-docdb-secret --query SecretString --output text
curl -s -w "\n%{http_code}\n" http://${NOSQL_CLIENT_EC2_PUBLIC_IP}:8080/health
curl -s -w "\n%{http_code}\n" http://${NOSQL_CLIENT_EC2_PUBLIC_IP}:8080/v1/admin/summary
curl -s -w "\n%{http_code}\n" http://${NOSQL_CLIENT_EC2_PUBLIC_IP}:8080/v1/admin/indexes
curl -s -w "\n%{http_code}\n" http://${NOSQL_CLIENT_EC2_PUBLIC_IP}:8080/v1/orders/O-1001
curl -s -w "\n%{http_code}\n" "http://${NOSQL_CLIENT_EC2_PUBLIC_IP}:8080/v1/orders/pending?from=2026-06-01T00:00:00Z&to=2026-06-08T00:00:00Z"
curl -s -w "\n%{http_code}\n" "http://${NOSQL_CLIENT_EC2_PUBLIC_IP}:8080/v1/products/low-stock?warehouseId=W-A"
```

### 2. 모듈2: VPC Lattice (1.5점 x 5)

```bash
curl -s -w "\n%{http_code}\n" http://${LATTICE_CLIENT_EC2_PUBLIC_IP}/health
aws vpc-lattice list-service-networks --region ap-northeast-1 --output table
aws vpc-lattice list-targets --region ap-northeast-1 --target-group-identifier "$TARGET_GROUP_ID" --output table
aws vpc-lattice list-listeners --region ap-northeast-1 --service-identifier "$SERVICE_ID" --output table
curl -s -w "\n%{http_code}\n" "http://${LATTICE_CLIENT_EC2_PUBLIC_IP}/v1/client/orders?id=1001"
```

### 3. 모듈3: Cloud Event Handling (1.5점 x 5)

```bash
aws ec2 describe-security-groups --region ap-southeast-1 --filters Name=tag:Name,Values=skills-ceh-protected-sg --query "SecurityGroups[].IpPermissions" --output json
aws lambda get-function-configuration --region ap-southeast-1 --function-name skills-ceh-remediate-fn --output table
aws cloudtrail get-trail-status --region ap-southeast-1 --name skills-ceh-cloudtrail --output table
aws events describe-rule --region ap-southeast-1 --name skills-ceh-sg-change-rule --event-bus-name default --output json
# 복구 검증
export PROTECTED_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --region ap-southeast-1 --filters Name=tag:Name,Values=skills-ceh-protected-sg --query "SecurityGroups[0].GroupId" --output text)
aws ec2 authorize-security-group-ingress --region ap-southeast-1 --group-id "$PROTECTED_SECURITY_GROUP_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0
jq -n --arg sg "$PROTECTED_SECURITY_GROUP_ID" '{detail:{eventName:"AuthorizeSecurityGroupIngress",requestParameters:{groupId:$sg}}}' > /tmp/ev.json
aws lambda invoke --region ap-southeast-1 --function-name skills-ceh-remediate-fn --cli-binary-format raw-in-base64-out --payload file:///tmp/ev.json /tmp/out.json
aws ec2 describe-security-groups --region ap-southeast-1 --group-ids "$PROTECTED_SECURITY_GROUP_ID" --query "SecurityGroups[0].IpPermissions" --output json
```

### 4. 모듈4: EKS + SQS (1.25점 x 6)

```bash
aws eks update-kubeconfig --region us-west-2 --name skills-sqs-cluster
kubectl get nodes -l eks.amazonaws.com/compute-type=fargate -o wide
kubectl get serviceaccount sqs-worker-sa -n skills-sqs -o yaml
kubectl get deployment,pod -n keda -o wide
kubectl get deployment,pod -n karpenter -o wide
kubectl get scaledobject sqs-worker-scaledobject -n skills-sqs -o yaml
kubectl get nodepool skills-sqs-nodepool -o yaml
kubectl get ec2nodeclass skills-sqs-nodeclass -o yaml
# Scale Out 검증
for i in $(seq 1 12); do aws sqs send-message --region us-west-2 --queue-url "$QUEUE_URL" --message-body "judge-$i"; done
kubectl get pods -n skills-sqs -l app=sqs-worker -o wide
kubectl get nodes -l karpenter.sh/nodepool=skills-sqs-nodepool,skills-nodepool=event-worker -o wide
```
