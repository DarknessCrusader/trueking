#!/bin/bash

echo "Module 1 - NoSQL"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
rm -rf ~/.aws
aws sts get-caller-identity | jq .Account
echo "채점준비 끝! 채점 시작!"

echo "\n=== 1-1-A ==="

aws dynamodb describe-table --table-name bigbae-nosql-reservation-table --region ap-southeast-1 | jq -r '.Table.TableName, (.Table.KeySchema[] | .KeyType + " " + .AttributeName), (.Table.AttributeDefinitions[] | .AttributeName + " " + .AttributeType), .Table.StreamSpecification.StreamViewType, .Table.BillingModeSummary.BillingMode'
aws dynamodb describe-continuous-backups --table-name bigbae-nosql-reservation-table --region ap-southeast-1 | jq -r .ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus

echo "\n=== 1-2-A ==="

aws dynamodb describe-table --table-name bigbae-nosql-reservation-table --region ap-southeast-1 | jq -r '.Table.GlobalSecondaryIndexes[] | .IndexName, (.KeySchema[] | .KeyType + " " + .AttributeName), .Projection.ProjectionType'
aws dynamodb describe-table --table-name bigbae-nosql-audit-table --region ap-southeast-1 | jq -r '.Table.TableName, (.Table.KeySchema[] | .KeyType + " " + .AttributeName)'

echo "\n=== 1-3-A ==="
aws lambda get-function --function-name bigbae-nosql-reservation-audit --region ap-southeast-1 | jq -r '.Configuration.FunctionName, .Configuration.Runtime, (.Configuration.Timeout | tostring)'
aws lambda list-event-source-mappings --function-name bigbae-nosql-reservation-audit --region ap-southeast-1 | jq -r '.EventSourceMappings[] | (.EventSourceArn | split("/")[1]), .State'

echo "\n=== 1-4-A ==="
EC2_IP=$(aws ec2 describe-instances --region ap-southeast-1 --filters "Name=tag:Name,Values=bigbae-nosql-app-ec2"  "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].PublicIpAddress" --output text)
echo "EC2 IP" ${EC2_IP}
curl -s --max-time 10 -o /dev/null -w "healthcheck %{http_code}\n" "http://${EC2_IP}:8080/healthcheck"

echo "\n=== 1-5-A ==="

I=$(aws ec2 describe-instances --region ap-southeast-1 --filters Name=tag:Name,Values=bigbae-nosql-app-ec2 Name=instance-state-name,Values=running --query Reservations[].Instances[].PublicIpAddress --output text)
T=train-$(date +%s) S=A1 U=user1 V=user2
R(){ curl -s -w" %{http_code}" -X POST http://$I:8080/$1 -H Content-Type:application/json -d "{\"train_id\":\"$T\",\"seat_id\":\"$S\",\"user_id\":\"$2\"}"; echo; }
R reserve $U; R reserve $V; R cancel $V; R cancel $U

echo "\n=== 1-6-A ==="
I=$(aws ec2 describe-instances --region ap-southeast-1 --filters Name=tag:Name,Values=bigbae-nosql-app-ec2 Name=instance-state-name,Values=running --query Reservations[].Instances[].PublicIpAddress --output text)
T=train-$(date +%s) S=B1 U=usr1
P(){ curl -s -X POST http://$I:8080/$1 -H Content-Type:application/json -d "{\"train_id\":\"$T\",\"seat_id\":\"$S\",\"user_id\":\"$U\"}" >/dev/null; }
A(){ aws dynamodb scan --table-name bigbae-nosql-audit-table --region ap-southeast-1|jq "[.Items[]|select(.train_id.S==\"$T\" and .seat_id.S==\"$S\")]|length"; }
P reserve
curl -s http://$I:8080/my-bookings/$U|jq "[.[]|select(.train_id==\"$T\" and .seat_id==\"$S\")]|length"
curl -s http://$I:8080/seats/$T|jq "[.[]|select(.seat_id==\"$S\")]|[.[0].status,.[0].user_id==\"$U\"]"
sleep 30;A
P cancel
curl -s http://$I:8080/my-bookings/$U|jq "[.[]|select(.train_id==\"$T\" and .seat_id==\"$S\")]|length"
sleep 30;A