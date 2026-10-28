# Diagnosis: intermittent 5xx after release

Based only on `incident.md`. Each point is marked as **fact** (stated in the artifact), **inference** (follows from facts), or **to verify**.

## Timeline

| Time (WIB) | Event | Reading |
|---|---|---|
| 10:05 | New version released | Rollout starts |
| 10:07:41 | `x2m4p`: readiness probe returns **503** | The server process is up but reports not ready (it is still in its startup check) |
| 10:07:53 | `x2m4p`: `BackOff restarting failed container` | The container has already exited at least once |
| 10:08 | Gateway starts reporting intermittent 5xx | About 3 minutes after release, right after the probe failures |
| 10:08:04 | `startup_check downstream reconciliation service unavailable` → `server startup aborted` | The process exits by itself, then restarts; this fits "restarted twice" |

The logs at 10:08:04 have no pod name. I assume they come from `x2m4p` (to verify: `kubectl logs --previous`).

## 1. Leading hypothesis and evidence

**Hypothesis:** the new version made the downstream reconciliation service a hard startup dependency, and the new pods cannot reach it. Each new pod starts, fails the check, aborts and is restarted. It is `Running` (the kubelet restarts the container in place) but never `Ready`, so the rollout cannot finish and the cluster serves from a reduced, mixed set of pods.

Evidence:
- **Fact:** the app's own log says the startup check failed and startup was aborted. This is a deliberate exit, not a crash, OOM or probe kill.
- **Fact:** the readiness probe returned 503 rather than timing out. The process was listening, so port, probe path and pod networking to the pod all work.
- **Fact:** BackOff, two restarts, and a rollout that hasn't completed: the new ReplicaSet never becomes available.
- **Fact:** the selector matches and there is no sign of a cluster-wide network fault, so a Service misconfiguration or a cluster outage is unlikely.
- **Inference:** "all three pods Running" during an incomplete rollout implies no surge pod. With `maxUnavailable: 0, maxSurge: 1` there would be 4 pods. That suggests an old pod was removed before its replacement was Ready, leaving 2 serving pods (to verify: the Deployment strategy).

**What the evidence does not yet settle is where the user-facing 5xx come from.** A not-Ready pod is removed from the Service endpoints, so the crash-looping pod should not receive traffic. Ranked candidates:

| # | Candidate | Fits because | Rule in/out with |
|---|---|---|---|
| H1 | **Downstream is degraded for every pod.** Old pods fail the requests that call it, and other requests succeed. | "Some requests succeed" (some fail by endpoint); the downstream error and the start of the 5xx are in the same minute | Old-pod logs for downstream errors; 5xx broken down by path; downstream's own health |
| H2 | **Lost capacity.** 2 old pods carry the full load and return 503/504 when saturated | 3 pods during an incomplete rollout | Deployment strategy; per-pod latency and CPU; 5xx are mostly 503/504 spread across paths |
| H3 | **Traffic reaches pods that aren't Ready or are terminating** (gateway targets pod IPs, or an old pod was killed without draining) | Errors start when pods start churning | 5xx by upstream IP mapped to pods; 502 resets clustered at restart and termination times |

H1 also decides the rollback outcome: rolling back fixes the crash loop and capacity, but not a downstream outage.

## 2. Next checks

Capture evidence first: rolling back deletes the failing pods and their logs.

```sh
NS=paytrack; APP=app.kubernetes.io/name=paytrack-api; POD=paytrack-api-6b7c9d7f9c-x2m4p

# Rollout state: which version is serving, and is a pod missing?
kubectl -n $NS rollout status deploy/paytrack-api --timeout=10s
kubectl -n $NS get deploy paytrack-api -o jsonpath='{.spec.strategy}{"\n"}'
kubectl -n $NS get rs -l $APP -o wide          # old vs new image, desired/ready
kubectl -n $NS get pods -l $APP -o wide        # READY column, restarts, node, hash
kubectl -n $NS rollout history deploy/paytrack-api   # what changed: image, env, config

# The failing pod
kubectl -n $NS describe pod $POD               # Last State: reason + exit code; probe config
kubectl -n $NS logs $POD --previous            # logs of the crashed container
kubectl -n $NS get events --sort-by=.lastTimestamp

# Is the failing pod out of the Service? Which IPs actually receive traffic?
kubectl -n $NS get endpointslices -l kubernetes.io/service-name=paytrack-api -o yaml

# Config the new version uses vs the old one (URL, port, credentials)
kubectl -n $NS get rs <new-rs> -o jsonpath='{.spec.template.spec.containers[0].env}'

# Downstream reachability (DNS + TCP) from an OLD, running pod; the image already has Python
kubectl -n $NS exec <old-pod> -- python -c \
  'import socket,sys; h,p=sys.argv[1],int(sys.argv[2]); print(socket.getaddrinfo(h,p)[0][4]); socket.create_connection((h,p),3); print("tcp ok")' \
  <downstream-host> <port>
```

