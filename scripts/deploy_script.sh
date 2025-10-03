#!/bin/bash

###############################################################################
# AWS Cross-Account IAM Role Deployment Script (SSO Version)
# 
# This script deploys CloudFormation stacks to create cross-account IAM roles
# for secure S3 access between AWS accounts using AWS SSO profiles.
#
# Usage: ./deploy.sh
###############################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
    echo ""
}

# Check dependencies
check_dependencies() {
    print_info "Checking dependencies..."
    
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed!"
        echo "Install it from: https://aws.amazon.com/cli/"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        print_warning "jq is not installed. Some features may not work."
        echo "Install it from: https://stedolan.github.io/jq/"
    fi
    
    print_success "All dependencies found"
}

# Get AWS account ID for a profile
get_account_id() {
    local profile=$1
    aws sts get-caller-identity --profile "$profile" --query 'Account' --output text 2>/dev/null
}

# Collect user input
collect_input() {
    print_header "Configuration"
    
    # Account A (Development) profile
    read -p "Enter AWS SSO profile for Account A (Development) [admin-dev]: " PROFILE_A
    PROFILE_A=${PROFILE_A:-admin-dev}
    
    # Test Account A access
    print_info "Testing Account A access..."
    ACCOUNT_A_ID=$(get_account_id "$PROFILE_A")
    if [ -z "$ACCOUNT_A_ID" ]; then
        print_error "Cannot access Account A with profile: $PROFILE_A"
        print_info "Try logging in: aws sso login --profile $PROFILE_A"
        exit 1
    fi
    print_success "Account A ID: $ACCOUNT_A_ID"
    
    # Account B (Production) profile
    read -p "Enter AWS SSO profile for Account B (Production) [admin-prod]: " PROFILE_B
    PROFILE_B=${PROFILE_B:-admin-prod}
    
    # Test Account B access
    print_info "Testing Account B access..."
    ACCOUNT_B_ID=$(get_account_id "$PROFILE_B")
    if [ -z "$ACCOUNT_B_ID" ]; then
        print_error "Cannot access Account B with profile: $PROFILE_B"
        print_info "Try logging in: aws sso login --profile $PROFILE_B"
        exit 1
    fi
    print_success "Account B ID: $ACCOUNT_B_ID"
    
    # Verify different accounts
    if [ "$ACCOUNT_A_ID" == "$ACCOUNT_B_ID" ]; then
        print_error "Both profiles point to the same AWS account!"
        print_error "Cross-account access requires two different accounts."
        exit 1
    fi
    
    # S3 Bucket
    read -p "Enter S3 bucket name in Account B: " S3_BUCKET
    if [ -z "$S3_BUCKET" ]; then
        print_error "S3 bucket name is required!"
        exit 1
    fi
    
    # Verify bucket exists
    print_info "Verifying S3 bucket exists..."
    if aws s3 ls "s3://${S3_BUCKET}" --profile "$PROFILE_B" &>/dev/null; then
        print_success "Bucket exists: $S3_BUCKET"
    else
        print_warning "Bucket may not exist or you don't have access to it"
        read -p "Continue anyway? (yes/no): " CONTINUE
        if [ "$CONTINUE" != "yes" ]; then
            exit 1
        fi
    fi
    
    # Role name
    read -p "Enter IAM role name [CrossAccountS3Access]: " ROLE_NAME
    ROLE_NAME=${ROLE_NAME:-CrossAccountS3Access}
    
    # External ID
    read -p "Enter External ID [CrossAccountAccess-2024]: " EXTERNAL_ID
    EXTERNAL_ID=${EXTERNAL_ID:-CrossAccountAccess-2024}
    
    # Session duration
    read -p "Enter max session duration in seconds [3600]: " MAX_SESSION_DURATION
    MAX_SESSION_DURATION=${MAX_SESSION_DURATION:-3600}
    
    # Stack names
    STACK_NAME_A="${ROLE_NAME}-AccountA"
    STACK_NAME_B="${ROLE_NAME}-AccountB"
}

# Display configuration summary
display_summary() {
    print_header "Configuration Summary"
    
    echo "Account A (Development):"
    echo "  Profile:    $PROFILE_A"
    echo "  Account ID: $ACCOUNT_A_ID"
    echo "  Stack Name: $STACK_NAME_A"
    echo ""
    echo "Account B (Production):"
    echo "  Profile:    $PROFILE_B"
    echo "  Account ID: $ACCOUNT_B_ID"
    echo "  Stack Name: $STACK_NAME_B"
    echo ""
    echo "Configuration:"
    echo "  S3 Bucket:          $S3_BUCKET"
    echo "  Role Name:          $ROLE_NAME"
    echo "  External ID:        $EXTERNAL_ID"
    echo "  Max Session (sec):  $MAX_SESSION_DURATION"
    echo ""
    
    read -p "Proceed with deployment? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        print_info "Deployment cancelled."
        exit 0
    fi
}

