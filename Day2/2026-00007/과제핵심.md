# 제2과제 vf — 리소스별 이론 완전 설명
### NoSQL · CDN Function · EKS Scaling · Container Logging

> 문제에 등장하는 리소스명을 그대로 써서, **각 리소스의 역할 · 왜 이 스펙인지 · 옆 리소스와의 연결**을 정리했습니다.

---
---

## 📦 모듈 1. NoSQL

### `bigbae-nosql-reservation-table`
DynamoDB 메인 테이블

> **핵심**: PK/SK 조합으로 "기차 단위 조회"에 최적화된 테이블

- **PK `train_id` + SK `seat_id`**
  - 같은 `train_id`의 아이템들은 같은(또는 인접) 파티션에 모여 `seat_id` 순으로 정렬 저장됨
  - → "이 기차의 모든 좌석"을 한 번의 Query로 효율적으로 조회 가능
- **Billing Mode: `PAY_PER_REQUEST`**
  - 사전 용량(RCU/WCU) 설정 없이 요청량 기반 자동 과금·확장
  - 오픈런처럼 트래픽이 순간적으로 몰리는 워크로드의 쓰로틀링 리스크 제거
- **Stream: `NEW_AND_OLD_IMAGES`**
  - 변경 전/후 아이템 전체가 스트림 레코드에 함께 담김
  - 취소 시 "누가 취소했는지" 같은 정보를 old image에서 확인 가능
- **PITR + 삭제 방지**
  - PITR: 최근 35일 내 임의 시점 복원 (실수로 인한 논리적 오류 대비)
  - 삭제 방지: 테이블 자체가 실수로 지워지는 것 방지

---

### `gsi-user-reservations`
Global Secondary Index

> **핵심**: 메인 테이블과 다른 축(사용자 기준)으로 재색인한 별도 조회 경로

- **왜 필요한가**: 메인 테이블 PK가 `train_id`라서, "이 사용자의 예약"을 찾으려면 원래 전체 Scan이 필요함 → 비효율
- **PK `user_id` + SK `reserved_at`**: 사용자별 파티셔닝 + 예약시각 정렬 → 최신순 조회 자연스럽게 가능
- **Sparse Index 성질** ⭐ 이 모듈의 핵심 이론
  - GSI 키 속성이 아이템에 아예 없으면, 그 아이템은 인덱스에 나타나지 않음
  - → 좌석이 "available"이면 `user_id`/`reserved_at` 속성 자체가 없어서 GSI에 자동으로 안 잡힘
  - → **취소 시**: `status`만 바꾸면 안 됨. `user_id`/`reserved_at` 속성 자체를 `REMOVE`해야 GSI에서 빠짐
- **Projection: `ALL`**: GSI만 조회해도 메인 테이블 재조회 불필요 (지연시간↓, 저장공간↑)

---

### `bigbae-nosql-audit-table`
감사(이력) 테이블

> **핵심**: "현재 상태"와 "이력 전체"의 책임을 물리적으로 분리

- PK만 존재(`event_id`) — 복합 조회 패턴이 필요 없는 순수 로그 나열용
- 원본 예약 테이블과 분리해서, 예약 테이블 오염 없이 이력을 누적

---

### `bigbae-nosql-reservation-audit` (Lambda)
DynamoDB Streams 트리거

> **핵심**: DB 변경 자체가 후속 처리를 자동으로 유발하는 CDC(Change Data Capture) 패턴

- Streams를 이벤트 소스로 폴링 → 새 레코드 생기면 자동 실행
- 원본 API 서버(EC2)는 감사 로직을 전혀 몰라도 됨 (관심사 완전 분리)
- **Timeout 30초**: 실제로는 보통 수 초 내 처리되므로 이 값은 안전마진

---

### `bigbae-nosql-app-ec2` (Flask)
클라이언트 요청 처리 계층

> **핵심**: ConditionExpression으로 원자적 동시성 제어

- **Conditional Write**: "현재 값이 조건을 만족할 때만" 쓰기 허용, 아니면 원자적으로 실패
  - RDB의 Row Lock 없이도, DynamoDB 단일 아이템의 원자성만으로 동시성 문제 해결
- Public Subnet + Public IP + TCP 8080 → 외부 직접 접근
- IAM Instance Profile: DynamoDB 최소 권한(Get/Put/Update/Query) + GSI 인덱스 ARN 별도 허용 필요

---
---

## 🌐 모듈 2. CDN Function

### `skillsphone-landing-ab-<ACCOUNT_ID>` (S3)
> **핵심**: Public Access 완전 차단 → CloudFront가 유일한 경로

### OAC (Origin Access Control)
> **핵심**: CloudFront → S3 요청에 SigV4 서명을 자동으로 붙여 인증

