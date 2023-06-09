#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

def helpMessage () {
    log.info """
    OViSP - ONT-based Viral Screening for Plants
    Marie-Emilie Gauthier 23/05/2023

    Usage:
    Run the command
    nextflow run eresearchqut/ovisp {optional arguments}...

    Optional arguments:
      -resume                           Resume a failed run
      --outdir                          Path to save the output file
                                        'results'
      --samplesheet '[path/to/file]'    Path to the csv file that contains the list of
                                        samples to be analysed by this pipeline.
                              Default:  'index.csv'
      Contents of samplesheet csv:
        sampleid,sample_files
        SAMPLE01,/user/folder/sample.fastq.gz
        SAMPLE02,/user/folder/*.fastq.gz

        sample_files can refer to a folder with a number of
        files that will be merged in the pipeline

        --flye_read_error               adjust parameters for given read error rate (as fraction e.g. 0.03)
                              Default:  0.03

        --flye_ont_mode                 Select from nano-raw, nano-corr, nano-hq
                              Default:  'nano-hq'

        --nanoq_code_start              Start codon position in the reference sequence
                              Default:  1

        --nanoq_read_length             Length cut off for read size
                              Default:  9000

        --nanoq_num_ref                 Number of references used in the alignment
                              Default:  1

        --nanoq_qual_threshhold         Base quality score cut off
                              Default:  5

        --nanoq_jump                    Increase this to make larger read intervals
                              Default:  10

    """.stripIndent()
}
// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

if (params.blastn_db != null) {
    blastn_db_name = file(params.blastn_db).name
    blastn_db_dir = file(params.blastn_db).parent
}

if (params.reference != null) {
    reference_name = file(params.reference).name
    reference_dir = file(params.reference).parent
}


switch (workflow.containerEngine) {
  case "singularity":
    bindbuild = "";
    if (params.blastn_db != null) {
      bindbuild = (bindbuild + "-B ${blastn_db_dir} ")
    }
    if (params.reference != null) {
      bindbuild = (bindbuild + "-B ${reference_dir} ")
    }
    bindOptions = bindbuild;
    break;
  default:
    bindOptions = "";
}
process MERGE {
  //publishDir "${params.outdir}/${sampleid}/merge", pattern: '*.fastq.gz', mode: 'link'
  tag "${sampleid}"
  label 'small'

  input:
    tuple val(sampleid), path(lanes)
  output:
    tuple val(sampleid), path("${sampleid}.fastq.gz"), emit: merged
  script:
  """
  cat ${lanes} > ${sampleid}.fastq.gz
  """
}

process NANOPLOT {
  publishDir "${params.outdir}/${sampleid}/nanoplot",  pattern: '*.html', mode: 'link', saveAs: { filename -> "${sampleid}_$filename" }
  publishDir "${params.outdir}/${sampleid}/nanoplot",  pattern: '*.NanoStats.txt', mode: 'link', saveAs: { filename -> "${sampleid}_$filename" }
  tag "${sampleid}"
  cpus 2

  container 'quay.io/biocontainers/nanoplot:1.41.0--pyhdfd78af_0'
  
  input:
    tuple val(sampleid), path(sample)
  output:
    path("*.html")
    path("*NanoStats.txt")
  script:
  """
  NanoPlot -t 2 --fastq ${sample} --prefix raw --plots dot --N50
  """
}

