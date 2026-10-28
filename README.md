# PayTrack: DevOps technical assessment

PayTrack is an internal payment-reconciliation API. This repository holds the infrastructure, manifests and CI that run it on Amazon EKS. The starter repository is kept as the first commit, so `git diff` against it shows every change.

| Path | Part | What it is |
|---|---|---|
| [`infra/`](infra/README.md) | A | Terraform for the EKS cluster, managed node group and IAM, in an existing VPC |
| [`k8s/`](k8s/README.md) | B | Namespace, ServiceAccount, ConfigMap, Deployment, Service, PDB (kustomize) |
| [`.github/workflows/validate.yml`](.github/workflows/validate.yml) | C | PR validation: Terraform, kubeconform, Checkov |
| `troubleshooting/` | D | Incident artifacts; diagnosis to be added as `troubleshooting/diagnosis.md` |
| `app/`, `Dockerfile` | — | Starter app, with security fixes (see Findings) |

## Findings in the starter repository

| Finding | Risk | Fix |
|---|---|---|
| `Dockerfile` ran `python app/app.py`: the Flask development server with `debug=True` | The Werkzeug debugger allows remote code execution; the dev server is not built for production | Serve with gunicorn (`--workers 2 --threads 4`); removed `debug=True` (opt in locally with `FLASK_DEBUG=1`) |
| Container ran as root | A container escape lands as root; it fails the `restricted` Pod Security profile | Fixed non-root UID 10001, matching `runAsUser` in the Deployment |
| `Flask==3.1.0` | CVE-2025-47278 (fixed in 3.1.1) and CVE-2026-27205 (fixed in 3.1.3), per the PyPI advisory data | Pinned `Flask==3.1.3` and `gunicorn==26.2.0` (no known advisories) |
| `terraform.tfvars.example` existed in both the repo root and `infra/` | Two copies drift apart; the root one isn't read by anything | Kept only `infra/terraform.tfvars.example` |

## 1. Design decisions and assumptions

