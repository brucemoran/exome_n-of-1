#!/usr/bin/env nextflow

params.help = ""

if (params.help) {
  log.info ''
  log.info '--------------------------------------------------'
  log.info 'NEXTFLOW BAM QC, TRIM, ALIGN, SOMATIC SNV, CNA'
  log.info '--------------------------------------------------'
  log.info ''
  log.info 'Usage: '
  log.info 'nextflow run exome_n-of-1.simg.nf \
              --sampleCsv "data/sample.csv" \
              --refDir "refs" \
              --includeOrder "tumour_A,tumour_B" \
              --germline'
  log.info ''
  log.info 'Mandatory arguments:'
  log.info '    --sampleCsv      STRING      CSV format, headers: type ("germline" or "somatic"),sampleID,/path/to/read1.fastq.gz,/path/to/read2.fastq.gz '
  log.info '    --refDir      STRING      dir in which reference data and required indices held; recommended to run associated reference creation NextFlow, DNAseq_references; still; stuck on GRCh37 for several reasons=('
  log.info ''
  log.info 'Optional argument:'
  log.info '    --includeOrder      STRING      in final plots, use this ordering of samples (if multiple somatic); comma-separated, no spaces'
  log.info '    --germline      STRING      include germline calling with GATK4 HaplotypeCaller for all samples'
  log.info ''
  exit 1
}

/* -2: Global Variables
*/
params.runDir = "$workflow.launchDir"
params.outDir = "$params.runDir/analysis"
params.scriptDir = "$params.runDir/scripts"
params.exomebed = "$params.refDir/exome.bed"

/* into/set Channels
*/
Channel.fromPath("$params.refDir/human_g1k_v37{.fasta,.fasta.amb,.fasta.ann,.fasta.bwt,.fasta.fai,.fasta.pac,.fasta.sa}", type: 'file')
       .flatten().collect().set { bwa_index }
Channel.fromPath("$params.refDir/human_g1k_v37.{fasta,fasta.fai,dict}", type: 'file')
       .flatten().collect().into { gatk_fasta; gatkgerm_fasta; mltmet_fasta; fcts_fasta; mutect2_fasta; mantastrelka_fasta; lancet_fasta; vep_fasta; cpsrgerm_fasta }
Channel.fromPath("$params.refDir/human_g1k_v37.dict", type: 'file')
       .flatten().collect().set { fcts_dict }
Channel.fromPath("$params.refDir/exome.bed.interval_list", type: 'file')
       .flatten().collect().into { gatk_exomebedintlist; gatkgerm_exomebedintlist; mltmet_exomebedintlist; mutect2_exomebedintlist; cpsrgerm_exomebedintlist }
Channel.fromPath("$params.refDir/exome.bed", type: 'file')
       .flatten().collect().into { msi_exomebed; lancet_exomebed }
Channel.fromPath("$params.refDir/exome.bed.{gz,gz.tbi}", type: 'file')
       .flatten().collect().set { mantastrelka_exomebedgz }
Channel.fromPath("$params.refDir/dbsnp_*.{vcf,vcf.tbi}", type: 'file')
       .flatten().collect().into { fcts_dbsnp; gatk_dbsnp; gatkgerm_dbsnp; mutect2_dbsnp }
Channel.fromPath("$params.refDir/KG_omni*.{vcf,vcf.tbi}", type: 'file')
       .flatten().collect().set { gatkgerm_omniKg }
Channel.fromPath("$params.refDir/KG_phase1*.{vcf,vcf.tbi}", type: 'file')
       .flatten().collect().set { gatkgerm_phase1Kg }
Channel.fromPath("$params.refDir/hapmap*.{vcf,vcf.tbi}", type: 'file')
       .flatten().collect().set { gatkgerm_hapmap }
Channel.fromPath("$params.refDir/COSMIC_CGC.bed", type: 'file')
       .flatten().collect().set { fcts_cosmicbed }
Channel.fromPath("$params.refDir/msisensor_microsatellites.list", type: 'file')
       .flatten().collect().set { msi_ssr }
Channel.fromPath("$params.refDir/mutect2_GetPileupSummaries.vcf.{gz,gz.tbi}", type: 'file')
       .flatten().collect().set { mutect2_gps }

