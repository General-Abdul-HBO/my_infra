# example-app

A small Spring Boot 4 (Java 21) REST service used to exercise the platform:
health probes, Prometheus metrics, config from a ConfigMap, and endpoints that
deliberately fail or slow down so you can watch dashboards and alerts react.

| Endpoint | Port | Purpose |
|---|---|---|
| `GET /` | 8080 | app name, **version**, environment, **pod name** (watch rollouts) |
| `GET /api/greeting?name=X` | 8080 | greeting text comes from config (`APP_GREETING`) |
| `GET /api/simulate-error` | 8080 | always HTTP 500 → triggers `ExampleAppHighErrorRate` |
| `GET /api/slow?ms=1500` | 8080 | delayed response (max 5000 ms) → moves latency graphs |
| `GET /livez`, `/readyz` | 8080 | health for the ALB |
| `GET /actuator/health/{liveness,readiness}` | 8081 | Kubernetes probes |
| `GET /actuator/prometheus` | 8081 | metrics scraped by Prometheus |

Actuator lives on port 8081, which the load balancer never routes to, so
metrics and health internals aren't public.

## Build and run locally

```bash
docker build -t example-app:dev .     # compiles, runs the tests, builds the image
docker run --rm -p 8080:8080 -p 8081:8081 -e APP_GREETING=Howdy example-app:dev
curl localhost:8080/api/greeting?name=you
curl -s localhost:8081/actuator/prometheus | grep http_server_requests
```

With Java 21 + Maven installed you can also run `mvn test` / `mvn spring-boot:run`.

## Deploying

Nothing here is applied by hand. ArgoCD watches `k8s/` in Git:

1. Build and push a new image tag to ECR (tags are immutable — every build needs a new one).
2. Change `newTag` in `k8s/kustomization.yaml`, commit, push.
3. ArgoCD sees the commit and performs a zero-downtime rolling update.

See `docs/DEPLOYMENT-GUIDE.md` phases 5–9. Phase 10 prepares the CI/CD
pipeline (GitHub Actions + SonarQube Cloud) that will automate these steps.