Outside the cluster:
- Gateway logs for 10:00–now: 5xx rate, split by status code (502/503/504), path and upstream IP.
- The downstream service's dashboard and its owner team.
- CloudTrail for security group or NetworkPolicy changes around 10:05.

## 3. Telling the failure classes apart

| Class | What you would see | In this incident |
|---|---|---|
| **Application** | Container exits non-zero with an app error in the logs; same failure on every restart; old version healthy on the same nodes | **Yes:** `server startup aborted` |
| **Readiness** | Running, not Ready, few or no restarts; `/ready` fails, but `kubectl port-forward` + `curl` shows the app serving; often a wrong path, port or too-short timeout | Partly. The 503 is real app output, so the probe works; the app reports not ready |
| **Resource** | `Last State: OOMKilled` (exit 137), Pending (`Insufficient cpu/memory`), evictions, CPU throttling, probe *timeouts* under load | No evidence yet; confirm the exit code in `describe` |
| **Networking** | From inside the pod: DNS NXDOMAIN or timeout, TCP connect timeout or refused, TLS errors; CNI IP exhaustion (`failed to assign an IP address`) | Possible *underneath* the app error: "unavailable" could be DNS, a policy, a security group or a real outage |

The deciding test for networking versus application: from an old, running pod, run the DNS and TCP check against **both** the address the old version uses and the address the new version is configured with.
- Both fail: the downstream is down or the network path is broken (H1); this is not a release bug.
- Only the new address fails: the new version's config is the cause (wrong host or port), or a policy blocks it.
- Both succeed: the network is fine, and the new version's startup check is the cause (credentials or CA, a timeout that is too short, or the wrong endpoint).

## 4. When to roll back

Roll back when all of these hold:
- the errors began with the release,
- the previous version is known good and still available,
- no fix can be shipped within a short window (about 15 minutes),
- and rollback is safe for data.

In this incident:
- The first three already hold: 5xx within 3 minutes, a stuck rollout, and the previous image still available.
- **Check first:** did the new release run a schema or data migration? A forward-only migration in a payment-reconciliation system can make the old version unsafe; in that case roll forward or hold.
- **Then:** capture the evidence from section 2 (about 2 minutes), and roll back through the pipeline (revert to the previous image digest) so git stays the source of truth. `kubectl -n paytrack rollout undo deploy/paytrack-api` is the emergency path.
- **Confirm:** `rollout status` completes, all 3 pods are Ready, and the gateway 5xx rate returns to baseline.
- **If the 5xx continue after rollback:** that confirms H1. Escalate to the downstream owners; the rollback still removed the crash loop and restored capacity.

Blast radius to assess alongside:
- Which paths fail and what share of requests.
- Whether the errors are internal only (ops staff and any automated reconciliation jobs).
- Whether failed reconciliation requests left partial writes or are safe to retry (idempotency).
- Whether the same downstream also serves other consumers.

## 5. Preventive improvements (highest value first)

1. **Don't hard-fail startup on a downstream.** Start, report not-Ready through `/ready` while a *required* dependency is down, and recover automatically. Keep `/health` (liveness) process-only, so a downstream outage never restarts pods. If only some endpoints need the downstream, return 503 on those paths only rather than taking the whole pod out.
2. **Rollouts that cannot remove capacity.** `maxUnavailable: 0`, `maxSurge: 1`, `minReadySeconds` and `progressDeadlineSeconds: 300`, as implemented in `k8s/deployment.yaml`. A version that never becomes Ready then stalls harmlessly and is reported as `ProgressDeadlineExceeded`.
3. **Verify every deploy, and roll back automatically.** The deploy job runs `kubectl rollout status --timeout=5m` and runs `rollout undo` on failure. Canary analysis (e.g. Argo Rollouts) can come later if needed.
4. **Alert before users report.** Alert on the gateway 5xx rate per service, `CrashLoopBackOff`, a Deployment whose `Progressing` condition is false, and readiness-failure rate. Add deploy markers on dashboards so a release and an error spike line up at a glance.
5. **Test dependency config before production.** Run a staging smoke test that the new build reaches the downstream with its new config, and review config diffs (URLs, ports, secrets) in the PR alongside the image change.
