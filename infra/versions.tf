terraform {
  # 1.9+ for cross-variable validation, 1.10+ for S3 native state locking.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }

  # Partial configuration: bucket, key and region are passed with -backend-config
  # at init time so no environment-specific values are committed.
  backend "s3" {}
}
