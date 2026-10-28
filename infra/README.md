# Terraform: EKS for PayTrack

Creates an EKS cluster and one managed node group inside an **existing** VPC and private subnets owned by the platform team. Nothing here has been applied.

| File | Contents |
|---|---|
| `versions.tf` | Terraform `>= 1.10`, AWS provider `~> 6.70` (locked to 6.70.0 in `.terraform.lock.hcl`), partial S3 backend |
| `main.tf` | Provider (region from `var.aws_region`), cluster, KMS key, log group, API security group, access entries, launch template, node group |
| `iam.tf` | Cluster role and node role with their policy attachments |
| `variables.tf` / `outputs.tf` | Inputs with validation; outputs needed to connect and to add IRSA later |
| `terraform.tfvars.example` | Placeholder inputs, no credentials |

## What is configured

| Area | Configuration |
|---|---|
| Cluster | Kubernetes `var.kubernetes_version` (example: 1.36), secrets envelope-encrypted with a customer-managed KMS key (rotation on), `api`/`audit`/`authenticator` logs to CloudWatch with 365-day retention, `upgrade_policy = STANDARD` |
| Cluster IAM | Role trusted by `eks.amazonaws.com` with `AmazonEKSClusterPolicy`, plus an inline policy for the KMS key only |
| Node group | `default`, AL2023 x86_64, on-demand `t3.medium` ×2 (2 to 4), in the private subnets, `max_unavailable = 1` during upgrades, version follows the control plane |
| Node IAM | Role trusted by `ec2.amazonaws.com` with `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryPullOnly` |
| Node hardening | Launch template: IMDSv2 required with hop limit 1, encrypted 50 GiB gp3 root volume, no SSH key |
| Networking | Control plane ENIs and nodes in `var.private_subnet_ids`; private endpoint only; extra security group admits only `var.cluster_endpoint_allowed_cidrs` on 443 |
| Access | Access entries (`authentication_mode = "API"`); cluster-admin only for `var.cluster_admin_role_arns` |
| Tags | `Project`, `Environment`, `ManagedBy` + `var.tags` via provider `default_tags`, and on node instances/volumes via the launch template |

**Why raw resources and not `terraform-aws-modules/eks` (v21.29.0 at time of writing):** the module is well maintained, but for one cluster and one node group the raw resources are about 250 lines in which every IAM, network and access setting can be read directly in review, with no module upgrade cadence to track. The cost is that we wire up extras such as add-ons and IRSA ourselves. For a larger fleet I would revisit this.

## Networking assumptions

- `vpc_id` and at least two private subnets in different AZs already exist. Preconditions check at plan time that every subnet is in `vpc_id` and that they span two or more AZs.
- The private subnets have outbound access for nodes, via NAT or VPC endpoints for ECR (`api`, `dkr`), S3 (gateway), STS, EC2 and CloudWatch Logs. Nodes need this to pull images and for the VPC CNI to manage ENIs.
- The VPC has DNS support and DNS hostnames enabled, which the private endpoint needs to resolve.
- The subnets have free IP space: the VPC CNI gives every pod a VPC IP.
- Subnet tags: none are required for this configuration. If an internal load balancer is added later through the AWS Load Balancer Controller, the subnets need `kubernetes.io/role/internal-elb = 1`.

## Cluster and node access assumptions

- **API endpoint is private only.** The API is internal, so the control plane isn't reachable from the internet. Operators use `kubectl` from a VPN or bastion network that is routed into the VPC and listed in `cluster_endpoint_allowed_cidrs`. From on-prem or VPN they also need a Route 53 Resolver inbound endpoint to resolve the private endpoint name.
- **No implicit admin.** `bootstrap_cluster_creator_admin_permissions = false`, so the identity running Terraform does not become cluster-admin. Only the IAM roles in `cluster_admin_role_arns` (roles, never IAM users) get `AmazonEKSClusterAdminPolicy`. Access entries are managed through the EKS API, so a lost admin is recovered through IAM rather than by editing an `aws-auth` ConfigMap.
- EKS creates the node role's access entry automatically for managed node groups.
- **Nodes** have no public IPs and no SSH key. Pods cannot reach IMDS (hop limit 1), so they cannot use the node role; workloads that need AWS access get their own role via IRSA or Pod Identity. If shell access is ever needed, use SSM Session Manager (would require `AmazonSSMManagedInstanceCore`, not attached) or `kubectl debug node/...`.
- **CI cannot reach the API.** GitHub-hosted runners are outside the VPC. That's fine for validation, which needs no cluster. Deployment options are covered in the root `README.md`.

## Validate without creating resources

```sh
cd infra
terraform fmt -check -recursive
terraform init -backend=false     # downloads the provider only; no state, no AWS calls
terraform validate
```

CI runs the same commands, plus Checkov over this directory (`.github/workflows/validate.yml`).

`terraform plan` is the next step but is **not** part of this submission: it needs AWS credentials and real subnet IDs, because the subnet preconditions read the VPC. With a read-only role it would look like this:

```sh
cp terraform.tfvars.example terraform.tfvars   # fill in real IDs; file is gitignored
terraform init \
  -backend-config="bucket=<state-bucket>" \
  -backend-config="key=paytrack/sandbox/eks.tfstate" \
  -backend-config="region=ap-southeast-3" \
  -backend-config="use_lockfile=true"
terraform plan -out=tfplan
```
