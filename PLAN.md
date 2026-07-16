# Production Plan — Metagenomics Pipeline

## Current State

Three shell scripts run locally: `remove_host_reads.sh` (bowtie2) → `runkraken.sh` (kraken2) → `run_bracken.sh` (bracken). One sample, ~17.5M paired-end reads, ~1 GB input. Outputs a species-level abundance table. Everything hardcoded.

Scope: 2-3 samples initially. May scale later.

---

## Architecture Decisions

### Orchestration: Two viable paths

**Path A: Docker + bash on a single VM (recommended for now)**

Build a Docker image with bowtie2 + kraken2 + bracken. Write a parameterised bash script that runs the 3 steps. Launch a large GCE VM, pull the image, run the script, upload results to GCS, tear down.

- Pros: No orchestration framework to learn; ~30 lines of bash; dead simple.
- Cons: No workflow-level retry, resume, or parallelism. Adding steps later means editing bash.

**Path B: Nextflow on a single VM**

Same VM setup, but use Nextflow (local executor) to define the 3 processes. Gives structured logging, `-resume`, per-process resource directives.

- Pros: Same reproducibility benefits as Path A; clean upgrade path to Cloud Batch if you scale to 100+ samples.
- Cons: ~100 lines of Groovy DSL to learn. Overkill at 2-3 samples, but not by much.

**Decision: Path A now; migrate to Path B if/when you need multi-sample parallelism or per-step machine sizing.** The bash script is a superset of the existing scripts — just add variables. You can wrap it in Nextflow later in an hour. No lock-in.

### Per-step Machine Sizing

When using per-step machines (requires Nextflow + Cloud Batch), each step gets its own instance type. For a single VM you must use the largest machine needed by any step; per-step lets each step pay only for what it uses.

| Step | Machine | vCPUs | RAM | Rationale |
|---|---|---|---|---|
| **bowtie2** | `n2d-highcpu-16` | 16 | 16 GB | CPU-bound alignment. GRCh38 index is ~3.2 GB + alignment buffers, fits in 16 GB. `n2d-highcpu-32` (32 vCPU, 32 GB) is faster if you want to cut the 1 hr down. |
| **kraken2** | `n2d-highmem-16` | 16 | 128 GB | RAM-bound. 100 GB DB mmap'd — needs ~110 GB working set (OS + DB + process). If OOM: `n2d-highmem-32` (256 GB). More vCPUs don't help much here; it's memory-bandwidth-bound. |
| **bracken** | `n2d-standard-4` | 4 | 16 GB | Light I/O. Reads the Kraken report and `.dlist` files from the DB. Minimal CPU/RAM. |

**Cost comparison (3 samples, preemptible, us-central1):**

| Approach | bowtie2 (3×1 hr) | kraken2 (3×2 hr) | bracken (3×15 min) | Total |
|---|---|---|---|---|
| Single VM (`n2d-highmem-16`) | $1.20 | $2.40 | $0.30 | **~$3.90** |
| Per-step (optimal) | $0.36 (`highcpu-16`) | $2.40 (`highmem-16`) | $0.03 (`standard-4`) | **~$2.79** |

The per-step approach saves ~$1 per batch. Not compelling at 3 samples, but at 100+ samples where you'd also run steps in parallel across samples (bowtie2 for sample 2 while kraken2 finishes sample 1), the savings compound.

**Key point:** On a single VM you're paying for 128 GB RAM during bowtie2 and bracken which only need 16 GB. The RAM is the expensive part of `highmem` instances. Per-step sizing eliminates that waste.

### Platform: GCP

- **Compute**: For Path A (single VM): `n2d-highmem-16` (16 vCPU, 128 GB RAM). The 100 GB DB is mmap'd — 128 GB is just enough for the working set. If kraken2 OOMs, bump to `n2d-highmem-32` (256 GB). Preemptible to save ~60%.
- **Storage**: Cloud Storage bucket for input reads and output reports.
- **Container**: Artifact Registry for the Docker image.

### Database Strategy

Pre-built Kraken2 DB ~100 GB. For 2-3 ad-hoc runs:

**Download from GCS at runtime.** Store the DB tarball in a GCS bucket. On VM startup, download to local SSD (900 GB free on n2d machines). Over a 10 Gbps VM NIC, 100 GB takes ~90 seconds. Extract another ~30 seconds. Total startup: ~2 minutes. For 2-3 runs this is inconsequential.

- If you re-run frequently, wrap a snapshot of a populated disk (clone at boot, <30 sec, no download).
- If you scale to dozens of concurrent samples, use a persistent disk or Filestore, but that's a future problem.

