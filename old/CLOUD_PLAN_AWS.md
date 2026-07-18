# AWS Infrastructure Plan — Terraform (all-in)

## Overview

Terraform-managed AWS infrastructure for the metagenomics pipeline. Single EC2 VM running Docker with the pipeline container. Everything is managed by Terraform so `terraform destroy` tears it all down.

---

## Project & Provider

| Item | Value | Notes |
|---|---|---|
| **AWS region** | `us-east-1` | Lowest cost, matches existing PLAN.md assumptions (closest equivalent to GCP `us-central1`). |
| **Availability zone** | `us-east-1a` | Used for the EC2 instance. |
| **Provider** | `hashicorp/aws` ~> 5.0 | Stable. |

---

## Terraform State Backend

Local backend (`terraform/terraform.tfstate`). Since you run from your laptop with your own credentials, there's no team to share state with. Simpler and avoids the bootstrap step of creating an S3 bucket first.

If you later want to share state (e.g., with CI), migrate to an S3 backend with DynamoDB locking.

---

## Resource List

### 1. `aws_s3_bucket` — `metagenomics-pipeline`

| Attribute | Value |
|---|---|
| Bucket | `metagenomics-pipeline` (must be globally unique) |
| Region | `us-east-1` |
| Object ownership | `BucketOwnerEnforced` (disables ACLs) |
| Versioning | `false` |
| Force destroy | `true` (so `terraform destroy` can delete non-empty bucket) |
| Tags | `{pipeline: metagenomics, managed-by: terraform}` |

Implicit folder structure (convention-based, used by startup script):

```
db/
reads/
results/
```

### 2. `aws_ecr_repository` — `metagenomics`

| Attribute | Value |
|---|---|
| Name | `metagenomics` |
| Image tag mutability | `MUTABLE` |
| Scan on push | `true` |
| Tags | `{pipeline: metagenomics, managed-by: terraform}` |

Repository URI: `{ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/metagenomics:{tag}`

### 3. `aws_instance` — `metagenomics-vm`

| Attribute | Value |
|---|---|
| Name | `metagenomics-vm` |
| AMI | `ami-0e86a20c3fbf7cd06` (Ubuntu 22.04 LTS, us-east-1) |
| Instance type | `m6a.xlarge` (4 vCPU, 16 GB) — roughly equivalent to `e2-standard-4` |
| Root volume size | 100 GB (gp3) |
| On-demand | `true` (no spot — pipeline runs are too long to risk interruption) |
| IAM instance profile | Reference to `aws_iam_instance_profile.metagenomics` |
| VPC security groups | Reference to `aws_security_group.metagenomics` |

**Why Ubuntu 22.04:** Docker installation is straightforward via startup script, and the OS is familiar for SSH debugging. Amazon Linux 2 would work too but adds friction if you need to poke around.

**Why m6a.xlarge:** Non-burstable, AMD-based, same 4 vCPU / 16 GB as the GCP plan. Unlike t3a, it doesn't rely on CPU credits — sustained pipeline runs won't throttle.

**Startup script:** Inline via `user_data` in `main.tf`. Installs Docker, authenticates to ECR, pulls the pipeline image, and runs it. See below.

**Attached EBS volume (optional):** If input reads + DB exceed 100 GB, add an `aws_ebs_volume` and attach it as `/mnt/data`. This is an open question — depends on actual data sizes.

### 4. `aws_security_group` — `metagenomics`

| Attribute | Value |
|---|---|
| Name | `metagenomics` |
| VPC | `default` |
| Ingress | `tcp:22` from `0.0.0.0/0` (or your IP for tighter security) |
| Egress | `0.0.0.0/0` (all traffic) |

Rationale: The startup script might fail and you'll want to SSH in (or use SSM) to debug. If you don't need SSH, drop the ingress rule — the instance can still be accessed via AWS SSM Session Manager.

**Decision:** Keep SSH open to your IP only. Add a variable `ssh_source_ranges` defaulting to `["0.0.0.0/0"]` for simplicity, document that you should restrict it.

### 5. `aws_ebs_volume` — `metagenomics-data`

A 200 GB `gp3` volume in `us-east-1a` attached to the instance at `/dev/sdf` (mounted at `/mnt/data`). Required because the Kraken2 index alone is ~103 GB uncompressed, and the 100 GB root volume can't hold both the OS/Docker overhead and the index.