- S3 Bucket Policy에서 "이 서명이 특정 Distribution ARN에서 왔는지" 조건부 허용
- 이 조건 밖의 요청(직접 S3 접근 등)은 전부 거부
- 예전 방식(OAI)보다 세밀한 리소스 단위 제어 + SSE-KMS 지원

### `skillsphone-cdn-ab-config` (KeyValueStore)
> **핵심**: 엣지에 복제되는 저지연 Key-Value 저장소 = "설정과 로직의 분리"

| 키 | 값 | 의미 |
|---|---|---|
| `weight` | 0.3 | A/B 노출 비율 |
| `version_a` | `/version-a/index.html` | A 버전 실제 경로 |
| `version_b` | `/version-b/index.html` | B 버전 실제 경로 |

- 함수 코드는 "KVS에서 읽어와 비교한다"는 로직만 담고, 실제 숫자는 함수 밖(KVS)에 존재
- 비율 변경 시 **함수 재배포 불필요**, KVS 값만 갱신하면 즉시 반영

### `skillsphone-cdn-ab-req-fn` (viewer-request 함수)
> **핵심**: 캐시 조회 직전 실행, 버전 할당 + URI 재작성 + 다음 단계로 값 전달

1. 쿠키(`x-sp-ab`) 있음? → 그 값 그대로 사용
2. 없음? → KVS `weight` 읽어 랜덤 비교로 a/b 할당
3. 할당된 버전의 실제 경로로 **Request URI 재작성**
4. `x-sp-ab-assigned` 커스텀 헤더에 할당값 기록 → viewer-response로 전달

- `cloudfront-js-2.0` 런타임 + KVS 연결(Associate) 필수 — 연결 안 하면 KVS 접근 자체 불가

### `skillsphone-cdn-ab-res-fn` (viewer-response 함수)
> **핵심**: 응답 직전 실행, 쿠키를 세팅해 "재접속해도 동일 버전" 구현

- `x-sp-ab-assigned` 값이 있으면 → `Set-Cookie: x-sp-ab=<값>; Path=/; Max-Age=86400`
- 브라우저에 쿠키 저장 → 다음 요청부터 viewer-request가 "쿠키 있음" 분기로 재사용

### `skillsphone-cdn-ab-cache-policy`
> **핵심**: A/B 버전이 캐시에서 섞이지 않도록 쿠키를 캐시 키에 포함

- Cookies: whitelist(`x-sp-ab`) — 안전장치 성격 (URI 재작성만으로도 어느 정도 분리되지만 명시적으로 한 번 더 고정)
- Min/Default/Max TTL = 0 / 300 / 3600 — 오리진이 캐시 헤더 안 보내면 Default(300초) 적용

### Response Headers Policy (커스텀)
> **핵심**: AWS Managed 대신 직접 설계 → "미리 정의된 값이 아니라 서비스에 맞게" 원칙

### `skillsphone-cdn-ab-distribution`
> **핵심**: 위 모든 구성요소를 하나로 묶는 최상위 리소스, Pay-as-you-go 요금제

---
---

## ☸️ 모듈 3. EKS Scaling

### `skm-order-queue` (SQS Standard)
> **핵심**: 순서 보장 없음 + 무제한에 가까운 처리량 → 대량 주문 처리에 적합

- KEDA가 `ApproximateNumberOfMessages` 지표를 주기적으로 폴링

### `skm-eks-cluster`
> **핵심**: Control Plane(API Server, etcd, Scheduler)을 AWS가 완전관리

### `skm-cluster-addon-ng` (Addon NodeGroup)
> **핵심**: Taint로 App과 물리적 격리 → 스케일링 시스템의 안정성 확보

- Desired/Min/Max = 1/1/1 → **고정 크기, 스케일링 대상 아님**
- **Taint/Toleration 이론**
  - Taint: 노드에 거는 "특별한 조건 없이 아무 Pod도 못 들어옴" 배타 표시
  - Toleration: Pod가 "나는 이 taint를 견딜 수 있다"고 선언
  - KEDA/Karpenter만 Toleration 부여 → App이 실수로도 여기 배치 안 됨
  - **이유**: App이 스케일 인/아웃 되며 노드가 빈번히 생성/삭제될 때, 시스템 컴포넌트까지 흔들리면 스케일링 시스템 자체가 불안정해짐

### KEDA (`keda` 네임스페이스)
> **핵심**: HPA의 한계(CPU/메모리만 지표 가능)를 넘어 외부 이벤트(큐 길이 등) 기반 스케일링

### `order-scaler` (ScaledObject, `skillsmkt`)
> **핵심**: `필요 Pod 수 ≈ ceil(큐 메시지 수 / queueLength)`

- `queueLength: 5`, Min 1 / Max 5
- Min=1인 이유: 메시지 0건이라도 Pod를 완전히 0으로 줄이면 다음 메시지 올 때 Cold Start 지연 발생

