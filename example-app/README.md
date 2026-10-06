# example-app

A small Spring Boot 4 (Java 21) REST service used to exercise the platform:
health probes, Prometheus metrics, config from a ConfigMap, and endpoints that
deliberately fail or slow down so you can watch dashboards and alerts react.

| Endpoint | Port | Purpose |
|---|---|---|
| `GET /` | 8080 | app name, **version**, **commit** it was built from, environment, **pod name** (watch rollouts) |
| `GET /api/greeting?name=X` | 8080 | greeting text comes from config (`APP_GREETING`) |
| `GET /api/simulate-error` | 8080 | always HTTP 500 → triggers `ExampleAppHighErrorRate` |
| `GET /api/slow?ms=1500` | 8080 | delayed response (max 5000 ms) → moves latency graphs |
| `GET /livez`, `/readyz` | 8080 | simple health endpoints (handy for curl checks) |
| `GET /actuator/health/{liveness,readiness}` | 8081 | Kubernetes probes |
| `GET /actuator/prometheus` | 8081 | metrics scraped by Prometheus |

Actuator lives on port 8081, which the gateway never routes to, so metrics
and health internals aren't public.

**In the cluster** every pod also runs an Istio **Envoy sidecar**. Traffic
arrives only from the Istio ingress gateway, over mutual TLS
(`k8s/virtualservice.yaml`), and `k8s/authorizationpolicy.yaml` refuses every
other caller. Port 8081 bypasses the sidecar, so probes and Prometheus reach
it directly.

## Build and run locally

```bash
docker build -t example-app:dev .     # compiles, runs the tests, builds the image
docker run --rm -p 8080:8080 -p 8081:8081 -e APP_GREETING=Howdy example-app:dev
curl localhost:8080/api/greeting?name=you
curl -s localhost:8081/actuator/prometheus | grep http_server_requests
```

With Java 21 + Maven installed you can also run `mvn test` / `mvn spring-boot:run`.

## Deploying

Open a pull request that changes this folder. `.github/workflows/ci-cd.yml`
builds, tests and scans it with SonarQube Cloud (quality gate). When you
merge, the pipeline:

1. builds the image and pushes it to ECR as `example-app:<short-commit-sha>`;
2. sets `newTag` in `k8s/kustomization.yaml` and commits that to `main`;
3. ArgoCD sees the commit and performs a zero-downtime rolling update.

`curl http://<alb>/` then reports the new `commit`. Changes to `k8s/` only
(config, replicas) skip the pipeline: ArgoCD applies them directly.
To roll back, `git revert` the bot's `deploy(example-app): …` commit.

Manual equivalent and walkthrough: `docs/DEPLOYMENT-GUIDE.md` Phases 5, 9-B and 10.