# Deploy Account B stack
deploy_account_b() {
    print_header "Step 1: Deploying to Account B (Production)"
    
    # Create parameters file
    PARAMS_FILE_B="/tmp/account-b-params-$$.json"
    cat > "$PARAMS_FILE_B" << EOF
[
  {
    "ParameterKey": "TrustedAccountId",
    "ParameterValue": "$ACCOUNT_A_ID"
  },
  {
    "ParameterKey": "S3BucketName",
    "ParameterValue": "$S3_BUCKET"
  },
  {
    "ParameterKey": "RoleName",
    "ParameterValue": "$ROLE_NAME"
  },
  {
    "ParameterKey": "ExternalId",
    "ParameterValue": "$EXTERNAL_ID"
  },
  {
    "ParameterKey": "MaxSessionDuration",
    "ParameterValue": "$MAX_SESSION_DURATION"
  }
]
EOF
    
    print_info "Creating CloudFormation stack in Account B..."
    
    # Check if stack already exists
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME_B" --profile "$PROFILE_B" &>/dev/null; then
        print_warning "Stack $STACK_NAME_B already exists in Account B"
        read -p "Update existing stack? (yes/no): " UPDATE
        if [ "$UPDATE" == "yes" ]; then
            aws cloudformation update-stack \
                --stack-name "$STACK_NAME_B" \
                --template-body file://cloudformation/account-b-role.yaml \
                --parameters file://"$PARAMS_FILE_B" \
                --capabilities CAPABILITY_NAMED_IAM \
                --profile "$PROFILE_B"
            
            print_info "Waiting for stack update to complete..."
            aws cloudformation wait stack-update-complete \
                --stack-name "$STACK_NAME_B" \
                --profile "$PROFILE_B"
        else
            print_info "Skipping Account B deployment"
        fi
    else
        aws cloudformation create-stack \
            --stack-name "$STACK_NAME_B" \
            --template-body file://cloudformation/account-b-role.yaml \
            --parameters file://"$PARAMS_FILE_B" \
            --capabilities CAPABILITY_NAMED_IAM \
            --profile "$PROFILE_B"
        
        print_info "Waiting for stack creation to complete (this may take 1-2 minutes)..."
        aws cloudformation wait stack-create-complete \
            --stack-name "$STACK_NAME_B" \
            --profile "$PROFILE_B"
    fi
    
    # Clean up params file
    rm -f "$PARAMS_FILE_B"
    
    print_success "Account B stack deployed successfully"
    
    # Get the role ARN
    ROLE_ARN_B=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME_B" \
        --profile "$PROFILE_B" \
        --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' \
        --output text)
    
    print_success "Role ARN in Account B: $ROLE_ARN_B"
}

# Deploy Account A stack
deploy_account_a() {
    print_header "Step 2: Deploying to Account A (Development)"
    
    # Create parameters file
    PARAMS_FILE_A="/tmp/account-a-params-$.json"
    cat > "$PARAMS_FILE_A" << EOF
[
  {
    "ParameterKey": "AccountBRoleArn",
    "ParameterValue": "$ROLE_ARN_B"
  },
  {
    "ParameterKey": "RoleName",
    "ParameterValue": "${ROLE_NAME}Assumer"
  }
]
EOF
    
    print_info "Creating CloudFormation stack in Account A..."
    
    # Check if stack already exists
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME_A" --profile "$PROFILE_A" &>/dev/null; then
        print_warning "Stack $STACK_NAME_A already exists in Account A"
        read -p "Update existing stack? (yes/no): " UPDATE
        if [ "$UPDATE" == "yes" ]; then
            aws cloudformation update-stack \
                --stack-name "$STACK_NAME_A" \
                --template-body file://cloudformation/account-a-role.yaml \
                --parameters file://"$PARAMS_FILE_A" \
                --capabilities CAPABILITY_NAMED_IAM \
                --profile "$PROFILE_A"
            
            print_info "Waiting for stack update to complete..."
            aws cloudformation wait stack-update-complete \
                --stack-name "$STACK_NAME_A" \
                --profile "$PROFILE_A"
        else
            print_info "Skipping Account A deployment"
        fi
    else
        aws cloudformation create-stack \
            --stack-name "$STACK_NAME_A" \
            --template-body file://cloudformation/account-a-role.yaml \
            --parameters file://"$PARAMS_FILE_A" \
            --capabilities CAPABILITY_NAMED_IAM \
            --profile "$PROFILE_A"
        
        print_info "Waiting for stack creation to complete (this may take 1-2 minutes)..."
        aws cloudformation wait stack-create-complete \
            --stack-name "$STACK_NAME_A" \
            --profile "$PROFILE_A"
    fi
    
    # Clean up params file
    rm -f "$PARAMS_FILE_A"
    
    print_success "Account A stack deployed successfully"
}

