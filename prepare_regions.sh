#!/usr/local/bin/bash

## Description:
# Creating a gene based genome annotation file based on various sources that
# contain gene-linked regulatory features as well. The link between the regulatory
# feature and the gene is made based on simple overlap between regulatory feat and
# the gene, or a regulatory feature is considered to be associated with a gene
# if the regulatory feature overlaps with a variant that has been found to be
# and eQTL for the gene in the GTEx dataset.
# The resulting file is also contains information if the

# we are maintaining for burden testing. This file relies on a series of online sources:
## 1. Gencode
## 2. Ensembl Regulation
## 3. GTEx
## 4. Appris
##

##
## Warning: this version was modified for regressing to the older (V84) Ensembl release:
#### The V85 ensembl release contained a faulty regulatory build, which although was rich in
#### cell types, the number of features were much fewer, there were only promoters and
#### enhancers annotated as active. After a discussion with the Ensembl team we decided
#### to regress to V84. To use a newer version, the script has to be adjusted
#### as data format of subsequent releases are quite different.

##
## Date: 2016.12.22 by Daniel Suveges. ds26@sanger.ac.uk
##
script_version=1.5
last_modified=2016.12.22

# Get script dir:
scriptDir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

## printing out information if no parameter is provided:
function usage {
    echo ""
    echo "Usage: $0 <targetdir>"
    echo ""
    echo " This script was written to prepare input file for the 15x burden testing."
    echo ""
    echo ""
    echo "Version: ${script_version}, Last modified: ${last_modified}"
    echo ""
    echo "Requirements:"
    echo "  bgzip, tabix in path"
    echo "  liftOver in path"
    echo "  hg19ToHg38.over.chain chain file in script dir"
    echo "  bedtools in path"
    echo ""
    echo ""
    echo "Workflow:"
    echo "  1: Downloads newest GENCODE release."
    echo "  2: V84. Ensembl Regulation release."
    echo "  3: Downloads newest APPRIS release"
    echo "  4: Downloads GTEx release hardcoded... "
    echo "  5: Adds Appris annotation to Gencode transcripts."
    echo "  6: Creates cell-specific regulatory features."
    echo "  7: Lifts over GTEx coordinates to GRCh38."
    echo "  8: Links regulatory features to genes based on GTEx data."
    echo "  9: Links regulatory features to genes based on overlapping."
    echo "  10: Combined GENCODE, GTEx and Overlap data together into a single bedfile."
    echo "  11: Tabix output, cleaning up."
    echo ""
    echo ""
    echo "The output is a bed file, where the first 4 columns are the chromosome, start/end
coordinates and the stable ID of the gene respectively. The 5th column is a json
formatted string describing one genomic region associated to the given gene. This
line contains all information of the association."
    echo ""
    echo "Tags:"
    echo "  -source: from which source the given region is coming from (GENCODE, GTEx, Overlap)."
    echo "  -class: class of the given region (eg. exon, promoter etc.)"
    echo "  -chr, start, end: GRCh38 coordintes of the feature."
    echo "  -other sources contain information about the evidence. (linked rsID, tissue in
    which the feature in active etc.)"
    echo ""
    echo "WARNINGS: ALL COORDINATES ARE BASED ON GRCH38 BUILD!"
    echo ""
    exit 0
}

# Function to test if a given file exists or not in which case it reports and terminates the
# execution.
function testFile {
    if [[ ! -e "$1"  ]]; then
        echo "[Error] At this step something failed. The file was not created! $1"
        echo "[Error] Exiting."
        exit 1
    fi
}

# Checking if tabix, liftOver and bedtools are installed...
function checkCommand {
    isCommand=$( which $1 | wc -l )

    # exit program is not in path:
    if [[ $isCommand == 0 ]]; then
        echo "[Error] $1 is not in path. Install program before proceeding. Exiting.";
        exit 1;
    fi
}

