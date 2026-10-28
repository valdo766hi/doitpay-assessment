# Terraform task

Write Terraform configuration for an EKS cluster and managed node group using an existing VPC and private subnets. The network is managed by another team and should be passed as inputs.

Suggested files:
- `main.tf`
- `variables.tf`
- `outputs.tf`
- `versions.tf`
- `terraform.tfvars.example`

Do not run `terraform apply`. You may use local validation commands. Explain any assumptions about endpoint access, subnet tags, IAM, and node connectivity.
