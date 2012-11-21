#!/bin/bash

# Simple script that annotates the centimorgans from the hapmap centimorgan map.
#
#
# $1 extrafiles path
# $2 basename
# $3 galaxy impute data folder containing the centimorgan files
# $4 galaxy root dir
#
#
#

cp "$1/$2.ped" "$2.ped" 
cat "$1/$2.map" | awk '{print $1}' | uniq > chromosomes


while read chrom
do
    
    if [ $chrom == "23" ]; then
        chrom="X_PAR2"
    fi
    MAP_FILE=${3}genetic_map_chr${chrom}_combined_b37.txt
    if [ ${chrom} != "26" ]  && [ ${chrom} != "24" ]; then
         python $4/tools/SOER1000genes/galaxy/cm_to_lped/annotate_cm.py $MAP_FILE "${1}/${2}.map" $chrom >> out.tmp
    else
        python $4/tools/SOER1000genes/galaxy/cm_to_lped/add_999.py "${1}/${2}.map" >> out.tmp
    fi

done < chromosomes
cp -f out.tmp "${2}.map"