/* -1: Install scripts required if not extant
*/
process scrpts {

  publishDir path: "$params.scriptDir", mode: "copy", pattern: "*"

  output:
  file('*') into completedmin1
  file('facets_cna.call.R') into facetscallscript
  file('facets_cna_consensus.call.R') into facetsconcscript
  file('facets_cna_consensus.func.R') into facetsconfscript
  file('filterLancetSomaticFormat.pl') into filterlancetscript
  file('filterMuTect2Format.pl') into filtermutect2script
  file('filterStrelka2IndelFormat.pl') into filterstrelka2iscript
  file('filterStrelka2SNVFormat.pl') into filterstrelka2sscript
  file('MuTect2_contamination.call.R') into mutect2contamscript
  file('QDNAseq_CNA.tumour-germline.call.R') into qdnaseqscript
  file('variants_GRanges*.R') into variantsGRangesscript

  script:
  """
  git clone https://github.com/brucemoran/Exome_n-of-1
  mv ./Exome_n-of-1/scripts/* ./
  rm -rf ./Exome_n-of-1

  git clone https://github.com/brucemoran/somaticVariantConsensus
  mv ./somaticVariantConsensus/scripts/* ./
  rm -rf ./somaticVariantConsensus
  """
}
completedmin1.subscribe { println "Scripts, images output to: $params.scriptDir" }

/* 0.00: Input using sample.csv
*/
Channel.fromPath("$params.sampleCsv", type: 'file')
       .splitCsv( header: true )
       .map { row -> [row.type, row.sampleID, file(row.read1), file(row.read2)] }
       .set { bbduking }

/* 0.0: Input trimming
*/
process bbduke {

  label 'c10_30G_cpu_mem'

  publishDir path: "$params.outDir/$sampleID/bbduk", mode: "copy", pattern: "*.txt"

  input:
  set val(type), val(sampleID), file(read1), file(read2) from bbduking

  output:
  file('*') into completed0_0
  set val(type), val(sampleID), file(read1), file(read2) into fastping
  set val(type), val(sampleID), file('*.bbduk.R1.fastq.gz'), file('*.bbduk.R2.fastq.gz') into bwa_memming

  script:
  """
  {
    sh bbduk.sh ${params.quarter_javamem} \
      in1=$read1 \
      in2=$read2 \
      out1=$sampleID".bbduk.R1.fastq.gz" \
      out2=$sampleID".bbduk.R2.fastq.gz" \
      k=31 \
      mink=5 \
      hdist=1 \
      ktrim=r \
      trimq=20 qtrim=rl \
      maq=20 \
      ref=/usr/local/bbmap/resources/adapters.fa \
      tpe \
      tbo \
      stats=$sampleID".bbduk.adapterstats.txt" \
      overwrite=T
  } 2>&1 | tee > $sampleID".bbduk.runstats.txt"
  """
}
completed0_0.subscribe { println "Completed BBDuk: " + it.toString().tokenize("/").last() }

process fastp {

  label 'c8_24G_cpu_mem'

  publishDir path: "$params.outDir/$sampleID/fastp", mode: "copy", pattern: "*.html"

  input:
  set val(type), val(sampleID), file(read1), file(read2) from fastping

  output:
  file('*.html') into completed0_1
  file('*.json') into fastp_multiqc

  script:
  """
  fastp -w ${task.cpus} -h $sampleID".fastp.html" -j $sampleID".fastp.json" --in1 $read1 --in2 $read2
  """
}
completed0_1.subscribe { println "Completed Fastp: " + it }

/* 1.0: Input alignment
*/
process bwamem {

  label 'c20_60G_cpu_mem'

  publishDir path: "$params.outDir/$sampleID/bwa", mode: "copy", pattern: "*[!bam]"

  input:
  set val(type), val(sampleID), file(read1), file(read2) from bwa_memming
  set file(fa), file(am), file(an), file(bw), file(fai), file(pa), file(sa) from bwa_index

  output:
  val(sampleID) into completed1_0
  set val(type), val(sampleID), file('*.bam'), file('*.bai') into dup_marking

  script:
  """
  DATE=\$(date +"%Y-%m-%dT%T")
  RGLINE="@RG\\tID:$sampleID\\tPL:ILLUMINA\\tSM:$sampleID\\tDS:$type\\tCN:UCD\\tLB:LANE_X\\tDT:\$DATE"

  {
    bwa mem \
    -t${task.cpus} \
    -M \
    -R \$RGLINE \
    $fa \
    $read1 $read2 | \
    samtools sort -T "tmp."$sampleID -o $sampleID".sort.bam"

  samtools index $sampleID".sort.bam"

  samtools view -hC -T $fa $sampleID".sort.bam" > $sampleID".sort.cram"
  } 2>&1 | tee > $sampleID".bwa-mem.log"
  """
}
completed1_0.subscribe { println "Completed bwa-mem: " + it }

