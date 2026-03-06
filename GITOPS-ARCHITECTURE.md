# GitOps Architecture & Service Connectivity

A GitOps-based deployment of the e-commerce microservices platform using **ArgoCD + Kustomize** on Kubernetes.

---

## Repository Structure

```
GitOps/
├── argocd-app.yaml              # 14 ArgoCD Application manifests
├── kustomization.yaml           # Root Kustomize config
│
├── base/                        # Base Kubernetes manifests (all environments)
│   ├── adservice/
│   ├── authservice/
│   ├── cartservice/             # Includes redis-cart deployment
│   ├── checkoutservice/
│   ├── currencyservice/
│   ├── emailservice/
│   ├── frontend/
│   ├── loadgenerator/
│   ├── paymentservice/
│   ├── postgres/
│   ├── productcatalogservice/
│   ├── recommendationservice/
│   ├── shippingservice/
│   └── shoppingassistantservice/
│
└── overlays/
    ├── microk8s/                # Single-node dev environment
    └── eks/                    # AWS EKS production environment
```

---

## GitOps Flow

```
Developer pushes code
        |
        v
 GitHub Repo (ITkannadigaru/GitOps) [branch: main]
        |
        v (watches & auto-syncs)
     ArgoCD
        |
        v
 Kubernetes Cluster (default namespace)
        |
        ├── Creates/Updates/Prunes resources automatically
        └── Self-heals if cluster drifts from Git state
```

**ArgoCD Settings:**
- Auto-sync: enabled
- Prune: `true` — removes resources deleted from Git
- Self-heal: `true` — reverts manual cluster changes
- CreateNamespace: `true` — auto-creates namespaces

---

## All Services — Ports & Images

| Service | Image | Container Port | Service Port | Type |
|---|---|---|---|---|
| frontend | manojkrishnappa/frontend:**2** | 8080 | 80 (ClusterIP) / 80 (LoadBalancer) | HTTP |
| authservice | manojkrishnappa/authservice:1 | 8081 | 8081 | HTTP |
| productcatalogservice | manojkrishnappa/productcatalogservice:1 | 3550 | 3550 | gRPC |
| cartservice | manojkrishnappa/cartservice:1 | 7070 | 7070 | gRPC |
| redis-cart | redis:alpine | 6379 | 6379 | Redis |
| checkoutservice | manojkrishnappa/checkoutservice:1 | 5050 | 5050 | gRPC |
| paymentservice | manojkrishnappa/paymentservice:1 | 50051 | 50051 | gRPC |
| currencyservice | manojkrishnappa/currencyservice:1 | 7000 | 7000 | gRPC |
| shippingservice | manojkrishnappa/shippingservice:1 | 50051 | 50051 | gRPC |
| emailservice | manojkrishnappa/emailservice:1 | 8080 | **5000** | gRPC |
| recommendationservice | manojkrishnappa/recommendationservice:1 | 8080 | 8080 | gRPC |
| adservice | manojkrishnappa/adservice:1 | 9555 | 9555 | gRPC |
| shoppingassistantservice | manojkrishnappa/shoppingassistantservice:1 | 8080 | 80 | HTTP |
| loadgenerator | manojkrishnappa/loadgenerator:1 | — | — | None |
| postgres | postgres:16-alpine | 5432 | 5432 | SQL |

> **Note:** emailservice has a port mismatch — container listens on `8080`, but the Kubernetes Service exposes `5000`. CheckoutService connects to `emailservice:5000`.

---

## How Services Are Connected (Environment Variables)

The services find each other using Kubernetes DNS names injected as environment variables.

