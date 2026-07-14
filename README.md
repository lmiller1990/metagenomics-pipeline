This is a simple metagenomics project. Our goal is to figure out the relative abundance of microbes in this humam gut microbiome sample.

First we use bowtie2 to separate the human (host) reads from the microbes: `remove_host_reads.sh`.

Then `wc -l` to count.

non_host.fastq.1.gz:  69978952 = 17.4M reads
host.fastq.1.gz: 6108 = 1.5K reads

Very few host reads.

Now we must profile and figure out what the community contains.

## Profiling

Now we must doing profiling and figure out *what is in the community*. There are a bunch of tools and techniques depending on what we want. For each read we need to figure out what it belongs to. The core idea is to take each read and check it against the genomes for any microbe we might expect to find in a gut microbiome. A native approach would be to just loop over each read and blast it against a large database of microbes we expect to encounter. 

```
for each read:
  compare against reference database
  assign best matching taxon
  count assignments
  convert to abundance
```

In practice, this is too slow and resource intensive.

Another similar, but more efficient way, is k-mer matching. One tool in this space is Kraken 2 [GitHub](https://github.com/DerrickWood/kraken2), [Paper](https://link.springer.com/article/10.1186/s13059-019-1891-0#Sec1). It breaks the reads into k-mers, (eg if k=31 then into reads that are 31bp in length) and matches those against reference genomes. So for a read of 150bp, with k=31 and a sliding window of 1, the Kraken2 database will contain (150-31)+1=120 entries.
