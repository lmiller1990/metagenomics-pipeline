# GCP Infrastructure Plan — Terraform (all-in)

## Overview

Terraform-managed GCP infrastructure for the metagenomics pipeline. Single VM running Docker with the pipeline container. Everything is managed by Terraform so `terraform destroy` tears it all down.

---

## Project & Provider

| Item | Value | Notes |
|---|---|---|
| **Project ID** | `metagenomics-pipeline` (TBD) | Confirm the actual GCP project ID. Make it a variable. |
| **Default region** | `us-central1` | Lowest cost, matches existing PLAN.md assumptions. |
| **Default zone** | `us-central1-a` | Used for the GCE VM. |
| **Provider** | `hashicorp/google` ~> 6.0 | Stable. |

---

## Terraform State Backend

Local backend (`terraform/terraform.tfstate`). Since you run from your laptop with your own credentials, there's no team to share state with. Simpler and avoids the bootstrap step of creating a GCS bucket first.

If you later want to share state (e.g., with CI), migrate to a GCS backend.

---

## Resource List

### 1. `google_storage_bucket` — `metagenomics-pipeline`

| Attribute | Value |
|---|---|
| Name | `metagenomics-pipeline` |
| Location | `US-CENTRAL1` |
| Storage class | `STANDARD` |
| Uniform bucket-level access | `true` |
| Versioning | `false` |
| Labels | `{pipeline: metagenomics, managed-by: terraform}` |

Implicit folder structure (convention-based, used by startup script):

```
db/
reads/
results/
```

### 2. `google_artifact_registry_repository` — `metagenomics`

| Attribute | Value |
|---|---|
| Location | `us-central1` |
| Format | `DOCKER` |
| Mode | `STANDARD_REPOSITORY` |
| Labels | `{pipeline: metagenomics, managed-by: terraform}` |

Image URI: `us-central1-docker.pkg.dev/{PROJECT}/metagenomics/pipeline:{tag}`

### 3. `google_compute_instance` — `metagenomics-vm`

| Attribute | Value |
|---|---|
| Name | `metagenomics-vm` |
| Zone | `us-central1-a` |
| Machine type | `e2-standard-4` (4 vCPU, 16 GB) |
| Boot disk image | `ubuntu-os-cloud/ubuntu-2204-lts` |
| Boot disk size | 100 GB (SSD persistent) |
| Preemptible | `true` (experiment, tear-down friendly) |
| Service account | None (uses your credentials / default compute SA) |

**Why Ubuntu 22.04:** Docker installation is straightforward via startup script, and the OS is familiar for SSH debugging. Container-Optimized OS would work too but adds friction if you need to poke around.

**Startup script:** Inline via `metadata_startup_script` in `main.tf`. Installs Docker, pulls the pipeline image, and runs it. See below.

**Attached disk (optional):** If input reads + DB exceed 100 GB, add a `google_compute_disk` and attach it as `/mnt/data`. This is an open question — depends on actual data sizes.

### 4. `google_compute_firewall` — `metagenomics-ssh`

| Attribute | Value |
|---|---|
| Name | `metagenomics-ssh` |
| Network | `default` |
| Direction | `INGRESS` |
| Source ranges | `0.0.0.0/0` (or your IP for tighter security) |
| Protocol | `tcp:22` |
| Target tags | `metagenomics-vm` |

Rationale: The startup script might fail and you'll want to SSH in to debug. If you don't need SSH, drop this rule — the VM is created without an external IP (or with one, your call).

**Decision:** Keep SSH open to your IP only. Add a variable `ssh_source_ranges` defaulting to `["0.0.0.0/0"]` for simplicity, document that you should restrict it.

### 5. (Optional) `google_compute_disk` — `metagenomics-data`

If needed, a 200 GB SSD in `us-central1-a` attached to the VM at `/mnt/data`. Only create this if the pipeline's DB + input reads exceed ~80 GB (OS + Docker overhead).

---

## Startup Script

Inlined in `main.tf` via `metadata_startup_script`. Contents:

```bash
#!/bin/bash
set -euxo pipefail

# Install Docker
apt-get update
apt-get install -y docker.io
systemctl enable docker
systemctl start docker

# Authenticate to Artifact Registry (VM uses default compute SA with artifactregistry.reader)
gcloud auth configure-docker us-central1-docker.pkg.dev

# Pull and run the pipeline
docker pull us-central1-docker.pkg.dev/${PROJECT_ID}/metagenomics/pipeline:latest

# Mount GCS bucket via gcsfuse (or use gsutil cp for simpler approach)
# Option A: gsutil cp (simpler, no FUSE)
gsutil -m cp -r gs://${BUCKET_NAME}/db/* /data/db/
gsutil -m cp -r gs://${BUCKET_NAME}/reads/* /data/reads/

docker run --rm \
  -v /data:/data \
  us-central1-docker.pkg.dev/${PROJECT_ID}/metagenomics/pipeline:latest \
  /data/db /data/reads /data/results

# Copy results back
gsutil -m cp -r /data/results/* gs://${BUCKET_NAME}/results/

# Self-destruct (optional)
# gcloud compute instances delete metagenomics-vm --zone=us-central1-a --quiet
```