process CUTADAPT_RACE {
  //publishDir "${params.outdir}/${sampleid}/canu", pattern: '*_cutadapt_filtered.fastq.gz', mode: 'link'
  publishDir "${params.outdir}/${sampleid}/cutadapt", pattern: '*_cutadapt.log', mode: 'link'
  tag "${sampleid}"
  label 'medium'

  container 'quay.io/biocontainers/cutadapt:4.1--py310h1425a21_1'

  input:
    tuple val(sampleid), path(sample)
  output:
    //path("${sampleid}_cutadapt_filtered.fastq.gz")
    path("${sampleid}_cutadapt.log")
    tuple val(sampleid), path("${sampleid}_cutadapt_filtered.fastq.gz"), emit: cutadapt_filtered
  script:
  """
  if [[ ${params.race5} == true ]]; then
    cutadapt -j ${task.cpus} --times 3 -e 0.2 -g "AAGCAGTGGTATCAACGCAGAGTACGCGGG;min_overlap=14" -o ${sampleid}_filtered1.fastq.gz ${sample} > ${sampleid}_cutadapt.log
    cutadapt -j ${task.cpus} --times 2 -e 0.2 -a ${params.rev_primer} -o ${sampleid}_filtered2.fastq.gz ${sampleid}_filtered1.fastq.gz  >> ${sampleid}_cutadapt.log
    cutadapt -j ${task.cpus} --times 3 -e 0.2  -a "CCCGCGTACTCTGCGTTGATACCACTGCTT;min_overlap=14" -o ${sampleid}_filtered3.fastq.gz ${sampleid}_filtered2.fastq.gz  >> ${sampleid}_cutadapt.log
    cutadapt -j ${task.cpus} --times 2 -e 0.2 -g ${params.rev_primer_rc} -o ${sampleid}_cutadapt_filtered.fastq.gz ${sampleid}_filtered3.fastq.gz  >> ${sampleid}_cutadapt.log
    rm ${sampleid}_filtered*.fastq.gz

  elif [[ ${params.race3} == true ]]; then
    cutadapt -j ${task.cpus} --times 2 -e 0.2 -g ${params.fwd_primer} -o ${sampleid}_filtered1.fastq.gz ${sample} > ${sampleid}_cutadapt.log
    cutadapt -j ${task.cpus} --times 2 -e 0.2 -a ${params.fwd_primer_rc} -o ${sampleid}_cutadapt_filtered.fastq.gz ${sampleid}_filtered1.fastq.gz  >> ${sampleid}_cutadapt.log
    rm ${sampleid}_filtered*.fastq.gz
  fi
  """
}

process CHOPPER {
  //publishDir "${params.outdir}/${sampleid}/chopper", pattern:'*_filtered.fastq.gz', mode: 'link'
  publishDir "${params.outdir}/${sampleid}/chopper", pattern: '*_chopper.log', mode: 'link'
  tag "${sampleid}"
  label 'large'

  container 'quay.io/biocontainers/chopper:0.5.0--hdcf5f25_2'

  input:
    tuple val(sampleid), path(sample)

  output:
  path("${sampleid}_chopper.log")
    path("${sampleid}_filtered.fastq.gz")
    tuple val(sampleid), path("${sampleid}_filtered.fastq.gz"), emit: chopper_filtered_fq

  script:
  """
  gunzip -c ${sample} | chopper -q ${params.chopper_qual_threshold} -l ${params.chopper_min_read_length} 2> ${sampleid}_chopper.log | gzip > ${sampleid}_filtered.fastq.gz
  """
}

process NANOFILT {
  publishDir "${params.outdir}/${sampleid}/nanofilt", pattern:'*_filtered.fastq.gz', mode: 'link'
  //publishDir "${params.outdir}/${sampleid}/canu", pattern: '*_nanofilt.log', mode: 'link'
  tag "${sampleid}"
  label 'small'

  container 'quay.io/biocontainers/nanofilt:2.8.0--py_0'

  input:
    tuple val(sampleid), path(sample)

  output:
    path("${sampleid}_filtered.fastq.gz")
    //path("${sampleid}_nanofilt.log")
    tuple val(sampleid), path("${sampleid}_filtered.fastq.gz"), emit: nanofilt_filtered_fq

  script:
  """
  gunzip -c ${sample} | NanoFilt -q ${params.nanofilt_qual_threshold} -l ${params.nanofilt_min_read_length} | gzip > ${sampleid}_filtered.fastq.gz
  """
}
/*
process CANU {
  publishDir "${params.outdir}/${sampleid}/denovo", pattern:'*_assembly.fasta', mode: 'link'
  tag "${sampleid}"
  memory "24GB"
  cpus "4"

  container 'quay.io/biocontainers/canu:2.2--ha47f30e_0'

  input:
    tuple val(sampleid), path(sample)

  output:
    path("${sampleid}_canu_assembly.fasta")
    tuple val(sampleid), path("${sampleid}_canu_assembly.fasta"), emit: assembly
    
  script:
  """
  canu -p ${sampleid} -d ${sampleid} \
    genomeSize=${params.canu_genome_size} \
    useGrid=false minOverlapLength=50 minReadLength=50 minInputCoverage=0 corMinCoverage=0 stopOnLowCoverage=0 \
    -nanopore ${sample}
    

  cat ${sampleid}/${sampleid}.contigs.fasta ${sampleid}/${sampleid}.unassembled.fasta > ${sampleid}_canu_assembly.fasta
  """
}
*/

