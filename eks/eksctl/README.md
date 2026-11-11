# CloudBees CI on EKS — eksctl Provisioning Scripts

This directory provisions a demo CloudBees CI environment on Amazon EKS: a
cluster with dedicated controller/agent node pools, a shared Application Load
Balancer fronting both an in-cluster Operations Center (CJOC) and an optional
standalone EC2-hosted Client Controller, TLS via ACM, and DNS via Route53.

Scripts are numbered in the order they're meant to be run. Numbers that share
a prefix (e.g. `01-*`, `04-*`) operate on the same resource and are grouped
together below.

## Setup

Every script sources `.env` for its configuration — none of them work
until it exists. Create it from the template before running anything else:

```bash
cp .env-template .env
```

Then edit `.env` and replace every `<USER_ID>` placeholder (in `TAG_CB_USER`
and `CJOC_HOST_NAME`) with your own identifier — it's used to tag every AWS
resource, name the cluster (`CLUSTER_NAME=${TAG_CB_USER}`), and build the
CJOC hostname. Review the rest of the file too (region, chart versions,
storage class) and adjust anything that doesn't match your account.

`.env` is tracked in git in this copy of the repo, so double-check you're
not committing personal values before pushing changes to it.

Finally, source it in every new shell before running any numbered script:

```bash
source .env
```

See [`.env-template`](.env-template) for the full list of variables.

## Execution Sequence

```
00-login.sh
   │
   ▼
01-createCluster.sh                (EKS cluster, VPC, node groups)
   │
   ├── 02-create-efs-filesystem.sh          (optional: shared EFS storage)
   ├── 03-installClusterAutoscaler.sh       (independent, any time after 01)
   ├── 07-createS3BackupBucket.sh           (optional, independent; re-run after
   └── 07-createS3ArtifactStorage.sh         adding controllers; see S3 Storage)
   │
   ▼
03-installAwsLbController.sh       (AWS Load Balancer Controller)
   │
   ▼
04-installEnvoy.sh                 (Envoy Gateway + shared ALB + ACM cert)
   │
   ├── 07-createS3PlugableStorage-LogsBucket.sh
   │   (optional — run BEFORE 05 when S3_LOGS_ENABLED=true)
   ▼
05-installCloudBees.sh             (CloudBees CI / CJOC via Helm)
   │                                optional flags in .env: CASC_ENABLED,
   │                                S3_LOGS_ENABLED, CHANNEL_PINGER_ENABLED,
   │                                MCP_ENABLED
   ▼
06-installExternalDNS.sh           (Route53 record automation for CJOC)
   │
   ▼
07-createEC2WithController.sh      (optional: standalone EC2 Client Controller)
```

Demo: migrating from ingress-nginx (NLB) to Envoy Gateway (ALB), with the scripts for the before state: [README-NGINX-TO-ENVOY.md](README-NGINX-TO-ENVOY.md).

### Operational Scripts (Day-2)

The following scripts are **operational** — run them any time after the initial sequence, not as part of it:

- **Node pool scaling:** [`01-scaleDonwNodePools.sh`](01-scaleDonwNodePools.sh) / [`01-scaleUpNodePools.sh`](01-scaleUpNodePools.sh)
- **Cluster upgrades:** [`01-upgradeCluster.sh`](01-upgradeCluster.sh)
- **EC2 controller power management:** [`07-stopEC2Instance.sh`](07-stopEC2Instance.sh) / [`07-startEC2Instance.sh`](07-startEC2Instance.sh)
- **S3 bucket management:** The `07-*S3*` bucket scripts (see [S3 Storage](#s3-storage-optional))
- **Remote agent service account:** [`08-createServiceAccountforRemoteAgents.sh`](08-createServiceAccountforRemoteAgents.sh)
- **Teardown and cleanup:** Every `*delete*.sh` script (for teardown order, see [Execution Sequence (Teardown)](#execution-sequence-teardown))

## Execution Sequence (Teardown)

> **Status: not yet validated end-to-end.** `01-deleteCluster.sh` and `06-deleteExternalDNS.sh` have only been syntax-checked. Run `--dry-run` first and try a full teardown on a throwaway cluster. Unverified: how the external-dns Pod Identity role interacts with the identically purposed entry in [`eksctl-config.yaml.tpl`](eksctl-config.yaml.tpl), and whether the ACM certificates' DNS-validation CNAME records are removed with the certificates. Check the orphan report after the first run, then delete this note.

[`01-deleteCluster.sh`](01-deleteCluster.sh) **orchestrates the whole teardown**: it calls the individual delete scripts in reverse order of creation, deletes the EKS cluster, and finishes with a read-only orphan scan. You normally don't run the other delete scripts by hand.

**Prerequisites:** `aws`, `eksctl`, `kubectl`, `helm`, `jq` and `envsubst` on `PATH`; a valid AWS session (`00-login.sh`); and `kubectl` access to the cluster (`KUBECONFIG` from `.env`). Without `kubectl` access the Kubernetes-side steps are skipped, which can orphan the ALB and ENIs, so the plan warns you.

```
01-deleteCluster.sh   (each step runs only if its resources are detected)
   │
   ├─ 07-deleteEC2WithController.sh --delete-cert          optional add-on
   ├─ 05-deleteCloudBees.sh --delete-data --delete-namespace
   ├─ 07-deleteS3PlugableStorage-LogsBucket.sh   (DESTRUCTIVE)   optional
   ├─ 07-deleteS3ArtifactStorage.sh              (DESTRUCTIVE)   optional
   ├─ 07-deleteS3BackupBucket.sh                 (DESTRUCTIVE)   optional
   ├─ 04-deleteEnvoy.sh --delete-crds --delete-cert   (Ingress → ALB first)
   ├─ 06-deleteExternalDNS.sh                    (waits for Route53 record sync)
   ├─ 02-delete-efs-filesystem.sh                (no prompt)     optional
   ├─ eksctl delete cluster
   └─ orphan report (read-only)
```

```bash
source .env
./01-deleteCluster.sh --dry-run     # print the plan only
./01-deleteCluster.sh               # plan + type the cluster name to confirm
./01-deleteCluster.sh --yes         # skip the typed confirmation (automation)
./01-deleteCluster.sh --report-only # only scan for leftover resources
```

- **Auto-detection.** Each step runs only if its resources exist (EC2 add-on, Helm releases, buckets, EFS, ACM certs, IAM) and is shown as `[DELETE]` or `[skip]` in the plan. If the cluster is gone, the AWS-side steps still run.
- **Irreversible.** It deletes JENKINS_HOME volumes, the three S3 buckets with all their objects, the ACM certificates and the Gateway API/Envoy CRDs. Nothing is deleted before the plan is confirmed.
- **Fail-stop and re-runnable.** A failing step aborts the run; the delete scripts are idempotent, so fix the cause and run it again.
- **Not covered by a delete script:** `03-*` (LB controller, Cluster Autoscaler) and `08-createServiceAccountforRemoteAgents.sh` live inside the cluster and are removed with it.
- **Orphan report.** Lists remaining CloudFormation stacks, resources tagged for the cluster (ALBs, ENIs, security groups, EBS volumes), the named S3/EFS/IAM/ACM/Route53 resources and EC2 add-on. It only reports; it never deletes.
- **Individual scripts** still work standalone; the three S3 delete scripts and `06-deleteExternalDNS.sh` accept `--yes`. Run `04-deleteEnvoy.sh` before `06-deleteExternalDNS.sh`, because external-dns removes the Route53 records only after the Ingress is gone.

### Applying IAM-only config changes to an existing cluster

[`03-installClusterAutoscaler.sh`](03-installClusterAutoscaler.sh) depends on the `cluster-autoscaler` entry
under `iam.serviceAccounts` in [`eksctl-config.yaml.tpl`](eksctl-config.yaml.tpl). If that entry was
added after the cluster already exists, don't re-run [`01-createCluster.sh`](01-createCluster.sh) —
reconcile just the IAM service accounts instead:

```bash
source .env
envsubst < eksctl-config.yaml.tpl > eksctl-config.yaml
eksctl create iamserviceaccount --config-file=eksctl-config.yaml --approve
```

This creates any service account defined in the config that doesn't exist yet
(e.g. `cluster-autoscaler`) and leaves existing ones (e.g.
`aws-load-balancer-controller`) untouched unless you also pass
`--override-existing-serviceaccounts`.

### Reconciling other config changes with `eksctl update cluster`

`eksctl update cluster` is **deprecated** as of the eksctl version pinned for
this environment (`eksctl update cluster --help` prints "DEPRECATED: use
'upgrade cluster' instead") — it only upgrades the control plane's
Kubernetes version and reconciles the CloudFormation stack if resources are
missing, it does **not** apply arbitrary field changes from the config file
the way `terraform apply` would.

```bash
source .env
envsubst < eksctl-config.yaml.tpl > eksctl-config.yaml
eksctl upgrade cluster -f eksctl-config.yaml       # dry run — prints planned changes
eksctl upgrade cluster -f eksctl-config.yaml --approve   # actually apply them
```

For an actual Kubernetes version bump, use
[`01-upgradeCluster.sh`](01-upgradeCluster.sh) instead — it wraps `eksctl
upgrade cluster` plus the EKS-managed add-on and node group upgrade steps
this command doesn't perform. For most other day-2 config drift (IAM service
accounts, node group scaling, add-on config), use the targeted commands in
[Applying IAM-only config changes to an existing cluster](#applying-iam-only-config-changes-to-an-existing-cluster)
above or the relevant numbered script instead.

## Node Groups & Workload Isolation

[`eksctl-config.yaml.tpl`](eksctl-config.yaml.tpl) provisions three managed node groups:

| Node group | Taint | Label | Purpose |
| --- | --- | --- | --- |
| `controllers` | `workload=controller:NoSchedule` | `workload: controller` | CJOC and CloudBees CI Managed Controllers only. Graviton (ARM64), sized for steady-state control-plane-style workloads. |
| `agents` | `workload=agent:NoSchedule` | `workload: agent` | Ephemeral Jenkins Pipeline build pods only. x86_64. |
| `system` | *(none — deliberately untainted)* | `workload: system` | Cluster add-ons that don't carry a `workload`-specific toleration: CoreDNS, EBS/EFS CSI controllers, Envoy Gateway, external-dns, aws-load-balancer-controller, cluster-autoscaler, metrics-server. |

**Why `system` exists:** `controllers` and `agents` are both tainted so CI
workloads land only where intended — build pods can never land on
controller nodes and vice versa. But once *every* node group carries a
taint, any pod without a matching toleration has nowhere left to schedule,
including cluster-critical Deployments that ship with no custom tolerations
by default (CoreDNS, CSI driver controllers, the LB controller, the
autoscaler itself, etc.). Patching tolerations onto each of those
individually means touching a different mechanism per component — EKS addon
`configurationValues`, Helm chart values, raw manifests — and redoing it
every time a new add-on is installed. `system` sidesteps that: as the only
untainted pool, anything without a `workload` toleration schedules there
automatically, with zero changes to the add-on's own spec.

Workloads that need to land specifically on `controllers` or `agents` must
carry **both**:

- a **toleration** matching that pool's taint (permission to land there), and
- a **`nodeSelector`** for that pool's `workload` label (the actual
  requirement to land there — see the `nodeAffinity` caveat below).

A toleration alone only grants permission, it doesn't force placement — a
pod with the right toleration but no matching selector can still land on
`system` (or any other untainted node) instead, since nothing requires
otherwise. This is a live gotcha, not theoretical: see
[`controller-statefullset-patch.yaml`](controller-statefullset-patch.yaml) below.

### [`controller-statefullset-patch.yaml`](controller-statefullset-patch.yaml)

Raw StatefulSet YAML merge patch intended for CJOC's **Kubernetes Master
Provisioning → Advanced** config, so that dynamically-provisioned Managed
Controller pods land on the `controllers` pool. **This file is not
referenced by any script** — it only takes effect if its contents are
pasted into that CJOC config field (or wired in via CasC/groovy) by hand.
Confirm it's actually applied by inspecting a live controller's pod spec
(`kubectl get pod <controller>-0 -o jsonpath='{.spec.nodeSelector}{"\n"}{.spec.tolerations}'`),
not by assuming the file's existence means it's in effect.

Confirmed live behavior: CJOC's StatefulSet merge does **not** deep-merge
`spec.affinity`. The base template it generates for every Managed Controller
already sets `affinity.nodeAffinity` (a `kubernetes.io/os: linux` check), so
merging in a patch that adds a second `matchExpressions` entry under that
same key silently drops the addition — and the patch's whole
`podAntiAffinity` block never applied either. `tolerations`, by contrast,
isn't set by the base template at all, so it merges in with no collision.
**This is why the patch sets both `tolerations` and a plain `nodeSelector`**
— `nodeSelector` is a distinct top-level field the base template never
populates, so it isn't subject to the same merge collision, and is what
actually forces controllers onto the `controllers` pool today. Don't rely on
the `nodeAffinity`/`podAntiAffinity` blocks in this file taking effect until
CJOC's merge behavior is confirmed otherwise.

### [`Jenkinsfile`](Jenkinsfile)

Sample pipeline in this directory. Its inline Kubernetes pod agent carries a
`nodeSelector: {workload: agent}` and a matching toleration for
`workload=agent:NoSchedule` — required now that the `agents` pool is
tainted. Any other pipeline or Kubernetes-plugin `PodTemplate` that
provisions build agents on this cluster needs the same two additions, or its
agent pods will stay `Pending` indefinitely.

## Scripts Reference

| Order | Script | Purpose |
| --- | --- | --- |
| 00 | [`00-login.sh`](00-login.sh) | Authenticates the AWS CLI via `aws sso login`. Run this first in any new shell/session. |
| 01 | [`01-createCluster.sh`](01-createCluster.sh) | Renders [`eksctl-config.yaml.tpl`](eksctl-config.yaml.tpl) and creates the EKS cluster, VPC, managed node groups (`controllers` and `agents`, both tainted for workload isolation; `system`, untainted, for cluster add-ons — see [Node Groups & Workload Isolation](#node-groups--workload-isolation)), OIDC/IRSA and Pod Identity, and the EBS/EFS CSI + Pod Identity Agent add-ons. Migrates to EKS Pod Identity and writes kubeconfig. |
| 01 | [`01-scaleDonwNodePools.sh`](01-scaleDonwNodePools.sh) | Scales every managed node group to 0 to park the environment (saves EC2 cost only — control plane, NAT, ALB, EBS/EFS keep billing). Saves current sizes to [`.nodepool-scale-state.json`](.nodepool-scale-state.json). |
| 01 | [`01-scaleUpNodePools.sh`](01-scaleUpNodePools.sh) | Restores node groups to the sizes recorded by the scale-down script (or explicit `--nodes*` flags / config defaults if that state file is missing). |
| 01 | [`01-deleteCluster.sh`](01-deleteCluster.sh) | Orchestrates the full teardown by calling the delete scripts in reverse order, then `eksctl delete cluster`, then a read-only orphan scan. Supports `--dry-run`, `--yes`, `--report-only`. See [Execution Sequence (Teardown)](#execution-sequence-teardown). |
| 01 | [`01-upgradeCluster.sh`](01-upgradeCluster.sh) | Upgrades the cluster one Kubernetes minor version at a time: control plane (`eksctl upgrade cluster`), EKS-managed add-ons (`eksctl update addon`), then managed node groups (`eksctl upgrade nodegroup`). Refreshes kubeconfig and bumps the `version:` field in [`eksctl-config.yaml.tpl`](eksctl-config.yaml.tpl) to match. Defaults to current+1 minor version; override with `--version`. |
| 02 | [`02-create-efs-filesystem.sh`](02-create-efs-filesystem.sh) | Creates an EFS file system + mount target + security group for shared storage, verifies the `aws-efs-csi-driver` IAM role, deploys a StorageClass, and runs an end-to-end test PVC/Pod. |
| 02 | [`02-delete-efs-filesystem.sh`](02-delete-efs-filesystem.sh) | Removes everything the EFS create script made: test namespace, StorageClass, fallback IAM role, mount targets, file system, and security group. Has no flags and no confirmation prompt. |
| 03 | [`03-installAwsLbController.sh`](03-installAwsLbController.sh) | Installs the AWS Load Balancer Controller via Helm using the IRSA ServiceAccount eksctl already created, applies its CRDs, and verifies public subnets carry the `kubernetes.io/role/elb=1` tag the controller needs to place an ALB. |
| 03 | [`03-installClusterAutoscaler.sh`](03-installClusterAutoscaler.sh) | Installs Kubernetes Cluster Autoscaler via Helm using the IRSA ServiceAccount eksctl created (`wellKnownPolicies.autoScaler`), matches the image tag to the cluster's live Kubernetes minor version, and verifies both node groups' ASGs are tagged for auto-discovery (automatic since `minSize != maxSize` on `controllers`/`agents`). Also grants supplemental read-only RBAC on the `resource.k8s.io` API group (Dynamic Resource Allocation objects), which newer autoscaler builds watch unconditionally but the Helm chart's bundled ClusterRole doesn't grant. Independent of the ALB/Envoy chain — run any time after [`01-createCluster.sh`](01-createCluster.sh). |
| 04 | [`04-installEnvoy.sh`](04-installEnvoy.sh) | Installs Envoy Gateway, requests/validates the ACM certificate for `CJOC_HOST_NAME` (with automated Route53 DNS validation), and creates the Gateway/GatewayClass/HTTPRoute plumbing plus the `cjoc-alb` Ingress that provisions the **shared internet-facing ALB**. |
| 04 | [`04-deleteEnvoy.sh`](04-deleteEnvoy.sh) | Tears down the Ingress (deprovisioning the ALB), Gateway API resources, and the Envoy Gateway Helm release. Leaves the CloudBees namespace, CRDs, and ACM certificate in place unless `--delete-crds` / `--delete-cert` are passed. `--yes` skips the prompt. |
| 05 | [`05-installCloudBees.sh`](05-installCloudBees.sh) | Installs CloudBees CI (Operations Center / CJOC) via the `cloudbees/cloudbees-core` Helm chart, wired to the Gateway from step 04, and waits for the Gateway to get an address. Optional parts are switched on in `.env` (see [Optional install flags](#optional-install-flags-05-installcloudbeessh)). |
| 05 | [`05-deleteCloudBees.sh`](05-deleteCloudBees.sh) | Uninstalls the CloudBees CI Helm release and stops managed controllers, keeping their volumes by default. `--delete-data` also deletes the PVCs (JENKINS_HOME), `--delete-namespace` the namespaces (requires `--delete-data`), `--keep-controllers` leaves managed controllers running, `--yes` skips the prompt. |
| 06 | [`06-installExternalDNS.sh`](06-installExternalDNS.sh) | Installs `external-dns` (via EKS Pod Identity) scoped to a least-privilege, hosted-zone-specific IAM policy, so Route53 A records for `CJOC_HOST_NAME` are created/kept in sync automatically from the Ingress. |
| 06 | [`06-deleteExternalDNS.sh`](06-deleteExternalDNS.sh) | Waits for external-dns to remove the Route53 records for `CJOC_HOST_NAME` (deleting leftovers owned by this cluster's `txtOwnerId`), uninstalls the Helm release and namespace, then removes the Pod Identity association, IAM role (unless CloudFormation-managed) and IAM policy. Run after `04-deleteEnvoy.sh`. `--yes` skips the prompt. |
| 07 | [`07-createEC2WithController.sh`](07-createEC2WithController.sh) | **Optional add-on.** Provisions a standalone Amazon Linux 2023 EC2 instance (Java 21 + Docker + systemd-managed CloudBees CI Client Controller container) and wires it into the *same shared ALB* from step 04 via a new host-header listener rule, its own ACM certificate (SNI), a dedicated target group/security group/IAM instance profile, and a Route53 alias record — without creating a second ALB. Also adds a scoped 443 rule to the EKS cluster's own security group so this instance can reach the Kubernetes API server (needed because `clusterEndpoints.privateAccess: true` routes in-VPC clients through that security group, not the public endpoint). |
| 07 | [`07-deleteEC2WithController.sh`](07-deleteEC2WithController.sh) | Tears down everything the EC2 create script added (listener rule, target group, instance, the cluster-security-group's 443 rule, security group, IAM role/profile, Route53 record; ACM cert opt-in via `--delete-cert`) while explicitly leaving the VPC, EKS cluster, and shared ALB/listener/default certificate untouched. `--yes` skips the prompt. |
| 07 | [`07-stopEC2Instance.sh`](07-stopEC2Instance.sh) | Stops (does not terminate) the EC2 Client Controller instance to park it and save EC2 compute cost, leaving its security group, IAM role, target group, listener rule, ACM cert, Route53 record, and EBS volume untouched. Waits for `stopped` by default (`--no-wait`, `--yes`). |
| 07 | [`07-startEC2Instance.sh`](07-startEC2Instance.sh) | Starts a previously stopped EC2 Client Controller instance back up so the target group reports healthy again. Waits for `running` by default (`--no-wait`, `--yes`). |
| 07 | [`07-createS3BackupBucket.sh`](07-createS3BackupBucket.sh) | **Optional.** Creates a CloudBees CI backup bucket (public access blocked, lifecycle expiry) and grants every managed controller access via EKS Pod Identity. Controller ServiceAccounts are discovered from pods labelled `com.cloudbees.cje.type=master`. Re-run after adding a controller. |
| 07 | [`07-deleteS3BackupBucket.sh`](07-deleteS3BackupBucket.sh) | **Destructive.** Deletes the backup bucket and all objects, plus the IAM policy. Keeps the role and associations if another policy (e.g. artifacts) is still attached. Asks for confirmation. |
| 07 | [`07-createS3ArtifactStorage.sh`](07-createS3ArtifactStorage.sh) | **Optional.** Creates the bucket for the *Artifact Manager on S3* plugin and grants the controller ServiceAccounts access via Pod Identity instead of IAM-user access keys. Policy is scoped to this bucket by default. |
| 07 | [`07-deleteS3ArtifactStorage.sh`](07-deleteS3ArtifactStorage.sh) | **Destructive.** Deletes the artifacts bucket and all objects, the policy, role and its associations. Associations that point at another role are kept; only the artifacts policy is detached from that role. |
| 07 | [`07-createS3PlugableStorage-LogsBucket.sh`](07-createS3PlugableStorage-LogsBucket.sh) | **Optional.** Creates the bucket for Pluggable Storage (Pipeline build logs) and grants the `pluggable-storage-service` ServiceAccount access via Pod Identity. Run before `05-installCloudBees.sh` with `S3_LOGS_ENABLED=true`. |
| 07 | [`07-deleteS3PlugableStorage-LogsBucket.sh`](07-deleteS3PlugableStorage-LogsBucket.sh) | **Destructive.** Deletes the logs bucket and all build logs, plus the policy, role and association. Asks for confirmation. |
| 08 | [`08-createServiceAccountforRemoteAgents.sh`](08-createServiceAccountforRemoteAgents.sh) | Creates a `jenkins-agent` ServiceAccount, Role, and RoleBinding in the `cbci-builds` namespace (get/list/watch/create/delete/update/patch on pods, pods/log, pods/exec, events, and PVCs), plus a non-expiring legacy-style Secret token, and prints the decoded token — used to configure a Jenkins Kubernetes Cloud (e.g. from a remote/standalone Controller) so it can provision agent pods in this cluster. |

## Optional install flags (`05-installCloudBees.sh`)

The base install always runs. Everything below is off by default and switched on in `.env`; `HELM_DEBUG=true` adds `helm --debug`. Flags are read at install time, so re-run the script (a `helm upgrade`) after changing them.

| Variable | Default | Effect |
|---|---|---|
| `CASC_ENABLED` | `false` | Deploys the CasC bundle retriever for the operations center from `CASC_SCM_REPO`/`CASC_SCM_BRANCH`, path `CASC_SCM_BUNDLE_PATH_CJOC`. Requires `CASC_SCM_USERNAME`, `CASC_SCM_PASSWORD` and `CJOC_ADMIN_PASSWORD`; the script aborts if they are missing. Bundles live in [`../../casc`](../../casc). |
| `S3_LOGS_ENABLED` | `false` | Enables Pluggable Storage with build logs on S3 (`AMAZON_S3`). Bucket, prefix and ServiceAccount come from `S3_LOGS_*`; create them first with `07-createS3PlugableStorage-LogsBucket.sh`. |
| `CHANNEL_PINGER_ENABLED` | `false` | Sets `-Dhudson.slaves.ChannelPinger.pingIntervalSeconds` on the operations center and managed controllers. `CHANNEL_PINGER_INTERVAL_SECONDS` defaults to `1200`. |
| `MCP_ENABLED` | `false` | Deploys the MCP Router with OAuth; see [MCP Router](#mcp-router-optional). |

`05a-installCloudBees-CasCBundleRetriever.sh` and `05c-installCloudBees-PlugableStorage.sh` were removed; their functionality is now these flags.

## S3 Storage (optional)

Three independent buckets, each with a create and a delete script. All grant access through **EKS Pod Identity** (no static keys, no node-role changes) and require `aws` CLI v2 and the Pod Identity Agent add-on from `01-createCluster.sh`.

| Purpose | Create / delete | Consumer | Key variables (see [`.env-template`](.env-template)) |
|---|---|---|---|
| Backups | `07-createS3BackupBucket.sh` / `07-deleteS3BackupBucket.sh` | Managed controllers | `S3_BACKUP_BUCKET`, `S3_BACKUP_EXPIRE_DAYS`, `S3_BACKUP_SA_NAMESPACE`, `S3_BACKUP_POD_SELECTOR`, `S3_BACKUP_SA_NAMES` |
| Artifacts | `07-createS3ArtifactStorage.sh` / `07-deleteS3ArtifactStorage.sh` | *Artifact Manager on S3* plugin on controllers | `S3_ARTIFACTS_BUCKET`, `S3_ARTIFACTS_PREFIX`, `S3_ARTIFACTS_EXPIRE_DAYS`, `S3_ARTIFACTS_SA_NAMES`, `S3_ARTIFACTS_POLICY_SCOPE` |
| Build logs | `07-createS3PlugableStorage-LogsBucket.sh` / `07-deleteS3PlugableStorage-LogsBucket.sh` | Pluggable Storage service (`S3_LOGS_ENABLED=true`) | `S3_LOGS_BUCKET`, `S3_LOGS_PREFIX`, `S3_LOGS_EXPIRE_DAYS`, `S3_LOGS_SA_NAME` |

Behavior worth knowing:

- **One association per ServiceAccount.** If a ServiceAccount already has a Pod Identity association, the script keeps its role and attaches its policy to that role rather than replacing it, so the backup and artifacts policies can share a controller's role.
- **No wildcard matching.** Re-run the backup/artifacts create script after adding a controller, and restart pods that received a new association.
- **Artifacts policy scope.** Defaults to `s3:*` on the one bucket. `S3_ARTIFACTS_POLICY_SCOPE=any` widens it to every bucket in the account; avoid it. `s3:ListAllMyBuckets` on `*` is always granted because the plugin's client lists buckets (names only).
- **Controller configuration is manual.** For artifacts, set the bucket and prefix printed by the script in *Manage Jenkins > System > Artifact Management for Builds* and *Manage Jenkins > AWS*, and leave credentials unset so the default credential chain (Pod Identity) is used.
- **Delete scripts are destructive.** They permanently remove the bucket and all objects after you type the bucket name; `--yes` skips the prompt (used by `01-deleteCluster.sh`). Back up anything you need first.
- **Ordering.** The logs bucket can be created before the ServiceAccount exists (the Helm chart creates it), but the pluggable storage pod must be restarted afterward to pick up credentials. `01-deleteCluster.sh` deletes them for you before the cluster.

## MCP Router (optional)

Set `MCP_ENABLED=true` in `.env` before running `05-installCloudBees.sh` to deploy the CloudBees CI MCP Router with OAuth through the `cloudbees-core` chart (`McpRouter.enabled`, `OperationsCenter.OAuthServer.Enabled`, upstream mode `AUTO`). Background, auth flow and chart values are in [`01-MCP.md`](../../docs/01-MCP.md).

| Variable | Default | Purpose |
|---|---|---|
| `MCP_ENABLED` | `false` | Deploy the router and enable the OAuth authorization server. |
| `MCP_UPSTREAM_MODE` | `AUTO` | `AUTO` accepts OAuth bearer tokens and Basic/API-token headers. `OAUTH_ONLY` rejects everything but bearer tokens. |
| `MCP_RATE_LIMIT_ENABLED` | `false` | Per-caller rate limiting on `/mcp`. Optional `MCP_RATE_LIMIT_PERMITS` and `MCP_RATE_LIMIT_WINDOW`. |
| `MCP_CONTROLLERS_CACHE_TTL` | router default (`1H`) | How long the router caches the controller list (`H`, `M`, `S` suffix). |

The router is served through the Gateway at `https://<CJOC_HOST_NAME>/mcp-router/mcp`.

**Prerequisite:** the MCP Server plugin must be on the controllers, and the OAuth Authorization Server plugin on the operations center and the OAuth Resource Server plugin on the controllers (`OAUTH_ONLY` needs the last one everywhere). The `casc/` bundles install them: `cloudbees-oauth-server` and `cloudbees-oauth-resource` in `casc/cjoc/plugins.yaml`, `mcp-server` and `cloudbees-oauth-resource` in `casc/controller-base/plugins.yaml`. The retriever reads the bundles from `CASC_SCM_REPO`/`CASC_SCM_BRANCH`, so commit and push them first.

## Architecture

```mermaid
flowchart TB
    User(("Internet users"))

    subgraph DNS["Route53 — acaternberg.aws.ps.beescloud.com"]
        direction LR
        R53_CJOC["A (Record)\ncjoc.___\nmanaged by external-dns"]
        R53_EC2["A (Record)\nec2-controller.___\nmanaged by the EC2 controller add-on"]
    end

    subgraph AWSAcct["AWS account-level resources"]
        direction LR
        ACM["ACM certificates\n(cjoc + ec2-controller, DNS-validated)"]
        SSM["AWS Systems Manager\nSession Manager"]
    end

    subgraph VPC["VPC"]
        subgraph Public["Public subnets"]
            ALB["Shared internet-facing ALB\nHTTPS :443, host-header routing"]
            NAT["NAT Gateway"]
        end

        subgraph Private["Private subnets"]
            subgraph EKS["EKS cluster: acaternberg"]
                LBC["aws-load-balancer-controller"]
                CA["cluster-autoscaler"]
                EDNS["external-dns"]
                EnvoySvc["Envoy Service (ClusterIP)"]
                EnvoyGW["Envoy Gateway + HTTPRoute"]
                CJOC["CJOC / CloudBees CI\nStatefulSet + PVC"]
                NGControllers["Node group: controllers\n(tainted, Graviton)"]
                NGAgents["Node group: agents\n(tainted)"]
                NGSystem["Node group: system\n(untainted — CoreDNS, CSI\ncontrollers, LBC, CA, EDNS,\nEnvoy Gateway, metrics-server)"]
            end

            EC2["EC2 instance (Amazon Linux 2023)\nCloudBees CI Client Controller\nsystemd + Docker, :8080"]
        end

        EFS[("EFS shared storage")]
        EBS[("EBS volume\nJENKINS_HOME")]
    end

    User -->|HTTPS| R53_CJOC
    User -->|HTTPS| R53_EC2
    R53_CJOC --> ALB
    R53_EC2 --> ALB

    ALB -->|"host: cjoc.___"| EnvoySvc --> EnvoyGW --> CJOC
    ALB -->|"host: ec2-controller.___"| EC2
    ALB -. SNI certificates .-> ACM

    LBC -. reconciles .-> ALB
    EDNS -. upserts .-> R53_CJOC
    CJOC --> EBS
    NGControllers --- CJOC
    NGAgents -. build agents .-> CJOC
    NGSystem --- LBC
    NGSystem --- CA
    NGSystem --- EDNS
    NGSystem --- EnvoyGW
    CA -. resizes on pod pressure .-> NGControllers
    CA -. resizes on pod pressure .-> NGAgents
    CA -. resizes on pod pressure .-> NGSystem
    EC2 -. IAM instance profile .-> SSM
    Private -->|egress| NAT

    classDef optional stroke-dasharray: 5 5
    class EC2,R53_EC2 optional
```

Dashed-border nodes (`EC2`, `R53_EC2`) are the optional add-on from step 07 —
everything else is created by the core 01–06 sequence.