### Frontend → Backend Services
```yaml
PRODUCT_CATALOG_SERVICE_ADDR:    "productcatalogservice:3550"
CURRENCY_SERVICE_ADDR:           "currencyservice:7000"
CART_SERVICE_ADDR:               "cartservice:7070"
RECOMMENDATION_SERVICE_ADDR:     "recommendationservice:8080"
SHIPPING_SERVICE_ADDR:           "shippingservice:50051"
CHECKOUT_SERVICE_ADDR:           "checkoutservice:5050"
AD_SERVICE_ADDR:                 "adservice:9555"
SHOPPING_ASSISTANT_SERVICE_ADDR: "shoppingassistantservice:80"
AUTH_SERVICE_ADDR:               "authservice:8081"
```

### CheckoutService → Downstream Services
```yaml
PRODUCT_CATALOG_SERVICE_ADDR: "productcatalogservice:3550"
SHIPPING_SERVICE_ADDR:        "shippingservice:50051"
PAYMENT_SERVICE_ADDR:         "paymentservice:50051"
EMAIL_SERVICE_ADDR:           "emailservice:5000"
CURRENCY_SERVICE_ADDR:        "currencyservice:7000"
CART_SERVICE_ADDR:            "cartservice:7070"
```

### RecommendationService → ProductCatalog
```yaml
PRODUCT_CATALOG_SERVICE_ADDR: "productcatalogservice:3550"
```

### CartService → Redis
```yaml
REDIS_ADDR: "redis-cart:6379"
```

### LoadGenerator → Frontend
```yaml
FRONTEND_ADDR: "frontend:80"   # Init container + main container
USERS:         "10"
RATE:          "1"
```

### AuthService → Postgres
```yaml
# Connection built from secret:
POSTGRES_DB:       "authdb"
POSTGRES_USER:     "authuser"
POSTGRES_PASSWORD: (from secret: postgres-secret/password)
```

### ShoppingAssistantService → GCP
```yaml
GOOGLE_API_KEY:        GOOGLE_API_KEY_VAL
PROJECT_ID:            PROJECT_ID_VAL
REGION:                REGION_VAL
ALLOYDB_CLUSTER_NAME:  ALLOYDB_CLUSTER_NAME_VAL
ALLOYDB_INSTANCE_NAME: ALLOYDB_INSTANCE_NAME_VAL
ALLOYDB_DATABASE_NAME: ALLOYDB_DATABASE_NAME_VAL
ALLOYDB_TABLE_NAME:    ALLOYDB_TABLE_NAME_VAL
ALLOYDB_SECRET_NAME:   ALLOYDB_SECRET_NAME_VAL
```

---

## Full Service Dependency Map

```
                    [ External User ]
                           |
                    LoadBalancer :80
                           |
                    ┌──────▼──────┐
                    │   Frontend   │ :8080
                    └──────┬───────┘
          ┌─────────┬───────┼────────┬──────────┬──────────┐
          │         │       │        │          │          │
          ▼         ▼       ▼        ▼          ▼          ▼
  Product     Currency    Cart    Recommend  Shipping   AdService
  Catalog      :7000     :7070    :8080       :50051     :9555
  :3550                    |         |
                           |         └──> ProductCatalog :3550
                           ▼
                       redis-cart
                          :6379
          │
          ▼
     Checkout :5050
       ├──> ProductCatalog :3550
       ├──> Currency :7000
       ├──> Cart :7070
       ├──> Shipping :50051
       ├──> Payment :50051
       └──> Email :5000 (container: 8080)
          │
          ▼
      AuthService :8081
          │
          ▼
       Postgres :5432 (authdb)

     ShoppingAssistant :80
          │
          └──> Google Gemini API (external)
          └──> AlloyDB (GCP, external)

     LoadGenerator
          │
          └──> frontend:80 (waits via init container, then load tests)
```

---

## Kustomize Overlay Strategy

### Base (`base/`)
Defines all raw Kubernetes manifests — Deployments, Services, ServiceAccounts.
All environment-specific customizations live in overlays.

### MicroK8s Overlay (`overlays/microk8s/`)
For local single-node development.

```yaml
Namespace:  default
All replicas: 1
Image tags: all :1 (frontend :2)
Labels: environment=microk8s
```

### EKS Overlay (`overlays/eks/`) — Production Ready
Commented patches available to activate for AWS production:

