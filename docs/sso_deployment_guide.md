# AWS SSO Cross-Account Deployment Guide using Cloud Formation

## 📋 Prerequisites

- ✅ AWS SSO configured with profiles:
  - `Development` profile for Account A (Development)
  - `Production` profile for Account B (Production)
- ✅ Admin permissions in both accounts
- ✅ AWS CLI configured with SSO
- ✅ An S3 bucket in Account B (Production)

## 🔍 Verify Your SSO Setup

```bash
# Check your SSO profiles
aws configure list-profiles

# Should show:
# Development
# Production

# Test Account A access
aws sts get-caller-identity --profile Development

# Test Account B access
aws sts get-caller-identity --profile Production
```

**Save the Account IDs from the output above!**
- Account A ID: (from Development)
- Account B ID: (from Production)

---

## 📦 Step 1: Deploy to Account B (Production)

This creates the role that Account A will assume to access S3.

### 1.1 Create Parameters File

Create `account-b-parameters.json`:

```json
[
  {
    "ParameterKey": "TrustedAccountId",
    "ParameterValue": "111111111111"
  },
  {
    "ParameterKey": "S3BucketName",
    "ParameterValue": "my-production-bucket"
  },
  {
    "ParameterKey": "RoleName",
    "ParameterValue": "CrossAccountS3Access"
  },
  {
    "ParameterKey": "ExternalId",
    "ParameterValue": "CrossAccountAccess-2024"
  },
  {
    "ParameterKey": "MaxSessionDuration",
    "ParameterValue": "3600"
  }
]
```

**Replace:**
- `111111111111` with your **Account A ID**
- `my-production-bucket` with your **actual S3 bucket name**

### 1.2 Deploy the Stack

```bash
aws cloudformation create-stack \
  --stack-name CrossAccountS3Access-AccountB \
  --template-body file://cloudformation/account-b-role.yaml \
  --parameters file://account-b-parameters.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --profile Production
```

### 1.3 Wait for Completion

```bash
# Monitor stack creation
aws cloudformation wait stack-create-complete \
  --stack-name CrossAccountS3Access-AccountB \
  --profile Production

# Check status
aws cloudformation describe-stacks \
  --stack-name CrossAccountS3Access-AccountB \
  --profile Production \
  --query 'Stacks[0].StackStatus'
```

### 1.4 Get the Role ARN

```bash
aws cloudformation describe-stacks \
  --stack-name CrossAccountS3Access-AccountB \
  --profile Production \
  --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' \
  --output text
```

**Save this ARN!** You'll need it for Account A.

Example: `arn:aws:iam::222222222222:role/CrossAccountS3Access`

---

## 📦 Step 2: Deploy to Account A (Development)

This creates the role that SSO users will use to assume the Account B role.

### 2.1 Create Parameters File

Create `account-a-parameters.json`:

```json
[
  {
    "ParameterKey": "AccountBRoleArn",
    "ParameterValue": "arn:aws:iam::222222222222:role/CrossAccountS3Access"
  },
  {
    "ParameterKey": "RoleName",
    "ParameterValue": "CrossAccountS3AccessAssumer"
  },
  {
    "ParameterKey": "UseSSO",
    "ParameterValue": "SSO"
  },
  {
    "ParameterKey": "AccountBAccountId",
    "ParameterValue": "222222222222"
  },
  {
    "ParameterKey": "TrustedPrincipals",
    "ParameterValue": "ec2.amazonaws.com"
  }
]
```

**Replace:**
- `arn:aws:iam::222222222222:role/CrossAccountS3Access` with the ARN from Step 1.4
- `222222222222` with your **Account B ID**

### 2.2 Deploy the Stack

```bash
aws cloudformation create-stack \
  --stack-name CrossAccountS3Access-AccountA \
  --template-body file://cloudformation/account-a-role.yaml \
  --parameters file://account-a-parameters.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --profile Development
```

### 2.3 Wait for Completion

```bash
# Monitor stack creation
aws cloudformation wait stack-create-complete \
  --stack-name CrossAccountS3Access-AccountA \
  --profile Development

# Check status
aws cloudformation describe-stacks \
  --stack-name CrossAccountS3Access-AccountA \
  --profile Development \
  --query 'Stacks[0].StackStatus'
```

---

## 🧪 Step 3: Test Cross-Account Access

### Option A: Using AWS CLI Directly

```bash
# 1. Get Account B role ARN
ACCOUNT_B_ROLE="arn:aws:iam::222222222222:role/CrossAccountS3Access"
EXTERNAL_ID="CrossAccountAccess-2024"

# 2. Assume the role
aws sts assume-role \
  --role-arn $ACCOUNT_B_ROLE \
  --role-session-name TestSession \
  --external-id $EXTERNAL_ID \
  --profile Development \
  --output json > /tmp/credentials.json

# 3. Export the temporary credentials
export AWS_ACCESS_KEY_ID=$(cat /tmp/credentials.json | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(cat /tmp/credentials.json | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(cat /tmp/credentials.json | jq -r '.Credentials.SessionToken')

# 4. Test S3 access
aws s3 ls s3://my-production-bucket/

# 5. Clean up credentials file
rm /tmp/credentials.json

# 6. Unset environment variables when done
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

### Option B: Using Helper Script

Create `test_cross_account.sh`:

```bash
#!/bin/bash

set -e

# Configuration
ACCOUNT_B_ROLE="arn:aws:iam::222222222222:role/CrossAccountS3Access"
EXTERNAL_ID="CrossAccountAccess-2024"
BUCKET_NAME="my-production-bucket"
PROFILE="Development"

