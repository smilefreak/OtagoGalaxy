# Parse RefSeq GPFF files to create xrefs.

package XrefParser::RefSeqGPFFParser;

use strict;

use File::Basename;

use base qw( XrefParser::BaseParser );

my $verbose;

sub run {

  my $self = shift;
  my $source_id = shift;
  my $species_id = shift;
  my $files_ref  = shift;
  my $rel_file   = shift;
  $verbose       = shift;

  my @files = @{$files_ref};

    my $peptide_source_id =
      $self->get_source_id_for_source_name('RefSeq_peptide');
    my $dna_source_id =
      $self->get_source_id_for_source_name('RefSeq_dna');

    print "RefSeq_peptide source ID = $peptide_source_id\n" if($verbose);
    print "RefSeq_dna source ID = $dna_source_id\n" if($verbose);

    my $pred_peptide_source_id =
      $self->get_source_id_for_source_name('RefSeq_peptide_predicted');
    my $pred_dna_source_id =
      $self->get_source_id_for_source_name('RefSeq_dna_predicted');

    print "RefSeq_peptide_predicted source ID = "
      . "$pred_peptide_source_id\n" if($verbose);
    print "RefSeq_dna_predicted source ID = $pred_dna_source_id\n" if($verbose);

    my @xrefs;
    foreach my $file (@files) {
        if ( $source_id < 1 ) {
            $source_id =
              $self->get_source_id_for_filename( basename($file) );
        }
        if ( !defined($species_id) ) {
            $species_id = $self->get_species_id_for_filename($file);
        }

        my $xrefs =
          $self->create_xrefs( $peptide_source_id,
                               $dna_source_id,
                               $pred_peptide_source_id,
                               $pred_dna_source_id,
                               $file,
                               $species_id );

        if ( !defined( $xrefs ) ) {
            return 1;    #error
        }

        push @xrefs, @{$xrefs};
    }

    if ( !defined( $self->upload_xref_object_graphs( \@xrefs ) ) ) {
        return 1;    # error
    }

    if ( defined $rel_file ) {
        # Parse and set release info.
        my $release_io = $self->get_filehandle($rel_file);
        local $/ = "\n*";
        my $release = $release_io->getline();
        $release_io->close();

        $release =~ s/\s{2,}/ /g;
        $release =~ s/.*(NCBI Reference Sequence.*) Distribution.*/$1/s;
        # Put a comma after the release number to make it more readable.
        $release =~ s/Release (\d+)/Release $1,/;

        print "RefSeq release: '$release'\n" if($verbose);

        $self->set_release( $source_id,              $release );
        $self->set_release( $peptide_source_id,      $release );
        $self->set_release( $dna_source_id,          $release );
        $self->set_release( $pred_peptide_source_id, $release );
        $self->set_release( $pred_dna_source_id,     $release );
    }

  return 0; # successful
}

# --------------------------------------------------------------------------------
# Parse file into array of xref objects
# There are 2 types of RefSeq files that we are interested in:
# - protein sequence files *.protein.faa
# - mRNA sequence files *.rna.fna
# Slightly different formats