- **Internal means private by default.** The EKS API endpoint is private only, the Service is ClusterIP, and nodes have no public IPs or SSH. Reaching the API needs a VPN or bastion network listed in `cluster_endpoint_allowed_cidrs`.
- **Narrow, explicit admin access.** Access entries (`authentication_mode = "API"`) replace the `aws-auth` ConfigMap. The Terraform runner gets no implicit admin. Cluster-admin goes only to the named IAM roles.
- **The network is an input, not owned here.** `vpc_id` and `private_subnet_ids` come from the platform team. Preconditions fail the plan if the subnets are in another VPC or in a single AZ. The NAT/VPC-endpoint, DNS and IP-capacity assumptions are listed in [`infra/README.md`](infra/README.md#networking-assumptions).
- **Raw resources instead of the community EKS module.** About 250 readable lines for one cluster and one node group, instead of a large, frequently released module. Reasoning in `infra/README.md`.
- **Region is set once.** `var.aws_region` is used only in the provider block. ARNs are built from `aws_partition`, so no region or partition is hardcoded.
- **Manifests are designed around the incident.** Readiness gates traffic, liveness never checks dependencies, and `maxUnavailable: 0` with a progress deadline means a bad release can't take capacity away and shows up as a failed rollout. Details in [`k8s/README.md`](k8s/README.md).
- **Kubernetes 1.36.** It is in EKS standard support until 2027-08-02. 1.37 (released on EKS 2026-10-01) is newer, but add-ons and controllers usually lag a new minor version by a few weeks.

## 2. Validating without creating cloud resources

The checks below ran locally on 2026-10-28, and the same ones run in CI on every pull request and on pushes to `main`. CI has not run yet because nothing has been pushed.

| Check | Command | Result |
|---|---|---|
| Terraform format | `terraform fmt -check -recursive` | pass |
| Terraform config | `terraform init -backend=false && terraform validate` (local 1.16.5; CI pins 1.17.0) | pass |
| Manifests | `kubectl kustomize k8s \| kubeconform -strict -kubernetes-version 1.36.0` | 6/6 valid |
| IaC security | Checkov 3.3.30 over Terraform, Kubernetes, Dockerfile, workflows | 0 failed, 8 skipped with inline reasons |
| Workflow lint | `actionlint`, `zizmor` | no findings |
| App entrypoint | gunicorn `app.app:app` started locally; `/`, `/health`, `/ready` returned 200 | pass |
| Checks fail when they should | A field typo makes kubeconform exit 1; removing `allowPrivilegeEscalation: false` makes Checkov exit 1 (CKV_K8S_20) | pass |

**Not run:**
- `terraform plan`: needs AWS credentials and real subnets.
- `kubectl apply --dry-run=server`: needs a cluster.
- `docker build` and an image scan: Docker isn't available on my machine.

**CI design** (`validate.yml`):
- Three independent jobs, so one failure doesn't hide another and each shows up as a named check.
- Permissions are `contents: read` only. There is no `id-token` and no AWS access.
- Every action is pinned to a commit SHA, `persist-credentials: false` is set, the kubeconform binary is verified with SHA-256, and the Checkov image is pinned by digest.
- Checkov exceptions sit inline next to the resource they cover, each with a reason, so a new exception shows up in PR review.

## 3. Security and operational trade-offs

| Decision | Benefit | Cost / risk |
|---|---|---|
| Private-only API endpoint | No internet exposure of the control plane | Needs VPN/bastion; GitHub-hosted runners cannot deploy (see below) |
| Customer-managed KMS key for secrets | Key control and CloudTrail visibility of decrypts | Small cost; deleting the key makes Secrets unreadable (30-day deletion window) |
| `api`/`audit`/`authenticator` logs, 365 days | Who-did-what audit trail for a payments system | CloudWatch cost; scheduler/controller logs left off |
| `AmazonEKS_CNI_Policy` on the node role | Simple bootstrap, no IRSA/add-on ordering | Broader node role than AWS recommends; mitigated by IMDS hop limit 1 (pods can't use node credentials); moving it to IRSA/Pod Identity is a follow-up |
| `upgrade_policy = STANDARD` | No surprise extended-support charges | Forced control-plane upgrade at end of standard support, so upgrades must be planned |
| No CPU limit, memory limit = request | No CFS throttling; predictable memory | One pod can burst onto shared CPU; relies on accurate requests |
| No NetworkPolicy yet | No guessed rules that break traffic | Pod-to-pod traffic is open until the gateway and dependencies are known |
| On-demand nodes, fixed node count | Predictable, simple | No autoscaling or Spot savings yet |

### Deployment (proposal, not implemented)

Validation and deployment stay separate. A `deploy.yml` would run only on `main` after validation passes:

1. **Build and push.** Build the image, scan it (e.g. Trivy), and push it to ECR. Credentials come from GitHub OIDC (`id-token: write`) and `aws-actions/configure-aws-credentials`, assuming a role whose trust policy pins `aud = sts.amazonaws.com` and `sub = repo:<org>/<repo>:environment:production`. There are no long-lived keys.
2. **Deploy.** The job uses `environment: production` with required reviewers and a `main`-only deployment branch rule. The deploy role gets a namespace-scoped access entry (`AmazonEKSEditPolicy` on `paytrack` only), not cluster-admin. Because the endpoint is private, this job runs on a runner inside the VPC, such as a self-hosted runner or a CodeBuild-hosted GitHub runner.
3. **Alternative.** A pull-based GitOps controller (Argo CD or Flux) in the cluster would avoid exposing the API to CI at all. It's an extra component for a small team to run, so it's a decision for the platform team.

## 4. Not finished, and why

- **Part D diagnosis.** Pending; I prioritised A, B, C and this write-up first.
- **Deployment workflow.** Proposal only (above); it depends on the runner and network choice.
- **Next steps, in priority order:**
  1. NetworkPolicy, once the gateway and downstream addresses are known.
  2. Move the CNI policy to IRSA/Pod Identity, and manage `vpc-cni`, `kube-proxy` and `coredns` as EKS managed add-ons.
  3. Image build and vulnerability scan in CI.
  4. A read-only `terraform plan` in CI via OIDC.
  5. Node autoscaling (Karpenter or Cluster Autoscaler) and an HPA once there is load data.
  6. Alerts on 5xx rate and failed rollouts.

## 5. Use of AI and other tools

I used Claude Code to draft the configuration and to run the checks. Other sources: AWS EKS documentation, the Terraform and PyPI registries, Terraform, kubeconform, Checkov, actionlint and zizmor. I reviewed every file and checked version-sensitive claims against primary sources rather than model memory.

- **Verified:** Kubernetes version. The starter left a placeholder. The AWS EKS version page (2026-10-28) shows 1.34–1.37 in standard support; I chose 1.36 for the reason in section 1.
- **Changed:** node ECR policy. The common suggestion is `AmazonEC2ContainerRegistryReadOnly`. Current AWS docs recommend the narrower `AmazonEC2ContainerRegistryPullOnly`, so I used that.
- **Changed:** Checkov suppressions. The first draft put `#checkov:skip` comments above the resource blocks. A test showed Checkov ignores a comment there (the check still failed, 0 skipped), so I moved them inside the blocks and confirmed the scan reports them as skipped.
- **Rejected:** Checkov `CKV_DOCKER_2` (add a `HEALTHCHECK`). Kubernetes ignores Docker `HEALTHCHECK`, and the probes in the Deployment cover it. Suppressed with that reason.
- **Rejected:** overriding Nix's insecure-package block to install Checkov (its nixpkgs build pulled in a flagged `ecdsa` dependency). I ran the pinned PyPI release instead, the same version as the CI image.
- **Kept with mitigation:** AWS docs recommend moving `AmazonEKS_CNI_Policy` to a dedicated role. I kept it on the node role for a simpler bootstrap and documented the trade-off and follow-up (section 3).
