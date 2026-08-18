#!/usr/bin/env bash
set -euo pipefail

APP_DIR=/opt/skills-nosql
VENV_DIR=${APP_DIR}/.venv

mkdir -p "$APP_DIR"
cp docdb_client.py retail_dataset.json requirements.txt run_app.sh run_seed.sh run_validate.sh "$APP_DIR"/
chmod +x "$APP_DIR/docdb_client.py" "$APP_DIR/run_app.sh" "$APP_DIR/run_seed.sh" "$APP_DIR/run_validate.sh"

python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install -r "$APP_DIR/requirements.txt"

curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o "$APP_DIR/global-bundle.pem"

cat <<EOF2
installed: ${APP_DIR}
python: ${VENV_DIR}/bin/python
run app: ${APP_DIR}/run_app.sh
seed data: ${APP_DIR}/run_seed.sh
validate: ${APP_DIR}/run_validate.sh
EOF2
