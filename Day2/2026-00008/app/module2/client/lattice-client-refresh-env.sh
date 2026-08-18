#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
SERVICE_NAME="${SERVICE_NAME:-skills-lattice-order-service}"
CLIENT_PORT="${CLIENT_PORT:-80}"
SERVICE_TIMEOUT="${SERVICE_TIMEOUT:-3}"
SERVICE_URL="${SERVICE_URL:-}"

if [ -z "$SERVICE_URL" ]; then
  for _ in $(seq 1 60); do
    SERVICE_DOMAIN=$(aws vpc-lattice list-services \
      --region "$AWS_REGION" \
      --query "items[?name=='${SERVICE_NAME}'].dnsEntry.domainName | [0]" \
      --output text 2>/dev/null || true)

    if [ -n "$SERVICE_DOMAIN" ] && [ "$SERVICE_DOMAIN" != "None" ]; then
      SERVICE_URL="http://${SERVICE_DOMAIN}"
      break
    fi

    sleep 10
  done
fi

cat > /etc/skills-lattice-client.env <<EOF
SERVICE_URL=${SERVICE_URL}
CLIENT_PORT=${CLIENT_PORT}
SERVICE_TIMEOUT=${SERVICE_TIMEOUT}
EOF
chmod 0644 /etc/skills-lattice-client.env

if [ -z "$SERVICE_URL" ]; then
  echo "VPC Lattice Service domain not found for ${SERVICE_NAME}" >&2
  exit 1
fi
