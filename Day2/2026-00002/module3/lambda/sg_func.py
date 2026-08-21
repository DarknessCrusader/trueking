import json
import os
from datetime import datetime, timezone

import boto3

ec2 = boto3.client("ec2")
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
SECURITY_GROUP_ID = os.environ["SECURITY_GROUP_ID"]


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def handler(event, context):
    print(json.dumps(event))

    sg = ec2.describe_security_groups(GroupIds=[SECURITY_GROUP_ID])["SecurityGroups"][0]
    ip_permissions = sg.get("IpPermissions", [])

    if ip_permissions:
        ec2.revoke_security_group_ingress(GroupId=SECURITY_GROUP_ID, IpPermissions=ip_permissions)

    message = {
        "event": "SG_INBOUND_ADDED",
        "timestamp": now(),
        "detail": f"All ingress rules removed from {SECURITY_GROUP_ID}",
        "action": "RESTORED",
    }
    sns.publish(TopicArn=SNS_TOPIC_ARN, Subject="SG remediation", Message=json.dumps(message))
    print(json.dumps({"sns_publish": True, "message": message}))
    return {"statusCode": 200, "body": "completed"}