process CANU {
  publishDir "${params.outdir}/${sampleid}/denovo", pattern:'*_assembly.fasta', mode: 'link'
  tag "${sampleid}"
  memory "24GB"
  cpus "4"

  container 'quay.io/biocontainers/canu:2.2--ha47f30e_0'

  input:
    tuple val(sampleid), path(sample)

  output:
    path("${sampleid}_canu_assembly.fasta")
    tuple val(sampleid), path("${sampleid}_canu_assembly.fasta"), emit: assembly
    
  script:
  def canu_options = (params.canu_options) ? " ${params.canu_options}" : ''

  """
  canu -p ${sampleid} -d ${sampleid} \
    genomeSize=${params.canu_genome_size} \
    -nanopore ${sample} ${canu_options}

  cat ${sampleid}/${sampleid}.contigs.fasta ${sampleid}/${sampleid}.unassembled.fasta > ${sampleid}_canu_assembly.fasta
  """
}

//canu -assemble -p ${sampleid} -d ${sampleid} \
//    -corrected -trimmed \
//    genomeSize=${params.canu_genome_size} \
//    readSamplingCoverage=100 \
//    useGrid=false minOverlapLength=50  minReadLength=500 stopOnLowCoverage=0 corMinCoverage=0 \
//    contigFilter="2 0 1.0 0.5 0" \
//    -nanopore ${sample} \

process FLYE {
  publishDir "${params.outdir}/${sampleid}/denovo", mode: 'link'
  tag "${sampleid}"
  label 'large'
  errorStrategy 'ignore'

  container "quay.io/biocontainers/flye:2.9.1--py310h590eda1_0"

  input:
    tuple val(sampleid), path(sample)
  output:
    path 'outdir/*'
    path("${sampleid}_flye_assembly.fasta")
    tuple val(sampleid), path("${sampleid}_flye_assembly.fasta"), emit: assembly
  script:
  """
  flye  --out-dir outdir --threads ${task.cpus} --read-error ${params.flye_read_error} --${params.flye_ont_mode} ${sample}
  
  if [[ ! -s outdir/assembly.fasta ]]
    then
        touch ${sampleid}_flye_assembly.fasta
  else 
    cp outdir/assembly.fasta ${sampleid}_flye_assembly.fasta
  fi
  """
}
/*
process BLASTN_DENOVO {
  publishDir "${params.outdir}/${sampleid}/denovo", mode: 'link'
  tag "${sampleid}"
  label 'small'
  containerOptions "${bindOptions}"

  container 'quay.io/biocontainers/blast:2.13.0--hf3cf87c_0'

  input:
    tuple val(sampleid), path(assembly)
  output:
  path("*.bls")
  tuple val(sampleid), path("${sampleid}_blastn_vs_NT.bls"), emit: blast_results

  script:
  """
  cp ${blastn_db_dir}/taxdb.btd .
  cp ${blastn_db_dir}/taxdb.bti .
  blastn -query ${assembly} \
    -db ${params.blastn_db} \
    -out ${sampleid}_blastn_vs_NT.bls \
    -evalue 1e-3 \
    -num_threads ${params.blast_threads} \
    -outfmt '6 qseqid sgi sacc length pident mismatch gapopen qstart qend qlen sstart send slen sstrand evalue bitscore qcovhsp stitle staxids qseq sseq sseqid qcovs qframe sframe sscinames' \
    -max_target_seqs 5
    
  """
}
*/
process EXTRACT_VIRAL_BLAST_HITS_DENOVO {
  tag "${sampleid}"
  label "large"
  publishDir "$params.outdir/$sampleid/denovo",  mode: 'link', overwrite: true

  container = 'docker://infrahelpers/python-light:py310-bullseye'

  input:
  tuple val(sampleid), path(blast_results)
  output:
  file "${sampleid}_blastn_vs_NT_top_hits.txt"
  file "${sampleid}_blastn_vs_NT_top_viral_hits.txt"
  file "${sampleid}_blastn_vs_NT_top_viral_spp_hits.txt"

  script:
  """  
  cat ${blast_results} > ${sampleid}_blastn_vs_NT.txt

  select_top_blast_hit.py --sample_name ${sampleid} --megablast_results ${sampleid}_blastn_vs_NT.txt
  """
}


