# MISSION: K8s Agent Implementation for Infrastructure Pipeline

> **Save Location**: `C:\Users\Lenovo i7\Desktop\my_personal_projects\devops-agent-k8s-demo-master\MISSION_K8S_AGENT.md`

---

## Executive Summary

**Objective**: Extend the AWS Infrastructure Agent pipeline (Steps 1-6) to automatically generate Kubernetes manifests (Steps 7-8) that deploy applications on the provisioned infrastructure.

**Problem Statement**: Currently, after Terraform creates AWS infrastructure (VPC, RDS, ElastiCache, S3, ECR, EKS), there's a manual gap before K8s manifests can be deployed. This mission bridges that gap by:
1. Collecting Terraform outputs into structured context (Step 7)
2. Generating K8s manifests using a ReAct agent with templates (Step 8)

**Reference Implementation**: The target output structure is based on:
- `C:\Users\Lenovo i7\Desktop\my_personal_projects\devops-agent-k8s-demo-master`

**Source Code Location**:
- `C:\Users\Lenovo i7\Desktop\my_personal_projects\AWS-infra-agent-on-vm\python\`

---

## Final Architecture (User Confirmed)

### NEW Pipeline (Steps 1-8)
```
Step 1: VPC           → Networking foundation
Step 2: RDS           → PostgreSQL database
Step 3: ElastiCache   → Redis caching
Step 4: S3            → Object storage
Step 5: ECR           → Container registries (21 repos)
Step 5.5: ECR Push    → Test image push
Step 6: EKS + VPC Endpoints → Kubernetes cluster + private AWS access (MERGED)
Step 7: Context Bridge → Collect Terraform outputs → structured K8s context (NEW)
Step 8: K8s Generation → Generate K8s manifests via K8s ReAct Agent (NEW)
```

### Key Design Decisions (User Confirmed)
1. **Step 6**: Merge VPC Endpoints into EKS step
2. **Step 7**: Pure "Context Bridge" - no infrastructure, only output collection
3. **Step 8**: K8s ReAct Agent with BFS-style file generation
4. **Documentation**: Generated BEFORE manifests (as reasoning/planning)
5. **Templates**: Generic templates, LLM fills parameters from context
6. **Tools**: One tool per K8s resource type (~15 tools)
7. **Complex files**: Agent reasons in plan, then generates custom content
8. **Code location**: `agents/modular/k8s_agent/`

---

## The Critical Relationship (Terraform → K8s)

### Terraform Outputs Needed by K8s Manifests

| Terraform Resource | Output | K8s Manifest Usage |
|-------------------|--------|-------------------|
| **EKS (Step 6)** | cluster_name: `demo-pre-prod-cluster` | ArgoCD target, kubectl context |
| **EKS (Step 6)** | oidc_provider_arn | IRSA ServiceAccount annotations |
| **ECR (Step 5)** | repository_urls (21 repos) | Deployment image specs |
| **RDS (Step 2)** | endpoint: `demo-pre-prod-postgres.xxx.rds.amazonaws.com` | `database-config` ConfigMap |
| **RDS (Step 2)** | secret_arn | ExternalSecret reference |
| **ElastiCache (Step 3)** | primary_endpoint | `redis-config` ConfigMap |
| **ElastiCache (Step 3)** | secret_arn | ExternalSecret reference |
| **S3 (Step 4)** | bucket_name: `demo-replica-agent-images-pre-prod` | `image-processor` env vars |
| **S3 (Step 4)** | iam_policy_arn | IRSA role attachment |
| **VPC (Step 1)** | vpc_id, private_subnet_ids | Reference only (EKS uses these) |

### K8s Files That Reference Terraform Outputs

```
base/kustomization.yaml:81-123         → ECR image URLs (21 images)
base/configmaps/database-config.yaml   → RDS endpoint, port, dbname
base/configmaps/redis-config.yaml      → ElastiCache endpoint, port
base/rbac/service-accounts.yaml        → IRSA role ARNs (annotations)
base/secrets/external-secrets.yaml     → Secrets Manager secret names
infrastructure/argocd/secret-store.yaml → AWS region, Secrets Manager
overlays/*/kustomization.yaml          → Environment-specific overrides
```

---

## Proposed Step 7 Enhancement: "Infrastructure Context Bridge"

### Step 7 Should Generate

#### 1. **Terraform Outputs Summary Document**
```yaml
# outputs-summary.yaml
project_name: demo-replica-agent
environment: pre-prod
region: us-east-1
aws_account_id: 852140462703

networking:
  vpc_id: vpc-xxx
  vpc_cidr: 10.0.0.0/16
  private_subnet_ids: [subnet-xxx, subnet-yyy]

database:
  identifier: demo-replica-agent-pre-prod-postgres
  endpoint: demo-replica-agent-pre-prod-postgres.xxx.rds.amazonaws.com
  port: 5432
  database_name: appdb
  secret_name: demo-replica-agent/pre-prod/database

cache:
  replication_group_id: demo-replica-agent-pre-prod-redis
  primary_endpoint: demo-replica-agent-pre-prod-redis.xxx.cache.amazonaws.com
  port: 6379
  secret_name: demo-replica-agent/pre-prod/redis

storage:
  bucket_name: demo-replica-agent-images-pre-prod
  bucket_arn: arn:aws:s3:::demo-replica-agent-images-pre-prod
  iam_policy_arn: arn:aws:iam::852140462703:policy/demo-replica-agent-images-pre-prod-access-policy

container_registry:
  ecr_base_url: 852140462703.dkr.ecr.us-east-1.amazonaws.com
  repositories:
    frontend: [web-ui, admin-dashboard]
    backend: [api-gateway, auth-service, user-service, product-service, order-service, payment-service, notification-service]
    processing: [event-processor, analytics-service, report-generator, data-aggregator, image-processor]
    infrastructure: [db-proxy, cache-manager, config-service, metrics-collector, queue-monitor, health-checker]

kubernetes:
  cluster_name: demo-replica-agent-pre-prod-cluster
  cluster_endpoint: https://xxx.eks.us-east-1.amazonaws.com
  oidc_provider_arn: arn:aws:iam::852140462703:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/xxx
  oidc_issuer_url: https://oidc.eks.us-east-1.amazonaws.com/id/xxx
```

#### 2. **K8s Generation Plan Document**
```yaml
# k8s-generation-plan.yaml
generation_order:
  level_0:
    type: documentation
    items: [README.md]

  level_1:
    type: directories
    items: [base/, infrastructure/, overlays/, iam/, argocd-apps/]

  level_2a:
    type: namespace_rbac
    order: sequential
    items:
      - base/namespace/namespace.yaml
      - base/rbac/service-accounts.yaml  # Needs OIDC ARN for IRSA
      - base/rbac/roles.yaml
      - base/rbac/role-bindings.yaml

  level_2b:
    type: infrastructure
    items:
      - infrastructure/external-secrets/
      - infrastructure/aws-load-balancer-controller/
      - infrastructure/argocd/

  level_2c:
    type: configuration
    items:
      - base/secrets/external-secrets.yaml  # Needs secret names
      - base/configmaps/database-config.yaml  # Needs RDS endpoint
      - base/configmaps/redis-config.yaml     # Needs ElastiCache endpoint
      - base/configmaps/common-config.yaml

  level_3:
    type: networking
    items:
      - base/services/services.yaml
      - base/networkpolicies/network-policies.yaml

  level_4:
    type: deployments
    parallel_groups:
      frontend: [web-ui, admin-dashboard]  # Needs ECR URLs
      gateway: [api-gateway]
      backend: [auth-service, user-service, product-service, order-service, payment-service, notification-service]
      processing: [event-processor, analytics-service, report-generator, data-aggregator, image-processor]
      infrastructure: [db-proxy, cache-manager, config-service, metrics-collector, queue-monitor, health-checker]

  level_5:
    type: advanced
    order: sequential
    items:
      - base/ingress/ingress-no-domain.yaml
      - base/hpa/hpa.yaml
      - base/pdb/pdb.yaml

  level_6:
    type: overlays
    items:
      - overlays/dev-no-domain/
      - overlays/production/

service_inventory:
  total_services: 20
  services:
    - name: web-ui
      port: 3000
      tier: frontend
      service_account: frontend-sa
      ecr_repo: demo-replica-agent-web-ui

    # ... (all 20 services)
```

#### 3. **Template Variables File**
```yaml
# template-variables.yaml
# Computed values for Jinja2 templates in Step 8

namespace: devops-agent-demo
environment: pre-prod
project_name: demo-replica-agent

images:
  web_ui: 852140462703.dkr.ecr.us-east-1.amazonaws.com/demo-replica-agent-web-ui:latest
  admin_dashboard: 852140462703.dkr.ecr.us-east-1.amazonaws.com/demo-replica-agent-admin-dashboard:latest
  # ... all 20 images

config_values:
  database_host: demo-replica-agent-pre-prod-postgres.xxx.rds.amazonaws.com
  database_port: "5432"
  redis_host: demo-replica-agent-pre-prod-redis.xxx.cache.amazonaws.com
  redis_port: "6379"
  s3_bucket: demo-replica-agent-images-pre-prod

irsa_roles:
  external_secrets: arn:aws:iam::852140462703:role/demo-replica-agent-external-secrets-role
  processing: arn:aws:iam::852140462703:role/demo-replica-agent-processing-role
  infrastructure: arn:aws:iam::852140462703:role/demo-replica-agent-infrastructure-role
```

---

## Proposed Step 8: K8s Manifest Generation

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    K8s Generation Agent                          │
├─────────────────────────────────────────────────────────────────┤
│  Input: Step 7 outputs (outputs-summary.yaml, k8s-generation-   │
│         plan.yaml, template-variables.yaml)                      │
│                                                                  │
│  Sub-Agents:                                                     │
│  ┌──────────────────┐  ┌──────────────────┐  ┌────────────────┐ │
│  │ Structure Agent  │  │ Template Agent   │  │ Assembly Agent │ │
│  │ (BFS directory   │  │ (Per-file        │  │ (Kustomization │ │
│  │  generation)     │  │  generation)     │  │  & validation) │ │
│  └──────────────────┘  └──────────────────┘  └────────────────┘ │
│                                                                  │
│  Output: Complete K8s repo (like devops-agent-k8s-demo-master)  │
└─────────────────────────────────────────────────────────────────┘
```

### BFS Generation Algorithm

```python
# Pseudocode for hierarchical generation

generation_queue = PriorityQueue()  # Ordered by level

# Level 0: Root
generation_queue.add(level=0, type="documentation", items=["README.md"])

# Level 1: Directories
generation_queue.add(level=1, type="mkdir", items=["base/", "overlays/", ...])

# Level 2+: Files (processed per level)
while not generation_queue.empty():
    current_level = generation_queue.get_next_level()

    for item in current_level:
        if item.type == "mkdir":
            create_directory(item.path)
        elif item.type == "template":
            content = render_template(
                template=item.template_name,
                variables=template_variables,
                terraform_outputs=outputs_summary
            )
            write_file(item.path, content)

    # Add children to queue for next level
    add_children_to_queue(current_level.children)
```

---

## K8s ReAct Agent Architecture

### Agent Location & Structure
```
python/src/infra_agent/agents/modular/k8s_agent/
├── __init__.py
├── agent.py                    # Main K8s ReAct agent
├── graph.py                    # LangGraph workflow definition
├── state.py                    # Agent state management
├── tools/                      # K8s generation tools
│   ├── __init__.py
│   ├── namespace.py            # generate_namespace tool
│   ├── rbac.py                 # generate_service_account, generate_role, generate_role_binding
│   ├── config.py               # generate_configmap, generate_secret, generate_external_secret
│   ├── workloads.py            # generate_deployment
│   ├── networking.py           # generate_service, generate_ingress, generate_network_policy
│   ├── scaling.py              # generate_hpa, generate_pdb
│   ├── kustomize.py            # generate_kustomization, generate_overlay
│   └── documentation.py        # generate_architecture_doc, generate_deployment_guide
├── templates/                  # Jinja2 templates (generic)
│   ├── namespace.yaml.j2
│   ├── service-account.yaml.j2
│   ├── deployment.yaml.j2
│   ├── service.yaml.j2
│   ├── configmap.yaml.j2
│   ├── ingress.yaml.j2
│   ├── hpa.yaml.j2
│   ├── network-policy.yaml.j2
│   └── kustomization.yaml.j2
└── prompts/                    # LLM prompts for reasoning
    ├── planning.py             # Plan structure reasoning
    ├── parameter_extraction.py # Extract params from context
    └── custom_generation.py    # Generate non-template content
```

### ReAct Agent Workflow

```
┌─────────────────────────────────────────────────────────────────────┐
│                     K8s ReAct Agent Loop                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐         │
│  │   OBSERVE    │────▶│    THINK     │────▶│     ACT      │────┐    │
│  │ (Read state, │     │ (Reason about│     │ (Call tool,  │    │    │
│  │  TF outputs, │     │  next file,  │     │  generate    │    │    │
│  │  plan)       │     │  parameters) │     │  file)       │    │    │
│  └──────────────┘     └──────────────┘     └──────────────┘    │    │
│         ▲                                                       │    │
│         └───────────────────────────────────────────────────────┘    │
│                          (Loop until complete)                       │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### BFS Generation Order (Agent's Action Sequence)

```python
# Agent reasons through this order, one action per iteration

GENERATION_LEVELS = {
    0: {  # Documentation (reasoning/planning)
        "type": "docs",
        "actions": [
            ("generate_architecture_doc", {}),      # docs/architecture.md
            ("generate_deployment_guide", {}),      # docs/deployment-guide.md
        ]
    },
    1: {  # Directories + Namespace
        "type": "structure",
        "actions": [
            ("create_directory_structure", {}),     # Create all directories
            ("generate_namespace", {"name": "devops-agent-demo"}),
        ]
    },
    2: {  # RBAC
        "type": "rbac",
        "actions": [
            ("generate_service_account", {"name": "frontend-sa", ...}),
            ("generate_service_account", {"name": "backend-sa", ...}),
            ("generate_service_account", {"name": "processing-sa", ...}),
            ("generate_service_account", {"name": "infrastructure-sa", ...}),
            ("generate_role", {...}),
            ("generate_role_binding", {...}),
        ]
    },
    3: {  # Configuration
        "type": "config",
        "actions": [
            ("generate_configmap", {"name": "common-config", ...}),
            ("generate_configmap", {"name": "database-config", ...}),  # Uses RDS endpoint
            ("generate_configmap", {"name": "redis-config", ...}),     # Uses ElastiCache endpoint
            ("generate_external_secret", {"name": "database-credentials", ...}),
            ("generate_external_secret", {"name": "redis-credentials", ...}),
        ]
    },
    4: {  # Services (all 20)
        "type": "networking",
        "actions": [
            ("generate_service", {"name": "web-ui", "port": 3000, ...}),
            ("generate_service", {"name": "api-gateway", "port": 8080, ...}),
            # ... all 20 services
        ]
    },
    5: {  # Deployments (all 20) - Uses ECR URLs
        "type": "workloads",
        "actions": [
            ("generate_deployment", {
                "name": "web-ui",
                "image": "{{ecr_base_url}}/demo-replica-agent-web-ui:latest",
                "port": 3000,
                "service_account": "frontend-sa",
                ...
            }),
            # ... all 20 deployments
        ]
    },
    6: {  # Ingress, NetworkPolicies
        "type": "advanced_networking",
        "actions": [
            ("generate_ingress", {...}),           # Path-based routing for ALB
            ("generate_network_policy", {...}),    # Tier-based policies
        ]
    },
    7: {  # HPA, PDB
        "type": "scaling",
        "actions": [
            ("generate_hpa", {"deployment": "api-gateway", "min": 3, "max": 10, ...}),
            ("generate_hpa", {"deployment": "web-ui", "min": 2, "max": 8, ...}),
            # ... 8 HPAs
            ("generate_pdb", {...}),
        ]
    },
    8: {  # Kustomization files
        "type": "kustomize",
        "actions": [
            ("generate_kustomization", {"path": "base/", ...}),
            ("generate_overlay", {"env": "dev-no-domain", ...}),
            ("generate_overlay", {"env": "production", ...}),
        ]
    },
}
```

### Tool Interface (Example)

```python
# tools/workloads.py

@tool
def generate_deployment(
    name: str,
    image: str,
    port: int,
    service_account: str,
    tier: str,  # frontend, backend, processing, infrastructure
    replicas: int = 1,
    cpu_request: str = "100m",
    memory_request: str = "128Mi",
    cpu_limit: str = "500m",
    memory_limit: str = "512Mi",
    env_vars: dict = None,
    config_maps: list = None,
    secrets: list = None,
    health_check_path: str = "/health",
    context: K8sContext = None,  # Terraform outputs + plan
) -> str:
    """
    Generate a Kubernetes Deployment manifest.

    Uses Jinja2 template: templates/deployment.yaml.j2
    LLM fills parameters from context if not provided.
    Returns path to generated file.
    """
    template = load_template("deployment.yaml.j2")

    # LLM-assisted parameter extraction if missing
    if env_vars is None:
        env_vars = extract_env_vars_for_service(name, tier, context)

    content = template.render(
        name=name,
        image=image,
        port=port,
        # ... all parameters
    )

    output_path = f"base/deployments/{tier}/{name}.yaml"
    write_file(output_path, content)

    return output_path
```

### Template Example (Generic)

```yaml
# templates/deployment.yaml.j2
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ name }}
  namespace: {{ namespace | default('devops-agent-demo') }}
  labels:
    app: {{ name }}
    tier: {{ tier }}
spec:
  replicas: {{ replicas | default(1) }}
  selector:
    matchLabels:
      app: {{ name }}
  template:
    metadata:
      labels:
        app: {{ name }}
        tier: {{ tier }}
    spec:
      serviceAccountName: {{ service_account }}
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      containers:
        - name: {{ name }}
          image: {{ image }}
          ports:
            - containerPort: {{ port }}
          resources:
            requests:
              cpu: {{ cpu_request | default('100m') }}
              memory: {{ memory_request | default('128Mi') }}
            limits:
              cpu: {{ cpu_limit | default('500m') }}
              memory: {{ memory_limit | default('512Mi') }}
          {% if env_vars %}
          env:
            {% for key, value in env_vars.items() %}
            - name: {{ key }}
              value: "{{ value }}"
            {% endfor %}
          {% endif %}
          {% if config_maps %}
          envFrom:
            {% for cm in config_maps %}
            - configMapRef:
                name: {{ cm }}
            {% endfor %}
          {% endif %}
          livenessProbe:
            httpGet:
              path: {{ health_check_path | default('/health') }}
              port: {{ port }}
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: {{ health_check_path | default('/health') }}
              port: {{ port }}
            initialDelaySeconds: 5
            periodSeconds: 5
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
```

---

## Step 7: Context Bridge Implementation

### Step 7 Query (for test_demo_replica_full.py)

```python
7: {
    "name": "Context_Bridge",
    "description": "Collect all Terraform outputs and generate K8s context",
    "query": f"""Collect and structure all infrastructure outputs for K8s generation.

From the project '{PROJECT_NAME}', gather:

1. **Networking Outputs** (from VPC module):
   - vpc_id, vpc_cidr, private_subnet_ids

2. **Database Outputs** (from RDS module):
   - endpoint, port, database_name
   - Secrets Manager secret name: {PROJECT_NAME}/{ENVIRONMENT}/database

3. **Cache Outputs** (from ElastiCache module):
   - primary_endpoint, port
   - Secrets Manager secret name: {PROJECT_NAME}/{ENVIRONMENT}/redis

4. **Storage Outputs** (from S3 module):
   - bucket_name, bucket_arn, iam_policy_arn

5. **Container Registry Outputs** (from ECR module):
   - ecr_base_url (account.dkr.ecr.region.amazonaws.com)
   - All 21 repository URLs

6. **Kubernetes Outputs** (from EKS module):
   - cluster_name, cluster_endpoint
   - oidc_provider_arn, oidc_issuer_url

Generate structured output files:
- outputs-summary.yaml (all outputs in structured format)
- k8s-generation-plan.yaml (BFS generation order)
- template-variables.yaml (computed values for templates)
- service-inventory.yaml (20 services with ports, tiers, requirements)

Output location: {{workspace}}/k8s-context/""",
    "expected_resources": ["local_file"],  # Generates YAML files, not AWS resources
},
```

---

## Step 8: K8s Generation Query

```python
8: {
    "name": "K8s_Generation",
    "description": "Generate complete K8s manifests using K8s ReAct Agent",
    "query": f"""Generate Kubernetes manifests for the project '{PROJECT_NAME}'.

Use the context from Step 7 ({{workspace}}/k8s-context/):
- outputs-summary.yaml
- k8s-generation-plan.yaml
- template-variables.yaml
- service-inventory.yaml

Generation Requirements:
1. Generate documentation FIRST (architecture.md, deployment-guide.md)
2. Follow BFS generation order from k8s-generation-plan.yaml
3. Use generic templates, fill parameters from context
4. For complex files (ingress, network policies), reason first then generate

Target Structure (like devops-agent-k8s-demo-master):
- base/ (namespace, rbac, configmaps, secrets, deployments, services, ingress, hpa, pdb, networkpolicies)
- infrastructure/ (external-secrets, aws-load-balancer-controller, argocd)
- overlays/ (dev-no-domain, production)
- docs/ (architecture.md, deployment-guide.md, iam-setup.md, secrets-management.md, troubleshooting.md)
- argocd-apps/ (project.yaml, app definitions)

Output location: {{workspace}}/k8s-manifests/""",
    "expected_resources": ["local_file"],  # Generates K8s YAML files
},
```

---

## Implementation Steps

### Phase 1: Merge VPC Endpoints into Step 6
**Files to modify:**
- `test_demo_replica_full.py`: Update Step 6 query to include VPC Endpoints
- Remove Step 7 (VPC_Endpoints) from QUERIES dict

### Phase 2: Create K8s Agent Structure
**Files to create:**
```
agents/modular/k8s_agent/
├── __init__.py
├── agent.py
├── graph.py
├── state.py
├── tools/__init__.py
├── tools/namespace.py
├── tools/rbac.py
├── tools/config.py
├── tools/workloads.py
├── tools/networking.py
├── tools/scaling.py
├── tools/kustomize.py
├── tools/documentation.py
├── templates/*.yaml.j2
└── prompts/*.py
```

### Phase 3: Implement Step 7 (Context Bridge)
**Components:**
- Terraform output collector (reads from workspace state)
- YAML generator for context files
- Service inventory generator

### Phase 4: Implement Step 8 (K8s Generation)
**Components:**
- K8s ReAct agent with BFS generation loop
- Tool implementations (15 tools)
- Template rendering engine
- LLM-assisted parameter extraction

### Phase 5: Integration & Testing
- Add Steps 7 & 8 to test_demo_replica_full.py
- Test against reference repo (devops-agent-k8s-demo-master)
- Validate generated manifests with `kubectl apply --dry-run`

---

## Implementation Checklist

### Phase 1: Test File Updates (COMPLETED)
- [x] `test_demo_replica_full.py`: Merge VPC Endpoints into Step 6 query
- [x] `test_demo_replica_full.py`: Add Step 7 (Context_Bridge) query
- [x] `test_demo_replica_full.py`: Add Step 8 (K8s_Generation) query
- [x] Update file header comments to reflect new pipeline

### Phase 2: K8s Agent Directory Structure
**Base Path**: `python/src/infra_agent/agents/modular/k8s_agent/`

- [ ] `__init__.py` - Module exports
- [ ] `agent.py` - Main K8sAgent class (extends BaseAgentModule)
- [ ] `graph.py` - LangGraph workflow (ReAct pattern)
- [ ] `state.py` - K8sAgentState TypedDict
- [ ] `prompt_manager.py` - Prompt templates for LLM reasoning

### Phase 3: K8s Agent Tools (15 tools)
**Base Path**: `python/src/infra_agent/agents/modular/k8s_agent/tools/`

- [ ] `__init__.py` - Tool exports
- [ ] `namespace.py` - generate_namespace
- [ ] `rbac.py` - generate_service_account, generate_role, generate_role_binding
- [ ] `config.py` - generate_configmap, generate_secret, generate_external_secret
- [ ] `workloads.py` - generate_deployment
- [ ] `networking.py` - generate_service, generate_ingress, generate_network_policy
- [ ] `scaling.py` - generate_hpa, generate_pdb
- [ ] `kustomize.py` - generate_kustomization, generate_overlay
- [ ] `documentation.py` - generate_architecture_doc, generate_deployment_guide
- [ ] `structure.py` - create_directory_structure

### Phase 4: Jinja2 Templates
**Base Path**: `python/src/infra_agent/agents/modular/k8s_agent/templates/`

- [ ] `namespace.yaml.j2`
- [ ] `service-account.yaml.j2`
- [ ] `role.yaml.j2`
- [ ] `role-binding.yaml.j2`
- [ ] `configmap.yaml.j2`
- [ ] `secret.yaml.j2`
- [ ] `external-secret.yaml.j2`
- [ ] `deployment.yaml.j2`
- [ ] `service.yaml.j2`
- [ ] `ingress.yaml.j2`
- [ ] `hpa.yaml.j2`
- [ ] `pdb.yaml.j2`
- [ ] `network-policy.yaml.j2`
- [ ] `kustomization.yaml.j2`

### Phase 5: LLM Prompts
**Base Path**: `python/src/infra_agent/agents/modular/k8s_agent/prompts/`

- [ ] `planning.py` - Prompts for BFS plan reasoning
- [ ] `parameter_extraction.py` - Prompts for extracting params from context
- [ ] `custom_generation.py` - Prompts for non-template content (ingress rules, etc.)

### Phase 6: Integration
- [ ] Register K8sAgent in orchestrator's AGENT_MODULE_MAP
- [ ] Add routing logic for "Context_Bridge" and "K8s_Generation" queries
- [ ] Update modular/__init__.py to export K8sAgent

---

## Critical File Paths

### Files to MODIFY:
```
python/examples/test_demo_replica_full.py          # Step definitions (DONE)
python/src/infra_agent/agents/modular/__init__.py  # Add K8sAgent export
python/src/infra_agent/agents/modular_orchestrator.py  # Add K8s routing
```

### Files to CREATE:
```
python/src/infra_agent/agents/modular/k8s_agent/__init__.py
python/src/infra_agent/agents/modular/k8s_agent/agent.py
python/src/infra_agent/agents/modular/k8s_agent/graph.py
python/src/infra_agent/agents/modular/k8s_agent/state.py
python/src/infra_agent/agents/modular/k8s_agent/prompt_manager.py
python/src/infra_agent/agents/modular/k8s_agent/tools/__init__.py
python/src/infra_agent/agents/modular/k8s_agent/tools/*.py  (10 files)
python/src/infra_agent/agents/modular/k8s_agent/templates/*.yaml.j2  (14 files)
python/src/infra_agent/agents/modular/k8s_agent/prompts/*.py  (3 files)
```

### Reference Files (READ for patterns):
```
python/src/infra_agent/agents/modular/compute_serverless/agent.py  # Agent pattern
python/src/infra_agent/agents/modular/compute_serverless/graph.py  # Graph pattern
python/src/infra_agent/agents/modular/base_module.py               # Base class
C:/Users/Lenovo i7/Desktop/my_personal_projects/devops-agent-k8s-demo-master/  # Target structure
```

---

## Verification

After implementation, verify by:
1. Running full pipeline (Steps 1-8)
2. Comparing generated K8s repo structure to devops-agent-k8s-demo-master
3. Deploying generated manifests to EKS cluster
4. Confirming all 20 services start correctly

### Test Commands
```bash
# Dry run to see queries
python examples/test_demo_replica_full.py --dry-run

# Run single step
python examples/test_demo_replica_full.py --step 7  # Context Bridge
python examples/test_demo_replica_full.py --step 8  # K8s Generation

# Run full pipeline
python examples/test_demo_replica_full.py

# Validate generated manifests
kubectl apply -k k8s-manifests/overlays/dev-no-domain --dry-run=client
```

---

## Service Inventory (20 Services)

| # | Service | Port | Tier | ServiceAccount |
|---|---------|------|------|----------------|
| 1 | web-ui | 3000 | frontend | frontend-sa |
| 2 | admin-dashboard | 3001 | frontend | frontend-sa |
| 3 | api-gateway | 8080 | gateway | api-gateway-sa |
| 4 | auth-service | 8002 | backend | backend-sa |
| 5 | user-service | 8001 | backend | backend-sa |
| 6 | product-service | 8004 | backend | backend-sa |
| 7 | order-service | 8003 | backend | backend-sa |
| 8 | payment-service | 8005 | backend | backend-sa |
| 9 | notification-service | 8006 | backend | backend-sa |
| 10 | event-processor | 8010 | processing | processing-sa |
| 11 | analytics-service | 8011 | processing | processing-sa |
| 12 | report-generator | 8012 | processing | processing-sa |
| 13 | data-aggregator | 8013 | processing | processing-sa |
| 14 | image-processor | 8020 | processing | processing-sa |
| 15 | db-proxy | 5433 | infrastructure | infrastructure-sa |
| 16 | cache-manager | 6380 | infrastructure | infrastructure-sa |
| 17 | config-service | 9093 | infrastructure | infrastructure-sa |
| 18 | metrics-collector | 9090 | infrastructure | infrastructure-sa |
| 19 | queue-monitor | 9091 | infrastructure | infrastructure-sa |
| 20 | health-checker | 9092 | infrastructure | infrastructure-sa |
