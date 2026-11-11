# Demo: migrate from ingress-nginx to Envoy Gateway

This runbook shows the CloudBees-documented migration
[Migrate from Ingress to Gateway API](https://docs.cloudbees.com/docs/cloudbees-ci/latest/kubernetes-install-guide/gateway-api-migrate-ingress)
on the `eks/eksctl` path.

- **Before:** NLB (TLS ends on the NLB with the ACM cert) -> community ingress-nginx (plain HTTP) -> Ingress -> CJOC.
- **After:** ALB -> Envoy Gateway -> HTTPRoute -> CJOC. This is what `04-installEnvoy.sh` and `05-installCloudBees.sh` already build. They are not changed.

Why: community ingress-nginx is retired (no more security fixes), so moving to the Gateway API is the real-world reason. The before state is for demo use only.

## Quickstart

Run everything from `eks/eksctl` with `source .env` done (see [README.md](README.md#setup)).

**1. Build the before state**

```bash
./00-login.sh
./00-checkEnv.sh                    # read-only: .env, tools, AWS account, Route53 zone
./01-createCluster.sh
./03-installAwsLbController.sh      # needed for the NLB
./04-installNginx.sh                # ingress-nginx + NLB + ACM cert
./05-installCloudBeesNginx.sh       # CJOC with an nginx Ingress
./06-installExternalDNS.sh          # Route53 record -> NLB
```

If you use CasC (`CASC_ENABLED=true`), set `CASC_SCM_BUNDLE_PATH_CJOC=casc/cjoc-nginx` in `.env` first. The retriever reads the bundle from `CASC_SCM_REPO` / `CASC_SCM_BRANCH`, so that branch must contain `casc/cjoc-nginx`. Pushing it to your repository is your own step.

Keep `S3_LOGS_ENABLED`, `MCP_ENABLED` and `CHANNEL_PINGER_ENABLED` off. `05-installCloudBeesNginx.sh` refuses them, so the upgrade changes only the ingress values.

**2. Migrate**

```bash
./09-migrationPreflight.sh          # read-only checks; lower the DNS TTL; take a backup
./04-installEnvoy.sh                # Envoy Gateway, Gateway, ALB (reuses the ACM cert)
# .env: CASC_SCM_BUNDLE_PATH_CJOC=casc/cjoc   (CasC only; push the branch first)
./05-installCloudBees.sh            # the migration: helm upgrade of the same release
dig +short "$CJOC_HOST_NAME"        # must match the ALB; external-dns moves the record
# Drain, then reprovision every managed controller (CJOC UI or Cluster Operations)
./09-migrationCleanupIngress.sh     # back up, then delete leftover controller Ingresses
./04-deleteNginx.sh                 # remove ingress-nginx and the NLB
```

Run `04-installEnvoy.sh` before `05-installCloudBees.sh`. The existing `05` script waits for the Gateway address with `((RETRY_COUNT++))`, which aborts under `set -e` if the address is not there on the first check.

## What each new file does

| File | Purpose |
|---|---|
| `04-installNginx.sh` | ACM cert (reused if issued), ingress-nginx behind an internet-facing NLB. 443 = TLS on the NLB, 80 = redirect to https. |
| `04-deleteNginx.sh` | Uninstalls first and waits for the NLB, then deletes the namespace. `--delete-cert` is optional. |
| `casc/cjoc-nginx/` | Copy of `casc/cjoc`. Only `serviceExposure` differs: `ingress.ingressClass: nginx` instead of `gateway`. |
| `05-installCloudBeesNginx.sh` | Same Helm release name and values as `05-installCloudBees.sh`, with Ingress values instead of Gateway values and a 60 s external-dns TTL. |
| `09-migrationPreflight.sh` | Read-only prerequisites check from the CloudBees page. |
| `09-migrationCleanupIngress.sh` | Backs up and deletes leftover managed-controller Ingresses (only migrated ones, class nginx). |

The Helm release is named `cloudbees-core-envoy` on purpose. The unchanged `05-installCloudBees.sh` then upgrades this release: Helm removes the CJOC Ingress and creates the HTTPRoute.

New optional variables (defaults are inside the scripts, `.env-template` is not changed):

| Variable | Default |
|---|---|
| `INGRESS_NGINX_NAMESPACE` | `ingress-nginx` |
| `INGRESS_CLASS_NAME` | `nginx` |
| `INGRESS_NGINX_CHART_VERSION` | `4.15.1` (app 1.15.0) |

## Rollback

1. In `.env` set `CASC_SCM_BUNDLE_PATH_CJOC=casc/cjoc-nginx` (CasC only).
2. If you already ran `04-deleteNginx.sh`, run `./04-installNginx.sh` again.
3. Run `./05-installCloudBeesNginx.sh` (same release: the Gateway values go, the Ingress values return).
4. Point DNS back to the NLB. external-dns follows the Ingress; check with `dig`.
5. Deprovision, then reprovision all managed controllers. Each one creates an Ingress again.
6. Delete orphan routes: `kubectl delete httproute -l com.cloudbees.cje.type=master -n "$NAMESPACE_CLOUDBEES"`.

## Verification

**Before state**

```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'           # the NLB hostname
kubectl get ingress -n "$NAMESPACE_CLOUDBEES"                         # CJOC Ingress, class nginx
curl -I "https://$CJOC_HOST_NAME/cjoc/"                               # answers over https
curl -I "http://$CJOC_HOST_NAME/cjoc/"                                # 308 redirect to https
```

Also check: the NLB listener on 443 is TLS with the ACM cert (`aws elbv2 describe-listeners`), and Manage Jenkins shows no reverse proxy warning.

**Same release, only ingress keys change**

```bash
helm get values cloudbees-core-envoy -n "$NAMESPACE_CLOUDBEES" -o yaml > values-before.yaml
# ... after 05-installCloudBees.sh:
helm get values cloudbees-core-envoy -n "$NAMESPACE_CLOUDBEES" -o yaml > values-after.yaml
diff values-before.yaml values-after.yaml     # only Ingress and Gateway keys; do not commit these files
```

**After state** (CloudBees checks)

```bash
kubectl get httproute -n "$NAMESPACE_CLOUDBEES"
kubectl get gateway "$GATEWAY_NAME" -n "$NAMESPACE_CLOUDBEES" -o jsonpath='{.status.listeners[*].attachedRoutes}'   # > 0
dig +short "$CJOC_HOST_NAME"                                          # matches the ALB
kubectl get ingress -n "$NAMESPACE_CLOUDBEES" -l com.cloudbees.cje.type=master   # none left
```

Also check that controllers and WebSocket agents are reachable. After `04-deleteNginx.sh`, no NLB must remain (the script waits for it and warns if it stays).

## Teardown

`01-deleteCluster.sh` has no ingress-nginx step. Before it, run `./05-deleteCloudBees.sh` as usual and `./04-deleteNginx.sh --delete-cert` (or without `--delete-cert` if the Envoy ALB still uses the certificate). Otherwise the NLB can be orphaned and keep billing.

## Known limits and open points

These are not verified live yet:

1. **ingress-nginx is retired.** Demo only. The chart is pinned.
2. **`X-Forwarded-Proto`.** The NLB TLS listener sets no scheme header. `04-installNginx.sh` forces `https` and port `443` with `proxySetHeaders`. Whether this overrides nginx's own header is unverified. Check Manage Jenkins for the reverse proxy warning and for redirect loops.
3. **NLB idle timeout.** AWS documented a fixed 350 s idle timeout for TLS listeners when this was planned (the ALB path uses 4000 s). Check the current AWS docs. Idle long-poll, SSE or WebSocket connections may drop in the before state.
4. **Client IPs.** nginx sees NLB addresses, not client addresses. `use-forwarded-headers` is off on purpose: with a TLS listener on the NLB, clients could spoof `X-Forwarded-For`.
5. **DNS conflict window.** After `04-installEnvoy.sh`, the ALB Ingress `cjoc-alb` and the nginx controller Ingresses claim the same host for external-dns. The record may flap or stay on the NLB until the leftover Ingresses are gone. Fallback: set the record by hand with external-dns paused.
6. **Downtime** is part of the procedure: CJOC is unreachable until DNS moves, and controllers are unavailable until reprovisioned. Reprovision in place is valid because the host name does not change.
7. **CasC order differs slightly** from the CloudBees page: here the bundle path changes together with the Helm upgrade, not before it.
8. **Helm values.** `OperationsCenter.Ingress.Class`, `.Annotations` and `.tls.Enable` are not listed on the CloudBees migration page. Confirm them with `helm template cloudbees/cloudbees-core` before the first run. The same goes for the ingress-nginx values in `04-installNginx.sh` (`helm template ingress-nginx/ingress-nginx`).
9. **Preflight and cleanup assumptions.** Managed controllers are found by the label `com.cloudbees.cje.type=master`. The cleanup script assumes an HTTPRoute has the same name as its Ingress (use `--all` if not).
10. **`Common.image.tag=latest`** is mutable. Restarted pods may run a newer CloudBees CI than before. Do not combine the migration with a version upgrade.
