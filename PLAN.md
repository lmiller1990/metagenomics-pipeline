# Production Plan — Metagenomics Pipeline

## Current State

Three shell scripts run locally: `remove_host_reads.sh` (bowtie2) → `runkraken.sh` (kraken2) → `run_bracken.sh` (bracken). One sample, ~17.5M paired-end reads, ~1 GB input. Outputs a species-level abundance table. Everything hardcoded.

Goal: run this reproducibly on GCP at production scale (many samples, large Kraken DB, 128 GB+ RAM instances).

---

## Architecture Decisions

### Orchestration

| Tool | Pros | Cons | Fit |
|---|---|---|---|
| **Nextflow** | nf-core ecosystem (nf-core/taxprofiler is near-identical); mature GCP support (Google Cloud Batch); Groovy DSL is bioinformatics standard; built-in retry/error handling/parallelism. | Workflow DSL adds upfront complexity for a 3-step pipeline. | **Best fit.** |
| **Argo Workflows** | Kubernetes-native; great if already on GKE; general-purpose DAG orchestration. | Requires running a GKE cluster; no bioinformatics ecosystem; have to build everything from scratch. | Overkill unless K8s is a hard requirement. |
| **Snakemake** | Python-based (team already uses Python); simpler for small pipelines. | Cloud execution is less mature than Nextflow; small community outside academic compute. | Reasonable if you want minimal infra. |
| **Cromwell/WDL** | Broad Institute standard; good GCP support via PAPI. | Smaller ecosystem; heavier tooling overhead. | Decent but Nextflow has more momentum. |

**Decision: Nextflow.** It's the lingua franca of bioinformatics cloud pipelines, GCP support is first-class, and nf-core provides reference implementations we can crib from.

### Platform: GCP

