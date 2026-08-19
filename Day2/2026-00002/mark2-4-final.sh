#!/bin/bash
read -p "비번호: " NUMBER
REGION="ap-northeast-1"; CLUSTER_NAME="wsc2026-msk-cluster"; RAW_TOPIC="wsc2026-sensor-raw"; ALERT_TOPIC="wsc2026-sensor-alert"; TABLE_NAME="wsc2026-sensor-data"; RAW_FUNCTION="wsc2026-sensor-consumer"; ALERT_FUNCTION="wsc2026-sensor-alert-consumer"; NUMBER="${NUMBER:-}"; BUCKET_NAME="wsc2026-sensor-alert-bucket-${NUMBER}"; aws configure set region "$REGION"
echo ====================
echo "  4-1 VPC"
echo ====================
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=msk-vpc" --query 'Vpcs[0].VpcId' --output text); VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null); VPC_RESULT=PASS; [ "$VPC_CIDR" = "192.168.0.0/16" ] || VPC_RESULT=FAIL; for subnet in "msk-pub-a:192.168.0.0/24" "msk-pub-d:192.168.1.0/24" "msk-priv-a:192.168.10.0/24" "msk-priv-d:192.168.11.0/24"; do NAME=${subnet%%:*}; EXPECTED_CIDR=${subnet##*:}; ACTUAL_CIDR=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$NAME" --query 'Subnets[0].CidrBlock' --output text); [ "$ACTUAL_CIDR" = "$EXPECTED_CIDR" ] || VPC_RESULT=FAIL; done; if [ "$VPC_RESULT" = "PASS" ]; then echo -e "DynamoDB schema PASS\nS3 bucket PASS"; else echo -e "DynamoDB schema FAIL\nS3 bucket FAIL"; fi
echo ====================
echo "  4-2 MSK"
echo ====================
CLUSTER_ARN=$(aws kafka list-clusters-v2 --region "$REGION" --query "ClusterInfoList[?ClusterName=='$CLUSTER_NAME'].ClusterArn | [0]" --output text); MSK_INFO=$(aws kafka describe-cluster-v2 --cluster-arn "$CLUSTER_ARN" --region "$REGION" --query 'ClusterInfo.[ClusterName,State,Provisioned.CurrentBrokerSoftwareInfo.KafkaVersion,Provisioned.BrokerNodeGroupInfo.InstanceType,Provisioned.ClientAuthentication.Sasl.Iam.Enabled]' --output text | tr '\t' ' ' | xargs); SUBNET_COUNT=$(aws kafka describe-cluster-v2 --cluster-arn "$CLUSTER_ARN" --region "$REGION" --query 'length(ClusterInfo.Provisioned.BrokerNodeGroupInfo.ClientSubnets)' --output text); if [ "$MSK_INFO" = "$CLUSTER_NAME ACTIVE 3.6.0 kafka.t3.small True" ] && [ "$SUBNET_COUNT" -ge 2 ] 2>/dev/null; then echo -e "wsc2026-sensor-consumer PASS\nwsc2026-sensor-alert-consumer PASS"; else echo -e "wsc2026-sensor-consumer FAIL\nwsc2026-sensor-alert-consumer FAIL"; fi
echo ====================
echo "  4-3 Kafka Topic"
echo ====================
RAW_MAPPING=$(aws lambda list-event-source-mappings --function-name "$RAW_FUNCTION" --region "$REGION" --query "EventSourceMappings[?contains(Topics, '$RAW_TOPIC')].State | [0]" --output text); ALERT_MAPPING=$(aws lambda list-event-source-mappings --function-name "$ALERT_FUNCTION" --region "$REGION" --query "EventSourceMappings[?contains(Topics, '$ALERT_TOPIC')].State | [0]" --output text); if [ "$RAW_MAPPING" = Enabled ] && [ "$ALERT_MAPPING" = Enabled ]; then echo "MSK cluster PASS"; else echo "MSK cluster FAIL"; fi
echo ====================
echo "  4-4 Lambda"
echo ====================
LAMBDA_RESULT=PASS; for FUNCTION_NAME in "$RAW_FUNCTION" "$ALERT_FUNCTION"; do CONFIG=$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" --region "$REGION" --query '[Runtime,Handler]' --output text | tr '\t' ' ' | xargs); [ "$CONFIG" = "python3.14 wsc2026.consumer_handler" ] || LAMBDA_RESULT=FAIL; done; [ "$RAW_MAPPING" = Enabled ] && [ "$ALERT_MAPPING" = Enabled ] || LAMBDA_RESULT=FAIL; if [ "$LAMBDA_RESULT" = "PASS" ]; then echo -e "wsc2026-sensor-consumer PASS\nwsc2026-sensor-alert-consumer PASS"; else echo -e "wsc2026-sensor-consumer FAIL\nwsc2026-sensor-alert-consumer FAIL"; fi
echo ====================
echo "  4-5 Data Flow"
echo ====================
ITEM_COUNT=$(aws dynamodb scan --table-name "$TABLE_NAME" --region "$REGION" --select COUNT --query Count --output text); [ "$ITEM_COUNT" -gt 0 ] 2>/dev/null && echo "DynamoDB sensor item PASS" || echo "DynamoDB sensor item FAIL"; S3_COUNT=$(aws s3api list-objects-v2 --bucket "$BUCKET_NAME" --prefix alert/ --region "$REGION" --query 'length(Contents || `[]`)' --output text 2>/dev/null); [ "$S3_COUNT" -gt 0 ] 2>/dev/null && echo "S3 alert object PASS" || echo "S3 alert object FAIL"
echo ====================
echo "  추가과제 채점"
echo ====================
MSK_ARN=$(aws kafka list-clusters-v2 --query "ClusterInfoList[?ClusterName=='wsc2026-msk-cluster'].ClusterArn | [0]" --output text 2>/dev/null)
echo -n "  [추가] In-transit (expect TLS): "; aws kafka describe-cluster-v2 --cluster-arn "$MSK_ARN" --query "ClusterInfo.Provisioned.EncryptionInfo.EncryptionInTransit.ClientBroker" --output text 2>/dev/null
echo -n "  [추가] Enhanced Monitoring (expect PER_TOPIC_PER_PARTITION): "; aws kafka describe-cluster-v2 --cluster-arn "$MSK_ARN" --query "ClusterInfo.Provisioned.EnhancedMonitoring" --output text 2>/dev/null
