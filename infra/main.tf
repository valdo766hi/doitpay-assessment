provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

locals {
  tags = merge(var.tags, {
    Project     = "paytrack"
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

data "aws_partition" "current" {}

# Read the platform-owned subnets so a wrong ID, or a subnet from another VPC,
# fails at plan time instead of part-way through cluster creation.
data "aws_subnet" "private" {
  for_each = toset(var.private_subnet_ids)
  id       = each.value
}

# ---------------------------------------------------------------------------
# Control plane
# ---------------------------------------------------------------------------

resource "aws_kms_key" "eks" {
  #checkov:skip=CKV2_AWS_64:The default key policy (account root, delegated to IAM) is intended; access is granted by IAM policy on the cluster role.

  description             = "${var.cluster_name} EKS secrets envelope encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

# EKS writes control plane logs to this fixed name. Creating it here sets the
# retention; otherwise EKS creates it with logs that never expire.
resource "aws_cloudwatch_log_group" "eks" {
  #checkov:skip=CKV_AWS_158:CloudWatch encrypts log data at rest by default; a CMK would need a logs key policy for little added value here.

  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
}

# Attached to the control plane ENIs only (not the nodes). Starts empty and
# only admits operator networks, so the cluster never needs replacing to add one.
resource "aws_security_group" "cluster_api" {
  name        = "${var.cluster_name}-api-access"
  description = "Private Kubernetes API access for ${var.cluster_name}"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "cluster_api" {
  for_each = toset(var.cluster_endpoint_allowed_cidrs)

  security_group_id = aws_security_group.cluster_api.id
  description       = "Kubernetes API from operator network"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_eks_cluster" "this" {
  #checkov:skip=CKV_AWS_37:api, audit and authenticator logs cover access and change auditing; scheduler/controllerManager logs are left off for cost.

  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  # Internal-only API: no public endpoint. Operators reach it over VPN/bastion
  # routes into the VPC (see cluster_endpoint_allowed_cidrs).
  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.cluster_api.id]
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  # Access entries only (no aws-auth ConfigMap), and the identity running
  # Terraform is not silently made cluster-admin.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # Avoid silently paying for extended support; plan upgrades within standard support.
  upgrade_policy {
    support_type = "STANDARD"
  }

  lifecycle {
    precondition {
      condition     = alltrue([for s in data.aws_subnet.private : s.vpc_id == var.vpc_id])
      error_message = "Every private_subnet_ids entry must belong to vpc_id."
    }
    precondition {
      condition     = length(distinct([for s in data.aws_subnet.private : s.availability_zone])) >= 2
      error_message = "private_subnet_ids must span at least two availability zones."
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy.cluster_kms,
    aws_cloudwatch_log_group.eks,
  ]
}

# ---------------------------------------------------------------------------
# Cluster access
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_role_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = aws_eks_access_entry.admin

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# ---------------------------------------------------------------------------
# Managed node group
# ---------------------------------------------------------------------------

# Only hardens node defaults; the AMI is still chosen and patched by EKS (ami_type).
resource "aws_launch_template" "node" {
  name_prefix            = "${var.cluster_name}-node-"
  update_default_version = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # Pods sit one hop behind the node, so they cannot reach IMDS and borrow
    # the node role. Pods that need AWS access use IRSA/Pod Identity instead.
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # default_tags do not reach instances and volumes launched by the node group's ASG.
  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${var.cluster_name}-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.tags
  }
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  version         = aws_eks_cluster.this.version

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  instance_types = var.node_instance_types

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  # Replace one node at a time during upgrades; pairs with the app's PodDisruptionBudget.
  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}
