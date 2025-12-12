#!/bin/bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <bucket-name> [region]"
  echo "Creates an S3 bucket configured for Pulumi state storage"
  exit 1
fi

BUCKET_NAME="$1"
REGION="${2:-$(aws configure get region || echo "eu-central-1")}"

echo "Creating S3 bucket: $BUCKET_NAME in region: $REGION"

# Create bucket (handle us-east-1 which doesn't use LocationConstraint)
if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION"
else
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi

echo "Enabling versioning..."
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

echo "Blocking public access..."
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "Enabling server-side encryption..."
aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo "Generating Pulumi config passphrase..."
PASSPHRASE=$(openssl rand -base64 32)
PARAM_NAME="/pulumi/${BUCKET_NAME}/config-passphrase"

aws ssm put-parameter \
  --name "$PARAM_NAME" \
  --type SecureString \
  --value "$PASSPHRASE" \
  --description "Pulumi config passphrase for $BUCKET_NAME" \
  --overwrite

echo ""
echo "Bucket $BUCKET_NAME created successfully!"
echo "Passphrase stored in SSM: $PARAM_NAME"
echo ""
echo "To use with Pulumi:"
echo "  export PULUMI_CONFIG_PASSPHRASE=\$(aws ssm get-parameter --name $PARAM_NAME --with-decryption --query Parameter.Value --output text)"
echo "  pulumi login s3://$BUCKET_NAME"
