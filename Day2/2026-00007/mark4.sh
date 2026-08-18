#!/bin/bash

echo "Module 4 - Container Logging"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
rm -rf ~/.aws
aws sts get-caller-identity | jq .Account
echo "채점준비 끝! 채점 시작!"

echo "=== 4-1-A ==="
aws eks describe-cluster --name o11y-cluster --query 'cluster.[name, version, status]' --output text --region ap-northeast-1
aws eks describe-nodegroup --cluster-name o11y-cluster --nodegroup-name "$(aws eks list-nodegroups --cluster-name o11y-cluster --region ap-northeast-1 --query 'nodegroups[0]' --output text)" --query 'nodegroup.[instanceTypes[0], scalingConfig.minSize, scalingConfig.desiredSize, scalingConfig.maxSize]' --output text --region ap-northeast-1
aws eks update-kubeconfig --name o11y-cluster --region ap-northeast-1 > /dev/null 2>&1
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' | sort -u

echo "=== 4-2-A ==="

for n in o11y-app-alb o11y-grafana-alb; do
  aws elbv2 describe-load-balancers --names $n --query 'LoadBalancers[0].[State.Code, Type, Scheme]' --output text --region ap-northeast-1
done

for n in o11y-app-tg o11y-grafana-tg; do
  aws elbv2 describe-target-health --target-group-arn "$(aws elbv2 describe-target-groups --names $n --query 'TargetGroups[0].TargetGroupArn' --output text --region ap-northeast-1)" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text --region ap-northeast-1
done

echo "=== 4-3-A ==="
kubectl get deploy log-generator -n o11y -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas'
kubectl get ds o11y-otel -n monitoring -o custom-columns='NAME:.metadata.name,DESIRED:.status.desiredNumberScheduled,READY:.status.numberReady'
kubectl get svc o11y-loki -n monitoring -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,PORT:.spec.ports[0].port' 
kubectl get deploy o11y-grafana -n monitoring -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas' 

echo "=== 4-4-A ==="
ALB=$(aws elbv2 describe-load-balancers --names o11y-app-alb --query 'LoadBalancers[0].DNSName' --output text --region ap-northeast-1)
curl -s "http://$ALB/healthz"; echo
curl -s "http://$ALB/log?level=error&count=3" | head -1 | jq -r '.level, .generated'

echo "=== 4-5-A ==="
echo "manual marking"
# * mark4.sh의 하단에 해당 스크립트가 주석 처리되어 있으므로, 해당 스크립트를 사용할 수 있음에 유의합니다.
# RESP=$(curl -s "http://$(aws elbv2 describe-load-balancers --names o11y-app-alb --query 'LoadBalancers[0].DNSName' --output text --region ap-northeast-1)/log?level=error&count=3")
# kubectl port-forward -n monitoring svc/o11y-loki 3100:3100 > /dev/null 2>&1 &
# PF=$!
# sleep 2

# * 아래 명령어를 통해 로그가 정상적으로 조회되는지 확인합니다. 선수는 1분간 원하는 만큼 해당 명령어를 원하는 만큼 실행할 수 있습니다.
# curl -s -G http://localhost:3100/loki/api/v1/query_range --data-urlencode 'query={k8s_namespace_name="o11y"} | json | level="ERROR"' --data-urlencode "start=$(date -d '3 minutes ago' +%s)000000000" --data-urlencode "end=$(date +%s)000000000" --data-urlencode 'limit=20' | jq -r '.data.result[].values[][1]'

# * 이후, 아래 명령어를 통해 포트포워딩 중인 프로세스를 종료합니다.
# kill $PF 2>/dev/null


echo "=== 4-6-A ==="
echo 'manual marking'