/* 1.1: MarkDuplicates
*/
process mrkdup {

  label 'c40_120G_cpu_mem'

  publishDir path: "$params.outDir/$sampleID/picard/markdup", mode: "copy", pattern: "*[!.metrics.txt]"
  publishDir path: "$params.outDir/$sampleID/picard/metrics", mode: "copy", pattern: "*.metrics.txt"

  input:
  set val(type), val(sampleID), file(bam), file(bai) from dup_marking

  output:
  val(sampleID) into completed1_1
  file('*md.metrics.txt') into mrkdup_multiqc
  set val(type), val(sampleID), file('*.md.bam'), file('*.md.bam.bai') into gatk4recaling

  script:
  """
  OUTBAM=\$(echo $bam | sed 's/bam/md.bam/')
  OUTMET=\$(echo $bam | sed 's/bam/md.metrics.txt/')
  {
    picard-tools ${params.quarter_javamem} \
      MarkDuplicates \
      TMP_DIR=./ \
      INPUT=$bam \
      OUTPUT=/dev/stdout \
      COMPRESSION_LEVEL=0 \
      QUIET=TRUE \
      METRICS_FILE=\$OUTMET \
      REMOVE_DUPLICATES=FALSE \
      ASSUME_SORTED=TRUE \
      VALIDATION_STRINGENCY=LENIENT \
      VERBOSITY=ERROR | samtools view -Shb - > \$OUTBAM

  samtools index \$OUTBAM
  } 2>&1 | tee > $sampleID".picard-tools_markDuplicates.log.txt"
  """
}
completed1_1.subscribe { println "Completed MarkDuplicates: " + it }

/* 1.2: GATK4 BestPractices
* as per best practices of GATK4
*/
process gtkrcl {

  label 'c10_30G_cpu_mem'

  publishDir path: "$params.outDir/$sampleID/gatk4/bestpractice", mode: "copy"

  input:
  set val(type), val(sampleID), file(bam), file(bai) from gatk4recaling
  set file(fa), file(fai), file(dict) from gatk_fasta
  set file(dbsnp), file(dbsnpidx) from gatk_dbsnp
  file(exomebedintlist) from gatk_exomebedintlist

  output:
  val(sampleID) into completed1_2
  file('*.table') into gtkrcl_multiqc
  set val(type), val(sampleID), file('*.bqsr.bam') into (germfiltering, somafiltering)
  set val(type), val(sampleID), file('*.bqsr.bam') into gatk_germ

  script:
  """
  {
    gatk BaseRecalibrator \
    -R $fa \
    -I $bam \
    --known-sites $dbsnp \
    --use-original-qualities \
    -O ${sampleID}.recal_data.table \
    -L $exomebedintlist

  #ApplyBQSR
  OUTBAM=\$(echo $bam | sed 's/bam/bqsr.bam/')
  gatk ApplyBQSR \
    -R $fa \
    -I $bam \
    --bqsr-recal-file ${sampleID}.recal_data.table \
    --add-output-sam-program-record \
    --use-original-qualities \
    -O \$OUTBAM \
    -L $exomebedintlist

  } 2>&1 | tee > $sampleID".GATK4_recal.log.txt"
  """
}
completed1_2.subscribe { println "Completed GATK4 BaseRecalibration: " + it }