**Note:** The VM's default compute service account needs `artifactregistry.reader` and `storage.objectAdmin` on the bucket. Since you're running Terraform with admin credentials, you can grant these via Terraform on the default compute SA, or just rely on your project's org policies allowing the default SA broad access.

**Decision:** Keep startup script inline. Avoid a separate file. The script is short and tightly coupled to the resource. If it grows, extract to `infra/startup.sh`.

---

## IAM

No custom service account. The VM uses the **default compute engine service account** (`PROJECT_NUMBER-compute@developer.gserviceaccount.com`). Terraform grants it minimal roles:

| Role | Resource | Purpose |
|---|---|---|
| `roles/storage.objectAdmin` | `google_storage_bucket.metagenomics-pipeline` | Read/write all objects |
| `roles/artifactregistry.reader` | `google_artifact_registry_repository.metagenomics` | Pull Docker image |

These are added via `google_storage_bucket_iam_member` and `google_artifact_registry_repository_iam_member` resources.

For self-destruct, the default compute SA needs `compute.instances.delete` on the VM. Since you have admin access and run `terraform destroy`, this isn't needed — you tear down from your laptop, not from inside the VM. The self-destruct line in the startup script is commented out.

---

## VPC

Default VPC. One additional firewall rule for SSH (see resource 4 above).

---

## Terraform File Structure

```
infra/
├── main.tf           # resources (bucket, repo, VM, firewall, IAM)
├── variables.tf      # project_id, region, zone, ssh_source_ranges, etc.
├── outputs.tf        # bucket_name, repo_uri, vm_name, vm_external_ip
└── terraform.tfstate # local state (gitignored)
```

---

## Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `project_id` | `string` | (required) | GCP project ID |
| `region` | `string` | `us-central1` | Default region |
| `zone` | `string` | `us-central1-a` | VM zone |
| `bucket_name` | `string` | `metagenomics-pipeline` | GCS bucket name (must be globally unique) |
| `repo_id` | `string` | `metagenomics` | Artifact Registry repository ID |
| `machine_type` | `string` | `e2-standard-4` | GCE machine type |
| `preemptible` | `bool` | `true` | Use preemptible VM |
| `ssh_source_ranges` | `list(string)` | `["0.0.0.0/0"]` | CIDR blocks allowed SSH access (restrict to your IP) |
| `disk_size_gb` | `number` | `100` | Boot disk size |
| `pipeline_image_tag` | `string` | `latest` | Docker image tag to pull |

---

## Outputs

| Output | Value | Notes |
|---|---|---|
| `bucket_name` | `google_storage_bucket.pipeline.name` | For `gsutil` commands |
| `repository_uri` | `google_artifact_registry_repository.pipeline.id` | Docker push/pull base |
| `vm_name` | `google_compute_instance.pipeline.name` | Reference for SSH |
| `vm_external_ip` | `google_compute_instance.pipeline.network_interface[0].access_config[0].nat_ip` | SSH target |

---

## Dependencies

```
Bucket  (no deps)
   │
   ├── IAM: storage.objectAdmin (default compute SA) ──> Bucket
   │
Repo  (no deps)
   │
   ├── IAM: artifactregistry.reader (default compute SA) ──> Repo
   │
Firewall (depends on VPC, but default exists)
   │
VM ──> depends on: Firewall (SSH), IAM bindings (for data + image access)
```

Circular dependency note: The VM needs the IAM bindings to access the bucket and repo, but the IAM bindings reference the default compute SA which always exists. No circular issue. Use `depends_on` from the VM to the IAM resources to ensure proper ordering.

---

## Workflow

1. `terraform apply` — provisions bucket, repo, VM (with startup script). VM installs Docker, pulls image, runs pipeline, copies results to bucket.
2. Check results in `gsutil ls gs://{BUCKET_NAME}/results/`.
3. If pipeline fails, SSH in with `gcloud compute ssh metagenomics-vm --zone=us-central1-a` and debug.
4. `terraform destroy` — tears down everything (VM, bucket, repo, firewall rule). State is local, so this is clean.

---

## Resolved Decisions

| Question | Decision |
|---|---|
| Service account? | No. Use default compute SA with scoped IAM grants. |
| VM managed by Terraform? | Yes. `google_compute_instance` resource. |
| VM image? | `ubuntu-os-cloud/ubuntu-2204-lts`. Docker installed via startup script. |
| Terraform runs from? | Your laptop, local backend. |
| File structure? | Flat (Option A). |
| SA self-destruct? | Not needed. `terraform destroy` handles teardown. |
| State backend? | Local. No GCS bootstrap required. |
| Startup script? | Inline in `main.tf`. |

---

## Open Questions

1. **Project ID** — confirm the actual GCP project ID.
2. **Data disk** — does the pipeline need >80 GB of local storage? If so, add `google_compute_disk`.
3. **External IP** — does the VM need a public IP? Required for Docker pull from Artifact Registry and `gsutil` access to GCS. Private VM with Cloud NAT is also an option. Simplest: ephemeral external IP.
4. **Billing** — preemptible VM + bucket + Artifact Registry = a few dollars for a single run. Confirm budget.