# Create test script
create_test_script() {
    TEST_SCRIPT="test_cross_account_access.sh"
    
    cat > "$TEST_SCRIPT" << 'SCRIPT_END'
#!/bin/bash

# Configuration (replace with your values)
ACCOUNT_B_ROLE="ROLE_ARN_PLACEHOLDER"
EXTERNAL_ID="EXTERNAL_ID_PLACEHOLDER"
BUCKET_NAME="BUCKET_PLACEHOLDER"
PROFILE="PROFILE_A_PLACEHOLDER"

set -e

echo "=========================================="
echo "Testing Cross-Account S3 Access"
echo "=========================================="
echo ""

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed."
    echo "Install it from: https://stedolan.github.io/jq/"
    exit 1
fi

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
EXPIRATION=$(echo $CREDENTIALS | jq -r '.Credentials.Expiration')

echo "  Session expires: $EXPIRATION"
echo ""

# List bucket
echo "→ Testing bucket access..."
aws s3 ls "s3://${BUCKET_NAME}/" 2>&1
if [ $? -eq 0 ]; then
  echo "✓ Successfully listed bucket contents!"
else
  echo "✗ Failed to access bucket!"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  exit 1
fi

echo ""
echo "→ Testing file upload..."

# Create test file
TEST_FILE="/tmp/test-cross-account-$(date +%s).txt"
echo "Test file created at $(date)" > "$TEST_FILE"

# Upload
S3_KEY="test-cross-account/$(basename $TEST_FILE)"
aws s3 cp "$TEST_FILE" "s3://${BUCKET_NAME}/${S3_KEY}"
if [ $? -eq 0 ]; then
  echo "✓ Successfully uploaded test file to: s3://${BUCKET_NAME}/${S3_KEY}"
else
  echo "✗ Failed to upload file!"
  rm -f "$TEST_FILE"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  exit 1
fi

echo ""
echo "→ Testing file download..."

# Download
DOWNLOAD_FILE="/tmp/downloaded-$(date +%s).txt"
aws s3 cp "s3://${BUCKET_NAME}/${S3_KEY}" "$DOWNLOAD_FILE"
if [ $? -eq 0 ]; then
  echo "✓ Successfully downloaded test file!"
  echo "  Content: $(cat $DOWNLOAD_FILE)"
else
  echo "✗ Failed to download file!"
fi

echo ""
echo "→ Cleaning up test files..."

# Delete test file from S3
aws s3 rm "s3://${BUCKET_NAME}/${S3_KEY}"
rm -f "$TEST_FILE" "$DOWNLOAD_FILE"

echo ""
echo "=========================================="
echo "✓ All tests passed!"
echo "=========================================="
echo ""
echo "Your cross-account access is working correctly."

# Clean up credentials
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
SCRIPT_END

    # Replace placeholders
    sed -i.bak "s|ROLE_ARN_PLACEHOLDER|$ROLE_ARN_B|g" "$TEST_SCRIPT"
    sed -i.bak "s|EXTERNAL_ID_PLACEHOLDER|$EXTERNAL_ID|g" "$TEST_SCRIPT"
    sed -i.bak "s|BUCKET_PLACEHOLDER|$S3_BUCKET|g" "$TEST_SCRIPT"
    sed -i.bak "s|PROFILE_A_PLACEHOLDER|$PROFILE_A|g" "$TEST_SCRIPT"
    rm -f "${TEST_SCRIPT}.bak"
    
    chmod +x "$TEST_SCRIPT"
    
    print_success "Created test script: $TEST_SCRIPT"
}

# Display success message
display_success() {
    print_header "✓ Deployment Complete!"
    
    echo "Summary:"
    echo "  Account A Stack: $STACK_NAME_A"
    echo "  Account B Stack: $STACK_NAME_B"
    echo "  Account B Role:  $ROLE_ARN_B"
    echo ""
    echo "Next Steps:"
    echo "  1. Test the setup:"
    echo "     ./test_cross_account_access.sh"
    echo ""
    echo "  2. Use in your applications:"
    echo "     aws sts assume-role \\"
    echo "       --role-arn $ROLE_ARN_B \\"
    echo "       --role-session-name MySession \\"
    echo "       --external-id $EXTERNAL_ID \\"
    echo "       --profile $PROFILE_A"
    echo ""
    echo "  3. Monitor access in CloudTrail:"
    echo "     aws cloudtrail lookup-events \\"
    echo "       --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \\"
    echo "       --profile $PROFILE_B"
    echo ""
    print_success "Configuration files and test script have been created!"
}

# Main execution
main() {
    print_header "AWS Cross-Account IAM Role Deployment (SSO)"
    
    check_dependencies
    collect_input
    display_summary
    deploy_account_b
    deploy_account_a
    create_test_script
    display_success
}

# Run main function
main