/* 1.25: GATK4 Germline
*/
process gatkgerm {

  label 'c40_120G_cpu_mem'

  publishDir "$params.outDir/$type/$sampleID/gatk4/HC_germline", mode: "copy", pattern: "*"

  input:
  set val(type), val(sampleID), file(bam) from gatk_germ
  set file(fa), file(fai), file(dict) from gatkgerm_fasta
  set file(dbsnp), file(dbsnpidx) from gatkgerm_dbsnp
  set file(omni1000g), file(omni1000gidx) from gatkgerm_omniKg
  set file(mills1000g), file(mills1000gidx) from gatkgerm_phase1Kg
  set file(hapmap), file(hapmapidx) from gatkgerm_hapmap
  file(exomebedintlist) from gatkgerm_exomebedintlist

  output:
  val(sampleID) into completedhcgerm
  set val(sampleID), file('*recal_filt.vcf.gz'), file('*recal_filt.vcf.gz.tbi') into germ_vcf

  when:
  params.germline
  type == "germline"

  script:
  """
  samtools index $bam > $bam".bai"
  {
  #HaplotypeCaller
  INPUTBAM=$bam
  OUTVCF=\$(echo \$INPUTBAM | sed 's/bam/hc.vcf/')
  gatk --java-options ${params.full_javamem} HaplotypeCaller \
    -R $fa \
    -I \$INPUTBAM \
    --dont-use-soft-clipped-bases \
    --standard-min-confidence-threshold-for-calling 20 \
    --dbsnp $dbsnp \
    -O input.recal.vcf \
    -L $exomebedintlist

  gatk --java-options ${params.full_javamem} VariantRecalibrator \
    -R $fa \
    --variant input.recal.vcf \
    --resource hapmap,known=false,training=true,truth=true,prior=15.0:$hapmap \
    --resource omni,known=false,training=true,truth=false,prior=12.0:$omni1000g \
    --resource 1000G,known=false,training=true,truth=false,prior=10.0:$hsnp1000g \
    --resource dbsnp,known=true,training=false,truth=false,prior=2.0:$dbsnp \
    -an QD -an MQ -an MQRankSum -an ReadPosRankSum -an FS -an SOR -an InbreedingCoeff \
    --mode BOTH \
    --recal-file output.recal \
    --tranches-file output.tranches \
    --rscript-file output.recal.plots.R

  FILTVCF=\$(echo \$OUTVCF | sed 's/vcf/recal_filt.vcf/')
  gatk --java-options ${params.full_javamem} ApplyVQSR \
    -R $fa \
    --variant input.recal.vcf \
    --truth-sensitivity-filter-level 99.0 \
    --tranches-file output.tranches \
    --recal-file output.recal \
    --mode BOTH \
    --output \$FILTVCF

  bgzip \$FILTVCF
  tabix \$FILTVCF".gz"
  } 2>&1 | tee $sampleID".GATK4_HaplotypeCaller-germline.log.txt"

  """
}
completedhcgerm.subscribe { println "Completed GATK4 HC Variant Calling: " + it }

/* 1.25: GATK4 Germline
*/
process cpsrgerm {

  label 'c40_120G_cpu_mem'

  publishDir "$params.outDir/$type/$sampleID/calls/cpsr_germline", mode: "copy", pattern: "*"

  input:
  set val(sampleID), file(vcf), file(tbi) from germ_vcf
  set file(fa), file(fai), file(dict) from cpsrgerm_fasta
  file(exomebedintlist) from gatkgerm_exomebedintlist

  output:
  val(sampleID) into completedcpsr
  file('*') into cpsr_vcfs

  when:
  params.germline

  script:
  """
  {
    cpsr.py \
      --input_vcf $vcf \
      --no-docker \
      /data/genome/reference/pcgr/GRCh37 \
      ./ \
      grch37 \
      /data/genome/reference/cpsr/cpsr-0.3.0/cpsr.toml \
      $sampleID

  } 2>&1 | tee $sampleID".cpsr.log.txt"

  """
}
completedcpsr.subscribe { println "Completed cpsr Germline Variant Reporting: " + it }

/* 1.3: filter germ into a channel, index bam
*/
process grmflt {

  input:
  set val(type), val(sampleID), file(bam) from germfiltering

  output:
  file(bam) into germbamcombine
  file('*.bam.bai') into germbaicombine
  set val(sampleID), file(bam), file('*.bam.bai') into gmultimetricing

  when:
  type == "germline"

  script:
  """
  samtools index $bam > $bam".bai"
  """
}

/* 1.4: filter somatic into a channel, index bam
*/
process smaflt {

  input:
  set val(type), val(sampleID), file(bam) from somafiltering

  output:
  set val(sampleID), file(bam), file ('*.bam.bai') into (multimetricing, germcombine)

  when:
  type != "germline"

  script:
  """
  samtools index $bam > $bam".bai"
  """
}

/*1.5 combine germline with somatic and unique those outputs
*/
process combinegs {

    echo true

    input:
    set val(sampleID), file(bam), file (bai) from germcombine
    each file(germlinebam) from germbamcombine
    each file(germlinebai) from germbaicombine

    output:
    set val(sampleID), file(bam), file(bai), stdout, file(germlinebam), file(germlinebai) into ( mutect2somaticing, facetsomaing, qdnaseqsomaing, msisensoring, mantastrelka2ing, lanceting )
    stdout into vcfGRaID

    """
    echo $germlinebam | perl -ane '@s=split(/\\./); print \$s[0];'
    """
}
//combinesg.unique().into {  }