# We also run a test to check if the number of lines of a temporary file is zero or not.
# If it is zero, the script exits, because it indicates there were some problem.
function testFileLines {

    # Check if file is zipped:
    IsCompressed=$( file $1 | grep compressed | wc -l)

    # Check the number of lines:
    if [[ $IsCompressed -ne 0 ]]; then
        lines=$( zcat $1 | wc -l )
    else
        lines=$( cat $1 | wc -l )
    fi

    # exit if lines are zero:
    if [[ $lines == 0 ]]; then
        echo "[Error] file ($1) contains no lines. There were errors. Exiting.";
        exit 1;
    fi
}

# This function prints out all the reports that were generated during the run (with time stamp!):
function info {
    hourMin=$(date +"%T" | awk 'BEGIN{FS=OFS=":"}{print $1, $2}')
    echo -ne "[Info ${hourMin}] $1"
}

# Printing help message if no parameters are given:
[ -z $1 ] && { usage; }

## Steps:
# 1. First parameter is the target directory. Temporarily holds all source files.
# 2. Download GENCODE file.
# 3. Download Ensembl regulation file.
# 4. Donwload GTEx file.
# 5. Download APPRIS data.
# 5. Check if all downloads were successfull. If yes, proceed.
# 6. Process GENCODE file.
# 8. Process regulation files.
# 9. Process GTEx file
# 10. Liftover GTEx file.
# 11. Pull everything together.
# 12. Test if everything went well.

##
## Step 1. Checking target directory:
##

targetDir=$1
if [[  ! -d "${targetDir}" ]]; then
    echo "[Error] The provided directory does not exists: $targetDir"
    exit 1
fi

# Checking if the defined working directory is writable:
if [[ ! -w "${targetDir}" ]]; then
    echo "[Error] The provided working directory is not writable: ${targetDir}"
    exit 1
fi

# Checking required commands:
checkCommand tabix
checkCommand liftOver
checkCommand bedtools

# Checking chainfile in the scriptDir:
testFile ${scriptDir}/hg19ToHg38.over.chain

# Last step in setup:
today=$(date "+%Y.%m.%d")
info "Current date: ${today}\n"
info "Working directory: ${targetDir}/${today}\n\n"

##
## Step 2. Downloading GENCODE file (newest version, GRCh38 build)
##

# Get the most recent version of the data:
mkdir -p ${targetDir}/${today}/GENCODE
GENCODE_release=$(curl -s  ftp://ftp.sanger.ac.uk/pub/gencode/Gencode_human/ | \
        grep release | perl -lane 'push @a, $1 if $_ =~/release_(\d+)/; END {@a = sort {$a <=> $b} @a; print pop @a} ')
info "Downloading GENCODE annotation from http://www.gencodegenes.org/. Release version: ${GENCODE_release}... "
wget -q ftp://ftp.sanger.ac.uk/pub/gencode/Gencode_human/release_${GENCODE_release}/gencode.v${GENCODE_release}.annotation.gtf.gz \
        -O ${targetDir}/${today}/GENCODE/gencode.v${GENCODE_release}.annotation.gtf.gz
echo -e "done."

# Testing if the file is exists or not:
testFile "${targetDir}/${today}/GENCODE/gencode.v${GENCODE_release}.annotation.gtf.gz"

# Counting genes in the dataset:
genes=$(zcat ${targetDir}/${today}/GENCODE/gencode.v${GENCODE_release}.annotation.gtf.gz | awk '$3 == "gene"' | wc -l )
info "Total number of genes in the GENCODE file: ${genes}\n\n"

##
## Step 3. Downloading Ensembl Regulation (GRCh38 build)
##          These lines should be reviewed and adjusted if other version of Ensembl release
##          is being used!
##

# prepare target directory:
mkdir -p ${targetDir}/${today}/EnsemblRegulation
info "Downloading cell specific regulatory features from Ensembl.\n"

# Get the number of the most recent Ensembl version:
# Ensembl_release=$(curl -s  ftp://ftp.ensembl.org/pub/ | \
#       grep release | perl -lane 'push @a, $1 if $_ =~/release-(\d+)/; END {@a = sort {$a <=> $b} @a; print pop @a} ')
Ensembl_release=84 # The Ensembl release version is hardcoded
echo "[Warning] Ensembl regulatory release version is hardcoded! Version: v.${Ensembl_release}"
# If the most recent release is not accessible, we use the previous one:
#accessTest=$(curl -s ftp://ftp.ensembl.org/pub/release-${Ensembl_release}/regulation/homo_sapiens/ | perl -lane 'print $_ ? 1 : 0' | head -n1)
#if [[ ${accessTest} != 1 ]]; then
#    Ensembl_release=`expr ${Ensembl_release} - 1`
#fi
#info "Ensembl release: ${Ensembl_release}.\n"

# Get list of all cell types:
cells=$(curl -s ftp://ftp.ensembl.org/pub/release-${Ensembl_release}/regulation/homo_sapiens/ \
          | grep gff.gz \
          | perl -lane 'print $F[-1]')

# If there are no cell types present in the downloaded set, it means there were some problems. We are exiting.
if [ -z "${cells}" ]; then
    echo "[Error] No cell types were found in the Ensembl regulation folder."
    echo "[Error] URL: ftp://ftp.ensembl.org/pub/release-${Ensembl_release}/regulation/homo_sapiens/regulatory_features/"
    echo "Exiting."
    exit 1
fi

# Download all cell types:
for cell in ${cells}; do
    echo -n "."
    # Download all cell type:
    wget -q ftp://ftp.ensembl.org/pub/release-${Ensembl_release}/regulation/homo_sapiens/${cell} \
        -O ${targetDir}/${today}/EnsemblRegulation/${cell}

    # Testing if the file is exists or not:
    testFile "${targetDir}/${today}/EnsemblRegulation/${cell}"

done
echo "Done."

