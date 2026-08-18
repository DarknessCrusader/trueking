#!/bin/bash
set -ex
exec > /var/log/skills-setup.log 2>&1

REGION="${region}"
S3_BUCKET="${s3_bucket}"
APP_DIR=/opt/skills-nosql
VENV=$APP_DIR/.venv

dnf install -y python3 python3-pip || yum install -y python3 python3-pip

mkdir -p "$APP_DIR"
cd "$APP_DIR"

# 앱 파일을 S3에서 다운로드 (외부 GitHub 의존 제거)
for f in docdb_client.py retail_dataset.json requirements.txt run_app.sh run_seed.sh run_validate.sh; do
  aws s3 cp "s3://$S3_BUCKET/app/module1/$f" "$APP_DIR/$f" --region "$REGION"
done
chmod +x "$APP_DIR"/*.sh "$APP_DIR/docdb_client.py"

python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip
"$VENV/bin/python" -m pip install -r "$APP_DIR/requirements.txt"

# DocumentDB TLS CA 번들
curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o "$APP_DIR/global-bundle.pem"

# Client App을 systemd 서비스로 상시 실행 (:8080)
cat > /etc/systemd/system/skills-nosql.service <<UNIT
[Unit]
Description=Skills NoSQL Client App
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$VENV/bin/python $APP_DIR/docdb_client.py serve
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now skills-nosql.service

# 앱 기동 대기
for i in $(seq 1 60); do
  curl -fs http://127.0.0.1:8080/health >/dev/null 2>&1 && break
  sleep 10
done

# 데이터 적재 (DocumentDB 준비될 때까지 재시도)
for i in $(seq 1 30); do
  curl -fs -X POST http://127.0.0.1:8080/v1/admin/seed >/dev/null 2>&1 && break
  sleep 10
done

# Index + TTL Index 생성 (run_seed.sh는 데이터만 적재하므로 직접 구성)
"$VENV/bin/python" - <<'PY'
from docdb_client import db
from pymongo import ASCENDING, DESCENDING
d = db()
d.orders.create_index([('orderId', ASCENDING)], unique=True, name='orderId_1')
d.orders.create_index([('customerId', ASCENDING), ('createdAt', DESCENDING)], name='customerId_1_createdAt_-1')
d.orders.create_index([('status', ASCENDING), ('dueAt', ASCENDING)], name='status_1_dueAt_1')
d.products.create_index([('productId', ASCENDING)], unique=True, name='productId_1')
d.products.create_index([('warehouseId', ASCENDING), ('stock', ASCENDING)], name='warehouseId_1_stock_1')
d.sessions.create_index([('sessionId', ASCENDING)], unique=True, name='sessionId_1')
d.sessions.create_index([('expiresAt', ASCENDING)], expireAfterSeconds=0, name='expiresAt_1')
d.sessions.create_index([('customerId', ASCENDING), ('lastSeen', DESCENDING)], name='customerId_1_lastSeen_-1')
print("indexes done")
PY

# 완료 마커 (terraform이 폴링)
echo done | aws s3 cp - "s3://$S3_BUCKET/done/module1" --region "$REGION"
