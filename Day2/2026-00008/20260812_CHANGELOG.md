## 채점 4-5

### 채점 명령어

```bash
kubectl get nodepool skills-sqs-nodepool -o json | jq '{name:.metadata.name, labels:.spec.template.metadata.labels, nodeClassRef:.spec.template.spec.nodeClassRef, requirements:.spec.template.spec.requirements, consolidationPolicy:.spec.disruption.consolidationPolicy}'
kubectl get ec2nodeclass skills-sqs-nodeclass -o json | jq '{name:.metadata.name, role:.spec.role, instanceProfile:.spec.instanceProfile, subnetSelectorTerms:.spec.subnetSelectorTerms, securityGroupSelectorTerms:.spec.securityGroupSelectorTerms, amiFamily:.spec.amiFamily}'
kubectl get nodes -l karpenter.sh/nodepool=skills-sqs-nodepool,skills-nodepool=event-worker -o json | jq '[.items[] | {name:.metadata.name, nodepool:.metadata.labels["karpenter.sh/nodepool"], skillsNodepool:.metadata.labels["skills-nodepool"], instanceType:.metadata.labels["node.kubernetes.io/instance-type"], ready:([.status.conditions[] | select(.type=="Ready")][0].status)}]'
kubectl get pods -n skills-sqs -l app=sqs-worker -o json | jq '[.items[] | {name:.metadata.name, phase:.status.phase, node:.spec.nodeName}]'
```

### 판정 기준

```text
NodePool name=skills-sqs-nodepool이어야 합니다.
NodePool labels에 skills-nodepool=event-worker가 있어야 합니다.
NodePool nodeClassRef.name=skills-sqs-nodeclass이어야 합니다.
NodePool consolidationPolicy가 비어 있지 않아야 합니다.
EC2NodeClass name=skills-sqs-nodeclass이어야 하며 role 또는 instanceProfile이 출력되어야 합니다.
Worker EC2 Node는 nodepool=skills-sqs-nodepool, skillsNodepool=event-worker, ready=True가 출력되어야 합니다.
Worker Pod는 phase와 node가 출력되어야 합니다.
단, Worker Deployment 및 KEDA 설정의 minReplicaCount=0 특성상 채점 시점에 Worker EC2 Node 또는 Worker Pod가 없을 수 있으므로, 이 경우 동일 과제의 4-6 SQS 기반 Scale Out 실행 결과에서 확인된 Worker EC2 Node 및 Worker Pod 출력을 포함하여 판정할 수 있습니다.
```