The bowtie2 host index (GRCh38, ~3.5 GB) also lives in GCS and downloads in seconds.

### Containerisation

Single Dockerfile with all three tools. Use Biocontainers as base or `apt install`:

```dockerfile
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y bowtie2 kraken2 bracken
```

Push to Artifact Registry. Tag with a version or git SHA for reproducibility.

---

## Implementation Plan

### Phase 1: Docker image + parameterised script

1. Write `Dockerfile` with bowtie2, kraken2, bracken.
2. Rewrite the three shell scripts as a single parameterised `run_pipeline.sh`:

```sh
#!/bin/bash
set -euo pipefail
SAMPLE_ID=$1
READS_R1=$2
READS_R2=$3
KRAKEN_DB=$4
BOWTIE_INDEX=$5
OUTDIR=$6
THREADS=${7:-16}
READ_LEN=${8:-150}

# 1. Host removal
bowtie2 -p "$THREADS" --very-sensitive \
  -x "$BOWTIE_INDEX" \
  -1 "$READS_R1" -2 "$READS_R2" \
  --un-conc-gz non_host.fastq.gz \
  --al-conc-gz host.fastq.gz \
  -S host.sam

# 2. Kraken2 classification
kraken2 --db "$KRAKEN_DB" --paired --threads "$THREADS" \
  --report "${SAMPLE_ID}.report" \
  --output "${SAMPLE_ID}.kraken" \
  non_host.fastq.1.gz non_host.fastq.2.gz

# 3. Bracken abundance
bracken -d "$KRAKEN_DB" -i "${SAMPLE_ID}.report" \
  -o "${SAMPLE_ID}.bracken" -r "$READ_LEN" -l S

# Upload results
gsutil cp "${SAMPLE_ID}".{report,kraken,bracken} "$OUTDIR/"
```

3. Build and push: `docker build -t us-central1-docker.pkg.dev/PROJECT/metagenomics/pipeline:v1 . && docker push ...`

### Phase 2: GCP setup (one-time)

1. **GCS bucket**: `gs://metagenomics-pipeline/` with structure:
   ```
   gs://metagenomics-pipeline/
     db/
       kraken2_standard_100gb.tar.gz    # the Kraken DB
       GRCh38_noalt_as.tar.gz            # bowtie2 index
     reads/
       BCP0123/BCP0123_R{1,2}.fastq.gz  # input samples
       SAMPLE2/...
       SAMPLE3/...
     results/
       BCP0123/                          # per-sample output
       SAMPLE2/
       SAMPLE3/
   ```

2. **Service account**: With roles `storage.objectViewer` (read reads + DB) and `storage.objectCreator` (write results). No Compute Engine permissions needed if using `gcloud` from your laptop.

3. **Artifact Registry**: Push the Docker image.

### Phase 3: Run

A single `gcloud` command (or a wrapper script) per batch:

```sh
gcloud compute instances create metagenomics-run \
  --zone=us-central1-a \
  --machine-type=n2d-highmem-16 \
  --boot-disk-size=200GB \
  --boot-disk-type=pd-ssd \
  --preemptible \
  --service-account=metagenomics@PROJECT.iam.gserviceaccount.com \
  --scopes=cloud-platform \
  --metadata-from-file startup-script=startup.sh
```

`startup.sh`:

```sh
#!/bin/bash
set -euo pipefail

# Mount local SSD if available (optional, n2d comes with 900 GB ephemeral)
mkdir -p /mnt/disks/local
# (format and mount steps omitted for brevity — use --local-ssd=nvme-block if desired)

# Pull DB and reads from GCS
mkdir -p /data/db /data/reads /data/results
gsutil cp gs://metagenomics-pipeline/db/kraken2_standard_100gb.tar.gz /data/db/
gsutil cp gs://metagenomics-pipeline/db/GRCh38_noalt_as.tar.gz /data/db/
gsutil cp -r gs://metagenomics-pipeline/reads/* /data/reads/

# Extract DBs
tar -xzf /data/db/kraken2_standard_100gb.tar.gz -C /data/db/
tar -xzf /data/db/GRCh38_noalt_as.tar.gz -C /data/db/

# Pull and run Docker
docker pull us-central1-docker.pkg.dev/PROJECT/metagenomics/pipeline:v1

for sample in BCP0123 SAMPLE2 SAMPLE3; do
  docker run --rm \
    -v /data:/data \
    -v /data/results:/results \
    us-central1-docker.pkg.dev/PROJECT/metagenomics/pipeline:v1 \
    /pipeline/run_pipeline.sh \
      "$sample" \
      "/data/reads/${sample}/${sample}_R1.fastq.gz" \
      "/data/reads/${sample}/${sample}_R2.fastq.gz" \
      "/data/db/kraken_db" \
      "/data/db/GRCh38_noalt_as" \
      "gs://metagenomics-pipeline/results/${sample}/" \
      16 150
done

# Self-destruct
gcloud compute instances delete metagenomics-run --zone=us-central1-a --quiet
```

