# SonarQube on Kubernetes

SonarQube Community + PostgreSQL 15, deployed with Kustomize.

```
k8s/
├── kind/kind-config.yaml      # local single-node cluster ("sonar")
└── sonarqube/                 # namespace, secret, postgres, sonarqube
```

## Run locally with kind

Needs Docker, [kind](https://kind.sigs.k8s.io/) and kubectl, plus about 3 GB of free RAM.

```bash
# 1. Create the cluster (also switches kubectl to the kind-sonar context)
kind create cluster --config k8s/kind/kind-config.yaml

# 2. Deploy
kubectl apply -k k8s/sonarqube

# 3. Wait until it's up (first boot takes 1–3 minutes; Ready means status is UP)
kubectl -n sonarqube rollout status deploy/postgres
kubectl -n sonarqube rollout status deploy/sonarqube --timeout=10m

# 4. Open it on localhost (keep this terminal open)
kubectl -n sonarqube port-forward svc/sonarqube 9000:9000
```

Open http://localhost:9000 and log in as `admin` / `admin`. SonarQube asks you to
change the password on first login.

To run the port-forward in the background instead:

```bash
nohup kubectl -n sonarqube port-forward svc/sonarqube 9000:9000 > sonarqube-port-forward.log 2>&1 &
```

## Scan a project

1. In the UI: **Create Project → Local project**, then generate a token.
2. From the project's source directory:

```bash
docker run --rm --network host \
  -e SONAR_HOST_URL=http://localhost:9000 \
  -e SONAR_TOKEN=<your-token> \
  -v "$PWD:/usr/src" \
  sonarsource/sonar-scanner-cli \
  -Dsonar.projectKey=<your-project-key>
```

`--network host` lets the scanner container reach the port-forward on localhost.
Results appear in the UI once the background task finishes.

## Day-to-day

| Task | Command |
|---|---|
| Status | `kubectl -n sonarqube get pods,pvc` |
| SonarQube logs | `kubectl -n sonarqube logs deploy/sonarqube -c sonarqube -f` |
| Postgres shell | `kubectl -n sonarqube exec -it deploy/postgres -- psql -U sonarqube` |
| Apply manifest changes | `kubectl apply -k k8s/sonarqube` |
| Restart SonarQube | `kubectl -n sonarqube rollout restart deploy/sonarqube` |
| Stop the port-forward | `pkill -f "port-forward svc/sonarqube"` |

Data lives on the two PVCs (`postgres-pvc`, `sonarqube-data`), so it survives pod
restarts and redeploys.

## Tear down

```bash
kubectl delete -k k8s/sonarqube     # removes the app AND its data volumes
kind delete cluster --name sonar    # removes the whole local cluster
```

kind clusters don't survive a Docker restart reliably. If the cluster is gone
after a reboot, re-run steps 1–4 (you'll start with an empty database).

## Notes

- **Postgres must stay at `replicas: 1`.** Both pods would share one
  ReadWriteOnce volume and corrupt the data. HA needs a replication operator such
  as CloudNativePG.
- The `init-sysctl` container only *raises* `vm.max_map_count` / `fs.file-max`.
  On kind these are your host's kernel settings, so it never lowers them.
- `postgres-secret.yaml` holds a plaintext password. Fine for local use, but
  don't use it for a shared or production cluster.
- Switching back to EKS: `kubectl config use-context <context>`.
