#!/bin/bash

###############################################################################
# AWS Cross-Account IAM Role Cleanup Script
# 
# This script removes all CloudFormation stacks and resources created
# by the deployment script.
#
# Usage: ./cleanup.sh
###############################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

print_header "AWS Cross-Account IAM Role Cleanup"

# Collect input
read -p "Enter AWS SSO profile for Account A [admin-dev]: " PROFILE_A
PROFILE_A=${PROFILE_A:-admin-dev}

read -p "Enter AWS SSO profile for Account B [admin-prod]: " PROFILE_B
PROFILE_B=${PROFILE_B:-admin-prod}

read -p "Enter stack name prefix [CrossAccountS3Access]: " STACK_PREFIX
STACK_PREFIX=${STACK_PREFIX:-CrossAccountS3Access}

STACK_NAME_A="${STACK_PREFIX}-AccountA"
STACK_NAME_B="${STACK_PREFIX}-AccountB"

print_header "Cleanup Configuration"
echo "Account A Profile: $PROFILE_A"
echo "Account A Stack:   $STACK_NAME_A"
echo ""
echo "Account B Profile: $PROFILE_B"
echo "Account B Stack:   $STACK_NAME_B"
echo ""

print_warning "This will DELETE all resources created by the deployment script!"
read -p "Are you sure you want to continue? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    print_info "Cleanup cancelled."
    exit 0
fi

# Delete Account A stack first
print_header "Deleting Account A Stack"

if aws cloudformation describe-stacks --stack-name "$STACK_NAME_A" --profile "$PROFILE_A" &>/dev/null; then
    print_info "Deleting stack: $STACK_NAME_A"
    
    aws cloudformation delete-stack \
        --stack-name "$STACK_NAME_A" \
        --profile "$PROFILE_A"
    
    print_info "Waiting for stack deletion to complete..."
    aws cloudformation wait stack-delete-complete \
        --stack-name "$STACK_NAME_A" \
        --profile "$PROFILE_A" || true
    
    print_success "Account A stack deleted"
else
    print_warning "Stack $STACK_NAME_A not found in Account A"
fi

# Delete Account B stack
print_header "Deleting Account B Stack"

if aws cloudformation describe-stacks --stack-name "$STACK_NAME_B" --profile "$PROFILE_B" &>/dev/null; then
    print_info "Deleting stack: $STACK_NAME_B"
    
    aws cloudformation delete-stack \
        --stack-name "$STACK_NAME_B" \
        --profile "$PROFILE_B"
    
    print_info "Waiting for stack deletion to complete..."
    aws cloudformation wait stack-delete-complete \
        --stack-name "$STACK_NAME_B" \
        --profile "$PROFILE_B" || true
    
    print_success "Account B stack deleted"
else
    print_warning "Stack $STACK_NAME_B not found in Account B"
fi

# Clean up local files
print_header "Cleaning Up Local Files"

if [ -f "test_cross_account_access.sh" ]; then
    rm -f test_cross_account_access.sh
    print_success "Removed test script"
fi

if [ -f "account-a-parameters.json" ]; then
    rm -f account-a-parameters.json
    print_success "Removed Account A parameters file"
fi

if [ -f "account-b-parameters.json" ]; then
    rm -f account-b-parameters.json
    print_success "Removed Account B parameters file"
fi

print_header "✓ Cleanup Complete!"
echo "All CloudFormation stacks and local files have been removed."
echo ""