sub create_xrefs {
  my $self = shift;

  my ( $peptide_source_id, $dna_source_id, $pred_peptide_source_id,
      $pred_dna_source_id, $file, $species_id ) = @_;

  # Create a hash of all valid names and taxon_ids for this species
  my %species2name = $self->species_id2name();
  my %species2tax  = $self->species_id2taxonomy();
  my @names   = @{$species2name{$species_id}};
  my @tax_ids = @{$species2tax{$species_id}};
  my %name2species_id     = map{ $_=>$species_id } @names;
  my %taxonomy2species_id = map{ $_=>$species_id } @tax_ids;

  my %dependent_sources =  $self->get_dependent_xref_sources();

  my $refseq_io = $self->get_filehandle($file);

  if ( !defined $refseq_io ) {
    print STDERR "ERROR: Can't open RefSeqGPFF file $file\n";
    return;
  }

  my @xrefs;

  local $/ = "\/\/\n";

  my $type;
  if ($file =~ /protein/) {

    $type = 'peptide';

  } elsif ($file =~ /rna/) {

    $type = 'dna';

  } elsif($file =~ /RefSeq_dna/){

    $type = 'dna';

  } elsif($file =~ /RefSeq_protein/){

    $type = 'peptide';

  }else{
    print STDERR "Could not work out sequence type for $file\n";
    return;
  }


  while ( $_ = $refseq_io->getline() ) {

    my $xref;

    my $entry = $_;
    chomp $entry;

    my ($species) = $entry =~ /\s+ORGANISM\s+(.*)\n/;
    $species = lc $species;
    $species =~ s/^\s*//g;
    $species =~ s/\s*\(.+\)//; # Ditch anything in parens
    $species =~ s/\s+/_/g;
    $species =~ s/\n//g;
    my $species_id_check = $name2species_id{$species};

    # Try going through the taxon ID if species check didn't work.
    if ( !defined $species_id_check ) {
        my ($taxon_id) = $entry =~ /db_xref="taxon:(\d+)"/;
        $species_id_check = $taxonomy2species_id{$taxon_id};
    }

    # skip xrefs for species that aren't in the species table
    if (   defined $species_id
        && defined $species_id_check
        && $species_id == $species_id_check )
    {
      my ($acc) = $entry =~ /ACCESSION\s+(\S+)/;
      my ($ver) = $entry =~ /VERSION\s+(\S+)/;

      # get the right source ID based on $type and whether this is predicted (X*) or not
      my $source_id;
      if ($type =~ /dna/) {
	if ($acc =~ /^XM_/) {
	  $source_id = $pred_dna_source_id;
	} else {
	  $source_id = $dna_source_id;
	}
      } elsif ($type =~ /peptide/) {
	if ($acc =~ /^XP_/) {
	  $source_id = $pred_peptide_source_id;
	} else {
	  $source_id = $peptide_source_id;
	}
      }
      print "Warning: can't get source ID for $type $acc\n" if (!$source_id);

      # Description - may be multi-line
      my ($description) = $entry =~ /DEFINITION\s+([^[]+)/s;
      print $entry if (length($description) == 0);
      $description =~ s/\nACCESSION.*//s;
      $description =~ s/\n//g;
      $description =~ s/\s+/ /g;
      $description = substr($description, 0, 255) if (length($description) > 255);

      my ($seq) = $_ =~ /ORIGIN\s+(.+)/s; # /s allows . to match newline
      my @seq_lines = split /\n/, $seq;
      my $parsed_seq = "";
      foreach my $x (@seq_lines) {
        my ($seq_only) = $x =~ /^\s*\d+\s+(.*)$/;
        next if (!defined $seq_only);
        $parsed_seq .= $seq_only;
      }
      $parsed_seq =~ s#//##g;    # remove trailing end-of-record character
      $parsed_seq =~ s#\s##g;    # remove whitespace

      ( my $acc_no_ver, $ver ) = split( /\./, $ver );

      $xref->{ACCESSION} = $acc;
      if($acc eq $acc_no_ver){
         $xref->{VERSION} = $ver;
      }
      else{
         print "$acc NE $acc_no_ver\n";
      }

      $xref->{LABEL} = $acc . "\." . $ver;
      $xref->{DESCRIPTION} = $description;
      $xref->{SOURCE_ID} = $source_id;
      $xref->{SEQUENCE} = $parsed_seq;
      $xref->{SEQUENCE_TYPE} = $type;
      $xref->{SPECIES_ID} = $species_id;
      $xref->{INFO_TYPE} = "SEQUENCE_MATCH";

      # TODO experimental/predicted

      my @EntrezGeneIDline = $entry =~ /db_xref=.GeneID:(\d+)/g;
      my @SGDGeneIDline = $entry =~ /db_xref=.SGD:(S\d+)/g;
      my @protein_id = $entry =~ /\/protein_id=.(\S+_\d+)/g;
      my @coded_by = $entry =~  /\/coded_by=.(\w+_\d+)/g;

      foreach my $cb (@coded_by){
	$xref->{PAIR} = $cb;
      }

      foreach my $pi (@protein_id){
	$xref->{PROTEIN} = $pi;
      }

      foreach my $ll (@EntrezGeneIDline) {
	my %dep;
	$dep{SOURCE_ID} = $dependent_sources{EntrezGene} 
          || die( 'No source for EntrezGene!' );
	$dep{LINKAGE_SOURCE_ID} = $source_id;
	$dep{ACCESSION} = $ll;
	push @{$xref->{DEPENDENT_XREFS}}, \%dep;

	my %dep2;
	$dep2{SOURCE_ID} = $dependent_sources{WikiGene} 
          || die( 'No source for WikiGene!' );
	$dep2{LINKAGE_SOURCE_ID} = $source_id;
	$dep2{ACCESSION} = $ll;
	push @{$xref->{DEPENDENT_XREFS}}, \%dep2;
      }

      # Don't add SGD Xrefs, as they are mapped directly from SGD ftp site

      #foreach my $ll (@SGDGeneIDline) {
	#my %dep;
	#$dep{SOURCE_ID} = $dependent_sources{"SGD"} 
        #  || die( 'No source for SGD!' );
	#$dep{LINKAGE_SOURCE_ID} = $source_id;
	#$dep{ACCESSION} = $ll;
	#push @{$xref->{DEPENDENT_XREFS}}, \%dep;
      #}
      
      # Refseq's do not tell whether the mim is for the gene of morbid so ignore for now.

      push @xrefs, $xref;

    }# if defined species

  } # while <REFSEQ>

  $refseq_io->close();

  print "Read " . scalar(@xrefs) ." xrefs from $file\n" if($verbose);

  return \@xrefs;

}

# --------------------------------------------------------------------------------

1;
