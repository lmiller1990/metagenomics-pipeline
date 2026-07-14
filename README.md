This is a simple metagenomics project. Our goal is to figure out the relative abundance of microbes in this humam gut microbiome sample.

First we use bowtie2 to separate the human (host) reads from the microbes: `remove_host_reads.sh`.

Then `wc -l` to count.

non_host.fastq.1.gz:  69978952 = 17.4M reads
host.fastq.1.gz: 6108 = 1.5K reads

Very few host reads.

Now we must profile and figure out what the community contains.