/* 2.0: Metrics suite, this will produce an HTML report
*/
MULTIALL = gmultimetricing.mix(multimetricing)

process mltmet {

  label 'c8_24G_cpu_mem'

  publishDir path: "$params.outDir/$sampleID/metrics"

  input:
  set val(sampleID), file(bam), file(bai) from MULTIALL
  set file(fa), file(fai), file(dict) from mltmet_fasta
  file(exomebedintlist) from mltmet_exomebedintlist

  output:
  val(sampleID) into completed2_0
  file('*') into all2_0
  file('*.txt') into multimetrics_multiqc
  set file(fa), file(fai) into mutect2_fa

  script:
  """
  {
    picard-tools CollectHsMetrics \
      I=$bam \
      O=$sampleID".hs_metrics.txt" \
      TMP_DIR=./ \
      R=$fa \
      BAIT_INTERVALS=$exomebedintlist \
      TARGET_INTERVALS=$exomebedintlist

    picard-tools CollectAlignmentSummaryMetrics \
      I=$bam \
      O=$sampleID".AlignmentSummaryMetrics.txt" \
      TMP_DIR=./ \
      R=$fa

    picard-tools CollectMultipleMetrics \
      I=$bam \
      O=$sampleID".CollectMultipleMetrics.txt" \
      TMP_DIR=./ \
      R=$fa

    picard-tools CollectSequencingArtifactMetrics \
      I=$bam \
      O=$sampleID".artifact_metrics.txt" \
      TMP_DIR=./ \
      R=$fa

    picard-tools EstimateLibraryComplexity \
      I=$bam \
      O=$sampleID".est_lib_complex_metrics.txt" \
      TMP_DIR=./

    picard-tools CollectInsertSizeMetrics \
      I=$bam \
      O=$sampleID".insert_size_metrics.txt" \
      H=$bam".histogram.pdf" \
      TMP_DIR=./

  } 2>&1 | tee > $sampleID".picard.metrics.log"
  """
}
completed2_0.subscribe { println "Completed running metrics: " + it }

/*2.1: SCNA with facets CSV snp-pileup
*/
process fctcsv {

  label 'c8_24G_cpu_mem'

  publishDir path: "$params.outDir/$sampleID/facets"

  input:
  set val(sampleID), file(tumourbam), file(tumourbai), val(germlineID), file(germlinebam), file(germlinebai) from facetsomaing
  set file(dbsnp), file(dbsnpidx) from fcts_dbsnp
  file(facetsR) from facetscallscript

  output:
  val(sampleID) into completed2_1
  file('*.tab') into facets_consensusing
  file('*') into facetsoutputR

  script:
  """
  CSVFILE=\$(echo $tumourbam | sed 's/bam/facets.r10.csv/')

  {
    snp-pileup \
      $dbsnp \
      -r 10 \
      -p \
      \$CSVFILE \
      $germlinebam \
      $tumourbam

    Rscript --vanilla $facetsR \$CSVFILE

  } 2>&1 | tee > $sampleID".facets_snpp_call.log.txt"
  """
}
completed2_1.subscribe { println "Completed facets calling: " + it }

/* 2.11: SCNA consensus from facets
*/
process fctcon {

  label 'c8_24G_cpu_mem'

  publishDir path: "$params.outDir/calls/scna/facets"

  input:
  file(filesn) from facets_consensusing.collect()
  file(callR) from facetsconcscript
  file(funcR) from facetsconfscript
  file(dict) from fcts_dict
  file(cosmicbed) from fcts_cosmicbed

  output:
  file('*') into completed2_11

  script:
  """
  {
  OUTID=\$(basename ${params.runDir})
  Rscript --vanilla $callR \
    $dict \
    $cosmicbed \
    \$OUTID \
    $funcR
  } 2>&1 | tee > "facets_cons.log.txt"
  """
}
completed2_11.subscribe { println "Completed facets consenus: " + it }

/* 2.13: SCNA from QDNAseq
*/
BINS = Channel.from(10, 50, 100, 500)

process qdnasq {

  label 'c40_120G_cpu_mem'

  publishDir path: "$params.outDir/calls/scna/qdnaseq"

  input:
  set val(sampleID), file(tumourbam), file(tumourbai), val(germlineID), file(germlinebam), file(germlinebai) from qdnaseqsomaing

  each bin from BINS
  file(qdnascript) from qdnaseqscript

  output:
  file('*') into completed_30

  script:
  """
  Rscript --vanilla $qdnascript $tumourbam $germlinebam $bin
  """
}

