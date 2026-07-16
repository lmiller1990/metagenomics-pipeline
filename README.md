# Metagenomics Pipeline

This is a simple metagenomics project. Our goal is to figure out the relative abundance of microbes in this human gut microbiome sample.

## Data Overview

The sample (BCP0123) was sequenced on an Illumina shotgun platform:

```
seqkit stats BCP0123/*
file                         format  type    num_seqs        sum_len  min_len  avg_len  max_len
BCP0123/BCP0123_R1.fastq.gz  FASTQ   DNA   17,496,265  2,543,693,791       35    145.4      151
BCP0123/BCP0123_R2.fastq.gz  FASTQ   DNA   17,496,265  2,543,889,163       35    145.4      151
```

About 17.5M paired-end reads.

## Host Read Removal

First we use bowtie2 to separate the human (host) reads from the microbes. We write non-host reads to profile and host reads to a file in case we want to analyse them later.

`bowtie2` has `--un-conc-gz` and `--al-conc-gz` flags:

- `--un-conc <path>` — write pairs that didn't align concordantly to `<path>`
- `--al-conc <path>` — write pairs that aligned concordantly at least once to `<path>`

(Add `-gz` to either option name to gzip compress output, or `-bz2` for bzip2.)

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

Read counts after filtering:

- non_host.fastq.1.gz: 69,978,952 lines = 17.4M reads
- host.fastq.1.gz: 6,108 lines = 1.5K reads

Very few host reads. Using seqkit to confirm:

```
seqkit stats non_host.fastq.*
file                 format  type    num_seqs        sum_len  min_len  avg_len  max_len
non_host.fastq.1.gz  FASTQ   DNA   17,494,738  2,543,498,942       35    145.4      151
non_host.fastq.2.gz  FASTQ   DNA   17,494,738  2,543,694,328       35    145.4      151
```

## Profiling

Now we must profile and figure out what the community contains. For each read we need to figure out what it belongs to. The core idea is to take each read and check it against the genomes for any microbe we might expect to find in a gut microbiome. A naive approach would be to loop over each read and blast it against a large database:

```
for each read:
  compare against reference database
  assign best matching taxon
  count assignments
  convert to abundance
```

In practice, this is too slow and resource intensive.

