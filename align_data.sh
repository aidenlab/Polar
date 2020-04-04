#!/bin/bash
### Script to align sample to viral genomes
### Eventually will do entire pipline

# Variables: do we want to be able to set betacorona ref dir?
TOP_DIR=$(pwd)
BETACORONA_REF_DIR="/gpfs0/work/brian/references/betacoronaviruses/*/*.fasta"
FASTQ_DIR=${TOP_DIR}"/fastq/*_R*.fastq*"
READ1_STR="_R1"
READ2_STR="_R2"

usageHelp="Usage: ${0##*/} [-d TOP_DIR]"
dirHelp="* [TOP_DIR] is the top level directory (default\n  \"$TOP_DIR\")\n     [TOP_DIR]/fastq must contain the fastq files"
helpHelp="* -h: print this help and exit"

printHelpAndExit() {
    echo -e "$usageHelp"
    echo -e "$dirHelp"
    echo "$helpHelp"
    exit "$1"
}

while getopts "d:h" opt; do
    case $opt in
	h) printHelpAndExit 0;;
        d) TOP_DIR=$OPTARG ;;
	[?]) printHelpAndExit 1;;
    esac
done

if [ ! -d "$TOP_DIR/fastq" ]; then
    echo "Directory \"$TOP_DIR/fastq\" does not exist."
    echo "Create \"$TOP_DIR/fastq\" and put fastq files to be aligned there."
    printHelpAndExit 1
else
    if stat -t ${FASTQ_DIR} >/dev/null 2>&1
    then
        echo "(-: Looking for fastq files...fastq files exist"
        testname=$(ls -l ${FASTQ_DIR} | awk 'NR==1{print $9}')
        if [ "${testname: -3}" == ".gz" ]
        then
            read1=${TOP_DIR}"/fastq/*${READ1_STR}*.fastq.gz"
        else
            read1=${TOP_DIR}"/fastq/*${READ1_STR}*.fastq"
        fi
    else
        echo "***! Failed to find any files matching ${FASTQ_DIR}"
	printHelpAndExit 1
    fi
fi