process BLASTN2REF {
  publishDir "${params.outdir}/${sampleid}/blast_to_ref", mode: 'link'
  tag "${sampleid}"
  label 'small'
  containerOptions "${bindOptions}"

  container 'quay.io/biocontainers/blast:2.13.0--hf3cf87c_0'

  input:
    tuple val(sampleid), path(assembly)
  output:
    path "BLASTN_reference_vs_${assembly}.txt"

  script:
  """
  blastn -query ${assembly} -subject ${reference_dir}/${reference_name} -evalue 1e-3 -out blastn_reference_vs_${assembly}.txt \
  -outfmt '6 qseqid sacc length pident mismatch gapopen qstart qend qlen sstart send slen evalue bitscore qcovhsp qcovs' -max_target_seqs 5

  echo "qseqid sacc length pident mismatch gapopen qstart qend qlen sstart send slen evalue bitscore qcovhsp qcovs" > header
  cat header blastn_reference_vs_${assembly}.txt > BLASTN_reference_vs_${assembly}.txt

  """
}

process MINIMAP2 {
  publishDir "${params.outdir}/${sampleid}/denovo", mode: 'link'
  tag "${sampleid}"
  label 'large'
  containerOptions "${bindOptions}"

  container 'quay.io/biocontainers/minimap2:2.24--h7132678_1'

  input:
    tuple val(sampleid), path(fastq)
  output:
    tuple val(sampleid), path(fastq), path("${sampleid}_minimap.paf"), emit: paf
  script:
  """
  minimap2 -x ava-ont -t ${params.minimap_threads} ${fastq} ${fastq}  > ${sampleid}_minimap.paf
  """
}

process MINIASM {
  publishDir "${params.outdir}/${sampleid}/denovo", mode: 'link'
  tag "${sampleid}"
  label 'large'
  containerOptions "${bindOptions}"

  container 'quay.io/biocontainers/miniasm:0.3--he4a0461_2'

  input:
    tuple val(sampleid), path(fastq), path(paf)
  output:
    file("${sampleid}_miniasm.fasta")
  script:
  """
  miniasm -f ${fastq} ${paf} > ${sampleid}_miniasm.gfa
  awk '/^S/{print ">"\$2"\\n"\$3}' ${sampleid}_miniasm.gfa > ${sampleid}_miniasm.fasta
  """
}

process MINIMAP2_REF {
  publishDir "${params.outdir}/${sampleid}/minimap2", mode: 'link'
  tag "${sampleid}"
  label 'medium'
  containerOptions "${bindOptions}"

  container 'quay.io/biocontainers/minimap2:2.24--h7132678_1'

  input:
    tuple val(sampleid), path(sample)
  output:
    tuple val(sampleid), file("${sampleid}_aln.sam"), emit: aligned_sample
  script:
  """
  minimap2 -a --MD ${reference_dir}/${reference_name} ${sample} > ${sampleid}_aln.sam
  """
}

