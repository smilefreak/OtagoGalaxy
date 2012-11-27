#!/bin/bash
#
# Wrapper for 1000 genomes LD values script
#
# author: James Boocock
# date : 7/08/2012
#
#


usage(){
cat << EOF
	 Usage: This bash script obtains LD calculation from 1000 genomes VCFs
	 	or a users uploaded VCF file.
	
	-v <VCF_FILE> user vcf file
	-r  <RSID>     single snp to calculate LD for
	-s  <SNP_LIST> text file containing snp rsid to calculate ld of.
	-c  <REGION>   Chromosome region and position to calculate ld for.
	-w  <WINDOW>   LD distance in number of snps
	-r  <R2>       only show snps above this ld frequency
	-l  <KB>       Max distance away from snp to calculate LD
	-m  	       Output data in a matrix
	-o <OUTPUT FILE> file in which ld output i written into.
	-i <ID-LIST>  Ids to exclude in LD analysis.
	-R <RSID>     perform analysis on this single snp
	-O <LOGFILE>  path to log file
    -h            haploview output
    -p            Ped file output for haploview output
EOF


}

getoptions(){
while getopts "p:O:R:v:i:o:r:s:c:w:r:l:mh:" opt;  do
case $opt in
v)
	VCF_INPUT=$OPTARG
;;
R)
	RSID=$OPTARG
;;
s)
	SNP_LIST=$OPTARG
;;
c)
	REGION=$OPTARG
;;
w)
	WINDOW=$OPTARG
;;
r)
	R2=$OPTARG
;;
l)
	KB=$OPTARG
;;
m)
	MATRIX="TRUE"
;;
i)      
	ID_LIST=$OPTARG
;;
o)
	PLINK_OUTPUT=$OPTARG
;;
O)
	PLINK_LOG=$OPTARG
;;
h)
    HAPLOVIEW=$OPTARGt
;;
p)
    PED_FILE=$OPTARG
;;
?)
usage
exit 1
;;
esac
done

}

getoptions "$@"
if [ "$VCF_INPUT" != "" ]; then
    if [ "$REGION" != "" ]; then
	cat $VCF_INPUT | bgzip -c > temp_vcf.gz	
	tabix -p vcf temp_vcf.gz
	tabix -fh temp_vcf.gz $REGION > temp.vcf
    else
    cp -f $VCF_INPUT temp.vcf
    fi
else
	tabix -fh ftp://ftp.1000genomes.ebi.ac.uk/vol1/ftp/release/20110521/ALL.chr`echo ${REGION} | awk -F [\:] '{print $1}'`.phase1_release_v3.20101123.snps_indels_svs.genotypes.vcf.gz $REGION > temp.vcf 2> /dev/null
fi

	#subset vcf file
if [ "$ID_LIST" != "" ]; then
	vcf-subset -c $ID_LIST temp.vcf > temp2.vcf 2> /dev/null
else
	cp -f temp.vcf temp2.vcf
fi
    if [ "$HAPLOVIEW" == "" ]; then
	#convert to plink format
	vcftools --vcf temp2.vcf --plink-tped --out plinkfile  > /dev/null
	PLINK_COMMAND="p-link --tped plinkfile.tped --tfam plinkfile.tfam --r2 --noweb --ld-window $WINDOW  --ld-window-r2 $R2 --ld-window-kb $KB"
	if [ "$SNP_LIST" != "" ]; then
		PLINK_COMMAND="${PLINK_COMMAND} --ld-snp-list $SNP_LIST"
	fi
	if [ "$RSID" != "" ]; then
		PLINK_COMMAND="${PLINK_COMMAND} --ld-snp $RSID"
	fi
	if [ "$MATRIX" == "TRUE" ]; then
	PLINK_COMMAND="p-link --tped plinkfile.tped --tfam plinkfile.tfam --r2 --noweb --matrix"
	fi
	eval	$PLINK_COMMAND > /dev/null
	mv plink.ld $PLINK_OUTPUT
	mv plink.log $PLINK_LOG
    fi
    if [ "$HAPLOVIEW" != "" ]; then
        vcftools --vcf temp2.vcf --plink-tped --out  plinkfile > $PLINK_LOG
        p-link --tfile plinkfile  --noweb --recodeHV --out plinkfile >> $PLINK_LOG
        mv plinkfile.info $HAPLOVIEW
        mv plinkfile.ped $PED_FILE
    fi

	

