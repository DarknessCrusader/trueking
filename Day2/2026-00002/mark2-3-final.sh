#!/bin/bash
SCRIPT_START=$(date +%s)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws configure set region eu-west-1

INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=wsc2026-event-ec2" "Name=instance-state-name,Values=running,stopped" --query "Reservations[0].Instances[0].InstanceId" --output text)
VPC_ID=$(aws ec2 describe-vpcs --filter "Name=tag:Name,Values=event-vpc" --query "Vpcs[0].VpcId" --output text)
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=wsc2026-event-sg" "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[0].GroupId" --output text)
SNS_ARN="arn:aws:sns:eu-west-1:${ACCOUNT_ID}:wsc2026-event-alert"

echo ====================
echo "  3-1 Lambda, Cloudtrail, S3"
echo ====================
for fn in wsc2026-sg-remediation wsc2026-role-remediation wsc2026-termination-protection-remediation wsc2026-ec2-type-remediation; do aws lambda get-function-configuration --function-name $fn --query "[FunctionName,Runtime,Handler,Role]" --output text; done | column -t; aws cloudtrail describe-trails --trail-name-list wsc2026-event-trail --query "trailList[0].[Name]" --output text && aws cloudtrail get-trail-status --name wsc2026-event-trail --query "IsLogging" --output text; for b in $(aws s3api list-buckets --query "Buckets[*].Name" --output text); do loc=$(aws s3api get-bucket-location --bucket "$b" --query "LocationConstraint" --output text); if [ "$loc" = "eu-west-1" ]; then echo "$b"; break; fi; done

echo ====================
echo "  3-2 CloudTrail + EventBridge Rules"
echo ====================
for rule in wsc2026-sg-change-rule wsc2026-role-change-rule wsc2026-termination-protection-change-rule wsc2026-ec2-type-change-rule; do name_state=$(aws events describe-rule --name $rule --query "[Name,State]" --output text); target=$(aws events list-targets-by-rule --rule $rule --query "Targets[0].Arn" --output text | awk -F: '{print $NF}'); echo -e "$name_state\t$target"; done | column -t

echo ====================
echo "  3-3 Configure EC2"
echo ====================
SG_BACKUP_DIR="tmp/wsc2026-event-sg-$SG_ID" && mkdir -p "$SG_BACKUP_DIR" && aws ec2 describe-security-groups --group-ids "$SG_ID" --query "SecurityGroups[0].IpPermissions" --output json > "$SG_BACKUP_DIR/ingress.json" && aws ec2 describe-security-groups --group-ids "$SG_ID" --query "SecurityGroups[0].IpPermissionsEgress" --output json > "$SG_BACKUP_DIR/egress.json" && EC2_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=wsc2026-event-ec2" "Name=instance-state-name,Values=running" --query "Reservations[*].Instances[*].PublicIpAddress" --output text) && curl -s http://${EC2_IP} && aws ec2 describe-security-groups --group-ids $SG_ID --query "SecurityGroups[0].IpPermissions[*].[IpProtocol, FromPort, ToPort, IpRanges[0].CidrIp]" --output text | grep -q "^tcp\s*80\s*80\s*0\.0\.0\.0/0$" && echo "PASS" || echo "FAIL"; [ "$(aws ec2 describe-instance-attribute --instance-id $INSTANCE_ID --attribute userData --query "UserData.Value" --output text | tr -d '\r\n')" = "IyEvYmluL2Jhc2gKZG5mIHVwZGF0ZQpkbmYgaW5zdGFsbCBodHRwZCAteQpzeXN0ZW1jdGwgZW5hYmxlIC0tbm93IGh0dHBkCmhvc3RuYW1lID4gL3Zhci93d3cvaHRtbC9pbmRleC5odG1s" ] && echo "PASS" || echo "FAIL"; aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].IamInstanceProfile.Arn" --output text | awk -F'/' '{print $NF}'

echo ====================
echo "  3-4 EventBridge Rule + Lambda Check"
echo ====================
SECTION_34_START=$(date +%s)
SECTION_34_DEADLINE=$((SECTION_34_START + 180))
echo "Add All Traffic Rule to Security Group"
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol -1 --cidr 0.0.0.0/0 >/dev/null 2>&1
sleep 2

echo "Change EC2 Instance Profile to AdminAccessRole"
aws iam create-instance-profile --instance-profile-name AdminAccessRole >/dev/null 2>&1
aws iam add-role-to-instance-profile --instance-profile-name AdminAccessRole --role-name AdminAccessRole >/dev/null 2>&1
ASSOC_ID=$(aws ec2 describe-iam-instance-profile-associations --filters "Name=instance-id,Values=$INSTANCE_ID" "Name=state,Values=associated" --query "IamInstanceProfileAssociations[0].AssociationId" --output text)
if [ "$ASSOC_ID" != "None" ] && [ -n "$ASSOC_ID" ]; then
  aws ec2 replace-iam-instance-profile-association --association-id "$ASSOC_ID" --iam-instance-profile Name=AdminAccessRole >/dev/null 2>&1
else
  aws ec2 associate-iam-instance-profile --instance-id "$INSTANCE_ID" --iam-instance-profile Name=AdminAccessRole >/dev/null 2>&1
fi

echo "Disable EC2 Termination Protection"
aws ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" --no-disable-api-termination >/dev/null 2>&1
sleep 2

echo "Change EC2 Instance Type to t3.large"
aws ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
aws ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" --instance-type '{"Value":"t3.large"}' >/dev/null 2>&1
aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1

# Type remediation is the only operation that stops/starts the instance.
type_pass=0
c=0
while [ $c -lt 30 ] && [ "$(date +%s)" -lt "$SECTION_34_DEADLINE" ]; do
  if [ "$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].InstanceType" --output text)" = "t3.micro" ]; then
    type_pass=1
    break
  fi
  sleep 2
  c=$((c+1))
done

# Final validation after all events have had a chance to settle.
sg_pass=0; role_pass=0; term_pass=0
while [ "$(date +%s)" -lt "$SECTION_34_DEADLINE" ]; do
  [ "$(aws ec2 describe-security-groups --group-ids "$SG_ID" --query "SecurityGroups[0].IpPermissions[*].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp]" --output text | grep -cE "^-1[[:space:]]+None[[:space:]]+None[[:space:]]+0.0.0.0/0$|^tcp[[:space:]]+80[[:space:]]+80[[:space:]]+0.0.0.0/0$")" -eq 1 ] && sg_pass=1
  [ "$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].IamInstanceProfile.Arn" --output text | awk -F/ '{print $NF}')" = "wsc2026-event-ec2-role" ] && role_pass=1
  [ "$(aws ec2 describe-instance-attribute --instance-id "$INSTANCE_ID" --attribute disableApiTermination --query "DisableApiTermination.Value" --output text)" = "True" ] && term_pass=1
  [ "$sg_pass" -eq 1 ] && [ "$role_pass" -eq 1 ] && [ "$term_pass" -eq 1 ] && break
  sleep 2
done
{
  [ "$type_pass" -eq 1 ] && echo "Type remediation PASS" || echo "Type remediation FAIL"
  [ "$sg_pass" -eq 1 ] && echo "SG remediation PASS" || echo "SG remediation FAIL"
  [ "$role_pass" -eq 1 ] && echo "Role remediation PASS" || echo "Role remediation FAIL"
  [ "$term_pass" -eq 1 ] && echo "Termination remediation PASS" || echo "Termination remediation FAIL"
} | column -t
SECTION_34_ELAPSED=$(( $(date +%s) - SECTION_34_START ))
echo "[3-4 elapsed] ${SECTION_34_ELAPSED}s ($((SECTION_34_ELAPSED / 60))m $((SECTION_34_ELAPSED % 60))s)"
echo ""

echo ====================
echo "  3-5 SNS Notification Check"
echo ====================
aws sns get-topic-attributes --topic-arn "$SNS_ARN" --query "Attributes.TopicArn" --output text
echo "Check SNS Publish Logs"
LOG_START_MS=$((SECTION_34_START * 1000))
{
  for fn in wsc2026-sg-remediation wsc2026-role-remediation wsc2026-termination-protection-remediation wsc2026-ec2-type-remediation; do
    log_result=FAIL
    for attempt in $(seq 1 10); do
      if aws logs filter-log-events --log-group-name "/aws/lambda/$fn" --start-time "$LOG_START_MS" --filter-pattern '"sns_publish"' --region eu-west-1 --query 'events[*].message' --output text 2>/dev/null | grep -q 'sns_publish'; then
        log_result=PASS
        break
      fi
      sleep 2
    done
    echo "$fn $log_result"
  done
} | column -t

# Rollback Security Group
CURRENT_INGRESS="$SG_BACKUP_DIR/current-ingress.json"
aws ec2 describe-security-groups --group-ids "$SG_ID" --query "SecurityGroups[0].IpPermissions" --output json > "$CURRENT_INGRESS"
if [ "$(cat "$CURRENT_INGRESS")" != "[]" ]; then
  aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --ip-permissions "file://$CURRENT_INGRESS" >/dev/null 2>&1 || true
fi
if [ "$(cat "$SG_BACKUP_DIR/ingress.json")" != "[]" ]; then
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions "file://$SG_BACKUP_DIR/ingress.json" >/dev/null 2>&1 || true
fi
CURRENT_EGRESS="$SG_BACKUP_DIR/current-egress.json"
aws ec2 describe-security-groups --group-ids "$SG_ID" --query "SecurityGroups[0].IpPermissionsEgress" --output json > "$CURRENT_EGRESS"
if [ "$(cat "$CURRENT_EGRESS")" != "[]" ]; then
  aws ec2 revoke-security-group-egress --group-id "$SG_ID" --ip-permissions "file://$CURRENT_EGRESS" >/dev/null 2>&1 || true
fi
if [ "$(cat "$SG_BACKUP_DIR/egress.json")" != "[]" ]; then
  aws ec2 authorize-security-group-egress --group-id "$SG_ID" --ip-permissions "file://$SG_BACKUP_DIR/egress.json" >/dev/null 2>&1 || true
fi
SCRIPT_ELAPSED=$(( $(date +%s) - SCRIPT_START ))
echo "[total elapsed] ${SCRIPT_ELAPSED}s ($((SCRIPT_ELAPSED / 60))m $((SCRIPT_ELAPSED % 60))s)"

echo =====================
echo "추가과제 채점"
echo =====================
TOPIC_ARN=$(aws sns list-topics --query "Topics[?contains(TopicArn,'wsc2026-event-alert')].TopicArn | [0]" --output text 2>/dev/null)
echo -n "  [추가] CloudTrail Log File Validation (expect True): "; aws cloudtrail describe-trails --trail-name-list wsc2026-event-trail --query "trailList[0].LogFileValidationEnabled" --output text 2>/dev/null
echo -n "  [추가] SNS KMS Key (expect key id): "; aws sns get-topic-attributes --topic-arn "$TOPIC_ARN" --query "Attributes.KmsMasterKeyId" --output text 2>/dev/null
