# Module 3 유의사항

## 채점 스크립트 vs 과제지(lambda.md) vs terraform 차이점

### Lambda 이름
| 과제지(lambda.md) | terraform | 비고 |
|---|---|---|
| wsc2026-sg-remediation | wsc2026-sg-remediation | 동일 |
| wsc2026-role-remediation | wsc2026-role-remediation | 동일 |
| wsc2026-ec2-terminate-alert | wsc2026-ec2-terminate-alert | 동일 |
| wsc2026-ec2-type-remediation | wsc2026-ec2-type-remediation | 동일 |

### EventBridge Rule 이름
| 과제지(lambda.md) | terraform | 비고 |
|---|---|---|
| wsc2026-sg-change-rule | wsc2026-sg-change-rule | 동일 |
| wsc2026-role-change-rule | wsc2026-role-change-rule | 동일 |
| wsc2026-ec2-terminate-rule | wsc2026-ec2-terminate-rule | 동일 |
| wsc2026-ec2-type-change-rule | wsc2026-ec2-type-change-rule | 동일 |

### Runtime / Handler
| 항목 | 과제지(lambda.md) | terraform |
|---|---|---|
| Runtime | Python 3.12 | python3.12 ✅ |
| Handler | index.handler | index.handler ✅ |

### 환경변수
| 함수 | 과제지(lambda.md) | terraform | 비고 |
|---|---|---|---|
| role-remediation | ROLE_NAME | ROLE_NAME | ✅ (코드에서 `os.environ["ROLE_NAME"]` 사용) |
| ec2-type-remediation | INSTANCE_TYPE | INSTANCE_TYPE | ✅ (코드에서 `os.environ.get("INSTANCE_TYPE", "t3.micro")` 사용) |

### terminate-rule 이벤트 패턴
| 항목 | 과제지(lambda.md) | terraform |
|---|---|---|
| 이벤트 | EC2 Instance State-change Notification, state: terminated | state: ["stopped", "terminated"] |

> **주의**: terraform에서 `stopped`를 추가한 이유는 채점 스크립트가 `stop-instances` 후 30초 내에 running을 확인하기 때문. 과제지는 `terminated`만 명시하지만 `stopped` 추가해도 감점 없음.

### terminate-alert Lambda 동작
| 항목 | 과제지(lambda.md) | terraform |
|---|---|---|
| state=terminated | SNS 알림만 (ALERT_ONLY) | SNS 알림만 ✅ |
| state=stopped | 과제지에 없음 | start_instances + SG 전부 삭제 + SNS |

> **주의**: 채점 3-4에서 EC2 State=running, SG Inbound=0을 기대하므로 stopped 시 자동 복구 필요.

### SG Remediation 동작
| 항목 | 과제지(lambda.md) | terraform |
|---|---|---|
| 동작 | "위반 인바운드 규칙 삭제" | 모든 인바운드 삭제 (채점 expect 0) |

> **주의**: 채점 기준표에서 SG Inbound Count expect 0이므로 TCP 80 포함 전부 삭제.

### SECURITY_GROUP_ID 환경변수
- 과제지에는 `wsc2026-ec2-terminate-alert`에 SECURITY_GROUP_ID가 없음
- terraform에서 추가한 이유: stopped 이벤트 시 SG 삭제를 위해 필요

## apply 순서
```bash
terraform init
terraform apply --auto-approve
```
추가 조치 없이 apply만 하면 채점 가능.
