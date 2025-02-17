#!/bin/bash
#
# NOT FOR USE YET, TRIALLING WAYS TO SPEED UP
#
# FIXME: All references of 1kg are no longer true as we now use evs too.
# $1 = my vcf
# $2 = less or more
# $3 = af for 'myvcf'
# $4 = less or more
# $5 = af for 1kg/evs
# $6 = SNPs or Indels - not supported yet
# $7 = output vcf
# $8 = database
# $9 = population if database == evs

if [ "$8" == "1kg" ] 
then
    DATABASE=`ls ~/galaxy-dist/tools/OtagoGalaxy/data/1kg/vcf/ALL.*.gz`
else
    DATABASE=`ls ~/galaxy-dist/tools/OtagoGalaxy/data/evs/esp/ESP6500.ALL.snps.vcf.gz`
fi

# Filter original -fix to get positions only
# eg grep "AF=0.[5-9]" my.vcf |awk '{print $1":"$2"-"$2}' > pos1.txt
# Print out header into new file
cat $1 | awk '{if ($1 ~ /^#/) {print $0}}' > $7

java -jar ~/galaxy-dist/tool-data/shared/jars/AFfilter/AFfilter.jar $2 $3 $9 < $1 >| pos.txt

#remove potential duplicates before matching - assumes vcf is sorted
uniq pos.txt > pos1.txt 

if [ ! -f pos1.txt ]; then
    echo "No snps returned on first operation" >& 2
    exit 1
fi

# gets position from my filtered vcf
#filter 1kg vcf - fix again so only positions that match criteria are returned

zcat $DATABASE | java -jar /home/galaxy/galaxy-dist/tool-data/shared/jars/AFfilter/AFfilter.jar $4 $5 $9  >| pos.txt
uniq pos.txt > pos2.txt # remove potential duplicates before comparing

cat pos1.txt pos2.txt | sort -t ':' -k1,2 -n | uniq -d > matching.txt

# print out all those that match the 1kg and myvcf - will have problems if matching.txt is too big
while read line
do
    tabix -f my.vcf `echo "$line" |awk 'FS=":" {print $1":"$2"-"$2}' ` >> temp.vcf

done < matching.txt

tabix -fh my.vcf |cat temp.vcf | vcf-sort -c > $7

exit 0