read1files=()
read2files=()
for i in ${read1}
do
    ext=${i#*$READ1_STR}
    name=${i%$READ1_STR*}
    # these names have to be right or it'll break                                                                            
    name1=${name}${READ1_STR}
    name2=${name}${READ2_STR}
    read1files+=$name1$ext","
    read2files+=$name2$ext","
done

# replace commas with spaces for iteration, put in array
read1files=($(echo $read1files | tr ',' ' '))
read2files=($(echo $read2files | tr ',' ' '))

threads=8
threadstring="-t \$SLURM_JOB_CPUS_PER_NODE"

for REFERENCE in $BETACORONA_REF_DIR
do

    ######################################################################                                                           
    ######################################################################                                                           
    ##########Step #1: Align                                                                                                         
    ######################################################################                                                           
    ######################################################################         

    REFERENCE_NAME=$(echo $REFERENCE | sed 's:.*/::' | rev | cut -c7- | rev )
    echo -e "(-: Aligning files matching $FASTQ_DIR\n to genome $REFERENCE_NAME"

    if ! mkdir ${TOP_DIR}/${REFERENCE_NAME}_aligned; then echo "***! Unable to create ${TOP_DIR}/${REFERENCE_NAME}_aligned! Exiting"; exit 1; fi
    if ! mkdir ${TOP_DIR}/${REFERENCE_NAME}_debug; then echo "***! Unable to create ${TOP_DIR}/${REFERENCE_NAME}_debug! Exiting"; exit 1; fi
    errorfile=${REFERENCE_NAME}_debug/alignerror

    for ((i = 0; i < ${#read1files[@]}; ++i)); do
        usegzip=0
        file1=${read1files[$i]}
        file2=${read2files[$i]}

	FILE=$(basename ${file1%$read1str})
	ALIGNED_FILE=${TOP_DIR}/${REFERENCE_NAME}_aligned/${FILE}"_mapped.sam"

	dependsort="afterok"

        # Align reads
	jid=`sbatch <<- ALGNR | egrep -o -e "\b[0-9]+$"
		#!/bin/bash -l
		#SBATCH -p commons
		#SBATCH -o ${TOP_DIR}/${REFERENCE_NAME}_debug/align-%j.out                                                                               
		#SBATCH -e ${TOP_DIR}/${REFERENCE_NAME}_debug/align-%j.err
		#SBATCH -t 2880
		#SBATCH -n 1
		#SBATCH -c $threads
		#SBATCH --mem=4000
                #SBATCH -J "align_${FILE}"
		#SBATCH --threads-per-core=1

		spack load bwa@0.7.17 arch=\`spack arch\`
		bwa 2>&1 | awk '\\\$1=="Version:"{printf(" BWA %s; ", \\\$2)}' 
		echo "Running command bwa mem $threadstring $REFERENCE $file1 $file2 > $ALIGNED_FILE"
		srun --ntasks=1 bwa mem $threadstring $REFERENCE $file1 $file2 > $ALIGNED_FILE
		if [ \$? -ne 0 ]                                                                                         
		then                                                                                                     
			touch $errorfile                                                                                 
			exit 1                                                                                           
		else  
			echo "(-: Mem align of $name$ext.sam done successfully"                                          
		fi
ALGNR`
	dependalign="afterok:$jid"

        ######################################################################
        ######################################################################
        ##########Step #2: Sort SAMs                                       
        ######################################################################
        ######################################################################
	jid=`sbatch <<- SORTSAM | egrep -o -e "\b[0-9]+$"
		#!/bin/bash -l
		#SBATCH -p commons
		#SBATCH -o ${TOP_DIR}/${REFERENCE_NAME}_debug/sortsam-%j.out
		#SBATCH -e ${TOP_DIR}/${REFERENCE_NAME}_debug/sortsam-%j.err
		#SBATCH -t 2880 
		#SBATCH -n 1
		#SBATCH -c 8
		#SBATCH --mem-per-cpu=4G
		#SBATCH --threads-per-core=1
		#SBATCH -d $dependalign 
		samtools sort -m 4G -@ 8 $ALIGNED_FILE -o ${ALIGNED_FILE}"_sorted.bam"
SORTSAM`
	dependsort="${dependsort}:$jid"
    done


    ######################################################################
    ######################################################################
    ##########Step #3: Merge sorted SAMs into a BAM, get stats, and index
    ######################################################################
    ######################################################################
    jid=`sbatch <<- MERGESAM | egrep -o -e "\b[0-9]+$"
	#!/bin/bash -l
	#SBATCH -p commons
	#SBATCH -o ${TOP_DIR}/${REFERENCE_NAME}_debug/mergesam-%j.out
	#SBATCH -e ${TOP_DIR}/${REFERENCE_NAME}_debug/mergesam-%j.err
	#SBATCH -t 2880 
	#SBATCH -n 1 
	#SBATCH -c 1
	#SBATCH --mem=4000
	#SBATCH --threads-per-core=1 
	#SBATCH -d $dependsort

	if samtools merge ${TOP_DIR}/${REFERENCE_NAME}_aligned/sorted_merged.bam ${TOP_DIR}/${REFERENCE_NAME}_aligned/*_sorted.bam
	then
		rm ${TOP_DIR}/${REFERENCE_NAME}_aligned/*_sorted.bam
		rm ${TOP_DIR}/${REFERENCE_NAME}_aligned/*.sam
	fi
MERGESAM`

    dependmerge="afterok:$jid"
    jid=`sbatch <<- INDEXSAM | egrep -o -e "\b[0-9]+$"
	#!/bin/bash -l
	#SBATCH -p commons
	#SBATCH -o ${TOP_DIR}/${REFERENCE_NAME}_debug/indexsam-%j.out
	#SBATCH -e ${TOP_DIR}/${REFERENCE_NAME}_debug/indexsam-%j.err
	#SBATCH -t 2880 
	#SBATCH -n 1 
	#SBATCH -c 1
	#SBATCH --mem=4000
	#SBATCH --threads-per-core=1 
	#SBATCH -d $dependmerge

	samtools index ${TOP_DIR}/${REFERENCE_NAME}_aligned/sorted_merged.bam

INDEXSAM`

    dependstats="afterok"
    jid=`sbatch <<- SAMSTATS | egrep -o -e "\b[0-9]+$"
	#!/bin/bash -l
	#SBATCH -p commons
	#SBATCH -o ${TOP_DIR}/${REFERENCE_NAME}_debug/samstats-%j.out
	#SBATCH -e ${TOP_DIR}/${REFERENCE_NAME}_debug/samstats-%j.err
	#SBATCH -t 2880 
	#SBATCH -n 1 
	#SBATCH -c 1
	#SBATCH --mem=4000
	#SBATCH --threads-per-core=1 
	#SBATCH -d $dependmerge

	samtools flagstat ${TOP_DIR}/${REFERENCE_NAME}_aligned/sorted_merged.bam > ${TOP_DIR}/${REFERENCE_NAME}_aligned/stats.txt

SAMSTATS`

    dependstats="${dependstats}:$jid"
done


echo "#!/bin/bash -l" > $TOP_DIR/collect_stats.sh
echo "#SBATCH -p commons" >> $TOP_DIR/collect_stats.sh
echo "#SBATCH -o ${TOP_DIR}/collectstats-%j.out"  >> $TOP_DIR/collect_stats.sh
echo "#SBATCH -e ${TOP_DIR}/collectstats-%j.err" >> $TOP_DIR/collect_stats.sh
echo "#SBATCH -t 30" >> $TOP_DIR/collect_stats.sh
echo "#SBATCH -n 1 " >> $TOP_DIR/collect_stats.sh
echo "#SBATCH -c 1" >> $TOP_DIR/collect_stats.sh
echo "#SBATCH --mem=200" >> $TOP_DIR/collect_stats.sh
echo "#SBATCH --threads-per-core=1 " >> $TOP_DIR/collect_stats.sh
echo "#SBATCH -d $dependstats"  >> $TOP_DIR/collect_stats.sh 
echo "echo \"<table>\" > $TOP_DIR/stats.html " >> $TOP_DIR/collect_stats.sh
echo "for f in $TOP_DIR/*_aligned/stats.txt; do"  >> $TOP_DIR/collect_stats.sh
echo  "awk -v fname=\${f%%_aligned*} '\$4==\"mapped\"{split(\$5,a,\"(\"); print \"<tr><td> \"fname\" </td>\", \"<td> \"a[2]\" </td></tr>\"}' \$f >> ${TOP_DIR}/stats.html"  >> $TOP_DIR/collect_stats.sh 
echo "	done "  >> $TOP_DIR/collect_stats.sh
echo "echo \"</table>\" >> $TOP_DIR/stats.html " >> $TOP_DIR/collect_stats.sh

sbatch < $TOP_DIR/collect_stats.sh

echo "(-: Finished adding all jobs... Now is a good time to get that cup of coffee... Last job id $jid"