/* 2.2: MSIsensor
*/
process msisen {

  label 'c10_30G_cpu_mem'

  publishDir path: "$params.outDir/$sampleID/msisensor", mode: "copy"
  publishDir "$params.outDir/calls/msisensor", mode: "copy", pattern: '*.txt'

  input:
  set val(sampleID), file(tumourbam), file(tumourbai), val(germlineID), file(germlinebam), file(germlinebai) from msisensoring
  file(ssrs) from msi_ssr
  file(exomebed) from msi_exomebed

  output:
  val(sampleID) into completed2_2
  file('*') into msisensoroutput

  script:
  """
  msisensor msi \
    -d $ssrs \
    -n $germlinebam \
    -t $tumourbam \
    -e $exomebed \
    -o $sampleID \
    -b ${task.cpus}

  MSI=\$( tail -n1 $sampleID | cut -f 3)
  mv $sampleID $sampleID".MSI-pc_"\$MSI".txt"
  """
}
completed2_2.subscribe { println "Completed MSIsensor: " + it }

/* 2.3: MuTect2
* NB --germline-resource dollar-sign{dbsnp} removed as no AF causing error
*/
process mutct2 {

  label 'c40_120G_cpu_mem'

  publishDir path: "$params.outDir/$sampleID/mutect2", mode: "copy"
  publishDir path: "$params.outDir/calls/variants/vcf", mode: "copy", pattern: '*raw.vcf'

  input:
  set val(sampleID), file(tumourbam), file(tumourbai), val(germlineID), file(germlinebam), file(germlinebai) from mutect2somaticing
  set file(fa), file(fai), file(dict) from mutect2_fasta
  set file(dbsnp), file(dbsnpidx) from mutect2_dbsnp
  set file(gps), file(gpsidx) from mutect2_gps
  file(exomebedintlist) from mutect2_exomebedintlist
  file(filterpl) from filtermutect2script

  output:
  val(sampleID) into completed2_3
  file('*.pass.vcf') into mutect2_veping mode flatten
  file('*.raw.vcf') into mutect2_rawVcf
  file('*') into completedmutect2call
  set val(sampleID), file('*calculatecontamination.table') into contamination

  script:
  """
  GPS=$gps
  if [[ \$GPS =~ "tbi" ]];then
    GPS=\$(echo $gps | sed 's/.tbi//')
  fi
  {
    gatk --java-options ${params.full_javamem} \
      Mutect2 \
      --native-pair-hmm-threads ${task.cpus} \
      --reference $fa \
      --input $germlinebam \
      --input $tumourbam \
      --normal-sample $germlineID \
      --tumor-sample $sampleID \
      --output $sampleID".md.recal.mutect2.vcf" \
      -L $exomebedintlist

    gatk --java-options ${params.full_javamem} \
      GetPileupSummaries \
      -I $tumourbam \
      -V \$GPS \
      -O $sampleID".getpileupsummaries.table" \
      -L $exomebedintlist

    gatk CalculateContamination \
      -I $sampleID".getpileupsummaries.table" \
      -O $sampleID".calculatecontamination.table"

    gatk --java-options ${params.full_javamem} \
      FilterMutectCalls \
      --contamination-table $sampleID".calculatecontamination.table" \
      --interval-padding 5 \
      --output $sampleID".md.recal.mutect2.FilterMutectCalls.vcf" \
      --unique-alt-read-count 3 \
      --variant $sampleID".md.recal.mutect2.vcf" \
      -L $exomebedintlist

    perl $filterpl \
      ID=$sampleID \
      DP=14 \
      MD=2 \
      VCF=$sampleID".md.recal.mutect2.FilterMutectCalls.vcf"

  } 2>&1 | tee > $sampleID".GATK4_mutect2.log.txt"
  """

}
completed2_3.subscribe { println "Completed Mutect2: " + it }

/* 2.31: MuTect2 Contamination
*/
process mutct2_contam {

  echo true

  label 'c40_120G_cpu_mem'

  publishDir path: "$params.outDir/", mode: "copy", pattern: '*issue.table'

  input:
  set val(sampleID), file(contable) from contamination
  file script from mutect2contamscript

  output:
  file('*.table') into completedcontam

  """
  Rscript --vanilla $script $contable $sampleID
  """
}

