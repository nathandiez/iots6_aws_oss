#!/bin/bash
# set-aws-env.sh - Set up AWS environment for IoTS6

echo "Setting up AWS environment for IoTS6 deployment..."

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI is not installed. Please install it first:"
    echo "   brew install awscli    # On macOS"
    echo "   # Or follow: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

# Check if AWS is configured
if ! aws sts get-caller-identity &> /dev/null; then
    echo "❌ AWS CLI is not configured. Please configure it first:"
    echo "   aws configure"
    echo "   # You'll need your AWS Access Key ID and Secret Access Key"
    exit 1
fi

# Get current AWS identity
CURRENT_USER=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo "unknown")
CURRENT_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

echo "✅ AWS CLI configured"
echo "   User: $CURRENT_USER"
echo "   Region: $CURRENT_REGION"

# Export AWS region for Terraform
export AWS_DEFAULT_REGION="$CURRENT_REGION"
export TF_VAR_aws_region="$CURRENT_REGION"

echo "✅ AWS environment ready for IoTS6 deployment"
echo "   AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION"
echo "   TF_VAR_aws_region=$TF_VAR_aws_region"
