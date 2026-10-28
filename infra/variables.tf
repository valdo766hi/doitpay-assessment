variable "aws_region" {
  description = "AWS region for every resource in this configuration."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a region code such as ap-southeast-3."
  }
}

variable "environment" {
  description = "Environment name, used in tags (e.g. sandbox, staging, production)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment))
    error_message = "environment must contain only lowercase letters, digits and hyphens."
  }
}

variable "cluster_name" {
  description = "EKS cluster name. Also used as the prefix for IAM roles and other named resources."
  type        = string

  validation {
    # IAM role names are limited to 64 characters and get a suffix appended.
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,49}$", var.cluster_name))
    error_message = "cluster_name must start with a letter, contain only letters, digits and hyphens, and be at most 50 characters."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version (e.g. 1.36). Pick a version in EKS standard support."
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must be a minor version such as 1.36."
  }
}

variable "vpc_id" {
  description = "ID of the existing VPC managed by the platform team."
  type        = string

  validation {
    condition     = can(regex("^vpc-", var.vpc_id))
    error_message = "vpc_id must be a VPC ID (vpc-...)."
  }
}

variable "private_subnet_ids" {
  description = "Existing private subnets in vpc_id, in at least two AZs. Used for the control plane ENIs and the nodes."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2 && alltrue([for id in var.private_subnet_ids : can(regex("^subnet-", id))])
    error_message = "private_subnet_ids must contain at least two subnet IDs (subnet-...)."
  }
}

variable "cluster_endpoint_allowed_cidrs" {
  description = "Private CIDRs (e.g. corporate VPN, bastion subnet) allowed to reach the private Kubernetes API endpoint on 443."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.cluster_endpoint_allowed_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "cluster_endpoint_allowed_cidrs must be valid CIDRs and must not include 0.0.0.0/0."
  }
}

variable "cluster_admin_role_arns" {
  description = "IAM role ARNs (e.g. the platform team's SSO role) granted cluster-admin through EKS access entries."
  type        = list(string)

  validation {
    condition     = length(var.cluster_admin_role_arns) > 0 && alltrue([for arn in var.cluster_admin_role_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/", arn))])
    error_message = "cluster_admin_role_arns must contain at least one IAM role ARN; IAM users are intentionally not accepted."
  }
}

variable "node_instance_types" {
  description = "Instance types for the managed node group. Must be x86_64 to match the AL2023 x86_64 AMI type."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "min_size" {
  description = "Minimum number of nodes."
  type        = number
  default     = 2
}

variable "max_size" {
  description = "Maximum number of nodes."
  type        = number
  default     = 4
}

variable "desired_size" {
  description = "Desired number of nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.min_size >= 1 && var.min_size <= var.desired_size && var.desired_size <= var.max_size
    error_message = "Node counts must satisfy 1 <= min_size <= desired_size <= max_size."
  }
}

variable "log_retention_days" {
  description = "Retention for EKS control plane logs in CloudWatch."
  type        = number
  default     = 365
}

variable "tags" {
  description = "Extra tags applied to every resource (e.g. Owner, CostCenter)."
  type        = map(string)
  default     = {}
}
