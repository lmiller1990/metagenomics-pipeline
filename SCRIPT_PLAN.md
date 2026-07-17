# Pipeline Execution Script — Design Plan

## Scope

A single entrypoint that runs three tools sequentially for one sample:
bowtie2 (host removal) → kraken2 (classification) → bracken (abundance estimation),
with optional download of DBs from GCS and upload of results back to GCS.

PLAN.md sketches this as a ~30-line bash script. This document evaluates that
approach against a Python alternative and specifies the design in detail.

---

## 1. Language Decision: Python over Bash

### Bash pros (as in PLAN.md)
- Minimal boilerplate for shelling out to tools
- `gsutil cp` and `tar` are natural
- No dependency installation needed inside the container
- Matches the existing three `.sh` scripts directly

### Bash cons
- **No structured error handling.** `set -euo pipefail` helps but doesn't give
  per-step error context, line numbers, or the ability to retry transient
  failures (e.g. a GCS download that drops midway through a 100 GB tarball).
- **No argument validation.** Positional `$1..$N` with no type checking, no
  `--help`, no defaults beyond what you hardcode. Mistakes silently misbehave.
- **No structured logging.** No timestamps, log levels, or machine-parseable
  output. Debugging a failed run means reading interleaved stdout/stderr.
- **No resume capability.** If the script fails mid-way through kraken2 (e.g.
  preempted VM), the next run restarts from scratch. The only mitigation is
  upload-after-each-sample in the caller, not in the pipeline script itself.
- **Retry logic is fragile.** Wrapping `gsutil cp` in a retry loop requires
  bash arithmetic and obscure traps. Almost nobody gets this right.

### Python pros (recommended)
- **Structured error handling.** `try/except` per step with specific exception
  types for download failures, tool non-zero exits, missing files, etc.
- **Retry logic is trivial.** `tenacity` or a 10-line decorator for GCS downloads.
- **Resume / checkpointing.** Write a small JSON state file after each step.
  On restart, detect completed steps and skip them.
- **Argument parsing.** `argparse` gives typed arguments, `--help`, sensible
  defaults, and subcommands if needed (e.g. `pipeline download`, `pipeline run`).
- **Structured logging.** `logging` module with timestamps, log levels, optional
  JSON output for Cloud Logging.
- **Maintainability.** Adding a fourth tool (e.g. FastViromeExplorer) means
  adding a function and a CLI flag, not restructuring `if` chains in bash.
- **Testing.** Unit-testable helper functions (`test_download.py`). Bash scripts
  are effectively untestable beyond running them end-to-end.

### The real cost of Python
- **Extra dependency in the container.** Python 3.13 is already present in
  `ubuntu:24.04`. If using a Biocontainers base, it ships with Python too.
  The cost is zero for standard images; negligible if you `pip install` one
  dependency (`tenacity` or no deps at all if you write a trivial retry loop).
- **~80 lines vs ~30 lines.** The Python version will be longer. Almost all of
  that length is error handling, logging, argument parsing, and docstrings —
  the features bash lacks.

### Recommendation
**Use Python.** The bash version's brevity is its only advantage, and that
brevity is a liability at the first failure mode. For a pipeline that runs
for 3+ hours per sample and downloads 100 GB, the ability to retry downloads,
resume after failure, and log structured output is not nice-to-have — it's
essential. The PLAN.md sketch is a useful spec; implement it in Python.

---

## 2. Script Interface

### CLI (argparse)

```
python /pipeline/run_pipeline.py \
  --sample-id BCP0123 \
  --r1 /data/reads/BCP0123/BCP0123_R1.fastq.gz \
  --r2 /data/reads/BCP0123/BCP0123_R2.fastq.gz \
  --kraken-db /data/db/kraken_db \
  --bowtie2-index /data/db/GRCh38_noalt_as \
  --outdir gs://metagenomics-pipeline/results/BCP0123/ \
  --threads 16 \
  --read-len 150 \
  [--gcs-download-db gs://metagenomics-pipeline/db/kraken2_standard_100gb.tar.gz] \
  [--gcs-download-index gs://metagenomics-pipeline/db/GRCh38_noalt_as.tar.gz] \
  [--state-file /data/state/BCP0123_state.json] \
  [--log-file /var/log/pipeline.log] \
  [--log-format {text,json}]
```

### Why CLI args (not env vars or config file)

| Method | Pros | Cons |
|--------|------|------|
| CLI args | Self-documenting (`--help`), typed, easy to override per invocation | Verbose for many params |
| Env vars | Standard Docker pattern, easy to set in GCE metadata | No validation, no `--help`, hard to see what's expected |
| Config file (YAML/JSON) | Clean for many params, version-controlled | Extra file to mount in Docker, extra parsing |