/* 2.4: Manta output is a pre-req for Strelka2, so call both here
*/
process mntstr {

  label 'c40_120G_cpu_mem'

  publishDir path: "$params.outDir/$sampleID/manta-strelka2"
  publishDir path: "$params.outDir/calls/variants/vcf", mode: "copy", pattern: '*raw.vcf'

  input:
  set val(sampleID), file(tumourbam), file(tumourbai), val(germlineID), file(germlinebam), file(germlinebai) from mantastrelka2ing
  set file(fa), file(fai), file(dict) from mantastrelka_fasta
  set file(exomebedgz),file(exomebedgztbi) from mantastrelka_exomebedgz
  file(indelscript) from filterstrelka2iscript
  file(snvscript) from filterstrelka2sscript

  output:
  val(sampleID) into completed2_4
  file('*.pass.vcf') into strelka2_veping mode flatten
  file('*.raw.vcf') into strelka2_rawVcf
  file('manta/*') into completedmantacall

  script:
  """
  {
    configManta.py \
      --normalBam=$germlinebam \
      --tumourBam=$tumourbam \
      --referenceFasta=$fa \
      --runDir=manta

    manta/runWorkflow.py -m local

    configureStrelkaSomaticWorkflow.py \
      --exome \
      --referenceFasta=$fa \
      --callRegions $exomebedgz \
      --indelCandidates=manta/results/variants/candidateSmallIndels.vcf.gz \
      --normalBam=$germlinebam \
      --tumorBam=$tumourbam \
      --runDir=strelka2

    strelka2/runWorkflow.py -m local

    TUMOURSNVVCF=\$(echo $tumourbam | sed 's/bam/strelka2.snv.vcf/')
    gunzip -c strelka2/results/variants/somatic.snvs.vcf.gz | \
    perl -ane 'if(\$F[0]=~m/^#/){if(\$_=~m/^#CHROM/){
        \$_=~s/NORMAL/$germlineID/;
        \$_=~s/TUMOR/$sampleID/;
        print \$_;next;}
        else{print \$_;next;}
      }
      else{print \$_;}' > \$TUMOURSNVVCF

    perl $snvscript \
     ID=$sampleID \
     DP=14 \
     MD=2 \
     VCF=\$TUMOURSNVVCF

    TUMOURINDELVCF=\$(echo $tumourbam | sed 's/bam/strelka2.indel.vcf/')
    gunzip -c strelka2/results/variants/somatic.indels.vcf.gz | \
    perl -ane 'if(\$F[0]=~m/^#/){if(\$_=~m/^#CHROM/){
        \$_=~s/NORMAL/$germlineID/;
        \$_=~s/TUMOR/$sampleID/;
        print \$_;next;}
        else{print \$_;next;}}
      else{print \$_;}' > \$TUMOURINDELVCF

    perl $indelscript \
      ID=$sampleID \
      DP=14 \
      MD=2 \
      VCF=\$TUMOURINDELVCF

  } 2>&1 | tee > $sampleID".manta-strelka2.log.txt"
  """
}
completed2_4.subscribe { println "Completed Manta-Strelka2: " + it }

/* 2.5: Lancet
*/
process lancet {

  label 'c40_120G_cpu_mem'

  publishDir path: "$params.outDir/$sampleID/lancet"
  publishDir path: "$params.outDir/calls/variants/vcf", mode: "copy", pattern: '*raw.vcf'

  input:
  set val(sampleID), file(tumourbam), file(tumourbai), val(germlineID), file(germlinebam), file(germlinebai) from lanceting
  set file(fa), file(fai), file(dict) from lancet_fasta
  file(exomebed) from lancet_exomebed
  file(filterLancet) from filterlancetscript

  output:
  val(sampleID) into completed2_5
  file('*.pass.vcf') into lancet_veping mode flatten
  file('*.raw.vcf') into lancet_rawVcf
  file('*') into completedlancetcall

  script:
  """
  TUMOURVCF=\$(echo $tumourbam | sed 's/bam/lancet.vcf/')
  {
    lancet \
      --num-threads ${task.cpus} \
      --ref $fa \
      --bed $exomebed \
      --tumor $tumourbam \
      --normal $germlinebam | \
      perl -ane 'if(\$F[0]=~m/^\\#CHROM/){
        \$_=~s/TUMOR/$sampleID/;
        \$_=~s/NORMAL/$germlineID/;
        print \$_;}
      else{print \$_;}' > \$TUMOURVCF

    perl $filterLancet \
      ID=$sampleID \
      DP=14 \
      MD=2 \
      VCF=\$TUMOURVCF

  } 2>&1 | tee > $sampleID".lancet.log.txt"

  """
}
completed2_5.subscribe { println "Completed lancet: " + it }

