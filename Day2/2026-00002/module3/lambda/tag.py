import json
import os
from datetime import datetime, timezone

import boto3

sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def handler(event, context):
    print(json.dumps(event))

    message = {
        "event": "TAG_NON_COMPLIANT",
        "timestamp": now(),
        "detail": "Required tag compliance violation detected",
        "action": "ALERT_ONLY",
    }
    sns.publish(TopicArn=SNS_TOPIC_ARN, Subject="Tag compliance alert", Message=json.dumps(message))
    print(json.dumps({"sns_publish": True, "message": message}))
    return {"statusCode": 200, "body": "alerted"}