### Karpenter (`kube-system`)
> **핵심**: Pending Pod를 직접 감시 → 필요한 스펙의 노드를 그때그때 즉석 생성

- Cluster Autoscaler(미리 정의된 ASG 크기만 조절) vs Karpenter(동적으로 인스턴스 선택) — 근본적 차이

### `skm-app-nodepool` / `skm-app-nodeclass`
> **핵심**: NodeClass=AWS 레벨 스펙, NodePool=인스턴스 타입/라벨/taint/Consolidation 정책

- Consolidation 정책 → **"60초 후 반환"** 조건이 여기서 구현됨
- 이 NodePool에도 taint를 걸어 App만 배치되도록 강제

### `order-processor` (Deployment, `skillsmkt`)
> **핵심**: Request 값이 스케줄러/Karpenter의 판단 기준

- CPU 500m / Memory 512Mi Request → Karpenter가 Pending Pod 보고 필요한 인스턴스 크기 역산
- nodeSelector로 `skm-app-nodepool`만 지정 → 잘못된 노드풀 배치 방지

---
---

## 📊 모듈 4. Container Logging

### `o11y-cluster` (Multi-AZ NodeGroup)
> **핵심**: AZ 장애 격리 + 로그 타임존 통일(KST)

### `log-generator` (Deployment)
> **핵심**: stdout으로 JSON 로그 출력 = 컨테이너 로깅의 표준 관행 (12-Factor App)

- containerd가 stdout을 노드의 `/var/log/pods/...`에 자동 기록 → 앱이 직접 파일 I/O 불필요

### `o11y-app-alb` / `o11y-app-tg`
> **핵심**: 외부 트래픽을 log-generator Pod로 분산 (로그 발생 원천)

### `o11y-otel` (DaemonSet, `monitoring`)
> **핵심**: 로그는 그 노드에만 존재 → 수집기는 반드시 모든 노드에 있어야 함 (DaemonSet의 필연성)

- **filelog Receiver**: `/var/log/pods/*/*/*.log` tail 읽기
- **k8sattributes Processor**: 쿠버네티스 API 질의 → namespace/pod/container를 구조화된 라벨로 부착(Enrichment)
  - 이 라벨이 있어야 Loki/Grafana에서 namespace/pod 단위 필터링 가능
- **OTLP HTTP Exporter**: 표준 프로토콜로 Loki에 전송

### `o11y-loki`
> **핵심**: Single Binary 모드, Index+Chunks를 PV에 저장, ClusterIP로 내부 전용 노출

- Single Binary = 여러 마이크로서비스(distributor/ingester/querier 등)를 하나의 프로세스로 통합 (소규모용)
- Index(찾아주는 목차) + Chunks(압축된 로그 원문) → PV 저장 안 하면 Pod 재시작 시 로그 유실
- OTLP Ingestion Endpoint 활성화 → OTel Collector가 보내는 표준 포맷 수신
- ClusterIP → Grafana만 내부에서 접근

### `o11y-grafana` (`monitoring`)
> **핵심**: Loki를 Datasource로 등록, LogQL로 조회, ALB로 외부 노출

**Log Overview 대시보드 3패널**

| 패널 | 타입 | 내용 |
|---|---|---|
| Log Count Over Time | Bar chart | 구간별 로그 발생 건수 |
| Log Level Distribution | Pie chart | level별(info/warn/error) 비율 |
| Recent Logs | Logs 패널 | 원본 로그 스트림 최신순 |

- 범례는 대소문자 무관 plain text 표기 통일 필요

---
---

## 🎯 핵심 이론 요약

| 이론 개념 | 정의 | 적용 사례 |
|---|---|---|
| 조건부 원자적 쓰기 | 조건 만족 시에만 쓰기 원자적 허용/거부 | DynamoDB 좌석 예약 |
| 희소 인덱스 (Sparse Index) | 키 속성 없는 아이템은 인덱스 자동 제외 | GSI |
| 변경 데이터 캡처 (CDC) | DB 변경이 후속 이벤트를 자동 유발 | Streams → Lambda |
| 설정/로직 분리 | 동작을 결정하는 값을 코드 밖에 저장 | KeyValueStore |
| 오리진 접근 제어 | CDN 우회 접근 원천 차단 | OAC |
| 이벤트 기반 오토스케일링 | 리소스 메트릭 아닌 외부 지표로 스케일 | KEDA |
| 즉석 노드 프로비저닝 | Pending Pod 감지 후 맞는 노드 즉석 생성 | Karpenter |
| 노드 배타적 예약 | 특정 노드엔 특정 워크로드만 배치 | Taint/Toleration |
| 노드별 필수 배포 | 모든 노드에 정확히 1개씩 보장 | DaemonSet |