/* 3.0: Annotate Vcfs
*/
ALLVCFS = lancet_veping
          .mix( mutect2_veping )
          .mix( strelka2_veping )

process vepann {

  label 'c10_30G_cpu_mem'

  publishDir path: "$params.outDir/calls/variants/vcf", mode: "copy", pattern: '*.vcf'

  input:
  each file(vcf) from ALLVCFS
  set file(fa), file(fai), file(dict) from vep_fasta

  output:
  val("VEP") into completed3_0
  file('*.vcf') into annoVcfs
  file('*.vcf') into (completedvep, runGRanges)

  script:
  """
  VCFANNO=\$(echo $vcf | sed "s/.vcf/.vep.vcf/")

  vep --dir_cache /usr/local/ensembl-vep/cache \
    --offline \
    --assembly GRCh37 \
    --vcf_info_field ANN \
    --symbol \
    --species homo_sapiens \
    --check_existing \
    --cache \
    --merged \
    --fork ${task.cpus} \
    --af_1kg \
    --af_gnomad \
    --vcf \
    --input_file $vcf \
    --output_file \$VCFANNO \
    --format "vcf" \
    --fasta $fa \
    --hgvs \
    --canonical \
    --ccds \
    --force_overwrite \
    --verbose
  """
}
completed3_0.subscribe { println "Completed " + it + " annotation" }

/* 3.1 RData GRanges from processed VCFs
* take publishDir and check for number of files therein
* each sample has 9 associated (raw,snv,indel per caller)
* NB increment if adding callers!
*/
ALLRAWVEPVCFS = runGRanges
             .mix(lancet_rawVcf)
             .mix(mutect2_rawVcf)
             .mix(strelka2_rawVcf)

vartypes = Channel.from( "snv", "indel" )

process vcfGRa {

  label 'c20_60G_cpu_mem'

  publishDir path: "$params.outDir/calls/variants/pdf", mode: "copy", pattern: '*.pdf'
  publishDir path: "$params.outDir/calls/variants/vcf", mode: "copy", pattern: '*.vcf'
  publishDir path: "$params.outDir/calls/variants/data", mode: "copy", pattern: '*.{RData,tab}'

  input:
  file(rawGRangesvcff) from ALLRAWVEPVCFS.collect()
  each vartype from vartypes
  val(germlineID) from vcfGRaID.getVal()
  set file(callR), file(funcR) from variantsGRangesscript

  output:
  val(vartype) into completed3_1
  file('*') into completedvcfGRangesConsensus

  script:
  """
  OUTID=\$(basename ${params.runDir})
  Rscript --vanilla $callR \
    $funcR \
    $germlineID \
    $vartype".pass.vep.vcf" \
    \$OUTID \
    ${params.includeOrder}
  """
}
completed3_1.subscribe { println "Completed GRanges Consensus: " + it }

/* 4.0 Run multiQC to finalise report
*/
process mltiQC {

  label 'c10_30G_cpu_mem'

  publishDir path: "$params.runDir/output", mode: "copy", pattern: "*html"

  input:
  file('fastp/*') from fastp_multiqc.collect()
  file('mrkdup/*') from mrkdup_multiqc.collect()
  file('gtkrcl/*') from gtkrcl_multiqc.collect()
  file('multimetrics/*') from multimetrics_multiqc.collect()

  output:
  file('*') into completedmultiqc

  script:
  """
  OUTID=\$(basename ${params.runDir})
  multiqc . -i \$OUTID --tag DNA -f -c /usr/local/multiqc_config_BMB.yaml
  """
}
completedmultiqc.subscribe { println "Completed MultiQC" }

/* 5.0 Create output zip with XLSX of all variants per sample
* include all relevant PDFs, multiqc;
* this should be the base of final report

process report {

  publishDir path: "$params.runDir/output", mode: "copy", pattern: "*html"

  input:

  output:
  file('*') into completedreport

  script:
  """
  OUTID=\$(basename ${params.runDir})
  multiqc . -i \$OUTID --tag DNA -f -c /usr/local/multiqc_config_BMB.yaml
  """
}
completedmultiqc.subscribe { println "Completed MultiQC" }
*/
