# Incident: intermittent 5xx after release

A new PayTrack API version was released to the internal EKS cluster at 10:05 WIB. Starting at 10:08 WIB, the internal gateway reported intermittent HTTP 5xx responses. Some requests still succeed.

## Observations

- `kubectl get pods` shows all three pods as `Running`.
- One pod restarted twice since the release.
- The Deployment rollout has not completed.
- The Service selector matches the Deployment pod labels.
- The readiness endpoint is `/ready`; the liveness endpoint is `/health`.
- The new application version performs a startup-time connection check to a downstream reconciliation service.
- No confirmed evidence yet indicates a cluster-wide network outage.
- The previous application image is still available.

## Sample events and logs

```text
10:07:41 Warning Unhealthy pod/paytrack-api-6b7c9d7f9c-x2m4p
Readiness probe failed: HTTP probe failed with statuscode: 503

10:07:53 Warning BackOff pod/paytrack-api-6b7c9d7f9c-x2m4p
Back-off restarting failed container

10:08:04 ERROR startup_check downstream reconciliation service unavailable
10:08:04 INFO  server startup aborted
```

## Candidate task

Use these clues to form and prioritize hypotheses. Do not assume that `Running` means a pod is ready to serve traffic. Explain what evidence you would collect next, how you would assess the blast radius, and when you would roll back.
