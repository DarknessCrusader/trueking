#!/bin/bash

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "ACCOUNT ID: $ACCOUNT_ID"
aws configure set region ap-southeast-1

read -p "등번호: " NUM
BUCKET_NAME="wsc2026-student-score-bucket-${NUM}"

# 채점환경을 위해 업로드할 test.csv 파일 경로
# (스크립트와 같은 디렉토리에 test.csv를 두면 별도 수정 없이 동작합니다)
TEST_CSV_PATH="$(cd "$(dirname "$0")" && pwd)/test.csv"

# ============================================================
# 사전 준비: S3/DynamoDB 클렌징 확인 후 input/test.csv 업로드, 60초 대기
# (채점기준표 "1번 사전 준비" 절차)
# ============================================================
echo ====================
echo "  사전 준비: 클렌징 확인 및 test.csv 업로드"
echo ====================

# 폴더 마커(키가 '/'로 끝나는 0바이트 오브젝트)는 실제 데이터가 아니므로 카운트에서 제외
S3_OBJ_COUNT=$(aws s3api list-objects-v2 --bucket "$BUCKET_NAME" --query "length(Contents[?!ends_with(Key, '/')] || \`[]\`)" --output text 2>/dev/null)
DDB_ITEM_COUNT=$(aws dynamodb scan --table-name wsc2026-student-score --select COUNT --query "Count" --output text 2>/dev/null)

echo "S3 실데이터 오브젝트 수(폴더 마커 제외): ${S3_OBJ_COUNT:-N/A}"
echo "DynamoDB 아이템 수: ${DDB_ITEM_COUNT:-N/A}"

if [ "$S3_OBJ_COUNT" != "0" ] || [ "$DDB_ITEM_COUNT" != "0" ]; then
  echo "[경고] 클렌징이 완료되지 않았습니다 -> 1-1, 1-5, 1-6은 틀린 것으로 간주합니다."
else
  echo "클렌징 확인 완료."
  if [ ! -f "$TEST_CSV_PATH" ]; then
    echo "[오류] test.csv 파일을 찾을 수 없습니다: $TEST_CSV_PATH"
    echo "       스크립트와 같은 디렉토리에 test.csv를 두었는지 확인하세요."
  else
    if aws s3 cp "$TEST_CSV_PATH" "s3://$BUCKET_NAME/input/test.csv"; then
      echo "업로드 완료. 60초 대기합니다."
      sleep 60
    else
      echo "[오류] test.csv 업로드에 실패했습니다."
    fi
  fi
fi

# 1-1 S3 Bucket + Folder Structure
echo ====================
echo "  1-1 S3 Bucket + Folder Structure"
echo ====================
aws s3api head-bucket --bucket $BUCKET_NAME 2>&1 > /dev/null && aws s3 ls s3://$BUCKET_NAME/

# 1-2 DynamoDB Table + Key Schema
echo ====================
echo "  1-2 DynamoDB Table + Key Schema"
echo ====================
aws dynamodb describe-table --table-name wsc2026-student-score --query "Table.[TableName,KeySchema]" --output json

# 1-3 Lambda Function + Runtime + Env
echo ====================
echo "  1-3 Lambda Function + Runtime + Env"
echo ====================
aws lambda get-function-configuration --function-name wsc2026-student-score-function --query "[FunctionName,Runtime,Environment.Variables]" --output json

# 1-4 Step Functions State Machine
echo ====================
echo "  1-4 Step Functions State Machine"
echo ====================
SM_ARN=$(aws stepfunctions list-state-machines --query "stateMachines[?name=='wsc2026-student-score-workflow'].stateMachineArn" --output text)
aws stepfunctions describe-state-machine --state-machine-arn $SM_ARN --query "[name,type]" --output text

# 1-5 Workflow Result (Normal)
echo ====================
echo "  1-5 Workflow Result (Normal)"
echo ====================
aws dynamodb get-item --table-name wsc2026-student-score --key '{"studentId":{"S":"STU1020"},"examDate":{"S":"2026-05-30"}}' --query "Item.[studentId.S,average.N,grade.S]" --output text; aws s3 ls s3://$BUCKET_NAME/processed/

# 1-6 Workflow Result (Error)
echo ====================
echo "  1-6 Workflow Result (Error)"
echo ====================
aws s3 ls s3://$BUCKET_NAME/error/