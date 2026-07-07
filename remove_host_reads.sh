bowtie2 \
	-x bowtie_index/GRCh38_noalt_as \
	-1 BCP0123/BCP0123_R1.fastq.gz \
	-2 BCP0123/BCP0123_R2.fastq.gz \
	-S host.sam \
	-p 16 \
	--very-sensitive \
	--no-unal
