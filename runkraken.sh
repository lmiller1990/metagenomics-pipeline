kraken2 \
  --db ../data/standard_8gb \
  --paired \
  --threads 16 \
  --report sample.report \
  --output sample.kraken \
  ./non_host.fastq.1.gz \
  ./non_host.fastq.2.gz
