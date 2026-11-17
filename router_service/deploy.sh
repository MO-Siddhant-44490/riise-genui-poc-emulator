#!/bin/bash
# Deploys / updates the GenUI router service as a Lambda with a public Function URL.
# Usage: AWS_PROFILE=dev bash deploy.sh [function-name]
# Writes the URL and the shared app token to $OUT (default: scratchpad-like ./.deploy, git-ignored).
# Nothing here touches the Flutter repo. Re-running updates code and config in place.
set -euo pipefail
NAME=${1:-genui-router-poc}; REGION=${GENUI_REGION:-ap-south-1}; MODEL=${GENUI_MODEL:-qwen.qwen3-32b-v1:0}
OUT=${OUT:-$(dirname "$0")/.deploy}; mkdir -p "$OUT"; cd "$(dirname "$0")"
ACCT=$(aws sts get-caller-identity --query Account --output text)
ROLE="$NAME-role"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  aws iam put-role-policy --role-name "$ROLE" --policy-name bedrock-converse --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"bedrock:InvokeModel\",\"bedrock:Converse\"],\"Resource\":\"arn:aws:bedrock:$REGION::foundation-model/*\"}]}"
  echo "created role $ROLE; waiting for IAM propagation"; sleep 12
fi
TOKEN_FILE="$OUT/app_token.txt"; [ -s "$TOKEN_FILE" ] || openssl rand -hex 24 > "$TOKEN_FILE"
TOKEN=$(cat "$TOKEN_FILE")
rm -f "$OUT/fn.zip"; zip -q -j "$OUT/fn.zip" handler.py
ENV="Variables={GENUI_REGION=$REGION,GENUI_MODEL=$MODEL,GENUI_ALLOWED_MODELS=$MODEL,GENUI_TOKEN=$TOKEN}"
if aws lambda get-function --function-name "$NAME" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$NAME" --region "$REGION" --zip-file "fileb://$OUT/fn.zip" >/dev/null
  aws lambda wait function-updated --function-name "$NAME" --region "$REGION"
  aws lambda update-function-configuration --function-name "$NAME" --region "$REGION" --environment "$ENV" >/dev/null
else
  aws lambda create-function --function-name "$NAME" --region "$REGION" --runtime python3.12 --handler handler.handler \
    --role "arn:aws:iam::$ACCT:role/$ROLE" --zip-file "fileb://$OUT/fn.zip" --timeout 30 --memory-size 256 --environment "$ENV" \
    --description "GenUI POC router: forwards one routing prompt to Bedrock with the execution role" >/dev/null
  aws lambda wait function-active --function-name "$NAME" --region "$REGION"
  aws lambda put-function-concurrency --function-name "$NAME" --region "$REGION" --reserved-concurrent-executions 5 >/dev/null
fi
URL=$(aws lambda get-function-url-config --function-name "$NAME" --region "$REGION" --query FunctionUrl --output text 2>/dev/null || true)
if [ -z "$URL" ]; then
  URL=$(aws lambda create-function-url-config --function-name "$NAME" --region "$REGION" --auth-type NONE --query FunctionUrl --output text)
  aws lambda add-permission --function-name "$NAME" --region "$REGION" --statement-id public-url --action lambda:InvokeFunctionUrl --principal '*' --function-url-auth-type NONE >/dev/null
fi
echo "$URL" > "$OUT/url.txt"
echo "service: $URL"; echo "token:   $TOKEN_FILE (pass as --dart-define GENUI_AI_TOKEN)"
curl -s -X POST "$URL" -H "x-genui-token: $TOKEN" -H 'content-type: application/json' -d '{"message":"ping","system":"Reply with the single word pong."}' | head -c 300; echo