---

## Startup Script

Inlined in `main.tf` via `user_data`. Contents:

```bash
#!/bin/bash
set -euxo pipefail

DB_DIR=/mnt/data
INDEX_S3_URI="s3://genome-idx/kraken/k2_standard_20260626.tar.gz"
INDEX_FILE="k2_standard_20260626.tar.gz"

# Mount data volume (already formatted if this is a re-run)
mkfs.ext4 /dev/sdf || true
mount /dev/sdf $DB_DIR

# Install Docker
apt-get update
apt-get install -y docker.io
systemctl enable docker
systemctl start docker

# Authenticate to ECR (instance profile handles permissions)
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com

# Pull the pipeline image
docker pull ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/metagenomics:latest

# Seed the Kraken2 index from S3 if not already cached
if [ ! -f $DB_DIR/db/complete ]; then
  mkdir -p $DB_DIR/db
  INSTALL=$(date +%s)
  echo "Downloading Kraken2 index (80 GB gzip)..."
  if aws s3 cp --no-sign-request $INDEX_S3_URI $DB_DIR/$INDEX_FILE 2>/dev/null; then
    echo "Downloaded from public S3 (Open Data)"
  else
    # Fallback: HTTPS (no auth needed)
    curl -L -o $DB_DIR/$INDEX_FILE \
      https://genome-idx.s3.amazonaws.com/kraken/k2_standard_20260626.tar.gz
  fi
  echo "Extracting index..."
  tar xzf $DB_DIR/$INDEX_FILE -C $DB_DIR/db/
  rm $DB_DIR/$INDEX_FILE
  date +%s > $DB_DIR/db/complete
  echo "Index seeded (took $(( $(date +%s) - INSTALL )) seconds)"
fi

# Copy reads from S3
aws s3 cp --recursive s3://${BUCKET_NAME}/reads/ $DB_DIR/reads/

# Run the pipeline
docker run --rm \
  -v $DB_DIR:/data \
  ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/metagenomics:latest \
  /data/db /data/reads /data/results

# Copy results back
aws s3 cp --recursive $DB_DIR/results/ s3://${BUCKET_NAME}/results/

# Self-destruct (optional)
# aws ec2 terminate-instances --instance-ids $(curl -s http://169.254.169.254/latest/meta-data/instance-id)
```