```yaml
Namespace:  itkannadigaru (uncomment to activate)
Replicas:   2 for key services (scale-out)
Labels:     environment=eks

Patches available (currently commented out):
  - AWS NLB LoadBalancer annotations for frontend
  - IRSA (IAM Roles for Service Accounts) annotations
  - Increased CPU/memory resource limits
  - Replica scaling for high availability
```

---

## ArgoCD Applications

Each service has its own ArgoCD `Application` resource pointing to its directory in this repo.

| ArgoCD App | Source Path | Namespace |
|---|---|---|
| adservice | base/adservice | default |
| authservice | base/authservice | default |
| cartservice | base/cartservice | default |
| checkoutservice | base/checkoutservice | default |
| currencyservice | base/currencyservice | default |
| emailservice | base/emailservice | default |
| frontend | base/frontend | default |
| loadgenerator | base/loadgenerator | default |
| paymentservice | base/paymentservice | default |
| postgres | base/postgres | default |
| productcatalogservice | base/productcatalogservice | default |
| recommendationservice | base/recommendationservice | default |
| shippingservice | base/shippingservice | default |
| shoppingassistantservice | base/shoppingassistantservice | default |

All apps point to: `https://github.com/ITkannadigaru/GitOps.git` on branch `main`

---

## Secrets — Manual Setup Required

Before deploying, these secrets must be created manually in the cluster:

```bash
# Postgres credentials (used by postgres deployment and authservice)
kubectl create secret generic postgres-secret \
  --from-literal=password=<your-password> \
  -n default

# JWT secret for authservice
kubectl create secret generic authservice-secret \
  --from-literal=jwt-secret=<your-jwt-secret> \
  -n default
```

> ShoppingAssistantService also needs `GOOGLE_API_KEY` and AlloyDB credentials, but it is **disabled by default** (`replicas: 0`).

---

## Security Configuration

All service pods run with hardened security contexts:

```yaml
Pod level:
  runAsNonRoot:     true
  runAsUser:        1000
  runAsGroup:       1000
  fsGroup:          1000

Container level:
  allowPrivilegeEscalation: false
  privileged:               false
  readOnlyRootFilesystem:   true   # (except shoppingassistantservice)
  capabilities.drop:        [ALL]
```

---

## Resource Allocation

| Service | CPU Request | CPU Limit | Mem Request | Mem Limit |
|---|---|---|---|---|
| frontend | 100m | 200m | 64Mi | 128Mi |
| authservice | 50m | 100m | 64Mi | 128Mi |
| cartservice | 200m | 300m | 64Mi | 128Mi |
| redis-cart | 70m | 125m | 200Mi | 256Mi |
| checkoutservice | 100m | 200m | 64Mi | 128Mi |
| adservice | 200m | 300m | 180Mi | 300Mi |
| recommendationservice | 100m | 200m | 220Mi | 450Mi |
| loadgenerator | 300m | 500m | 256Mi | 512Mi |
| shoppingassistantservice | 100m | 500m | 256Mi | 512Mi |
| postgres | 100m | 250m | 128Mi | 256Mi |

---

## Notable Findings

| Item | Detail |
|---|---|
| ShoppingAssistant is OFF | `replicas: 0` — needs GCP credentials to enable |
| Email port mismatch | Container: 8080 → Service: 5000. CheckoutService uses `emailservice:5000` |
| Redis is ephemeral | Uses `emptyDir` — cart data is lost on pod restart |
| Postgres is ephemeral | Uses `emptyDir` — user data is lost on pod restart |
| Istio-ready | Frontend & LoadGenerator have `sidecar.istio.io/rewriteAppHTTPProbers: "true"` |
| LoadGenerator init | Waits 12× (10s each) for frontend to be ready before sending traffic |
| Image registry | All images on Docker Hub under `manojkrishnappa/` |
| Frontend has 2 versions | All services tag `:1`, frontend is tag `:2` |
