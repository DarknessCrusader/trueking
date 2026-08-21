import json
import os
from datetime import datetime, timezone

import boto3

ec2 = boto3.client("ec2")
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
INSTANCE_ID = os.environ["INSTANCE_ID"]
SECURITY_GROUP_ID = os.environ.get("SECURITY_GROUP_ID", "")


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def handler(event, context):
    print(json.dumps(event))

    state = event.get("detail", {}).get("state", "")

    if state == "stopped":
        # Restart the instance
        ec2.start_instances(InstanceIds=[INSTANCE_ID])

        # Remove all SG ingress rules
        if SECURITY_GROUP_ID:
            sg = ec2.describe_security_groups(GroupIds=[SECURITY_GROUP_ID])["SecurityGroups"][0]
            ip_permissions = sg.get("IpPermissions", [])
            if ip_permissions:
                ec2.revoke_security_group_ingress(GroupId=SECURITY_GROUP_ID, IpPermissions=ip_permissions)

        message = {
            "event": "EC2_STOPPED",
            "timestamp": now(),
            "detail": f"Instance {INSTANCE_ID} restarted, SG cleaned",
            "action": "RESTORED",
        }
    else:
        # terminated - alert only
        message = {
            "event": "EC2_TERMINATED",
            "timestamp": now(),
            "detail": f"EC2 instance {INSTANCE_ID} has been terminated",
            "action": "ALERT_ONLY",
        }

    sns.publish(TopicArn=SNS_TOPIC_ARN, Subject="EC2 state change alert", Message=json.dumps(message))
    print(json.dumps({"sns_publish": True, "message": message}))
    return {"statusCode": 200, "body": "completed"}
