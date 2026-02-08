# Tell Terraform what version to use
terraform {
  required_version = ">= 1.0"
  
  # We need the AWS provider (plugin for AWS)
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Configure AWS provider
provider "aws" {
  region = var.aws_region  # Use variable for flexibility
  
  # Add these tags to everything we create
  default_tags {
    tags = {
      Project     = "ImageProcessingPipeline"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# Define input variables
variable "aws_region" {
  description = "Which AWS region to use"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, prod, etc.)"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Name of this project"
  type        = string
  default     = "image-pipeline"
}

variable "notification_email" {
  description = "Your email for notifications"
  type        = string
  # No default - must be provided
}

# Get our AWS account ID automatically
data "aws_caller_identity" "current" {}

# Create source bucket (where you upload images)
resource "aws_s3_bucket" "source" {
  # Bucket name must be globally unique
  bucket = "${var.project_name}-source-${var.environment}-${data.aws_caller_identity.current.account_id}"
  
  # Allow Terraform to delete even if not empty
  force_destroy = true
}

# Create processed bucket (where resized images go)
resource "aws_s3_bucket" "processed" {
  bucket = "${var.project_name}-processed-${var.environment}-${data.aws_caller_identity.current.account_id}"
  
  force_destroy = true
}

# Make source bucket private
resource "aws_s3_bucket_public_access_block" "source" {
  bucket = aws_s3_bucket.source.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Make processed bucket private
resource "aws_s3_bucket_public_access_block" "processed" {
  bucket = aws_s3_bucket.processed.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Create SNS topic (for sending emails)
resource "aws_sns_topic" "image_processing" {
  name = "${var.project_name}-notifications-${var.environment}"
}

# Subscribe your email to the topic
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.image_processing.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# Create IAM role (like a job description for Lambda)
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role-${var.environment}"

  # This says "Lambda service can use this role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Create policy (specific permissions)
resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy-${var.environment}"
  role = aws_iam_role.lambda_role.id

  # Define what Lambda is allowed to do
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Allow reading from source bucket and writing to processed bucket
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          "${aws_s3_bucket.source.arn}/*",
          "${aws_s3_bucket.processed.arn}/*"
        ]
      },
      {
        # Allow publishing to SNS
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.image_processing.arn
      },
      {
        # Allow writing logs to CloudWatch
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Create log group (where Lambda writes logs)
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.project_name}-processor-${var.environment}"
  retention_in_days = 7  # Keep logs for 7 days
}

# Create the Lambda function
resource "aws_lambda_function" "image_processor" {
  # Path to our ZIP file
  filename      = "../lambda/lambda-deployment.zip"
  
  # Name of the function
  function_name = "${var.project_name}-processor-${var.environment}"
  
  # Use the IAM role we created
  role          = aws_iam_role.lambda_role.arn
  
  # Which function to run (filename.function_name)
  handler       = "lambda_function.lambda_handler"
  
  # Python version to use
  runtime       = "python3.9"
  
  # Max time to run (60 seconds)
  timeout       = 60
  
  # RAM to allocate (512 MB)
  memory_size   = 512

  # Terraform will recreate if ZIP changes
  source_code_hash = filebase64sha256("../lambda/lambda-deployment.zip")
  layers = ["arn:aws:lambda:us-east-1:770693421928:layer:Klayers-p39-pillow:1"]

  # Environment variables Lambda will have access to
  environment {
    variables = {
      PROCESSED_BUCKET = aws_s3_bucket.processed.id
      SNS_TOPIC_ARN    = aws_sns_topic.image_processing.arn
    }
  }

  # Make sure log group exists first
  depends_on = [
    aws_cloudwatch_log_group.lambda_logs,
    aws_iam_role_policy.lambda_policy
  ]
}

# Tell S3 to trigger Lambda when files are uploaded
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.source.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.image_processor.arn
    events              = ["s3:ObjectCreated:*"]  # Any file created
    filter_prefix       = ""                       # No prefix filter
    filter_suffix       = ""                       # No suffix filter
  }

  # Make sure permission exists first
  depends_on = [aws_lambda_permission.allow_s3]
}

# Give S3 permission to invoke Lambda
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.image_processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.source.arn
}

# Output values after creation (shown in terminal)
output "source_bucket_name" {
  description = "Name of the source S3 bucket"
  value       = aws_s3_bucket.source.id
}

output "processed_bucket_name" {
  description = "Name of the processed S3 bucket"
  value       = aws_s3_bucket.processed.id
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.image_processor.function_name
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic"
  value       = aws_sns_topic.image_processing.arn
}

# Add after source bucket creation
resource "aws_s3_bucket_cors_configuration" "source" {
  bucket = aws_s3_bucket.source.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "POST", "GET"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# Add after processed bucket creation
resource "aws_s3_bucket_cors_configuration" "processed" {
  bucket = aws_s3_bucket.processed.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET"]
    allowed_origins = ["*"]
    max_age_seconds = 3000
  }
}