echo "=========================================="
echo "Testing Cross-Account S3 Access"
echo "=========================================="
echo ""

# Assume role
echo "→ Assuming role in Account B..."
CREDENTIALS=$(aws sts assume-role \
  --role-arn "$ACCOUNT_B_ROLE" \
  --role-session-name TestSession \
  --external-id "$EXTERNAL_ID" \
  --profile "$PROFILE" \
  --output json)

if [ $? -ne 0 ]; then
  echo "✗ Failed to assume role!"
  exit 1
fi

echo "✓ Successfully assumed role!"

# Extract credentials
export AWS_ACCESS_KEY_ID=$(echo $CREDENTIALS | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $CREDENTIALS | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $CREDENTIALS | jq -r '.Credentials.SessionToken')

echo ""
echo "→ Testing S3 bucket access..."

# List bucket
aws s3 ls "s3://${BUCKET_NAME}/" 2>&1
if [ $? -eq 0 ]; then
  echo "✓ Successfully listed bucket contents!"
else
  echo "✗ Failed to access bucket!"
  exit 1
fi

echo ""
echo "→ Testing file upload..."

# Create test file
echo "Test file from cross-account access" > /tmp/test-cross-account.txt

# Upload
aws s3 cp /tmp/test-cross-account.txt "s3://${BUCKET_NAME}/test-cross-account.txt"
if [ $? -eq 0 ]; then
  echo "✓ Successfully uploaded test file!"
else
  echo "✗ Failed to upload file!"
  exit 1
fi

echo ""
echo "→ Testing file download..."

# Download
aws s3 cp "s3://${BUCKET_NAME}/test-cross-account.txt" /tmp/test-download.txt
if [ $? -eq 0 ]; then
  echo "✓ Successfully downloaded test file!"
  cat /tmp/test-download.txt
else
  echo "✗ Failed to download file!"
  exit 1
fi

echo ""
echo "→ Cleaning up test files..."

# Delete test file from S3
aws s3 rm "s3://${BUCKET_NAME}/test-cross-account.txt"
rm /tmp/test-cross-account.txt /tmp/test-download.txt

echo ""
echo "=========================================="
echo "✓ All tests passed!"
echo "=========================================="

# Clean up credentials
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

Make it executable and run:

```bash
chmod +x test_cross_account.sh
./test_cross_account.sh
```

---

## 📊 Step 4: Verify CloudTrail Logging

Check that cross-account access is being logged:

```bash
# In Account B, check CloudTrail for AssumeRole events
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
  --max-results 10 \
  --profile Production \
  --query 'Events[*].[CloudTrailEvent]' \
  --output text | jq .
```

You should see events showing Account A assuming the role.

---

## 🧹 Cleanup (When Done Testing)

### Delete Account A Stack

```bash
aws cloudformation delete-stack \
  --stack-name CrossAccountS3Access-AccountA \
  --profile Development

# Wait for deletion
aws cloudformation wait stack-delete-complete \
  --stack-name CrossAccountS3Access-AccountA \
  --profile Development
```

### Delete Account B Stack

```bash
aws cloudformation delete-stack \
  --stack-name CrossAccountS3Access-AccountB \
  --profile Production

# Wait for deletion
aws cloudformation wait stack-delete-complete \
  --stack-name CrossAccountS3Access-AccountB \
  --profile Production
```

---

## 🔧 Troubleshooting

### Issue: "Access Denied" when assuming role

**Check:**
1. Verify the External ID matches exactly: `CrossAccountAccess-2024`
2. Ensure the trust policy in Account B includes your Account A ID
3. Verify your SSO session hasn't expired: `aws sso login --profile Development`

```bash
# Re-authenticate with SSO
aws sso login --profile Development
aws sso login --profile Production
```

### Issue: "NoSuchBucket" error

**Check:**
1. The S3 bucket exists in Account B
2. The bucket name in the CloudFormation parameters matches exactly
3. You're using the correct AWS region

```bash
# List buckets in Account B
aws s3 ls --profile Production
```

### Issue: CloudFormation stack creation fails

**Check the stack events:**

```bash
# Account B
aws cloudformation describe-stack-events \
  --stack-name CrossAccountS3Access-AccountB \
  --profile Production \
  --max-items 20

# Account A
aws cloudformation describe-stack-events \
  --stack-name CrossAccountS3Access-AccountA \
  --profile Development \
  --max-items 20
```

### Issue: "User is not authorized to perform: sts:AssumeRole"

This is normal for SSO users! SSO users must use the role in Account A first, then use that to assume the role in Account B.

**Wrong approach (won't work):**
```bash
# SSO users can't do this directly
aws sts assume-role --role-arn <Account-B-Role> --profile Development
```

**Correct approach:**
```bash
# Assume the role with SSO credentials, which gives you temporary creds
# Then use those temporary creds to assume Account B role
# (The helper script handles this automatically)
```

---

## 📝 Summary

**What you created:**

1. **In Account B (Production)**:
   - IAM Role: `CrossAccountS3Access`
   - Trust policy allowing Account A
   - S3 permissions for your bucket

2. **In Account A (Development)**:
   - IAM Role: `CrossAccountS3AccessAssumer`
   - Permission to assume Account B role
   - Trust policy for SSO users

3. **Security features**:
   - External ID for confused deputy prevention
   - Temporary credentials (1-hour expiry)
   - Complete CloudTrail audit logs
   - Principle of least privilege

**Next steps:**
- Use the helper scripts for daily operations
- Set up CloudWatch monitoring for AssumeRole events
- Document the process for your team
- Consider adding MFA requirement for production access