**Index sourcing:** The Kraken2 index is hosted on the `genome-idx` public S3 bucket under the [AWS Open Data Sponsorship Program](https://aws.amazon.com/opendata/). Both buckets are in us-east-1, so S3->EC2 transfer is free. The startup script copies it with `--no-sign-request` (no credentials needed) and caches it on the persistent EBS volume. Subsequent runs skip the download entirely (checks for `$DB_DIR/db/complete`).

**Note:** The instance profile attached to the VM needs `s3:GetObject`/`s3:ListBucket` on the pipeline bucket and `ecr:GetDownloadUrlForLayer`/`ecr:BatchGetImage` on the ECR repository.

**Decision:** Keep startup script inline. Avoid a separate file. The script is short and tightly coupled to the resource. If it grows, extract to `infra/startup.sh`.

---

## IAM

The VM uses an **IAM instance profile** (not the default EC2 service role). Terraform creates a dedicated role with minimal permissions:

| Policy / Action | Resource | Purpose |
|---|---|---|
| `s3:GetObject`, `s3:ListBucket`, `s3:PutObject` | `aws_s3_bucket.metagenomics-pipeline` | Read/write all objects |
| `ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage`, `ecr:GetAuthorizationToken` | `aws_ecr_repository.metagenomics` | Pull Docker image |

No permissions needed for the `genome-idx` bucket — the startup script uses `--no-sign-request` (public dataset).

These are granted via `aws_iam_role_policy` resources attached to the role. The role is associated with the instance via `aws_iam_instance_profile`.

For self-destruct, the instance profile needs `ec2:TerminateInstances`. Since you have admin access and run `terraform destroy`, this isn't needed — you tear down from your laptop, not from inside the VM. The self-destruct line in the startup script is commented out.

---

## VPC

Default VPC. One security group for SSH (see resource 4 above). No additional VPC resources needed.

---

## Terraform File Structure

```
infra/
├── main.tf           # resources (bucket, ECR, EC2, security group, IAM)
├── variables.tf      # region, ssh_source_ranges, etc.
├── outputs.tf        # bucket_name, repo_uri, instance_id, public_ip
└── terraform.tfstate # local state (gitignored)
```

---

## Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `region` | `string` | `us-east-1` | Default region |
| `bucket_name` | `string` | `metagenomics-pipeline` | S3 bucket name (must be globally unique) |
| `repo_name` | `string` | `metagenomics` | ECR repository name |
| `instance_type` | `string` | `m6a.xlarge` | EC2 instance type |
| `use_spot` | `bool` | `false` | Use spot instance (cheaper but can be interrupted) |
| `ssh_source_ranges` | `list(string)` | `["0.0.0.0/0"]` | CIDR blocks allowed SSH access (restrict to your IP) |
| `disk_size_gb` | `number` | `100` | Root EBS volume size |
| `pipeline_image_tag` | `string` | `latest` | Docker image tag to pull |

---

## Outputs

| Output | Value | Notes |
|---|---|---|
| `bucket_name` | `aws_s3_bucket.pipeline.id` | For `aws s3` commands |
| `repository_url` | `aws_ecr_repository.pipeline.repository_url` | Docker push/pull URI |
| `instance_id` | `aws_instance.pipeline.id` | Reference for SSM/SSH |
| `public_ip` | `aws_instance.pipeline.public_ip` | SSH target |

---

## Dependencies

```
S3 Bucket  (no deps)
   │
   ├── IAM policy (S3 access) ──> Bucket
   │
ECR Repo  (no deps)
   │
   ├── IAM policy (ECR access) ──> Repo
   │
Security Group (depends on VPC, but default exists)
   │
EC2 Instance ──> depends on: Security Group, IAM instance profile (for data + image access)
```

Circular dependency note: The instance needs the IAM profile to access S3 and ECR, but the IAM policies reference the bucket and repo which exist independently. No circular issue. Use `depends_on` from the instance to the IAM resources to ensure proper ordering.

---

## Workflow

1. `terraform apply` — provisions S3 bucket, ECR repo, data EBS volume, EC2 instance (with startup script).
2. Instance mounts the EBS data volume, installs Docker, and checks if the Kraken2 index is already cached.
3. **First run only:** Downloads ~80 GB Kraken2 index from the public `genome-idx` S3 bucket (free, same-region, <5 min at 5 Gbps), extracts it to the EBS volume, and marks it cached.
4. Copies input reads from S3, runs the pipeline container, copies results back to S3.
5. Check results with `aws s3 ls s3://{BUCKET_NAME}/results/`.
6. If pipeline fails, SSH in with `ssh ubuntu@{PUBLIC_IP}` or use `aws ssm start-session`.
7. `terraform destroy` — tears down everything. **The data EBS volume is also destroyed** (if you want to keep the cached index between runs, set `delete_on_termination = false` on the volume and keep it in state).

---

## Resolved Decisions

| Question | Decision |
|---|---|
| IAM approach? | Dedicated IAM role + instance profile (not default EC2 role). |
| VM managed by Terraform? | Yes. `aws_instance` resource. |
| VM image? | `ubuntu-22.04-lts` (canonical). Docker installed via startup script. |
| Terraform runs from? | Your laptop, local backend. |
| File structure? | Flat (Option A). |
| Instance self-destruct? | Not needed. `terraform destroy` handles teardown. |
| State backend? | Local. No S3 bootstrap required. |
| Startup script? | Inline in `main.tf`. |

---

## Open Questions

1. **S3 bucket name** — `metagenomics-pipeline` might already be taken. Need a globally unique name (add a random suffix or use a variable).
3. **Public IP** — does the instance need a public IP? Required for Docker pull from ECR and `aws s3` access to S3. Private instance with VPC Gateway Endpoint + NAT Gateway is also an option. Simplest: auto-assign public IP.
4. **Billing** — on-demand m6a.xlarge (~$0.154/hr) + S3 + ECR = a few dollars for a single run. Confirm budget. Spot could cut compute cost ~60% but risks interruption mid-run — not worth it for batch jobs that take hours.
5. **SSM vs SSH** — AWS SSM Session Manager avoids needing a public IP or SSH key. The setup script could include the SSM agent (it's pre-installed on Ubuntu 22.04 AMIs from Canonical). Consider adding SSM as the primary access method and making SSH optional.