# Printing out report of the downloaded cell types:
cellTypeCount=$(ls -la ${targetDir}/${today}/EnsemblRegulation/*gff.gz | wc -l)
info "Number of cell types downloaded: ${cellTypeCount}.\n\n"

##
## Step 4. Download GTEx data:
##

mkdir -p ${targetDir}/${today}/GTEx
GTExRelease="V6"
info "Downloading GTEx data.\n"
info "GTEX data version: ${GTExRelease} dbGaP Accession phs000424.v6.p1.\n"
echo -e "[Warning] GTEx version is hardcoded! Please check if this is the most recent!\n"

#wget -q http://www.gtexportal.org/static/datasets/gtex_analysis_v6/single_tissue_eqtl_data/GTEx_Analysis_${GTExRelease}_eQTLs.tar.gz \
#    -O ${targetDir}/${today}/GTEx/GTEx_Analysis_${GTExRelease}_eQTLs.tar.gz

# Testing if the file was downloaded or not:
testFile "${targetDir}/${today}/GTEx/GTEx_Analysis_V6_eQTLs.tar.gz"

info "Download complete.\n\n"

##
## Step 5. Downloading APPRIS data
##

mkdir -p ${targetDir}/${today}/APPRIS
info "Downloading APPRIS isoform data.\n"
info "Download from the current release folder. Build: GRCh38, for GENCODE version: 24\n"
#wget -q http://apprisws.bioinfo.cnio.es/pub/current_release/datafiles/homo_sapiens/GRCh38/appris_data.principal.txt \
#    -O ${targetDir}/${today}/APPRIS/appris_data.principal.txt

# Testing if the file is exists or not:
testFile "${targetDir}/${today}/APPRIS/appris_data.principal.txt"

info "Download complete.\n\n"


##
## Step 6. Combining APPRIS and GENCODE data
##
info "Combining APPRIS and GENCODE data.. "
mkdir -p ${targetDir}/${today}/processed
export APPRIS_FILE=${targetDir}/${today}/APPRIS/appris_data.principal.txt
zcat ${targetDir}/${today}/GENCODE/gencode.v${GENCODE_release}.annotation.gtf.gz | grep -v "#" | awk '$3 != "Selenocysteine" && $3 != "start_codon" && $3 != "stop_codon"' \
                | perl -MJSON -M"Data::Dumper"  -F"\t" -lane '
                BEGIN {
                    $af = $ENV{APPRIS_FILE};
                    open($APP, "<", $af);
                    while ($line = <$APP>){
                        chomp $line;
                        $line =~ /(ENSG.+?)\s+(ENST.+?)\s.+?\s+(\S+)\:/;
                        $h{$1}{$2} = $3;
                    }
                }{
                    if ( $_ =~ /(ENSG.+?)\./){ # Gene related annotation
                        $geneID = $1;

                        $F[0] =~ s/chr//;
                        $start = $F[3];
                        $end = $F[4];
                        $strand = $F[6];
                        $class = $F[2];

                        ($transcriptID) = $F[8] =~ /(ENST.+?)\./ ? $F[8] =~ /(ENST.+?)\./ : "NA";
                        ($exonID) = $F[8] =~ /(ENSE.+?)\./ ? $F[8] =~ /(ENSE.+?)\./ : "NA";

                        $appris = "NA";
                        # Check if the given feature is belong to an annotated feature:
                        if( exists $h{$geneID} && $transcriptID ne "NA" ){
                            if (exists $h{$geneID}{$transcriptID}){
                                $appris = $h{$geneID}{$transcriptID};
                            }
                            else {
                                $appris = "Minor";
                            }
                        }

                        # Saving output in json format:
                        %hash = (
                            "chr" => "chr".$F[0],
                            "start" => $start,
                            "end" => $end,
                            "source" => "GENCODE",
                            "strand" => $strand,
                            "class" => $class,
                            "gene_ID" => $geneID,
                            "appris" => $appris
                        );
                        $hash{"transcript_ID"} = $transcriptID if $transcriptID ne "NA";
                        $hash{"exon_ID"} = $exonID if $exonID ne "NA";
                        print JSON->new->utf8->encode(\%hash);
                    }
                }' | gzip > ${targetDir}/${today}/processed/Appris_annotation_added.txt.gz

# Test if output is empty or not:
testFileLines  ${targetDir}/${today}/processed/Appris_annotation_added.txt.gz

echo "Done."

# Print out report:
appris_lines=$(zcat ${targetDir}/${today}/processed/Appris_annotation_added.txt.gz | wc -l | awk '{print $1}')
info "Number of Appris annotated GENCODE annotations: ${appris_lines}\n\n"

##
## Step 7. Pre-processing cell specific regulatory data
##
info "Aggregate cell specific information of regulatory features... "
CellTypes=$( ls -la ${targetDir}/${today}/EnsemblRegulation/ | perl -lane 'print $1 if  $F[-1] =~ /RegulatoryFeatures_(.+).gff.gz/ ' )
for cell in ${CellTypes}; do
    export cell
    # parsing cell specific files (At this point we only consider active features. Although repressed regions might also be informative.):
    zcat ${targetDir}/${today}/EnsemblRegulation/RegulatoryFeatures_${cell}.gff.gz | grep -i "=active" \
        | perl -F"\t" -lane '$F[0] =~ s/^chr//;
                next unless length($F[0]) < 3; # We skip irregular chromosome names.
                $cell_type = $ENV{cell};
                $start = $F[3];
                $type = $F[2];
                $end = $F[4];
                ($ID) = $_ =~ /ID=(ENSR\d+)/;
                ($bstart) = $F[8] =~ /bound_start=(.+?);/;
                ($bend) = $F[8] =~ /bound_end=(.+?);/;
                print join "\t", $cell_type, $F[0], $start, $end, $ID, $type, $bstart, $bend;'
# Now combining these lines in a fashion that each line will contain all active tissues:
done | perl -F"\t" -lane '
    $x =shift @F;
    $h{$F[3]}{line} = [@F];
    push(@{$h{$F[3]}{cells}}, $x);
    END {
        foreach $ID (keys %h){
            $cells = join "|", @{$h{$ID}{cells}};
            printf "chr%s\t%s\t%s\t%s\tchr=%s;start=%s;end=%s;class=%s;regulatory_ID=%s;Tissues=%s\n",
                $h{$ID}{line}[0], $h{$ID}{line}[1], $h{$ID}{line}[2], $h{$ID}{line}[3], $h{$ID}{line}[0],
                $h{$ID}{line}[1], $h{$ID}{line}[2], $h{$ID}{line}[4], $h{$ID}{line}[3], $cells
        }
    }
' | sort -k1,1 -k2,2n | bgzip > ${targetDir}/${today}/processed/Cell_spec_regulatory_features.bed.gz

# Test if output is empty or not:
testFileLines ${targetDir}/${today}/processed/Cell_spec_regulatory_features.bed.gz

tabix -p bed ${targetDir}/${today}/processed/Cell_spec_regulatory_features.bed.gz
echo  "Done."

# Print out report:
cellSpecFeatLines=$(zcat ${targetDir}/${today}/processed/Cell_spec_regulatory_features.bed.gz | wc -l | awk '{print $1}')
info "Number of cell specific regulatory features: $cellSpecFeatLines\n\n"


##
## Step 8. Adding GRCh38 coordinates to GTEx data. (based on rsID)
##

# Instead of the single step we can generate a bedfile and run liftover
# This step takes around 7 minutes.
info "Mapping GTEx variants to GRCh38 build.\n"
info "Creating temporary bed file (~9 minutes)... "
zcat ${targetDir}/${today}/GTEx/GTEx_Analysis_${GTExRelease}_eQTLs.tar.gz  | perl -F"\t" -lane '
        if ($_ =~ /snpgenes/){
            ($tissue) = $_ =~ /([A-Z]+.+)_Analysis.snpgenes/;
            next;
        }
        ($chr, $pos, $ref, $alt, $build) = split("_", $F[0]);
        ($gene) = $F[1] =~ /(ENS.+)\./;
        $rsID = $F[22];

        $h{$rsID}{chr}= $chr;
        $h{$rsID}{pos}= $pos;
        push( @{$h{$rsID}{genes}{$gene}}, $tissue ) if $tissue;

        END {
            foreach $rsID ( keys %h){
                $chr = $h{$rsID}{chr};
                $pos = $h{$rsID}{pos};

                foreach $gene ( keys %{$h{$rsID}{genes}}){
                    $tissues = join "|", @{$h{$rsID}{genes}{$gene}};

                    # Reporting problem if something comes upon:

                    printf "chr$chr\t%s\t$pos\tgene=$gene;rsID=$rsID;tissue=$tissues\n", $pos - 1 if $chr and $pos;
                }
            }
        }
    '  | sort -k1,1 -k2,2n > ${targetDir}/${today}/processed/GTEx_temp.bed

# Testing if output file has lines:
testFileLines ${targetDir}/${today}/processed/GTEx_temp.bed

echo "Done."

info "Running liftOver (~2 minutes).... "
liftOver ${targetDir}/${today}/processed/GTEx_temp.bed ${scriptDir}/hg19ToHg38.over.chain \
    ${targetDir}/${today}/processed/GTEx_temp_GRCh38.bed \
    ${targetDir}/${today}/processed/GTEx_temp_failed_to_map.bed
echo "Done."

# Generate report:
failedMap=$(wc -l ${targetDir}/${today}/processed/GTEx_temp_failed_to_map.bed | awk '{print $1}')
Mapped=$(wc -l ${targetDir}/${today}/processed/GTEx_temp_GRCh38.bed | awk '{print $1}')
info "Successfully mapped GTEx variants: ${Mapped}, failed variants: ${failedMap}.\n\n"

##
## Step 9. Using intersectbed. Find overlap between GTEx variations and regulatory regions
##
info "Linking genes to regulatory features using GTEx data... "
intersectBed -wb -a ${targetDir}/${today}/processed/GTEx_temp_GRCh38.bed -b ${targetDir}/${today}/processed/Cell_spec_regulatory_features.bed.gz \
    | perl -MData::Dumper -MJSON -F"\t" -lane '
        # Name of the source is GTEx
        $source= "GTEx";

        # Parsing input:
        ($gene) = $F[3] =~ /gene=(ENSG.+?);/;
        ($G_rsID) = $F[3] =~ /rsID=(rs.+?);/;
        ($G_tissues) = $F[3] =~ /tissue=(.+)/;
        $E_chr = $F[4];
        $E_start = $F[5];
        $E_end = $F[6];
        $E_ID = $F[7];
        ($E_class) = $F[8] =~ /class=(.+?);/;
        ($E_tissues) = $F[8] =~ /Tissues=(.+)/;

        # Building hash:
        $h{$gene."_".$E_ID}{gene_ID} = $gene;
        $h{$gene."_".$E_ID}{class} = $E_class;
        $h{$gene."_".$E_ID}{source} = $source;
        $h{$gene."_".$E_ID}{chr} = $E_chr;
        $h{$gene."_".$E_ID}{start} = $E_start;
        $h{$gene."_".$E_ID}{end} = $E_end;
        $h{$gene."_".$E_ID}{regulatory_ID} = $E_ID;
        $h{$gene."_".$E_ID}{Tissues} = [split /\|/, $E_tissues];

        # Adding GTEx details:
        push(@{$h{$gene."_".$E_ID}{GTEx_rsIDs}}, $G_rsID);
        push(@{$h{$gene."_".$E_ID}{GTEx_tissues}}, (split /\|/, $G_tissues));

        # Saving results when reading data has finished:
        END {
            # Looping through all gene/reg feature pairs:
            for $key ( keys %h){
                # Looping through all GTEx tissues and keep only the unique ones.
                %a = ();
                foreach $tissue (@{$h{$key}{GTEx_tissues}}){
                    $a{$tissue} = 1;
                }
                $h{$key}{GTEx_tissues} = [keys %a];

                # Saving json:
                print JSON->new->utf8->encode($h{$key})
            }
        }
    ' | gzip > ${targetDir}/${today}/processed/GTEx_Regulation_linked.txt.gz

# Testing if output file has lines:
testFileLines ${targetDir}/${today}/processed/GTEx_Regulation_linked.txt.gz

echo "Done."

# Generate report:
GTExLinkedFeatures=$( zcat ${targetDir}/${today}/processed/GTEx_Regulation_linked.txt.gz | wc -l | awk '{print $1}')
info "Number of GTEx linked regulatory features: ${GTExLinkedFeatures}\n\n"

##
## Step 10. Using intersectbed. Find overlap between genes and regulatory regions
##
info "Linking genes to regulatory features based on overlap... "
# generating a file.
zcat ${targetDir}/${today}/GENCODE/gencode.v${GENCODE_release}.annotation.gtf.gz | awk '$3 == "gene"' | perl -lane '
        ($g_name) = $_ =~ /gene_name "(.+?)";/;
        ($g_ID) = $_ =~ /gene_id "(.+?)";/;
        printf "$F[0]\t$F[3]\t$F[4]\tID:$g_ID;Name:$g_name\n";
    ' | sort -k1,1 -k2,2n | bgzip > ${targetDir}/${today}/processed/genes.bed.gz

# Intersect bed run.
# chr1	16048	29570	ID:ENSG00000227232.5;Name:WASH7P	chr1	16048	30847	ENSR00000528774	chr=1;start=16048;end=30847;class=CTCF_binding_site;regulatory_ID=ENSR00000528774;Tissues=DND-41|HMEC|HSMMtube|IMR90|K562|MultiCell|NHDF-AD
intersectBed -wb -a ${targetDir}/${today}/processed/genes.bed.gz -b ${targetDir}/${today}/processed/Cell_spec_regulatory_features.bed.gz -sorted \
    | perl -MData::Dumper -MJSON -F"\t" -lane '
        # Parsing gene info:
        ($g_ID) = $F[3] =~ /ID:(ENSG\d+)/;
        ($g_name) = $F[3] =~ /Name:(.+)/;

        # Parsing regulatory feature info:
        ($r_chr, $r_start, $r_end, $r_ID) = ($F[4], $F[5], $F[6], $F[7]);
        ($r_class) = $F[8] =~ /class=(.+?);/;
        ($r_tissue_string) = $F[8] =~ /Tissues=(.+)/;
        @r_tissues = split(/\|/, $r_tissue_string);

        # Saving JSON formatted string:
        print JSON->new->utf8->encode({
            "chr"   => $r_chr,
            "start" => $r_start,
            "end"   => $r_end,
            "class" => $r_class,
            "gene_ID"   => $g_ID,
            "gene_name" => $g_name,
            "Tissues"   => \@r_tissues,
            "regulatory_ID" => $r_ID,
            "source"    => "overlap",
        })
    ' | bgzip > ${targetDir}/${today}/processed/overlapping_features.txt.gz
echo "Done."

# Generate report:
OverlapLinkedFeatures=$( zcat ${targetDir}/${today}/processed/overlapping_features.txt.gz | wc -l | awk '{print $1}')
info "Number of regulatory features linked by overlap: ${OverlapLinkedFeatures}\n\n"

##
## Step 11. Merging all the components together create compressed, sorted bedfile.
##
info "Merging GENCODE, GTEx and overlap data together into an indexed bedfile. "
export gene_file=${targetDir}/${today}/processed/genes.bed.gz # make sure file readable from within the perl script
zcat ${targetDir}/${today}/processed/overlapping_features.txt.gz \
     ${targetDir}/${today}/processed/GTEx_Regulation_linked.txt.gz \
     ${targetDir}/${today}/processed/Appris_annotation_added.txt.gz  \
     | perl -lane 'BEGIN {
            open  $GF, "zcat $ENV{gene_file} |";
            while ($line = <$GF>){
                chop $line;
                @a = split "\t", $line;
                ($ID) = $a[3] =~ /ID:(ENSG\d+)/;
                $h{$ID} = [$a[0], $a[1], $a[2], $ID];

            }
        }{

            ($ID) = $_ =~ /"gene_ID":"(ENSG\d+)"/;
            exists $h{$ID} ? print join "\t", @{$h{$ID}}, $_ : print STDERR "$ID : gene was notfound in gencode! line: $_"
        }'  2> ${targetDir}/${today}/failed | sort -k1,1 -k2,2n > ${targetDir}/${today}/Linked_features.bed

echo -e "Done.\n"

# Creating header for the final output:
cat <(echo -e "# Regions file for burden testing. Created: 2016.09.21
#
# GENCODE version: v.${GENCODE_release}
# Ensembl version: v.${Ensembl_release}
# GTEx version: ${GTExRelease}
#
# CHR\tSTART\END\tGENEID\tANNOTATION" ) ${targetDir}/${today}/Linked_features.bed | sponge ${targetDir}/${today}/Linked_features.bed

# Compressing and indexing output file:
bgzip ${targetDir}/${today}/Linked_features.bed
tabix -p bed ${targetDir}/${today}/Linked_features.bed.gz

# Final report and we are done.
info "Output file was saved as: ${targetDir}/${today}/Linked_features.bed.gz\n"
totalLines=$(zcat ${targetDir}/${today}/Linked_features.bed.gz | wc -l | awk '{print $1}')
info "Total number of lines in the final files: ${totalLines}\n"

# Report failed associations:
FailedAssoc=$(wc -l ${targetDir}/${today}/failed | awk '{print $1}')
FailedGenes=$( cat ${targetDir}/${today}/failed | perl -lane '$_ =~ /(ENSG\d+)/; print $1' | sort | uniq | wc -l )
FailedSources=$( cat ${targetDir}/${today}/failed | perl -lane '$_ =~ /"source":"(.+?)"/; print $1' | sort | uniq | tr "\n" ", " )
info "Number of lost associations: ${FailedAssoc}, belonging to ${FailedGenes} genes in the following sournces: ${FailedSources}\n\n"
info "Cleaning up..\n"

#tar ${targetDir}/${today}/${today}.genome.annotation.tar.gz

# Exit.
info "Program finished.\n"
exit 0