**Decision: CLI args for per-invocation params (sample ID, paths, threads);
env vars for infra params (GCS bucket name, project ID).** The Docker
entrypoint will be a thin wrapper that passes CLI args through. This gives
the best of both: `docker run ... pipeline.py --help` works, and the outer
`startup.sh` can set env vars once for the whole VM.

### Arguments table

| Argument | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `--sample-id` | str | yes | — | Sample identifier (used in output filenames) |
| `--r1` | Path | yes | — | R1 FASTQ (local after download) |
| `--r2` | Path | yes | — | R2 FASTQ (local after download) |
| `--kraken-db` | Path | yes | — | Kraken2 DB directory (local) |
| `--bowtie2-index` | Path | yes | — | Bowtie2 index basename (local, no `.1.bt2` suffix) |
| `--outdir` | str | yes | — | GCS path (e.g. `gs://bucket/prefix/`) or local path |
| `--threads` | int | no | `16` | Thread count for bowtie2 and kraken2 |
| `--read-len` | int | no | `150` | Read length for bracken (`-r`) |
| `--gcs-download-db` | str | no | — | GCS URL of Kraken2 DB tarball to download before run |
| `--gcs-download-index` | str | no | — | GCS URL of bowtie2 index tarball |
| `--state-file` | Path | no | — | Path to JSON state file for resume |
| `--work-dir` | Path | no | `/tmp/pipeline` | Scratch directory |


### Docker entrypoint

```dockerfile
COPY run_pipeline.py /pipeline/run_pipeline.py
ENTRYPOINT ["python", "/pipeline/run_pipeline.py"]
```

Then invoke as:

```sh
docker run --rm \
  -v /data:/data \
  us-central1-docker.pkg.dev/PROJECT/metagenomics/pipeline:v1 \
  --sample-id BCP0123 \
  --r1 /data/reads/BCP0123/BCP0123_R1.fastq.gz \
  --r2 /data/reads/BCP0123/BCP0123_R2.fastq.gz \
  --kraken-db /data/db/kraken_db \
  --bowtie2-index /data/db/GRCh38_noalt_as \
  --outdir gs://metagenomics-pipeline/results/BCP0123/
```

The `startup.sh` loop from PLAN.md doesn't change — just the per-sample
invocation format.

---

## 3. Prep Phase: Download & Extract

### Sequence

1. Create work directory (`--work-dir` + sample ID subdir)
2. If `--gcs-download-db` is set:
   a. Download tarball via `gsutil cp` with retry (3 attempts, exponential backoff)
   b. Verify integrity: `gsutil hash` or compare MD5 from GCS object metadata
   c. Extract to `--kraken-db` parent directory
   d. Validate that `--kraken-db` / `hash.k2d` exists
   e. Delete tarball to free space
3. Same for `--gcs-download-index`
4. If `--r1` is a `gs://` URL, download to work dir

### Retry strategy for GCS downloads

```
MAX_RETRIES = 3
BASE_DELAY = 5  # seconds

for attempt in 1..MAX_RETRIES:
    run gsutil cp <src> <dst>
    if success: break
    if attempt < MAX_RETRIES:
        sleep(BASE_DELAY * 2 ** (attempt - 1))
    else:
        raise DownloadError(f"Failed after {MAX_RETRIES} attempts: {src}")
```

Use `subprocess.run` with `check=True` and `timeout=3600` for each download.
The 100 GB tarball over 10 Gbps should take ~90 seconds; set timeout well
above expected.

### Integrity verification

GCS objects have MD5 hashes in their metadata (`gsutil stat`). Compare against
local file after download:

```python
def verify_checksum(gcs_path: str, local_path: str) -> bool:
    # gsutil stat returns "Hash (crc32c): ..." and "Hash (md5): ..."
    result = subprocess.run(
        ["gsutil", "stat", gcs_path],
        capture_output=True, text=True, check=True
    )
    expected_md5 = parse_md5_from_stat(result.stdout)
    actual_md5 = hashlib.md5(open(local_path, "rb").read()).hexdigest()
    return expected_md5 == actual_md5
```

For the tarballs, also verify the extracted DB has the expected directory
structure (e.g. `hash.k2d` for Kraken2, `*.1.bt2` for bowtie2).

### Space management

- 100 GB tarball → 100 GB extracted = 200 GB peak
- 3.5 GB tarball → ~10 GB extracted = ~13.5 GB peak
- Total peak: ~215 GB during extraction phase
- VM local SSD: 900 GB → plenty of headroom

After extraction, delete tarballs. Also delete input FASTQ after processing
if disk pressure is a concern (not needed at current scale).

---

## 4. Pipeline Execution

### Step 1: bowtie2 — Host read removal

