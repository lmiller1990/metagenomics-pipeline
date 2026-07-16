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
- `main.py` — placeholder entry point.
- `bracken_build.sh` — reference for building the Bracken database (already done for `standard_8gb`).

## Where we're going

The user wants to calculate **"distance from average"** — comparing the per-species relative abundances of this sample against a reference cohort to answer: *"Is this a typical human gut microbiome, and if not, what's unusual about it?"*

### The reference cohort question

We discussed possible reference datasets:

| Dataset | Pros | Cons |
|---|---|---|
| **HMP** (Human Microbiome Project) | Gold standard; healthy cohort; well-characterised. | Old data (~2012); may not reflect modern populations. |
| **American Gut** | Large; open-access; includes "healthy-ish" subjects. | Self-reported; less controlled. |
| **GMrepo** | Curated; many disease states; abundance tables available directly. | Compositional data from varied pipelines. |

Key trade-off: running raw reads from a cohort through our *exact* pipeline (bowtie2 → Kraken2 → Bracken) vs using published abundance tables. The former ensures methodological consistency; the latter is more practical but introduces batch effects.

### The statistical approach

Because microbiome data is **compositional** (relative abundances sum to 1), standard Euclidean statistics are misleading. We discussed:

- **Aitchison distance** — log-ratio based distance for compositional data.
- **Centred log-ratio (CLR) transform** — maps compositions to real space, enabling z-score-like outlier detection.
- **Per-species z-scores** — after CLR transform, flag species where the sample deviates significantly from the cohort mean.

### Immediate next step

Agreed on: download the HMP (or similar) cohort abundance table, align species names with our Bracken output, compute CLR-transformed z-scores, and identify the species driving the deviation. This will be implemented in `main.py` (or a new analysis script).
