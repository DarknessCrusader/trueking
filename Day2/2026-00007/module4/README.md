# Module 4
## bastion에서 setup.sh 실행해줘야함 ##
curl -s -G http://localhost:3100/loki/api/v1/query_range --data-urlencode 'query={k8s_namespace_name="o11y"} | json | level="ERROR"' --data-urlencode "start=$(date -d '3 minutes ago' +%s)000000000" --data-urlencode "end=$(date +%s)000000000" --data-urlencode 'limit=20' | jq -r '.data.result[].values[][1]'
제대로 된 4-5 명령어
