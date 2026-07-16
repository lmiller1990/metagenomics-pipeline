# The Story Thus Far

## What we've built

A metagenomics pipeline for processing human gut microbiome shotgun sequencing data. The sample under analysis is **BCP0123** — ~17.5M paired-end Illumina reads.

### Pipeline steps (implemented as shell scripts)

1. **Host read removal** (`remove_host_reads.sh`) — `bowtie2` against GRCh38_noalt. ~99.99% of reads are non-human (only ~1.5K host reads filtered out).

2. **Taxonomic classification** (`runkraken.sh`) — `kraken2` with the `standard_8gb` database. 50.81% of reads unclassified (DB size limitation); 48.52% classified as Bacteria.

3. **Relative abundance estimation** (`run_bracken.sh`) — `bracken` at species level (`-l S`) re-distributes reads placed higher in the taxonomy down to species nodes.

### Key finding

The sample is dominated by the genus ***Blautia*** (phylum *Bacillota*, class *Clostridia*), accounting for ~22% of total reads. Top species: *Blautia obeum* (9.3%), *Blautia wexlerae* (8.2%), *Blautia massiliensis* (2.7%).

### Supporting code

- `tree.py` — parses the Kraken report into a taxonomic tree (uses `graphviz`; currently prints to stdout, dot rendering commented out).
- `main.py` — placeholder entry point (intended for the deferred analysis).
- `bracken_build.sh` — reference for building the Bracken database (no longer needed — `.dlist` files are included in the prebuilt Kraken2 DB).

## Infrastructure pivot

The distance-from-average analysis (see "Where we're going" below) is on hold. The immediate priority is productionising the pipeline on GCP.

### Orchestration: Path A (now), Path B (future)

We're keeping it simple for 2–3 samples. A Docker image (bowtie2 + Kraken2 + Bracken) is driven by a parameterised bash script running on a single GCE VM. The VM downloads prebuilt databases from GCS at startup, processes all samples sequentially, uploads results to GCS, then self-destructs. No orchestration framework to learn.

When we need to scale beyond a handful of samples, we'll migrate to Nextflow on Cloud Batch ("Path B") for per-step machine sizing, workflow-level retry, and per-sample parallelism. The bash script is designed as a clean extraction point — wrap each step as a Nextflow process with minimal refactoring.

### Database strategy

- **Kraken2 DB**: Pre-built ~100 GB standard database as a compressed tarball in GCS. Downloaded to the VM at startup (~90 seconds on a 100 Gbps NIC). No persistent disk — acceptable at this volume.
- **Bowtie2 index**: GRCh38_noalt, ~3.5 GB, also in GCS.
- **Bracken .dlist files**: Included in the Kraken2 DB tarball — `bracken-build` is unnecessary.

### Per-step machine sizing (reference for Path B)

| Step | Instance type | vCPU | RAM |
|---|---|---|---|
| bowtie2 | n2d-highcpu-16 | 16 | 16 GB |
| kraken2 | n2d-highmem-16 | 16 | 128 GB |
| bracken | n2d-standard-4 | 4 | 16 GB |

Path A uses a single `n2d-highmem-16` for all steps (sized for the most demanding step). The cost difference is negligible at 3 samples (~$4.70 vs ~$2.80 for per-step).

### Design decisions

- Read length is always ~150 bp Illumina — hardcoded in Bracken, no auto-detection.
- No PHI in the dataset; standard GCP project.
- Preemptible VMs are acceptable (save ~60%). We'll add per-sample checkpointing (upload intermediates to GCS after each sample) so preemptions only lose the current sample, not the whole batch.
- The detailed plan (machine types, cost breakdown, startup script, GCS layout, service accounts) is in `PLAN.md`.

## Where we're going (deferred)

Once the GCP pipeline is stable, we'll return to the original analysis question: **"Is this a typical human gut microbiome, and if not, what's unusual about it?"**

The approach is to compare per-species relative abundances against a reference cohort. Because microbiome data is compositional, standard Euclidean statistics are misleading. We'll use the centred log-ratio (CLR) transform and compute z-scores per species — flagging outliers relative to the cohort mean.

The statistical approach and reference dataset options (HMP, American Gut, GMrepo) are documented in the previous version of this file. The key trade-off (methodological consistency from running our exact pipeline on cohort raw reads vs the practicality of using published abundance tables) remains unresolved but will be revisited when we pick this up.
