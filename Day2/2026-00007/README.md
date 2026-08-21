# Task 2026-00007
1과제, 2과제

<!-- * mark4.sh의 하단에 해당 스크립트가 주석 처리되어 있으므로, 해당 스크립트를 사용할 수 있음에 유의합니다. -->
RESP=$(curl -s "http://$(aws elbv2 describe-load-balancers --names o11y-app-alb --query 'LoadBalancers[0].DNSName' --output text --region ap-northeast-1)/log?level=error count=3")
kubectl port-forward -n monitoring svc/o11y-loki 3100:3100 > /dev/null 2>&1 &
PF=$!
sleep 2

<!-- * 아래 명령어를 통해 로그가 정상적으로 조회되는지 확인합니다. 선수는 1분간 원하는 만큼 해당 명령어를 원하는 만큼 실행할 수 있습니다. -->
curl -s -G http://localhost:3100/loki/api/v1/query_range --data-urlencode 'query={k8s_namespace_name="o11y"} | json | level="ERROR"' --data-urlencode "start=$(date -d '3 minutes ago' +%s)000000000" --data-urlencode "end=$(date +%s)000000000" --data-urlencode 'limit=20' | jq -r '.data.result[].values[][1]'

<!-- # * 이후, 아래 명령어를 통해 포트포워딩 중인 프로세스를 종료합니다. -->
kill $PF 2>/dev/null