The VM downloads everything, runs all 3 samples sequentially, uploads results, and deletes itself. Total runtime: ~3 samples × ~3.5 hr = ~10.5 hr. On a preemptible VM this costs ~$0.40/hr → ~$4.20 total.

You can also stop instead of delete if you want to inspect intermediates.

### Runtime breakdown (per sample, 17.5M PE reads, n2d-highmem-16)

| Step | Est. time | Notes |
|---|---|---|
| GCS download (DB + reads) | ~3 min | 100 GB DB, single-region egress is free |
| bowtie2 (host removal) | ~1 hr | `--very-sensitive` against GRCh38, 16 threads. CPU-bound. |
| kraken2 (classification) | ~1.5–2 hr | 100 GB DB mmap'd into RAM. 128 GB is tight (DB is 100 GB + OS ~3 GB + process overhead). Should fit; if OOM, bump to `n2d-highmem-32` (256 GB). |
| bracken (abundance) | ~15 min | I/O-bound, reads DB `.dlist` files. |
| **Total per sample** | **~3.5 hr** | |

Kraken2 is the bottleneck. It's memory-bandwidth-bound — the DB is mmap'd and the classifier walks it for each k-mer. 16 cores helps but the 100 GB working set means you're mostly waiting on RAM.

---

## Cost Estimate (2-3 samples, one batch, GCP us-central1)

**Single VM (`n2d-highmem-16`) — Path A:**

| Resource | Spec | Cost |
|---|---|---|
| Compute | n2d-highmem-16 preemptible, ~10.5 hr | ~$4.20 |
| Boot disk | 200 GB pd-ssd, ~10.5 hr | ~$0.40 |
| GCS storage (DB) | 100 GB, Standard class, 1 day | ~$0.07 |
| GCS storage (reads + results) | ~5 GB, negligible | <$0.01 |
| GCS egress | Reads + DB to VM (within GCP, same region) | **$0** |
| **Total** | | **~$4.70** |

**Per-step VMs (Path B / Nextflow) — optimal sizing:** ~$2.79 (see machine sizing table above).

On-demand (single VM): ~$10.

---

## Future Scaling Path

When you outgrow the single-VM approach:

1. **Wrap in Nextflow** (~1 hr of work): same Docker image, but define 3 processes. Run with local executor on the same VM for structured logging and `-resume`.

2. **Per-step machine sizing via Cloud Batch** (Nextflow `google-batch` executor): each process gets its own VM — `n2d-highcpu-16` for bowtie2, `n2d-highmem-16` for kraken2, `n2d-standard-4` for bracken. Per-sample parallelism (bowtie2 for sample 2 runs while kraken2 finishes sample 1). Caveat: with per-step VMs, the DB must be on a shared persistent disk (not downloaded per VM), which adds ~$34/mo for the disk. Worth it only at higher sample volume.

3. **Persistent DB disk or Filestore**: When download-at-startup becomes the bottleneck across many concurrent jobs.

4. **nf-core/taxprofiler**: If you need more profilers (MetaPhlAn, Centrifuge, etc.) alongside Kraken2, adopt the standard community pipeline.

---

## Open Questions

1. ~~Does the prebuilt 100 GB Kraken DB include Bracken `.dlist` files?~~ **Yes. `bracken-build` is unnecessary.** Remove `bracken_build.sh`.
2. ~~Read length variability?~~ **No — always Illumina shotgun, ~150 bp.** Hardcode `-r 150` in Bracken.
3. **Preemptible vs on-demand:** Preemptible saves 60% but the VM can be terminated anytime. At ~10 hr for 3 samples the risk is moderate. If the run gets preempted, you lose all progress and must restart from scratch. Mitigation: write intermediates (per-sample outputs) to GCS after each sample completes; on restart, skip already-completed samples. Or just use on-demand for $10 — cheap enough for a one-off batch.
4. ~~Security/PHI?~~ **No — all open data.** Standard GCP project is fine.