process INFOSEQ {
  publishDir "${params.outdir}/${sampleid}/infoseq", mode: 'link'
  tag "${sampleid}"
  label 'small'
  containerOptions "${bindOptions}"

  container "quay.io/biocontainers/emboss:6.6.0--h1b6f16a_5"

  input:
    tuple val(sampleid), path(sample)
  output:
    tuple val(sampleid), path(sample), emit: infoseq_ref
  script:
  """
  infoseq ${reference_dir}/${reference_name} -only -name -length | sed 1d > ${reference_name}_list.txt
  """
}

process SAMTOOLS {
  publishDir "${params.outdir}/${sampleid}/samtools", mode: 'link'
  tag "${sampleid}"
  label 'small'

  container 'quay.io/biocontainers/samtools:1.16.1--h6899075_1'

  input:
    tuple val(sampleid), path(sample)
  output:
    tuple val(sampleid), path("${sampleid}_aln.sorted.bam"), path("${sampleid}_aln.sorted.bam.bai"), emit: sorted_sample
  script:
  """
  samtools view -bt ${reference_dir}/${reference_name} -o ${sampleid}_aln.bam ${sample}
  samtools sort -T /tmp/aln.sorted -o ${sampleid}_aln.sorted.bam ${sampleid}_aln.bam
  samtools index ${sampleid}_aln.sorted.bam
  """
}

process NANOQ {
  publishDir "${params.outdir}/${sampleid}/nano-q", mode: 'link'
  tag "${sampleid}"
  label 'medium'

  container 'ghcr.io/eresearchqut/nano-q:1.0.0'

  input:
    tuple val(sampleid), path(sorted_sample)
  output:
    //path 'Results/*'
    path 'Results'

  script:
  """
  nano-q.py -b ${sorted_sample} -c ${params.nanoq_code_start} -l ${params.nanoq_read_length} -nr ${params.nanoq_num_ref} -q ${params.nanoq_qual_threshhold} -j ${params.nanoq_jump}
  """
}

process PORECHOP {
	tag "${sampleid}"
	label "xlarge2"
	publishDir "$params.outdir/${sampleid}/porechop",  mode: 'copy', pattern: "*.log", saveAs: { filename -> "${sample}_$filename" }

  container = 'docker://quay.io/biocontainers/porechop:0.2.3_seqan2.1.1--0'

	input:
		tuple val(sampleid), path(sample)
	output:
		tuple val(sampleid), file("porechop_trimmed.fastq.gz"), emit: porechop_trimmed_fq
	script:
	"""
	porechop -i ${sample} -t ${params.porechop_threads} -o porechop_trimmed.fastq.gz ${params.porechop_args}
	"""
}

process PORECHOP_ABI {
  tag "${sampleid}"
  label "xlarge2"
  publishDir "$params.outdir/${sampleid}/porechop",  mode: 'copy', pattern: "*.log", saveAs: { filename -> "${sample}_$filename" }

  container = 'docker://quay.io/biocontainers/porechop_abi:0.5.0--py38he0f268d_2'

  input:
    tuple val(sampleid), path(sample)

  output:
    tuple val(sampleid), file("porechop_trimmed.fastq.gz"), emit: porechopabi_trimmed_fq

  script:
  """
  porechop_abi -abi -i ${sample} -t ${params.porechop_threads} -o porechop_trimmed.fastq.gz ${params.porechop_args}
  """
}

process FILTER_HOST {
  cpus "${params.minimap2_threads}"
  tag "${sampleid}"
  label "xlarge2"
  publishDir "$params.outdir/$sampleid/wgs",  mode: 'copy', pattern: '*unaligned_ids.txt', saveAs: { filename -> "${sampleid}_unaligned_ids.txt"}

  container 'quay.io/biocontainers/minimap2:2.24--h7132678_1'

  input:
  tuple val(sampleid), path(filtered)
  output:
  tuple val(sampleid), path(filtered), path("${sampleid}_unaligned_ids.txt"), emit: host_filtered_ids

  script:
  """
  minimap2 -ax splice -uf -k14 ${params.plant_host_fasta} ${filtered} > ${sampleid}_plant_host.sam
  awk '\$6 == "*" { print \$0 }' ${sampleid}_plant_host.sam | cut -f1 | uniq >  ${sampleid}_unaligned_ids.txt
  """
}