```python
subprocess.run([
    "bowtie2",
    "-p", str(threads),
    "--very-sensitive",
    "-x", bowtie2_index,
    "-1", r1, "-2", r2,
    "--un-conc-gz", work_dir / "non_host.fastq.gz",
    "--al-conc-gz", work_dir / "host.fastq.gz",
    "-S", work_dir / "host.sam",
], check=True, timeout=BOWTIE_TIMEOUT)
```

- Expected output: `non_host.fastq.1.gz`, `non_host.fastq.2.gz`
- Delete `host.sam` after completion (~1 GB for 17.5M reads)
- Validate paired-end output exists and is non-empty

### Step 2: kraken2 — Taxonomic classification

```python
subprocess.run([
    "kraken2",
    "--db", kraken_db,
    "--paired",
    "--threads", str(threads),
    "--report", str(report_path),
    "--output", str(kraken_path),
    str(work_dir / "non_host.fastq.1.gz"),
    str(work_dir / "non_host.fastq.2.gz"),
], check=True, timeout=KRAKEN_TIMEOUT)
```

- Expected output: `{sample_id}.report`, `{sample_id}.kraken`
- `.kraken` file is ~1.7 GB per sample — consider `--memory-mapping` if the
  DB is on a slow filesystem (not needed for local SSD)
- Validate report has non-zero classified reads

### Step 3: bracken — Abundance re-estimation

```python
subprocess.run([
    "bracken",
    "-d", kraken_db,
    "-i", str(report_path),
    "-o", str(bracken_path),
    "-r", str(read_len),
    "-l", "S",  # species level
], check=True, timeout=BRACKEN_TIMEOUT)
```

