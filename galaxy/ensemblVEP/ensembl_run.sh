#!/bin/bash
# Author: Edward Hills and James Boocock
# Date: 8/12/2011
#
# Script takes and runs the variant effect predictor
# from ensemble from the arguments given.
#
# Inputs
# $1 = input file
# $2 = Sift
# $3 = Polyphen
# $4 = Condel
# $5 = Regulatory
# $6 = Protein
# $7 = HGNC
# $8 = CCDS
# $9 = Most Severe
# $10 = Summary
# $11 = Per Gene
# $12 = Coding Only
# $13 = Check Existing
# $14 = Check Alleles

ENSEMBL_RUN_SCRIPT=""
NUM_SAMPLES=$#

if [ $NUM_SAMPLES != 1 ]
then
	for (( i=2; i <= $NUM_SAMPLES; i++ ))
	do
		NUM=${i}
		eval INPUT=\${${NUM}}
		if [ "${i}" -lt "5" ]; then
			if [ "${i}" != "none" ]; then
			    ENSEMBL_RUN_SCRIPT="${ENSEMBL_RUN_SCRIPT} --${INPUT} b"
			fi
		else
		    ENSEMBL_RUN_SCRIPT="${ENSEMBL_RUN_SCRIPT} --${INPUT}"
		fi
	done
# call actual script
	perl ~/galaxy-dist/tools/OtagoGalaxy/galaxy/ensemblVEP/variant_effect_predictor.pl -i $1 -o ~ensemble-TMP.tmp $ENSEMBL_RUN_SCRIPT --cache --dir "~/.vep/" --hgvs --force_overwrite --buffer 50000 --fork 2

	cat ~ensemble-TMP.tmp
	rm -f ~ensemble-TMP.tmp

else # call defaults 
	perl ~/galaxy-dist/tools/OtagoGalaxy/galaxy/ensemblVEP/variant_effect_predictor.pl -i $1 -o ~ensemble-TMP.tmp --check_existing --gene \
                        --cache --dir "/usr/local/ensembl_cache" \
                       --poly b --sift b --hgvs --force_overwrite  \
                       --buffer 50000 --fork 2
fi

exit 0
