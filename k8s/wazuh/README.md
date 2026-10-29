# Wazuh 5 on EKS

Production Wazuh cluster deployed with Kustomize, adapted from the official
[wazuh-kubernetes](https://github.com/wazuh/wazuh-kubernetes) EKS overlay (tag `v5.0.0-rc1`).

```
  users ─── NLB :443  (TCP pass-through) ──► wazuh-dashboard ─────────────────┐
                                                    │ API                     │
                                                    ▼                         ▼
  agents ── NLB :1517 (TCP pass-through) ──► wazuh-manager master + 2 workers ──► wazuh-indexer ×3
```

Both NLBs are reached on their AWS DNS names (`k8s-wazuh-….elb.<region>.amazonaws.com`) for now.
ACM cannot issue certificates for those names, so the dashboard serves its own certificate,
signed by the internal CA. Browsers warn unless you trust `.secrets/certs/root-ca.pem`.
Once you have a domain, see [Switching to a domain](#switching-to-a-domain).

```
k8s/wazuh/
├── kustomization.yaml       # image tags (one place to bump the version)
├── namespace.yaml, storage-class.yaml (gp3, encrypted, Retain), network-policy.yaml (default deny)
├── indexer/                 # 3-node OpenSearch quorum, 30Gi each, one pod per node
├── manager/                 # 1 master (API) + 2 workers, 10Gi each
├── dashboard/               # Wazuh dashboard
├── ingress/                 # NLBs for the dashboard (443) and agents (1517); ALB Ingress for later
└── secrets/create.sh        # certificates, passwords and Secrets, kept in .secrets/ (gitignored)
```

> **Version.** Wazuh 5.0 is at release candidate stage: `5.0.0-rc1` is the newest
> 5.x build and there is no GA `5.0.0` yet. When it ships, change the three tags in
> `kustomization.yaml` and diff these manifests against the upstream `v5.0.0` tag.

## Prerequisites on the cluster

On `dev-cluster` these come from Terraform in
[infra-setup](https://github.com/Navendu-creator/infra-setup) (`terraform/aws/environments/dev`),
except the controller itself, which Argo CD installs.

- **At least 3 worker nodes**, ideally in 3 AZs. Each indexer needs its own node.
  Requests are sized for 3× `m7i-flex.large` (2 vCPU / 8 GiB, the largest AWS Free plan type):
  about 3.25 vCPU / 14.5 GiB in total, at most 1.25 vCPU / 5.5 GiB per node. That suits a small
  number of agents. For real load, move to 4 vCPU / 16 GiB nodes and raise the indexer to
  1 CPU / 4 GiB (2 GB heap) and the managers to 1 CPU / 2 GiB.
- **[EBS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)** add-on, with its IAM role.
- **[AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)**,
  which creates the NLBs (and later the ALB). Its IAM role is in Terraform; the chart is
  [k8s/argocd/apps/aws-load-balancer-controller.yaml](../argocd/apps/aws-load-balancer-controller.yaml).
- **Network policy enforcement** in the VPC CNI (`enableNetworkPolicy: "true"` in the add-on config).
  Without it, the NetworkPolicies here are silently ignored.
- Public subnets tagged `kubernetes.io/role/elb=1`, so the controller can place internet-facing LBs.

## Optional hardening before the first deploy

| Where | What |
| --- | --- |
| `ingress/dashboard-nlb.yaml` → `loadBalancerSourceRanges` | Office / VPN ranges allowed to reach the dashboard (recommended) |
| `ingress/agents-nlb.yaml` → `loadBalancerSourceRanges` | Networks agents connect from, if known |
| `ingress/network-policy.yaml` | Narrow the private ranges to your VPC CIDR |

## Deploy (Argo CD)

Wazuh runs on the EKS cluster `dev-cluster` (account 731372490312) and is deployed by the
Argo CD on `kind-sonar`, through [k8s/argocd/apps/wazuh.yaml](../argocd/apps/wazuh.yaml).

The certificates must carry the NLB DNS names, and AWS only assigns those when the NLBs
are created. Argo CD therefore syncs everything first; the Wazuh pods wait in
`ContainerCreating` until step 5 creates their Secrets, then start on their own.

```bash
# 1. Register the EKS cluster with Argo CD (adds the kubeconfig context dev-cluster-731372490312)
k8s/argocd/clusters/dev-cluster/register.sh
EKS=dev-cluster-731372490312

# 2. Install the AWS Load Balancer Controller and wait for it
kubectl --context kind-sonar apply -f k8s/argocd/apps/aws-load-balancer-controller.yaml
kubectl --context $EKS -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=5m

# 3. Push k8s/wazuh to GitHub main (Argo CD deploys what is there), then create the Application
kubectl --context kind-sonar apply -f k8s/argocd/apps/wazuh.yaml

# 4. Wait for the NLBs' DNS names
kubectl --context $EKS -n wazuh get svc wazuh-agents-lb wazuh-dashboard-lb -w   # until EXTERNAL-IP is set
AGENTS_LB=$(kubectl --context $EKS -n wazuh get svc wazuh-agents-lb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
DASHBOARD_LB=$(kubectl --context $EKS -n wazuh get svc wazuh-dashboard-lb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# 5. Certificates, passwords and Secrets (stored in k8s/wazuh/.secrets/ — back this up)
KUBE_CONTEXT=$EKS AGENT_HOSTNAMES=$AGENTS_LB DASHBOARD_HOSTNAMES=$DASHBOARD_LB k8s/wazuh/secrets/create.sh

# 6. Wait for it (indexers first; the first start takes several minutes)
kubectl --context $EKS -n wazuh rollout status sts/wazuh-indexer --timeout=15m
kubectl --context $EKS -n wazuh rollout status sts/wazuh-manager-master sts/wazuh-manager-worker --timeout=10m
kubectl --context $EKS -n wazuh rollout status deploy/wazuh-dashboard --timeout=10m
```

From then on, changes reach the cluster by pushing to `main`; Argo CD reverts manual
`kubectl` edits to anything that is in git. The Secrets are not in git, so Argo CD never
touches them.

Open `https://$DASHBOARD_LB` and log in as `admin`, with the password in
`k8s/wazuh/.secrets/passwords/WAZUH_INDEXER_ADMIN_PASSWORD`. A new NLB can take a few
minutes before its DNS name resolves and its targets turn healthy.

To generate the files without touching the cluster, run `secrets/create.sh --generate-only`.

> **Keep the NLB Services.** Deleting `wazuh-agents-lb` or `wazuh-dashboard-lb` (including a
> `kubectl delete -k`) gives the NLB a new DNS name. The certificates, and every enrolled
> agent, then point at a name that no longer exists. Both Services, and the namespace, are
> annotated so that Argo CD never prunes them, even if the Application is deleted.

## Enroll an agent

5.x agents enroll with a token minted by the Wazuh API. The address in the token must be the
agents NLB name (`$AGENTS_LB`, in `AGENT_HOSTNAMES`).

```bash
kubectl --context $EKS -n wazuh port-forward svc/wazuh-api 55000:55000 &

TOKEN=$(printf 'user = "wazuh:%s"\n' "$(cat k8s/wazuh/.secrets/passwords/WAZUH_MANAGER_API_PASSWORD)" |
  curl -sk -K - -X POST "https://localhost:55000/security/user/authenticate?raw=true")

curl -sk -X POST https://localhost:55000/agents/enrollment-tokens \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"address\": \"$AGENTS_LB\", \"embed_ca\": true, \"ttl\": \"1h\", \"max_uses\": 1}"
```

Pass the returned token to the agent as `WAZUH_ENROLLMENT_TOKEN`. Without `ttl` and `max_uses`, a token lasts 30 days
and enrolls any number of agents.

## Operating notes

- **Secrets are set once.** Each component keeps the passwords it was first started with. Re-running
  `create.sh` reuses what is in `.secrets/` and never rotates. To rotate a password, follow the upstream
  [credentials guide](https://github.com/wazuh/wazuh-kubernetes/blob/v5.0.0-rc1/docs/ref/credentials.md).
- **Adding a hostname.** For agents, delete `.secrets/certs/manager-remoted*.pem`, re-run `create.sh` with all
  the names in `AGENT_HOSTNAMES`, then `kubectl --context $EKS -n wazuh rollout restart sts/wazuh-manager-master sts/wazuh-manager-worker`.
  For the dashboard, do the same with `.secrets/certs/dashboard*.pem`, `DASHBOARD_HOSTNAMES` and
  `kubectl --context $EKS -n wazuh rollout restart deploy/wazuh-dashboard`.
- **Scaling.** Add workers by raising `replicas` in `manager/worker-statefulset.yaml`. Adding indexers also means
  changing the seed hosts, `WAZUH_INDEXER_HOSTS`, and `INDEXER_REPLICAS` in `create.sh`, then reissuing the indexer certificate.
- **Disk.** Volumes use `Retain` and can be grown in place by editing the PVC's `storage` request. Set an
  index retention policy (ISM) in the dashboard, or the indexer volumes eventually fill up.
- **4.x agents** still work inside the cluster (`wazuh-events` :1514, `wazuh-registration` :1515). To accept
  them from outside, add those ports to an NLB and to `ingress/network-policy.yaml`.
- **Agents inside the cluster** (e.g. a DaemonSet in another namespace) are blocked by the default-deny policy.
  Allow their namespace to port 1517 in `ingress/network-policy.yaml`.

## Switching to a domain

When you have a domain (say `wazuh.example.com` for the dashboard, `wazuh-agents.example.com` for agents):

1. Request an ACM certificate for the dashboard name. In `ingress/dashboard-ingress.yaml`, set `host`,
   `certificate-arn` and `inbound-cidrs`. In `kustomization.yaml`, list `ingress/dashboard-ingress.yaml`
   instead of `ingress/dashboard-nlb.yaml`, push, and point the dashboard name at the ALB.
2. Point the agent name at the agents NLB (Route 53 alias). Then reissue the agent listener certificate
   with both names, `AGENT_HOSTNAMES=$AGENTS_LB,wazuh-agents.example.com`, as in *Adding a hostname*. Keeping
   the NLB name lets agents already enrolled on it carry on.