process EXTRACT_READS {
  tag "${sampleid}"
  label "large"
  publishDir "$params.outdir/$sampleid/wgs", mode: 'copy', pattern: '*_unaligned.fasta', saveAs: { filename -> "${sampleid}_unaligned.fasta"}

  container = 'docker://quay.io/biocontainers/seqtk:1.3--h7132678_4'

  input:
  tuple val(sampleid), path(filtered), path(unaligned_ids)
  output:
  tuple val(sampleid), path("${sampleid}_unaligned.fasta"), emit: host_filtered_fasta

  script:
  """
  seqtk subseq ${filtered} ${sampleid}_unaligned_ids.txt > ${sampleid}_unaligned.fastq
  seqtk seq -a ${sampleid}_unaligned.fastq > ${sampleid}_unaligned.fasta
  """
}

process FASTQ2FASTA {
  tag "${sampleid}"
  label "large"
  publishDir "$params.outdir/$sampleid/wgs", mode: 'copy', pattern: '*.fasta'

  container = 'docker://quay.io/biocontainers/seqtk:1.3--h7132678_4'

  input:
  tuple val(sampleid), path(fastq)
  output:
  tuple val(sampleid), path("${sampleid}.fasta"), emit: fasta

  script:
  """
  seqtk seq -A -C ${fastq} > ${sampleid}.fasta
  """
}

process CAP3 {
  tag "${sampleid}"
  label "large"
  time "3h"
  publishDir "$params.outdir/$sampleid/cap3", mode: 'copy', pattern: '*_cap3.fasta', saveAs: { filename -> "${sampleid}_cap3.fasta"}

  container = 'docker://quay.io/biocontainers/cap3:10.2011--h779adbc_3'

  input:
  tuple val(sampleid), path(fasta)
  output:
  tuple val(sampleid), path("${sampleid}_cap3.fasta"), emit: contigs

  script:
  """
  cap3 ${fasta}
  cat ${fasta}.cap.singlets ${fasta}.cap.contigs > ${sampleid}_cap3.fasta
  """
}

process BLASTN {
  cpus "${params.blast_threads}"
  tag "${sampleid}"
  label "xlarge"
  time "5h"
  containerOptions "${bindOptions}"
  publishDir "$params.outdir/$sampleid/blast",  mode: 'link', overwrite: true, pattern: '*.bls', saveAs: { filename -> "${sampleid}_blastn_vs_NT.bls"}

  container 'quay.io/biocontainers/blast:2.13.0--hf3cf87c_0'

  input:
  tuple val(sampleid), path(assembly)
  output:
  path("*.bls")
  tuple val(sampleid), path("${sampleid}_${params.blastn_method}_vs_NT.bls"), emit: blast_results

  script:
  def blast_task_param = (params.blastn_method == "blastn") ? "-task blastn" : ''
  """
  cp ${blastn_db_dir}/taxdb.btd .
  cp ${blastn_db_dir}/taxdb.bti .
  blastn ${blast_task_param} \
    -query ${assembly} \
    -db ${params.blastn_db} \
    -out ${sampleid}_${params.blastn_method}_vs_NT.bls \
    -evalue 1e-3 \
    -num_threads ${params.blast_threads} \
    -outfmt '6 qseqid sgi sacc length pident mismatch gapopen qstart qend qlen sstart send slen sstrand evalue bitscore qcovhsp stitle staxids qseq sseq sseqid qcovs qframe sframe sscinames' \
    -max_target_seqs 5
"""
}

process EXTRACT_VIRAL_BLAST_HITS {
  tag "${sampleid}"
  label "large"
  publishDir "$params.outdir/$sampleid/wgs",  mode: 'link', overwrite: true

  container = 'docker://infrahelpers/python-light:py310-bullseye'

  input:
  tuple val(sampleid), path(blast_results)
  output:
  file "${sampleid}_${params.blastn_method}_vs_NT_top_hits.txt"
  file "${sampleid}_${params.blastn_method}_vs_NT_top_viral_hits.txt"
  file "${sampleid}_${params.blastn_method}_vs_NT_top_viral_spp_hits.txt"

  script:
  """  
  cat ${blast_results} > ${sampleid}_blastn_vs_NT.txt

  select_top_blast_hit.py --sample_name ${sampleid} --megablast_results ${sampleid}_${params.blastn_method}_vs_NT.txt
  """
}