A more efficient way is k-mer matching. One tool in this space is [Kraken 2](https://github.com/DerrickWood/kraken2) ([Paper](https://link.springer.com/article/10.1186/s13059-019-1891-0#Sec1)). It breaks reads into k-mers (e.g. if k=31 then into fragments 31bp in length) and matches those against reference genomes. For a read of 150bp with k=31 and a sliding window of 1, the Kraken2 database will contain (150-31)+1=120 entries.

You need a database, and can get one [here](https://benlangmead.github.io/aws-indexes/k2). On a system with 32GB RAM, I grabbed a smaller subset — Standard with DB capped at 8GB. This will contain fewer species, so reads that would otherwise be classified in a larger database could be unclassified (or misclassified), but it's fine to get something running.

```
kraken2 \
  --db ../data/standard_8gb \
  --paired \
  --threads 16 \
  --report sample.report \
  --output sample.kraken \
  ./non_host.fastq.1.gz \
  ./non_host.fastq.2.gz
```

This produces `sample.report` (776K) and `sample.kraken` (1.7G). The report is the **summary by taxon** and the `.kraken` file is the **classification of each read**.

The report tells us 50.81% of reads are unclassified — probably due to our small database. 48.52% are Bacteria, together representing 99.33% of reads.

`clade_reads` and `direct_reads` mean the Clostridia clade contains 4,805,519 reads in total. 501,764 were directly assigned at the class rank because Kraken could not classify them more specifically. The remaining reads were assigned to descendant taxa (family, genus, etc). The indentation represents the taxonomic hierarchy.

```
  %    clade_reads  direct_reads  rank  taxid  name
 50.81	8888808	8888808	U	0	unclassified
 49.19	8605930	1545	R	1	root
 48.66	8513534	2136	R1	131567	  cellular organisms
 48.52	8488197	54501	D	2	    Bacteria
 33.91	5932339	26853	K	1783272	      Bacillati
 29.00	5073066	96676	P	1239	        Bacillota
 27.47	4805519	501764	C	186801	          Clostridia
 17.21	3010719	389	O	3085636	            Lachnospirales
 17.20	3009764	243644	F	186803	              Lachnospiraceae
  8.19	1432420	210048	G	572511	                Blautia
  3.50	612568	483739	S	40520	                  Blautia obeum
  0.59	102489	102489	S1	411459	                    Blautia obeum ATCC 29174
  0.15	26340	26340	S1	657314	                    Blautia obeum A2-162
  2.72	475997	344329	S	418240	                  Blautia wexlerae
  0.75	131668	131668	S1	1121115	                    Blautia wexlerae DSM 19850
  0.25	43594	43594	S	1737424	                  Blautia massiliensis (ex Durand et al. 2017)
  0.20	34937	0	G1	2648079	                  unclassified Blautia
  0.20	34937	34937	S	2479767	                    Blautia sp. SC05B48
  0.16	27960	24585	S	53443	                  Blautia hydrogenotrophica
  0.02	3375	3375	S1	476272	                    Blautia hydrogenotrophica DSM 10507
  0.11	20051	20051	S	89014	                  Blautia luti
  0.02	3031	3031	S	33035	                  Blautia producta
  0.01	1775	1230	S	1322	                  Blautia hansenii
  0.00	545	545	S1	537007	                    Blautia hansenii DSM 20583
  0.01	939	939	S	1912897	                  Blautia argi
  0.00	665	665	S	2877527	                  Blautia parvula
  0.00	598	598	S	1796616	                  Blautia pseudococcoides
  0.00	257	257	S	2779518	                  Blautia liquoris
  1.65	288237	41461	G	2316020	                Mediterraneibacter
  0.92	160774	120805	S	33039	                  [Ruminococcus] torques
  0.23	39969	39969	S1	657313	                    [Ruminococcus] torques L2-14
  0.26	46332	46332	S	33038	                  Mediterraneibacter gnavus
  0.18	30616	30616	S	592978	                  Mediterraneibacter faecis
```

The remaining ~0.77% are archaea, viruses, and some random human reads that snuck through:

```
0.00	748	1	D	2157	    Archaea
0.00	665	0	K	3366610	      Methanobacteriati
0.00	659	0	P	28890	        Methanobacteriota
0.00	455	3	P1	2290931	          Stenosarchaea group
0.00	277	0	C	183963	            Halobacteria
0.00	277	19	O	2235	              Halobacteriales
0.00	77	4	F	1644056	                Haloferacaceae
...
0.52	90851	0	R1	10239	  Viruses
```

## Relative Abundance

Knowing the composition of the community — what microbes dominate, etc. — is the *relative abundance*. There is a tool that derives this from the Kraken report: [Bracken](https://github.com/jenniferlu717/Bracken/).

Since we used a prebuilt Kraken database, we can run Bracken directly:

```sh
bracken \
  -d ../data/standard_8gb \
  -i sample.report \
  -o sample.bracken \
  -r 150 \ # Illumina shotgun read length
  -l S # species-level estimates
```

The resulting report:

| name | taxonomy_id | taxonomy_lvl | kraken_assigned_reads | added_reads | new_est_reads | fraction_total_reads |
|---|---|---|---|---|---|---|
| Blautia obeum | 40520 | S | 612568 | 184274 | 796842 | 0.09280 |
| Blautia wexlerae | 418240 | S | 475997 | 231781 | 707778 | 0.08243 |
| Blautia massiliensis (ex Durand et al. 2017) | 1737424 | S | 43594 | 192393 | 235987 | 0.02748 |
| Blautia sp. SC05B48 | 2479767 | S | 34937 | 45310 | 80247 | 0.00935 |
| Blautia hydrogenotrophica | 53443 | S | 27960 | 1252 | 29212 | 0.00340 |
| Blautia luti | 89014 | S | 20051 | 6432 | 26483 | 0.00308 |
| Blautia producta | 33035 | S | 3031 | 314 | 3345 | 0.00039 |
| Blautia hansenii | 1322 | S | 1775 | 394 | 2169 | 0.00025 |
| Blautia argi | 1912897 | S | 939 | 146 | 1085 | 0.00013 |
| Blautia parvula | 2877527 | S | 665 | 113 | 778 | 0.00009 |
| Blautia pseudococcoides | 1796616 | S | 598 | 50 | 648 | 0.00008 |
| Blautia liquoris | 2779518 | S | 257 | 5 | 262 | 0.00003 |
| [Ruminococcus] torques | 33039 | S | 160774 | 56420 | 217194 | 0.02530 |
| Mediterraneibacter gnavus | 33038 | S | 46332 | 6803 | 53135 | 0.00619 |
| Mediterraneibacter faecis | 592978 | S | 30616 | 22228 | 52844 | 0.00615 |
| Mediterraneibacter glycyrrhizinilyticus | 342942 | S | 6241 | 723 | 6964 | 0.00081 |

This sample is dominated by the genus *Blautia* (class *Clostridia*, phylum *Bacillota*).
