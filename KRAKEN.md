Here is the metagenomics sample we are working with:

```
seqkit stats BCP0123/*
processed files:  0 / 2 [--------------------------------------] ETA: 0s
processed files:  2 / 2 [======================================] ETA: 0s. done
file                         format  type    num_seqs        sum_len  min_len  avg_len  max_len
BCP0123/BCP0123_R1.fastq.gz  FASTQ   DNA   17,496,265  2,543,693,791       35    145.4      151
BCP0123/BCP0123_R2.fastq.gz  FASTQ   DNA   17,496,265  2,543,889,163       35    145.4      151
```

About 17.5 reads. It is an Illumina shotgun sequencing dataset.

The first thing we need to do is *remove* the host reads (eg, the human reads) from the microbiome reads - the bacteria, archaea, etc.

`bowtie2` has `--un-conc-gz` and `--al-conc-gz` flags.

```
--un-conc <path>   write pairs that didn't align concordantly to <path>
--al-conc <path>   write pairs that aligned concordantly at least once to <path>
(Note: for --un, --al, --un-conc, or --al-conc, add '-gz' to the option name, e.g.  --un-gz <path>, to gzip compress output, or add '-bz2' to bzip2 compress output.)
```

Pairs that did not align to the *host genome* are everything *non human* - what we want to profile. We write the host reads to a file, too, in case we want to analyse those later.

```
bowtie2 \
  -p 16 \
  --very-sensitive \
  -x bowtie_index/GRCh38_noalt_as \
  -1 BCP0123/BCP0123_R1.fastq.gz \
  -2 BCP0123/BCP0123_R2.fastq.gz \
  --un-conc-gz non_host.fastq.gz \
  --al-conc-gz host.fastq.gz \
  -S host.sam
```

Output:

```
80K     host.fastq.1.gz
927M    non_host.fastq.1.gz
80K     host.fastq.2.gz
971M    non_host.fastq.2.gz
```

We can use seqkit again to inspect the data - although unlikely there will be much change, there were already minimal host reads.

```
seqkit stats non_host.fastq.*
processed files:  2 / 2 [======================================] ETA: 0s. done
file                 format  type    num_seqs        sum_len  min_len  avg_len  max_len
non_host.fastq.1.gz  FASTQ   DNA   17,494,738  2,543,498,942       35    145.4      151
non_host.fastq.2.gz  FASTQ   DNA   17,494,738  2,543,694,328       35    145.4      151
```

## Profiling

We can use [GitHub](https://github.com/DerrickWood/kraken2) to profile our community. You need a database, and can get one [here](https://benlangmead.github.io/aws-indexes/k2). I am on a system with 32GB RAM, so I grabbed a smaller subset - Standard with DB capped at 8 GB. This will contain less species, so reads that would otherwise be classified in a larger database could be unclassified (or misclassified), but this is fine to get something running and try it out.

We can run kraken now!

```sh
kraken2 \
  --db ../data/standard_8gb \
  --paired \
  --threads 16 \
  --report sample.report \
  --output sample.kraken \
  ./non_host.fastq.1.gz \
  ./non_host.fastq.2.gz
```

This produces `sample.report` (776K) and `sample.kraken` (1.7G). The `sample.report` is the **summary by taxon** and the `sample.kraken` is the **classification of each read**.

The report is as follows:

