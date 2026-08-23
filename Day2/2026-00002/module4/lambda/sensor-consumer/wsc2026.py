import base64
import json
import os
from datetime import datetime, timezone, timedelta

import boto3
from kafka import KafkaProducer
from kafka.sasl.oauth import AbstractTokenProvider
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider


dynamodb = boto3.resource("dynamodb", region_name="ap-northeast-1")
table = dynamodb.Table("wsc2026-sensor-data")
AWS_REGION = "ap-northeast-1"
BOOTSTRAP_SERVERS = os.environ["BOOTSTRAP_SERVERS"].split(",")
ALERT_TOPIC = "wsc2026-sensor-alert"

KST = timezone(timedelta(hours=9))


class MSKTokenProvider(AbstractTokenProvider):
    def token(self):
        token, _ = MSKAuthTokenProvider.generate_auth_token(AWS_REGION)
        return token


producer = KafkaProducer(
    bootstrap_servers=BOOTSTRAP_SERVERS,
    security_protocol="SASL_SSL",
    sasl_mechanism="OAUTHBEARER",
    sasl_oauth_token_provider=MSKTokenProvider(),
    key_serializer=lambda value: value.encode("utf-8"),
    value_serializer=lambda value: json.dumps(value).encode("utf-8"),
)


def to_kst(ts_str):
    """Convert UTC timestamp to KST ISO8601 format."""
    try:
        if ts_str.endswith("Z"):
            dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        else:
            dt = datetime.fromisoformat(ts_str)
        return dt.astimezone(KST).isoformat()
    except (ValueError, AttributeError):
        return ts_str


def decode_record(record):
    value = record.get("value", "")
    return json.loads(base64.b64decode(value).decode("utf-8"))


def is_alert(data):
    temperature = float(data["temperature"])
    humidity = float(data["humidity"])
    reasons = []

    if temperature > 80:
        reasons.append(f"temperature exceeded threshold: {temperature}")
    if temperature < 10:
        reasons.append(f"temperature below threshold: {temperature}")
    if humidity > 90:
        reasons.append(f"humidity exceeded threshold: {humidity}")
    if humidity < 20:
        reasons.append(f"humidity below threshold: {humidity}")

    return reasons


def consumer_handler(event, context):
    for records in event.get("records", {}).values():
        for record in records:
            data = decode_record(record)
            reasons = is_alert(data)
            data["status"] = "ALERT" if reasons else "NORMAL"

            if reasons:
                data["alert_reason"] = "; ".join(reasons)
                producer.send(ALERT_TOPIC, key=data["sensorId"], value=data).get(timeout=10)

            # Convert timestamp to KST, float to string
            item = {}
            for key, value in data.items():
                if key == "timestamp":
                    item[key] = to_kst(str(value))
                elif isinstance(value, float):
                    item[key] = str(value)
                else:
                    item[key] = value

            table.put_item(Item=item)

    producer.flush()
    return {"statusCode": 200, "body": "processed"}
