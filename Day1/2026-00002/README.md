# 제1과제 — Terraform + setup.sh (2단계 완전 자동화)

`terraform apply` **한 번** + Bastion에서 `setup.sh` **한 번**으로 30/30 채점이 나오도록 구성되어 있습니다.
(예전의 "terraform → setup.sh → terraform 2차 apply" 3단계는 제거되었습니다.)

CloudFront가 필요로 하는 ALB Origin은 Bastion에서 setup.sh가 Ingress ALB를 만든 뒤
AWS CLI로 직접 붙입니다. 따라서 두 번째 terraform apply가 필요 없습니다.

---

## 1단계 — Terraform (로컬 / CloudShell 어디서든)

```bash
terraform init
terraform apply -auto-approve -var='pin_number=<비번호>'
```

이 단계에서 만들어지는 것:

- VPC / 서브넷 / NAT / 라우팅 / S3·DynamoDB 게이트웨이 엔드포인트
- KMS 키 3종 (s3 / dynamodb / eks)
- S3 버킷 + `web/main/index.html`, `web/main/main.jpeg` (KMS 암호화)
- DynamoDB `wskorea26-data-table` (삭제방지 + KMS + GSI)
- ECR `wskorea26-book-repo` (KMS 암호화 + scan-on-push)
- Lambda `wskorea26-book-lambda` (python3.14) + Lambda 타깃그룹
- Bastion EC2 (manifest 버킷 내용을 자동 다운로드)
- CloudFront (이 시점에는 **S3 Origin만** 존재 — ALB Origin은 setup.sh가 추가)

> `<비번호>`는 채점용 값입니다. S3 버킷 이름(`wskorea26-concert-bucket-<비번호>`)과
> Grafana 관리자 ID(`skills-<비번호>-admin`)에 그대로 쓰입니다.

---

## 2단계 — Bastion에서 setup.sh

Bastion EC2에 접속(SSM 또는 SSH) 후:

```bash
sudo bash setup.sh
```

setup.sh가 수행하는 것:

1. manifest 재다운로드 + **CRLF 제거** (Windows 개행 문제 방지)
2. Docker 이미지 빌드 → ECR `:stable` 푸시 (scan-on-push)
3. eksctl로 `wskorea26-cluster` (1.35) + addon-ng / app-ng 생성 (로그·Secret KMS 암호화)
4. IRSA(book-sa / fluentbit / grafana / lb-controller) 구성
5. AWS Load Balancer Controller 설치
6. 애플리케이션 / fluentbit / prometheus / grafana 배포
7. Ingress 적용 → `wskorea26-book-alb`, `wskorea26-grafana-alb` 생성
8. **ALB가 뜨면 CloudFront에 ALB Origin(`wskorea26-alb-origin`) + `/book*` 비헤이비어를 CLI로 부착**
9. CloudFront 배포 완료(`Deployed`)까지 대기

로그는 `/home/*/wskorea26-setup-*.log` 및 manifest 버킷 `logs/`에 저장됩니다.

```bash
tail -n 100 /home/ec2-user/wskorea26-setup-*.log
```

---

## 라우팅 동작 (URL rewrite 없이)

```text
사용자  ──HTTPS──▶  CloudFront (wskorea26-concert-cf)
                       │  X-Origin-Verify: wskorea26-cf
                       │  ALB Origin OriginPath=/v1  →  뷰어 "/book" 이 오리진엔 "/v1/book" 으로 도착
                       ▼
                 wskorea26-book-alb (HTTP 80)
     POST /v1/book + 헤더  ─▶ book-svc  ─▶ Book Pod:8080 (POST /v1/book)
     GET  /v1/book + 헤더  ─▶ Lambda 타깃그룹 (wskorea26-book-lambda)
     그 외 / 헤더 없음      ─▶ 403 Forbidden
```

- 예전엔 ALB `url-rewrite` transform으로 `/book→/v1/book`을 처리했지만, 불안정해서
  **CloudFront ALB Origin의 `OriginPath=/v1`** 로 대체했습니다. ingress 규칙은 `/v1/book`을 매칭합니다.
- 직접 ALB로 `/book` 요청 시 헤더가 없어 403이 반환됩니다 (채점 7-2 대응).

---

## 채점 / 주의사항

- 채점은 CloudShell에서 `mark.sh`로 진행합니다. VPC Environment(서브넷
  `wskorea26-priv-subnet-d`, SG `wskorea26-vpc-environment-sg`)로 CloudShell을 띄운 뒤 실행합니다.
- CloudShell에서 `kubectl`(채점 5-4)을 쓰려면 해당 IAM User가 EKS Access Entry에 있어야 합니다.
  setup.sh가 **계정 내 모든 IAM User + Bastion Role**을 ClusterAdmin으로 자동 등록하므로 별도 수동 등록이 필요 없습니다.
  (단, CloudShell을 IAM User가 아닌 SSO/Assumed-Role로 접속하는 경우엔 그 Role ARN을 직접 등록해야 합니다.)
- CloudFront 배포에는 수 분이 걸립니다. setup.sh가 `distribution-deployed`까지 기다리므로,
  스크립트가 정상 종료되면 8-x 채점(특히 8-1 `Deployed`)이 통과 상태가 됩니다.

## Monitoring (채점 10) 참고

Grafana 대시보드 `wskorea26-monitoring`은 과제지가 요구하는 5개 지표를 5개 패널로 표시합니다.
채점기준표는 CPU/Memory를 10-1로 묶어 4행이지만, 5개 패널 구성이 맞습니다.

- Container CPU Usage, Container Memory Usage  → 10-1
- Running Pods                                 → 10-2
- Container Restart Count                       → 10-3
- Container Network Receive                     → 10-4

**Restart Count 패널 주의**: 파드가 한 번도 재시작하지 않았으면 값이 0이라 그래프가
바닥에 붙어 "빈 패널"처럼 보입니다(지표 자체는 정상). 채점위원 오해를 피하려면 채점 직전에
한 번 재시작을 유발해 값을 1 이상으로 올려두면 확실합니다(선택 사항):

```bash
kubectl rollout restart deployment book-deploy -n wskorea26
# 새 파드가 Running 된 뒤 잠시 기다리면 Restart Count 패널에 값이 나타납니다.
kubectl rollout status deployment/book-deploy -n wskorea26
```