process BLASTN_SPLIT {
  //publishDir "${params.outdir}/${sampleid}/blastn", mode: 'link'
  tag "${sampleid}"
  containerOptions "${bindOptions}"
  time "12h"
  memory "48GB"
  cpus "4"

  container 'quay.io/biocontainers/blast:2.13.0--hf3cf87c_0'

  input:
    tuple val(sampleid), path(assembly)
  output:
    tuple val(sampleid), path("${sampleid}*_blastn_vs_NT.bls"), emit: blast_results

  script:
  def blastoutput = assembly.getBaseName() + "_blastn_vs_NT.bls"
  """
  cp ${blastn_db_dir}/taxdb.btd .
  cp ${blastn_db_dir}/taxdb.bti .
  blastn -query ${assembly} \
    -db ${params.blastn_db} \
    -out ${blastoutput} \
    -evalue 1e-3 \
    -num_threads ${params.blast_threads} \
    -outfmt '6 qseqid sgi sacc length pident mismatch gapopen qstart qend qlen sstart send slen sstrand evalue bitscore qcovhsp stitle staxids qseq sseq sseqid qcovs qframe sframe sscinames' \
    -max_target_seqs 5
  """
}

process KRAKEN2 {
	cpus 2
	tag "${sampleid}"
	memory "8GB"
	publishDir "$params.outdir/$sampleid/kraken",  mode: 'copy', pattern: '*filtered.fastq.gz', saveAs: { filename -> "${sample}_$filename" }
	input:
		tuple val(barcode), path(filtered), val(sample), val(genome_size)
	output:
		tuple val(barcode), path("filtered.fastq.gz"), val(sample), val(genome_size), emit: filtered_fastq
		path("*.log")
		path("filtlong_version.txt")
	script:
	"""
	set +eu
	sed '/^@/s/.\s./_/g' ${filtered} > krkinput.fastq
	kraken2 --db $krkdb --use-names --threads 2 krkinput.fastq > krakenreport.txt
	echo "seq_id" > seq_ids.txt 
	awk -F "\\t" '{print \$2}' krakenreport.txt >> seq_ids.txt       
	gawk -F "\\t" 'match(\$0, /\\(taxid\s([0-9]+)\\)/, ary) {print ary[1]}' krakenreport.txt | taxonkit lineage --data-dir $taxondb > lineage.txt
	cat lineage.txt | taxonkit reformat  --data-dir $taxondb | csvtk -H -t cut -f 1,3 | csvtk -H -t sep -f 2 -s ';' -R > seq_tax.txt
	cat lineage.txt | taxonkit reformat -P  --data-dir $taxondb | csvtk -H -t cut -f 1,3 > seq_tax_otu.txt
	paste seq_ids.txt seq_tax.txt > kraken_report_annotated.txt
	paste seq_ids.txt seq_tax_otu.txt > kraken_report_annotated_otu.txt
	"""
}

process RATTLE {
  publishDir "${params.outdir}/${sampleid}/clustering", mode: 'link'
  tag "${sampleid}"
  label 'medium'

  input:
  tuple val(sampleid), path(fastq)

  output:
  tuple val(sampleid), path("transcriptome.fq"), emit: clusters

  container =  'ghcr.io/eresearchqut/rattle-image:0.0.1'


  script:
  """
  rattle cluster -i ${fastq} -t 2 --lower-length 70 --upper-length 100  -o . --rna
  rattle cluster_summary -i ${fastq} -c clusters.out > cluster_summary.txt
  mkdir clusters
  rattle extract_clusters -i ${fastq} -c clusters.out --fastq -o clusters
  rattle correct -i ${fastq} -c clusters.out -t 2
  rattle polish -i consensi.fq -t 2 --rna --summary
  """

}
/*
  cd ${projectDir}/bin
*/

