# Kubernetes manifests: paytrack-api

Apply with `kubectl apply -k k8s/` (not run; no cluster was provided). CI renders the kustomization and validates it with kubeconform against the Kubernetes 1.36 schemas, then scans it with Checkov.

| File | Purpose |
|---|---|
| `namespace.yaml` | `paytrack` namespace with Pod Security Admission `restricted` (enforce + warn) |
| `serviceaccount.yaml` | Dedicated ServiceAccount, API token not mounted |
| `configmap.yaml` | `APP_ENV`, the only setting the app reads |
| `deployment.yaml` | 3 replicas of the API |
| `service.yaml` | ClusterIP on port 80 → container port 8080 |
| `pdb.yaml` | At most one pod disrupted at a time (node drains, upgrades) |

## Decisions

**Rollout safety.** These controls follow from the troubleshooting incident: a release reached Running pods that could not serve traffic.
- `maxUnavailable: 0`, `maxSurge: 1`: an old pod is removed only after its replacement is Ready, so a bad image cannot reduce serving capacity.
- `progressDeadlineSeconds: 300`: a stuck rollout is marked failed (`ProgressDeadlineExceeded`), so `kubectl rollout status` and alerts catch it instead of waiting forever.
- `minReadySeconds: 10`: a pod must stay Ready briefly before it counts as available.
- `preStop` sleep of 5 s: the gateway and endpoints have time to stop routing to a pod before it receives SIGTERM, which avoids 5xx on scale-down and rollouts.

**Probes.** Each probe has a separate job:
- `startupProbe` on `/health` allows up to 60 s to boot.
- `readinessProbe` on `/ready` decides whether the pod receives Service traffic.
- `livenessProbe` on `/health` only restarts a hung process.

Liveness must never check downstream services. If it did, a downstream outage would restart every pod at once.

**Pod security.** These settings meet the `restricted` profile:
- Non-root UID 10001, the same UID the Dockerfile sets
- Read-only root filesystem, with `/tmp` as a size-limited `emptyDir`
- All capabilities dropped, no privilege escalation, `RuntimeDefault` seccomp
- No ServiceAccount token, because the app does not call the Kubernetes API

**Resources.** Requests are 100m CPU and 256Mi memory. The memory limit equals the request, so memory is predictable and the pod isn't evicted first under node pressure. There is deliberately no CPU limit: CFS throttling causes latency spikes and probe timeouts, and the CPU request already reserves capacity.

**Placement.** Pods are spread across zones (`ScheduleAnyway`, so a missing zone does not block scheduling), and the PDB keeps two of three pods up during node drains. `unhealthyPodEvictionPolicy: AlwaysAllow` stops a crash-looping pod from blocking a drain.

**Image.** The ECR reference is a placeholder (`111122223333` is the AWS documentation account ID). The deploy pipeline pins the image by digest with `kustomize edit set image`.

## Not included, and why

- **NetworkPolicy.** The source of the internal gateway (in-cluster or an internal load balancer) and the downstream reconciliation service's address are not defined. A guessed policy would either break traffic or be so broad that it only gives false assurance. Enforcing it also requires enabling network policy in the VPC CNI. This is the first follow-up once those are known.
- **Secrets.** The current app needs none. When the downstream client needs credentials, use AWS Secrets Manager with External Secrets or the Secrets Store CSI driver and IRSA, not Secrets committed to git.
- **Ingress / LoadBalancer.** The Service is ClusterIP. If the gateway runs outside the cluster, add an internal NLB/ALB through the AWS Load Balancer Controller (`scheme: internal`).
- **HPA.** There is no load data yet, so replicas stay at a fixed 3.
