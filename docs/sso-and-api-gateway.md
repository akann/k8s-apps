# SSO & API Gateway: Authentik and Kong

Two different problems, two different tools: Authentik handles "is this a logged-in human," Kong handles "is this an authorized machine caller." Most services in the cluster use exactly one of these patterns, not both.

## Authentik: forward-auth for browser-facing apps

Authentik (`authentik.yanatech.co.uk`) is the cluster's SSO provider. Rather than every app implementing its own OIDC client, most browser-facing internal tools (the ones that don't ship native OIDC support) sit behind Authentik's **forward-auth** pattern, using ingress-nginx's `auth-url`/`auth-signin` mechanism:

1. Create an Authentik provider of type "Proxy, Forward auth (single application)".
2. Create the corresponding Authentik application — this auto-deploys a dedicated `ak-outpost-<name>` pod in the `authentik` namespace, one per protected app.
3. Create an `ExternalName` Service in the app's own namespace pointing at that outpost.
4. Add an Ingress path routing `/outpost.goauthentik.io` on the app's hostname to the outpost.
5. Annotate the app's main Ingress so nginx delegates the auth decision to the outpost before proxying the real request:

```yaml
nginx.ingress.kubernetes.io/auth-url: "https://<hostname>/outpost.goauthentik.io/auth/nginx"
nginx.ingress.kubernetes.io/auth-signin: "https://<hostname>/outpost.goauthentik.io/start?rd=$escaped_request_uri"
nginx.ingress.kubernetes.io/auth-response-headers: "Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid"
```

The `auth-url` has to be the app's *external* hostname, not an internal service URL — the outpost matches incoming auth checks by the external host it was configured for, so pointing it at an internal address breaks the flow in a way that isn't obvious from the error alone. Getting the `auth-snippet` annotation (used to forward the original request URL through to the app) working also requires ingress-nginx's controller to have `allowSnippetAnnotations` and a `Critical` annotations risk level enabled — the safer default blocks that annotation outright.

## Kong: gateway for service-to-service and external API calls

Kong (`api-gateway.yanatech.co.uk`) runs in DB-less mode — routes are declared directly as Kubernetes `Ingress` objects with `ingressClassName: kong` (or `KongIngress` CRDs) rather than configured through an admin API or database, which also means there's no admin UI in this setup. Kong fronts machine-to-machine traffic: internal microservice APIs and webhook-style endpoints that need caller authentication but aren't a human logging into a browser session.

Two authentication patterns sit behind Kong depending on the caller:

- **API-key auth** for simple service-to-service calls — for example, the shared email-sending API is only reachable through Kong, gated by a `key-auth` plugin, with a plain `NetworkPolicy` also restricting direct access to its ClusterIP to the `kong` namespace only, so a caller can't bypass the key check by hitting the pod directly.
- **JWT auth** for yana-stocks' own auth flow, via a `KongConsumer` and JWT plugin.

### The webhook timeout gotcha

Kong's own validating webhook (`kong-controller-kong-validations`) ships with a 10-second timeout on each of its three hooks. Combined with Cilium's native routing mode, the kube-apiserver's call to that webhook takes close to the full 10 seconds each time — which was enough to break unrelated operators waiting on their own webhook calls to complete within a shorter budget:

| Hook | What it intercepts | What it broke at 10s |
|---|---|---|
| `secrets.credentials.validation.*` | All Secret objects, cluster-wide | cert-manager's TLS secret writes (`context deadline exceeded` after two sequential 10s calls) |
| `secrets.plugins.validation.*` | All Secret objects, cluster-wide | same class of failure |
| `services.validation.*` | All Service create/update | the Kafka operator's own Kubernetes client timing out |

All three were patched down to a 5-second timeout, with an `ignoreDifferences` entry so ArgoCD doesn't revert the patch on the next sync. The timeout can't be safely raised back to 10s without reintroducing both failure modes.

## Why two patterns instead of one

Forward-auth through Authentik assumes a browser that can follow redirects and hold a session cookie — it's the right fit for admin dashboards and internal tools a human clicks into. It's the wrong fit for a service calling another service's API, which is why those paths go through Kong's key-auth or JWT plugins instead: a machine caller authenticates with a credential on every request rather than establishing a browser session.