- **Compute**: Google Cloud Batch (Nextflow's native GCP executor) or Compute Engine VMs via Nextflow's `google-lifesciences` plugin. Cloud Batch is the modern replacement for Google Genomics Pipelines.
- **Storage**: Cloud Storage (GCS) for input reads and output results. Nearline/Archive classes for long-term storage of raw data.
- **DB hosting**: see below.

### Database Strategy (the hard part)

Pre-built Kraken2 database ~100 GB. We want to avoid copying it from object storage on every run (could be 2-3 minutes on a fast VM, but adds up across many samples and feels wasteful).

**Option A: Persistent disk (recommended)**

Create a GCP persistent disk (e.g. 200 GB SSD, ~$34/mo), populate it once with the Kraken DB, and leave it running. Attach it read-only to each VM. No download time. Simplest.

- Pros: Zero startup cost; always available; can snapshot for disaster recovery.
- Cons: ~$34/mo idle cost when not processing; disk lives in one zone.

**Option B: Snapshot + clone on demand**

Create a disk snapshot of the populated DB. Each run creates a new disk from the snapshot (instant COW availability, data warms up lazily). Delete disk after run.

- Pros: Pay for snapshot storage only (~$5/mo for 100 GB); no idle disk cost.
- Cons: Requires automation to create/attach/delete disks per run; adds ~30 seconds orchestration overhead.

**Option C: Custom VM image**

Bake the DB into a custom Compute Engine image (up to 200 GB boot disk). Boot directly from it.

- Pros: Zero orchestration for DB; image is regional.
- Cons: Image creation/patching is slow; every DB update requires a new image build.

**Option D: GCS copy at runtime**

Keep the DB tarball in GCS, extract to local SSD at boot. A large GCE VM can sustain ~5-10 Gbps to GCS, so 100 GB takes 2-3 minutes.

- Pros: Simplest; no infra to manage.
- Cons: Cold start per run; local SSD is ephemeral (if VM restarts, lose DB).

**Decision: Option A (persistent disk) for now; move to Option B (snapshot + clone) if cost or multi-region matters.** The persistent disk approach is dead simple and $34/mo is negligible compared to compute costs.

If you need to run in multiple zones/regions, switch to snapshots. If you need concurrent multi-sample throughput, consider a Filestore (NFS) volume shared across VMs, but that's >$200/mo and overkill for this scale.

### Containerisation

Use Biocontainers (or build custom) for each tool:

| Tool | Image | Notes |
|---|---|---|
| bowtie2 | `biocontainers/bowtie2:v2.5.4_cv1` | Or latest. |
| kraken2 | `biocontainers/kraken2:v2.1.3_cv1` | Match DB format version. |
| bracken | `biocontainers/bracken:v2.9_cv1` | Bracken version MUST match Kraken DB version. |

A single multi-tool Dockerfile is also fine for such a small pipeline. Simpler to manage one image with `apt install bowtie2 kraken2 bracken` than three upstream images that may drift.

### Host Reference Genome

The GRCh38 bowtie2 index (~3.5 GB) can be downloaded at runtime from a GCS bucket or the Broad/NCBI source. Not large enough to warrant special handling. Include as a configurable parameter.

---

## Implementation Plan

### Phase 1: Container + Local Nextflow

1. Write a `Dockerfile` with bowtie2 + kraken2 + bracken installed.
2. Write a Nextflow `main.nf` pipeline with three processes:
   - `REMOVE_HOST` — bowtie2, output `non_host_R{1,2}.fastq.gz`
   - `CLASSIFY` — kraken2, output `.report` and `.kraken`
   - `ABUNDANCE` — bracken, output `.bracken`
3. Write `nextflow.config` with profile for `local` (Docker executor) and `gcp` (Cloud Batch executor).
4. Test end-to-end on the existing sample BCP0123 locally.

Pipeline signature:

```
nextflow run main.nf \
  --reads "BCP0123/BCP0123_R{1,2}.fastq.gz" \
  --kraken_db /path/to/db \
  --bowtie_index /path/to/GRCh38 \
  --read_length 150 \
  --outdir results/
```

### Phase 2: GCP Infrastructure

1. **Create persistent disk with DB**: Manual one-time setup — launch a small VM, download the prebuilt Kraken DB directly onto a 200 GB SSD persistent disk, detach, keep the disk.
2. **GCS bucket** for input reads and output results. Lifecycle policy: move raw reads to Nearline after 30 days.
3. **Service account** with minimal permissions: GCS read/write, Compute Engine disk attach, Cloud Batch job submit.
4. **Nextflow GCP config**: Point at Cloud Batch, the persistent disk (mounted as `--kraken_db`), the GCS input/output paths.

### Phase 3: Production Hardening

1. **Error handling**: Nextflow's built-in retry with `errorStrategy { retry }` and `maxRetries 3`.
2. **Resume support**: Nextflow's `-resume` flag reuses cached successful steps.
3. **Multi-sample**: Nextflow channel pattern — glob all sample directories, fan out.
4. **Logging**: Stdout/stderr captured per process in Nextflow work dirs. Optionally stream to Cloud Logging.
5. **Cost monitoring**: GCP labels on VMs/disks; Cloud Billing export for per-run cost attribution.
6. **DB version pinning**: Include DB build date in output paths so results are traceable to a specific DB.

### Phase 4: Optional — Analysis Module

The existing `tree.py` / CLR-zscore analysis can become a fourth process in the Nextflow pipeline, or remain a separate local analysis step that reads from GCS.

---

## Sample Configuration (`nextflow.config`)

```groovy
profiles {
  local {
    process.executor = 'local'
    docker.enabled = true
  }
  gcp {
    process.executor = 'google-batch'
    google {
      project = 'my-project'
      region  = 'us-central1'
    }
    process {
      machineType = 'n2d-highmem-8'     // 8 vCPU, 64 GB RAM
      disk {
        additionalDisks = ['my-kraken-db']  // pre-populated persistent disk
      }
    }
  }
}

params {
  read_length  = 150
  bracken_level = 'S'
}
```

---

## Cost Estimates (per sample, GCP us-central1)

| Resource | Spec | ~Cost/run |
|---|---|---|
| Compute (bowtie2) | n2d-highmem-8, ~30 min (estimated) | ~$0.25 |
| Compute (kraken2) | n2d-highmem-16 (128 GB), ~2 hr (estimated, depends on DB size) | ~$1.50 |
| Compute (bracken) | n2d-standard-4, ~5 min | ~$0.02 |
| Persistent disk (idle) | 200 GB SSD pd-ssd, monthly | ~$34/mo |
| GCS storage | ~2 GB output, negligible | <$0.01 |
| **Total per sample** | | **~$2 + $34/mo baseline** |

For 100 samples/month: ~$234 ($200 compute + $34 disk). The persistent disk dominates if you only run a few samples per month; switch to snapshot cloning if volume is low.

---

## Alternatives Considered

### Why not AWS Batch?
No strong reason not to. GCP chosen because the user mentioned it and Nextflow's GCP support is equal to or better than AWS. The architecture is portable — swap `google-batch` for `aws-batch` in `nextflow.config`.

### Why not a single monolithic script on a big VM?
Works for a handful of samples. Breaks down when you want to parallelise across samples, resume failed runs, or avoid babysitting long-running VMs. The Nextflow approach gives you all of that for about 200 lines of config + DSL.

### Why not nf-core/taxprofiler directly?
Taxprofiler does Kraken2+Bracken as one of many profilers. It's a reasonable option if you want the full nf-core ecosystem (pipeline releases, CI testing, community support). The downside is it's a large, complex pipeline and you're locked into their structure. For a focused Kraken2-only pipeline, a custom Nextflow workflow is more maintainable.

---

## Open Questions

1. **How many samples per batch?** Informs whether we need a shared Filestore or can get away with per-VM disk attachment.
2. **Bracken DB version:** Current `bracken_build.sh` ran `bracken-build` on the 8 GB DB. For the 100 GB DB, does the prebuilt distribution already include the Bracken `.dlist` files? (Most do.) If yes, `bracken-build` is unnecessary.
3. **Read length variability:** If reads vary in length across samples, Bracken's `-r` parameter needs to be configurable per sample.
4. **Security:** Is the data protected health information (PHI)? If so, the GCP project needs HIPAA compliance, VPC Service Controls, etc.