- Expected output: `{sample_id}.bracken`
- Also produces `{sample_id}_bracken_species.report` (Bracken's detailed output)
- Validate output exists and has rows beyond the header

### Error handling per step

Each step is wrapped in a `try/except` that:
1. Logs the error with step name, exit code (if available), and stderr tail
2. Writes a `FAILED` state to the state file
3. Re-raises or exits with a distinct exit code (1=download, 2=bowtie2,
   3=kraken2, 4=bracken, 5=upload)

This lets the caller (`startup.sh`) distinguish failure modes when checking
the container exit code.

### Timeouts

| Step | Timeout | Rationale |
|------|---------|-----------|
| bowtie2 | 3 hr | Typical ~1 hr, 3x safety margin |
| kraken2 | 6 hr | Typical ~2 hr, 3x safety margin |
| bracken | 1 hr | Typical ~15 min |
| gsutil cp (DB) | 1 hr | 100 GB at 10 Gbps ~90 sec |
| gsutil cp (index) | 10 min | ~3.5 GB |

---

## 5. Output Phase: Upload to GCS

### What to upload

Primary outputs (uploaded unconditionally):
- `{sample_id}.report` (Kraken2 report)
- `{sample_id}.kraken` (Kraken2 per-read classifications)
- `{sample_id}.bracken` (Bracken abundance table)
- `{sample_id}_bracken_species.report` (Bracken detailed report)

Optional / intermediate (upload if `--upload-intermediates` flag is set):
- `host.fastq.1.gz`, `host.fastq.2.gz` (host reads)
- `host.sam` (bowtie2 alignment)
- `non_host.fastq.1.gz`, `non_host.fastq.2.gz` (non-host reads)
- `state.json` (state file for debugging)

### Upload method

```python
def upload_to_gcs(local_path: Path, gcs_url: str) -> None:
    subprocess.run(
        ["gsutil", "cp", str(local_path), gcs_url],
        check=True, timeout=UPLOAD_TIMEOUT, capture_output=True
    )
```

Use `gsutil -m cp` for parallel upload if uploading multiple files at once.
Wrap in same retry loop as downloads.

### GCS path convention

```
{outdir}/{sample_id}/{filename}
```

Where `outdir` is `gs://metagenomics-pipeline/results/`.

Examples:
```
gs://metagenomics-pipeline/results/BCP0123/BCP0123.report
gs://metagenomics-pipeline/results/BCP0123/BCP0123.kraken
gs://metagenomics-pipeline/results/BCP0123/BCP0123.bracken
gs://metagenomics-pipeline/results/BCP0123/BCP0123_bracken_species.report
```

---

## 6. State File & Resume

### Format (JSON)

```json
{
  "sample_id": "BCP0123",
  "steps": {
    "download_db": {"status": "completed", "started_at": "...", "completed_at": "..."},
    "download_index": {"status": "completed", "started_at": "...", "completed_at": "..."},
    "download_reads": {"status": "completed", "started_at": "...", "completed_at": "..."},
    "bowtie2": {"status": "completed", "started_at": "...", "completed_at": "..."},
    "kraken2": {"status": "completed", "started_at": "...", "completed_at": "..."},
    "bracken": {"status": "completed", "started_at": "...", "completed_at": "..."},
    "upload": {"status": "pending", "started_at": null, "completed_at": null}
  },
  "exit_code": null
}
```

Possible statuses: `pending`, `running`, `completed`, `failed`.

### Resume logic

1. At startup, check if `--state-file` exists
2. If it does, load it and skip any step with `status == "completed"`
3. If a step has `status == "failed"`, log a warning and re-run it
   (or exit immediately — configurable)
4. Update the state file atomically (write to `.tmp`, then `rename`) after
   each step

This is useful for:
- Preempted VM restart: `startup.sh` can check for existing state on the
  persistent disk (or GCS) and re-invoke the container with `--state-file`
- Manual debugging: operator can edit state to re-run a specific step

---

## 7. Logging

### Setup

```python
import logging

def setup_logging(log_file: str | None, format: str = "text"):
    handlers = [logging.StreamHandler(sys.stderr)]
    if log_file:
        handlers.append(logging.FileHandler(log_file))
    if format == "json":
        # Custom JSON formatter for Cloud Logging compatibility
        ...
    else:
        fmt = "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
        logging.basicConfig(level=logging.INFO, format=fmt, handlers=handlers)
```

### What to log at each level

| Level | Events |
|-------|--------|
| INFO | Step start/completion, file sizes, durations |
| WARNING | Retry attempts, non-fatal validation warnings |
| ERROR | Step failures with exit code and stderr tail |
| DEBUG | Full command strings, environment, raw tool output |

### Log output destinations

- **Stderr** (always): Real-time monitoring in container logs
- **Log file** (optional): For post-hoc debugging on the VM
- **GCS** (after upload): State file is uploaded alongside outputs; log file
  can be too if `--upload-logs` is set

---

## 8. Dockerfile Considerations

### Entrypoint patterns

**Recommended: `ENTRYPOINT` with CLI passthrough**

```dockerfile
ENTRYPOINT ["python", "/pipeline/run_pipeline.py"]
```

This lets you run:

```sh
docker run pipeline:v1 --help                           # docs
docker run pipeline:v1 --sample-id BCP0123 ...          # normal run
docker run --entrypoint bash pipeline:v1 -c "..."       # debugging
```

**Not recommended: `CMD` with hardcoded args**

```dockerfile
CMD ["python", "/pipeline/run_pipeline.py", "--sample-id", "BCP0123", ...]
```

This makes the image specific to one sample. The whole point of the parameterised
script is to accept different samples.

### Image requirements

```
FROM ubuntu:24.04

# Install system deps
RUN apt-get update && apt-get install -y \
    bowtie2 \
    kraken2 \
    bracken \
    gsutil \
    python3 \
    && rm -rf /var/lib/apt/lists/*

COPY run_pipeline.py /pipeline/run_pipeline.py

ENTRYPOINT ["python", "/pipeline/run_pipeline.py"]
```

If `gsutil` is not available via apt, install `google-cloud-sdk` or use the
`google-cloud-storage` Python library instead (eliminates gsutil dependency
altogether — see §9).

---

## 9. Alternatives Considered

### Pure Python GCS client (google-cloud-storage)

Instead of shelling out to `gsutil`, use the Python SDK for downloads/uploads.
Pros:
- No `gsutil` binary needed in the container
- Better error handling (native exceptions, not parsing `subprocess` output)
- Streaming download progress callbacks

Cons:
- Adds a `pip install google-cloud-storage` dependency
- Credentials must be in JSON format (vs gsutil which picks up
  `GOOGLE_APPLICATION_CREDENTIALS` natively)

**Decision: Start with `gsutil` subprocess calls.** It works with the same
service account and credentials as every other GCP tool on the VM. If the
retry/integrity logic becomes unwieldy, migrate to the Python SDK.

### Snakemake / Nextflow in-container

Not recommended. If you want a workflow engine, use it as the orchestrator
(outside the container), not inside. The in-container script should be the
smallest atomic unit: "process one sample." The orchestrator decides which
samples, which machines, which order.

---

## 10. Summary: Recommended Approach

| Concern | Decision |
|---------|----------|
| Language | **Python** (argparse + subprocess + logging) |
| Args | CLI args with `--help`; env vars for infra params |
| DB download | `gsutil cp` with retry (3 attempts, exponential backoff) + MD5 verify |
| Pipeline steps | Sequential `subprocess.run(check=True)` per step |
| Error handling | `try/except` per step, distinct exit codes, state file |
| Resume | JSON state file, skip completed steps on restart |
| Logging | Python `logging` to stderr + optional file |
| Upload | `gsutil cp` with retry, same as download |
| Docker entrypoint | `ENTRYPOINT ["python", "/pipeline/run_pipeline.py"]` |
| Dependencies | Zero Python deps (stdlib only) |

The script will be ~100-120 lines, depending on how much retry logic is
inlined vs using `tenacity`. Recommend inlining a simple retry decorator
to keep the dependency count at zero.