workflow {
  
  if (params.samplesheet) {
    Channel
      .fromPath(params.samplesheet, checkIfExists: true)
      .splitCsv(header:true)
      .map{ row-> tuple((row.sampleid), file(row.sample_files)) }
      .set{ ch_sample }
  } else { exit 1, "Input samplesheet file not specified!" }
  
  MERGE ( ch_sample )
  NANOPLOT ( MERGE.out.merged )
  
  if (params.clustering){
    RATTLE (MERGE.out.merged)
    FASTQ2FASTA( RATTLE.out.clusters )
    CAP3( FASTQ2FASTA.out.fasta )
    if (params.blast_vs_ref) {
      BLASTN2REF ( CAP3.out.contigs )
      }
    else {
      BLASTN( CAP3.out.contigs )
      }
  }
  else if (params.denovo_assembly){
    if (params.minimap) {
      //PORECHOP_ABI (MERGE.out.merged)
      //NANOFILT ( PORECHOP_ABI.out.porechopabi_trimmed_fq )
      //MINIMAP2( NANOFILT.out.nanofilt_filtered_fq )
      MINIMAP2 ( MERGE.out.merged )
      MINIASM( MINIMAP2.out.paf )
    }
    if (params.canu) {
      if ( params.race3 || params.race5 ) {
      CUTADAPT_RACE ( MERGE.out.merged )
      NANOFILT ( CUTADAPT_RACE.out.cutadapt_filtered )
      CANU ( NANOFILT.out.nanofilt_filtered_fq )
      }
      if (params.nanofilt) {
        NANOFILT ( MERGE.out.merged )
        CANU ( NANOFILT.out.nanofilt_filtered_fq )
      }
      else {
        CANU ( MERGE.out.merged )
      }
      if (params.blast_vs_ref) {
          BLASTN2REF ( CANU.out.assembly )
      }
      else {
        BLASTN ( CANU.out.assembly )
        EXTRACT_VIRAL_BLAST_HITS_DENOVO( BLASTN.out.blast_results )
      }
    }
    if (params.flye) {
      FLYE ( MERGE.out.merged )
      if (params.blast_vs_ref) {
        BLASTN2REF ( FLYE.out.assembly )
        }
      else {
        BLASTN( FLYE.out.assembly )
        EXTRACT_VIRAL_BLAST_HITS_DENOVO( BLASTN.out.blast_results )
      }
    }
  }

  else {
    PORECHOP_ABI (MERGE.out.merged)
    //NANOFILT ( PORECHOP_ABI.out.porechopabi_trimmed_fq )
    if (params.host_filtering) {
      FILTER_HOST( PORECHOP_ABI.out.porechopabi_trimmed_fq )
      EXTRACT_READS( FILTER_HOST.out.host_filtered_ids )
      //CAP3( EXTRACT_READS.out.host_filtered_fasta )
      BLASTN_SPLIT( EXTRACT_READS.out.host_filtered_fasta.splitFasta(by: 25000, file: true) )
      //EXTRACT_VIRAL_BLAST_HITS( BLASTN.out.blast_results )
    }
    else if (!params.host_filtering) {
      FASTQ2FASTA( PORECHOP_ABI.out.porechopabi_trimmed_fq )
      BLASTN_SPLIT( FASTQ2FASTA.out.fasta.splitFasta(by: 25000, file: true) )
    }
    BLASTN_SPLIT.out.blast_results
      .groupTuple()
      .set { ch_blastresults }
    EXTRACT_VIRAL_BLAST_HITS( ch_blastresults )
    }

  if (params.map2ref) {
    MINIMAP2_REF ( MERGE.out.merged )
    if (params.infoseq) {
      INFOSEQ ( MINIMAP2_REF.out.aligned_sample )
      SAMTOOLS ( INFOSEQ.out.infoseq_ref )
      NANOQ ( SAMTOOLS.out.sorted_sample )
    }
  }
}
