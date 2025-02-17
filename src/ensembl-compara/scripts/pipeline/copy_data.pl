#!/usr/bin/env perl

use warnings;
use strict;

my $description = q{
###########################################################################
##
## PROGRAM copy_data.pl
##
## AUTHORS
##    Javier Herrero (jherrero@ebi.ac.uk)
##
## COPYRIGHT
##    This script is part of the Ensembl project http://www.ensembl.org
##
## DESCRIPTION
##    This script copies data over compara DBs. It has been
##    specifically developped to copy data from a production to a
##    release database.
##
###########################################################################

};

=head1 NAME

copy_data.pl

=head1 AUTHORS

 Javier Herrero (jherrero@ebi.ac.uk)

=head1 COPYRIGHT

This script is part of the Ensembl project http://www.ensembl.org

=head1 DESCRIPTION

This script copies data over compara DBs. It has been
specifically developped to copy data from a production to a
release database.

This script does not store the homology/family data as these are completely
rebuild for each release. Only the relevant DNA-DNA alignments and syntenic
regions are copied from the old database.

=head1 SYNOPSIS

perl copy_data.pl --help

perl copy_data.pl
    [--reg-conf registry_configuration_file]
    --from production_database_name
    --to release_database_name
    --mlss method_link_species_set_id

perl copy_data.pl
    --from_url production_database_url
    --to_url release_database_url
    --mlss method_link_species_set_id

example:

bsub  -q yesterday -ooutput_file -Jcopy_data -R "select[mem>5000] rusage[mem=5000]" -M5000000 
copy_data.pl --from_url mysql://username@server_name/sf5_production 
--to_url mysql://username:password@server_name/sf5_release --mlss 340



=head1 REQUIREMENTS

This script uses mysql, mysqldump and mysqlimport programs.
It requires at least version 4.1.12 of mysqldump as it uses
the --insert-ignore option.

=head1 ARGUMENTS

=head2 GETTING HELP

=over

=item B<[--help]>

  Prints help message and exits.

=back

=head2 DATABASES using URLs

=over

=item B<--from_url mysql://user[:passwd]@host[:port]/dbname>

URL for the production compara database. Data will be copied from this instance.

=item B<--to_url mysql://user[:passwd]@host[:port]/dbname>

URL for the release compara database. Data will be copied to this instance.

=back

=head2 DATABASES using the Registry

=over

=item B<[--reg_conf registry_configuration_file]>

The Bio::EnsEMBL::Registry configuration file. If none given,
the one set in ENSEMBL_REGISTRY will be used if defined, if not
~/.ensembl_init will be used.

=item B<--from from_compara_db_name>

The production compara database name as defined in the Registry or any valid alias.
Data will be copied from this instance.

=item B<--to to_compara_db_name>

The release compara database name as defined in the Registry or any valid alias.
Data will be copied to this instance.

=back

=head2 DATA

=over

=item B<--mlss method_link_species_set_id>

Copy data for this species only. This option can be used several times in order to restrict
the copy to several species.

=item B<[--merge boolean]>

If true, add new data to an existing data set in the release database. Default FALSE. 

=back

=head1 INTERNAL METHODS

=cut

use Bio::EnsEMBL::Registry;
use Bio::EnsEMBL::Compara::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Getopt::Long;

$| = 1;

my $help;

my $reg_conf;
my $from_name = undef;
my $to_name = undef;
my $from_url = undef;
my $to_url = undef;
my $mlss_id = undef;

#If true, then trust the TO database tables and update the FROM tables if 
#necessary. Currently only applies to differences in the dnafrag table and 
#will only update the genomic_align table.
my $trust_to = 0; 

#If true, assume that the range of ce_ids does not need to be shifted.
my $trust_ce = 0;

#If true, then add new data to existing set of alignments
my $merge = 0;

GetOptions(
    "help"      => \$help,
    "reg-conf|reg_conf|registry=s" => \$reg_conf,
    "from=s"    => \$from_name,
    "to=s"      => \$to_name,
    "from_url=s" => \$from_url,
    "to_url=s"  => \$to_url,
    "mlss_id=i" => \$mlss_id,
    "trust_to!" => \$trust_to,
    "merge!"    => \$merge,
    'trust_ce!' => \$trust_ce,
  );

# Print Help and exit if help is requested
if ($help or (!$from_name and !$from_url) or (!$to_name and !$to_url) or !$mlss_id) {
  exec("/usr/bin/env perldoc $0");
}

Bio::EnsEMBL::Registry->load_all($reg_conf) if ($from_name or $to_name);
my $from_dba = get_DBAdaptor($from_url, $from_name);
my $to_dba = get_DBAdaptor($to_url, $to_name);

my $method_link_species_set = $from_dba->get_MethodLinkSpeciesSetAdaptor->fetch_by_dbID($mlss_id);
if (!$method_link_species_set) {
  print " ** ERROR **  Cannot find any MethodLinkSpeciesSet with this ID ($mlss_id)\n";
  exit(1);
}

my $class = $method_link_species_set->method_link_class;

exit(1) if !check_table("method_link", $from_dba, $to_dba, undef,
    "method_link_id = ".$method_link_species_set->method_link_id);
exit(1) if !check_table("method_link_species_set", $from_dba, $to_dba, undef,
    "method_link_species_set_id = $mlss_id");

if ($class =~ /^GenomicAlignBlock/ or $class =~ /^GenomicAlignTree/) {
  copy_genomic_align_blocks($from_dba, $to_dba, $method_link_species_set);
} elsif ($class =~ /^ConservationScore.conservation_score/) {
  copy_conservation_scores($from_dba, $to_dba, $mlss_id);
} elsif ($class =~ /^ConstrainedElement.constrained_element/) {
  copy_constrained_elements($from_dba, $to_dba, $mlss_id);
} else {
  print " ** ERROR **  Copying data of class $class is not supported yet!\n";
  exit(1);
}

exit(0);

=head2 get_DBAdaptor

  Arg[1]      : string $dburl
  Arg[2]      : string $registry_dbname
  Description : Uses either the $dburl or the $registry_dbname (and the
                $regsitry_file if needed) to get the DBAdaptor for this
                database. Test that the DB exists.
  Returns     : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor
  Exceptions  : throw if argument test fails

=cut

sub get_DBAdaptor {
  my ($url, $name) = @_;
  my $compara_db_adaptor = undef;

  if ($url) {
    if ($url =~ /mysql\:\/\/([^\@]+\@)?([^\:\/]+)(\:\d+)?\/(.+)/) {
      my $user_pass = $1;
      my $host = $2;
      my $port = $3;
      my $dbname = $4;

      $user_pass =~ s/\@$//;
      my ($user, $pass) = $user_pass =~ m/([^\:]+)(\:.+)?/;
      $pass =~ s/^\:// if ($pass);
      $port =~ s/^\:// if ($port);

      $compara_db_adaptor = new Bio::EnsEMBL::Compara::DBSQL::DBAdaptor(
          -host => $host,
          -user => $user,
          -pass => $pass,
          -port => $port,
          -group => "compara",
          -dbname => $dbname,
          -species => $dbname,
        );
    } else {
      warn("Cannot undestand URL: $url\n");
    }
  } elsif ($name) {
    $compara_db_adaptor = Bio::EnsEMBL::Registry->get_DBAdaptor($name, "compara");
  }

  if (!$compara_db_adaptor->get_MetaContainer) {
    return undef;
  }

  return $compara_db_adaptor;
}


=head2 check_table

  Arg[1]      : string $table_name
  Arg[2]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $from_dba
  Arg[3]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $to_dba
  Arg[4]      : [optional] string columns (whatever comes between
                'SELECT' and 'FROM')
  Arg[5]      : [optional] string where (whatever comes after
                'WHERE')
  Description : Check the content of the table in $from DB against
                $to DB
  Returns     : bool
  Exceptions  : throw if argument test fails

=cut

sub check_table {
  my ($table_name, $from_dba, $to_dba, $columns, $where) = @_;

  print "Checking ".($columns ? "columns [$columns] of the" : '')." table $table_name ".($where ? "where [$where]" : '')."...";

  throw("[$from_dba] should be a Bio::EnsEMBL::Compara::DBSQL::DBAdaptor")
      unless (UNIVERSAL::isa($from_dba, "Bio::EnsEMBL::Compara::DBSQL::DBAdaptor"));

  throw("[$to_dba] should be a Bio::EnsEMBL::Compara::DBSQL::DBAdaptor")
      unless (UNIVERSAL::isa($to_dba, "Bio::EnsEMBL::Compara::DBSQL::DBAdaptor"));

  my $from_entries;
  ## Write SQL query
  my $sql;
  if ($columns) {
    $sql = "SELECT $columns FROM $table_name";
  } else {
    $sql = "SELECT * FROM $table_name";
  }
  if ($where) {
    $sql .= " WHERE $where";
  }

  ## Execute on FROM
  my $sth = $from_dba->dbc->prepare($sql);
  $sth->execute();
  while (my $row = $sth->fetchrow_arrayref) {
    my $key = join("..", @$row);
    $from_entries->{$key} = 1;
  }
  $sth->finish;

  ## Execute on TO
  $sth = $to_dba->dbc->prepare($sql);
  $sth->execute();
  while (my $row = $sth->fetchrow_arrayref) {
    my $key = join("..", @$row);
    $from_entries->{$key} -= 1;
  }
  $sth->finish;

  ## Check results
  my $result;
  foreach my $value (values %$from_entries) {
    $result->{$value} ++;
  }

  print "  from = ", ($result->{1} or 0), "; to = ", ($result->{-1} or 0),
      "; both = ", ($result->{0} or 0), "   ";
  if ($result->{1}) {
    print "FAIL\n\n ** ERROR ** $result->{1} rows from the production",
        " database (FROM) are not found on the release one.\n\n";
    return 0;
  } elsif (!$result->{0}) {
    print "WARN\n\n ** WARNING ** the production database (FROM) has",
        " no data in $table_name.\n\n";
  } else {
    print "ok.\n";
  }

  return 1;
}


=head2 copy_genomic_align_blocks

  Arg[1]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $from_dba
  Arg[2]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $to_dba
  Arg[3]      : Bio::EnsEMBL::Compara::MethodLinkSpeciesSet $this_mlss

  Description : copies GenomicAlignBlocks for this MethodLinkSpeciesSet.
  Returns     :
  Exceptions  : throw if argument test fails

=cut

sub copy_genomic_align_blocks {
  my ($from_dba, $to_dba, $mlss) = @_;
  my $fix_dnafrag = 0;

  my $mlss_id = $mlss->dbID;

  exit(1) if !check_table("genome_db", $from_dba, $to_dba, "genome_db_id, name, assembly, genebuild, assembly_default");
  #ignore ancestral dnafrags, will add those later
  if (!check_table("dnafrag", $from_dba, $to_dba, undef, "genome_db_id != 63")) {
      $fix_dnafrag = 1;
      if ($fix_dnafrag && !$trust_to) {
	  print " To fix the dnafrags in the genomic_align table, you can use the trust_to flag\n\n";
	  exit(1);
      }
  }

  ## Check min and max of the relevant internal IDs in the FROM database
  my $sth = $from_dba->dbc->prepare("SELECT
        MIN(gab.genomic_align_block_id), MAX(gab.genomic_align_block_id),
        MIN(gab.group_id), MAX(gab.group_id),
        MIN(ga.genomic_align_id), MAX(ga.genomic_align_id),
        MIN(gag.node_id), MAX(gag.node_id),
	MIN(gat.node_id), MAX(gat.node_id),
        MIN(gat.root_id), MAX(gat.root_id),
	MIN(gat.left_index)
      FROM genomic_align_block gab
        LEFT JOIN genomic_align ga using (genomic_align_block_id)
        LEFT JOIN genomic_align_group gag using (genomic_align_id)
	LEFT JOIN genomic_align_tree gat ON gat.node_id = gag.node_id
      WHERE
        gab.method_link_species_set_id = ?");

  $sth->execute($mlss_id);
  my ($min_gab, $max_gab, $min_gab_gid, $max_gab_gid, $min_ga, $max_ga, $min_gag, 
		$max_gag, $min_gat, $max_gat, $min_root_id, $max_root_id, $from_index_range_start) =
      $sth->fetchrow_array();

  $sth->finish();

  my $fix_gab;
  my $fix_ga;
  my $fix_gab_gid;
  my $fix_gag;

  #Want to add more data. Must find out current max(genomic_align_block) in TO
  #database and start from there
  #Currently only tested for pairwise alignments
  my ($to_min_gab, $to_max_gab, $to_min_gab_gid, $to_max_gab_gid, $to_min_ga, $to_max_ga, $to_min_gag, $to_max_gag, $to_min_gat, $to_max_gat, $to_min_root_id, $to_max_root_id, $to_from_index_range_start);

  if ($merge) {
      my $sth = $to_dba->dbc->prepare("SELECT
        MIN(gab.genomic_align_block_id), MAX(gab.genomic_align_block_id),
        MIN(gab.group_id), MAX(gab.group_id),
        MIN(ga.genomic_align_id), MAX(ga.genomic_align_id),
        MIN(gag.node_id), MAX(gag.node_id),
	MIN(gat.node_id), MAX(gat.node_id),
        MIN(gat.root_id), MAX(gat.root_id),
	MIN(gat.left_index)
      FROM genomic_align_block gab
        LEFT JOIN genomic_align ga using (genomic_align_block_id)
        LEFT JOIN genomic_align_group gag using (genomic_align_id)
	LEFT JOIN genomic_align_tree gat ON gat.node_id = gag.node_id
      WHERE
        gab.method_link_species_set_id = ?");

      $sth->execute($mlss_id);
      ($to_min_gab, $to_max_gab, $to_min_gab_gid, $to_max_gab_gid, $to_min_ga, $to_max_ga, $to_min_gag, $to_max_gag, $to_min_gat, $to_max_gat, $to_min_root_id, $to_max_root_id, $to_from_index_range_start) =  $sth->fetchrow_array();

      $sth->finish();
      $fix_gab = $to_max_gab-$min_gab+1;
      $fix_ga = $to_max_ga-$min_ga+1;
      $fix_gab_gid = $to_max_gab_gid-$min_gab_gid+1;

      #print "to max_gab $to_max_gab min_gab $to_min_gab max_ga $to_max_ga min_ga $to_min_ga max_gab_gid $to_max_gab_gid min_gab_gid $to_min_gab_gid\n";
  }

  #print "max_gab $max_gab min_gab $min_gab max_ga $max_ga min_ga $min_ga max_gab_gid $max_gab_gid min_gab_gid $min_gab_gid\n";


  my $lower_limit = $mlss_id * 10**10;
  my $upper_limit = ($mlss_id + 1) * 10**10;
  my $index_offset = 0;

  if (!defined $fix_gab) {
      if ($max_gab < 10**10) {
	  $fix_gab = $lower_limit;
      } elsif ($min_gab >= $lower_limit and $max_gab < $upper_limit) {
	  $fix_gab = 0;
      } else {
	  die " ** ERROR **  Internal IDs are funny: genomic_align_block_ids between $min_gab and $max_gab\n";
      }
  }

  if (!defined $fix_ga) {
      if ($max_ga < 10**10) {
	  $fix_ga = $lower_limit;
      } elsif ($min_ga >= $lower_limit and $max_ga < $upper_limit) {
	  $fix_ga = 0;
      } else {
	  die " ** ERROR **  Internal IDs are funny: genomic_align_ids between $min_ga and $max_ga\n";
      }
  }

  if (!defined $fix_gab_gid) {
      if (defined($max_gab_gid)) {
	  if ($max_gab_gid < 10**10) {
	      $fix_gab_gid = $lower_limit;
	  } elsif ($min_gab_gid >= $lower_limit and $max_gab_gid < $upper_limit) {
	      $fix_gab_gid = 0;
	  } else {
	      die " ** ERROR **  Internal IDs are funny: genomic_align_block.group_ids between $min_gab_gid and $max_gab_gid\n";
	  }
      } else {
	  $fix_gab_gid = 0;
      }
  }

  if (!defined $fix_gag) {
      if (defined($max_gag)) {
	  if ($max_gag < 10**10) {
	      $fix_gag = $lower_limit;
	  } elsif ($min_gag >= $lower_limit and $max_gag < $upper_limit) {
	      $fix_gag = 0;
	  } else {
	      die " ** ERROR **  Internal IDs are funny: genomic_align_block.group_ids between $min_gab_gid and $max_gab_gid\n";
	  }
      } else {
	  $fix_gag = 0;
      }
  }

  ## Check availability of the internal IDs in the TO database
  $sth = $to_dba->dbc->prepare("SELECT count(*)
      FROM genomic_align_block
      WHERE genomic_align_block_id >= $lower_limit
          AND genomic_align_block_id < $upper_limit");
  $sth->execute();
  my ($count) = $sth->fetchrow_array();
  if ($count && !$merge) {
    print " ** ERROR **  There are $count entries in the release database (TO) in the \n",
      " ** ERROR **  genomic_align_block table with IDs within the range defined by the\n",
      " ** ERROR **  convention!\n";
    exit(1);
  }

  $sth = $to_dba->dbc->prepare("SELECT count(*)
      FROM genomic_align
      WHERE genomic_align_id >= $lower_limit
          AND genomic_align_id < $upper_limit");
  $sth->execute();
  ($count) = $sth->fetchrow_array();
  if ($count && !$merge) {
    print " ** ERROR **  There are $count entries in the release database (TO) in the \n",
      " ** ERROR **  genomic_align table with IDs within the range defined by the\n",
      " ** ERROR **  convention!\n";
    exit(1);
  }

  if(defined($max_gag)) {
    $sth = $to_dba->dbc->prepare("SELECT count(*)
        FROM genomic_align_group
        WHERE node_id >= $lower_limit
            AND node_id < $upper_limit");
    $sth->execute();
    ($count) = $sth->fetchrow_array();
    if ($count) {
      print " ** ERROR **  There are $count entries in the release database (TO) in the \n",
        " ** ERROR **  genomic_align_group table with IDs within the range defined by the\n",
        " ** ERROR **  convention!\n";
      exit(1);
    }
  }

  if(defined($max_gat)) {
    $sth = $to_dba->dbc->prepare("SELECT count(*)
        FROM genomic_align_tree
        WHERE root_id >= $min_root_id
            AND root_id < $max_root_id");
    $sth->execute();
    my ($count) = $sth->fetchrow_array();
    if ($count) {
      print " ** ERROR **  There are $count entries in the release database (TO) in the \n",
        " ** ERROR **  genomic_align_tree table with IDs within the range defined by the\n",
        " ** ERROR **  convention!\n";
      exit(1);
   }

   # make sure the left_index and right_index are unique in the *to* db
   my $sth_index = $to_dba->dbc->prepare("SELECT max(right_index) FROM genomic_align_tree");
   $sth_index->execute();
   my ($to_index_prev_range_max) = $sth_index->fetchrow_array();
   $to_index_prev_range_max    ||= 0;

   my $to_index_magnitude        = 10**(length($to_index_prev_range_max)-1);
   my $to_index_range_start      = int($to_index_prev_range_max/$to_index_magnitude+1)*$to_index_magnitude+1;

   $index_offset = $to_index_range_start-$from_index_range_start; # may go negative, it's fine
  }

  #copy genomic_align table. Need to update dnafrag column
  if ($trust_to && $fix_dnafrag) {

      #create a temporary genomic_align table with TO dnafrag_ids
      my $temp_genomic_align = "temp_genomic_align";
      fix_genomic_align_table($from_dba, $to_dba, $mlss_id, $temp_genomic_align);
      
      #copy from the temporary genomic_align table
      copy_data($from_dba, $to_dba,
  	    "genomic_align",
	    "genomic_align_id", 
            $min_ga, $max_ga,
  	    "SELECT genomic_align_id+$fix_ga, genomic_align_block_id+$fix_gab, method_link_species_set_id,".
  	    " dnafrag_id, dnafrag_start, dnafrag_end, dnafrag_strand, cigar_line, level_id".
  	    " FROM $temp_genomic_align".
  	    " WHERE method_link_species_set_id = $mlss_id");

      #delete temporary genomic_align table
      $from_dba->dbc->db_handle->do("DROP TABLE $temp_genomic_align");
  } else {
      copy_data($from_dba, $to_dba,
		"genomic_align",
		"genomic_align_id", 
		$min_ga, $max_ga,
		"SELECT genomic_align_id+$fix_ga, genomic_align_block_id+$fix_gab, method_link_species_set_id,".
		" dnafrag_id, dnafrag_start, dnafrag_end, dnafrag_strand, cigar_line, level_id".
		" FROM genomic_align".
		" WHERE method_link_species_set_id = $mlss_id");
  }

  #copy genomic_align_block table
   copy_data($from_dba, $to_dba,
       "genomic_align_block",
       "genomic_align_block_id",
       $min_gab, $max_gab,
       "SELECT genomic_align_block_id+$fix_gab, method_link_species_set_id, score, perc_id, length, group_id+$fix_gab_gid".
         " FROM genomic_align_block WHERE method_link_species_set_id = $mlss_id");

  #copy genomic_align_group table
  if(defined($max_gag)) {
    copy_data($from_dba, $to_dba,
        "genomic_align_group",
        "gag.node_id",
        $min_gag, $max_gag,
        "SELECT gag.node_id+$fix_gag, gag.genomic_align_id+$fix_ga".
          " FROM genomic_align".
          " LEFT JOIN genomic_align_group gag USING (genomic_align_id)".
          " WHERE gag.node_id IS NOT NULL AND method_link_species_set_id = $mlss_id");
  }
  #copy genomic_align_tree table
  #Fixes node_id, parent_id, root_id, left_node_id, right_node_id 
  #Needs to correct parent_id, left_node_id, right_node_id if these were 0
  if(defined($max_gat)) {
    copy_data($from_dba, $to_dba,
        "genomic_align_tree",
        "root_id",
        $min_root_id, $max_root_id,
        "SELECT node_id+$fix_gag, parent_id+$fix_gag, root_id+$fix_gag, left_index+$index_offset, right_index+$index_offset, left_node_id+$fix_gag, right_node_id+$fix_gag, distance_to_parent".
        " FROM genomic_align_tree ".
	"WHERE root_id >= $min_root_id AND root_id <= $max_root_id");
    #Reset the appropriate nodes to zero. Only needs to be done if fix_lower 
    #has been applied.
    if ($fix_gag != 0) {
        foreach my $gt_field( qw/ parent_id node_id left_node_id right_node_id / ) {
            my $gt_sth = $to_dba->dbc->prepare("UPDATE genomic_align_tree SET $gt_field = ($gt_field - ?)
                                        WHERE $gt_field = ?");
            $gt_sth->execute($fix_gag, $fix_gag);
        }
    }
  }

  my $class = $mlss->method_link_class;
  if ($class eq "GenomicAlignTree.ancestral_alignment") {
      copy_ancestral_dnafrags($from_dba, $to_dba, $mlss_id, $lower_limit, $upper_limit);
  }
}


=head2 copy_ancestral_dnafrags

  Arg[1]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $from_dba
  Arg[2]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $to_dba
  Arg[3]      : Bio::EnsEMBL::Compara::MethodLinkSpeciesSet $this_mlss
  Arg[4]      : integer lower limit of dnafrag_id range ($mlss_id * 10**10)
  Arg[5]      : integer upper limit of dnafrag_id range (($mlss_id + 1) * 10**10)

  Description : copies ancestral dnafrags for this MethodLinkSpeciesSet.
  Returns     :
  Exceptions  : throw if argument test fails

=cut

sub copy_ancestral_dnafrags {
  my ($from_dba, $to_dba, $mlss_id, $lower_limit, $upper_limit) = @_;

  #Check name is correct syntax
  my $dnafrag_name = "Ancestor_" . $mlss_id . "_";
  my $sth = $from_dba->dbc->prepare("SELECT name FROM genomic_align
                                         LEFT JOIN dnafrag USING (dnafrag_id)
                                         WHERE genome_db_id = 63
                                         AND method_link_species_set_id = ?");
  $sth->execute($mlss_id);
  my @names = $sth->fetchrow_array();
  $sth->finish();
  #Just look at first name and assume all other names are of the same format
  my $name = $names[0];
  if ($name =~ /$dnafrag_name/) {
      print "valid name\n";
  } else {
      throw("name is not $dnafrag_name format\n");
  }
  #Check name does not already exist in TO database
  $sth = $to_dba->dbc->prepare("SELECT count(*) FROM dnafrag WHERE genome_db_id = 63 AND name LIKE '" . $dnafrag_name . "%'");
  
  $sth->execute();
  my ($count) = $sth->fetchrow_array();
  $sth->finish();
  if ($count) {
      throw("ERROR: $count rows in the dnafrag table with name like $dnafrag_name already exists in the release (TO) database\n");
  }

  #Check min and max of internal IDs in the FROM database
  $sth = $from_dba->dbc->prepare("SELECT MIN(dnafrag_id), 
                                         MAX(dnafrag_id)
                                         FROM genomic_align
                                         LEFT JOIN dnafrag USING (dnafrag_id)
                                         WHERE genome_db_id = 63
                                         AND method_link_species_set_id = ?");
  $sth->execute($mlss_id);
  my ($min_dnafrag_id, $max_dnafrag_id) = $sth->fetchrow_array();
  $sth->finish();
  my $fix_dnafrag_id;
  if ($max_dnafrag_id < 10**10) {
      $fix_dnafrag_id = $lower_limit;
  } elsif ($min_dnafrag_id >= $lower_limit and $max_dnafrag_id < $upper_limit) {
      $fix_dnafrag_id = 0;
  } else {
      die " ** ERROR **  Internal IDs are funny: dnafrag_ids between $min_dnafrag_id and $max_dnafrag_id\n";
  }
  
  ## Check availability of the internal IDs in the TO database
  $sth = $to_dba->dbc->prepare("SELECT count(*)
      FROM dnafrag
      WHERE dnafrag_id >= $lower_limit
      AND dnafrag_id < $upper_limit");
  $sth->execute();
  ($count) = $sth->fetchrow_array();
  if ($count) {
      print " ** ERROR **  There are $count entries in the release database (TO) in the \n",
	" ** ERROR **  dnafrag table with IDs within the range defined by the\n",
	  " ** ERROR **  convention!\n";
      exit(1);
  }
  
  #copy dnafrag table
   copy_data($from_dba, $to_dba,
       "dnafrag",
       "dnafrag_id",
       $min_dnafrag_id, $max_dnafrag_id,
       "SELECT dnafrag_id+$fix_dnafrag_id, length, name, genome_db_id, coord_system_name, is_reference".
         " FROM genomic_align LEFT JOIN dnafrag USING (dnafrag_id)" .
         " WHERE method_link_species_set_id = $mlss_id AND genome_db_id=63");

}

=head2 copy_conservation_scores

  Arg[1]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $from_dba
  Arg[2]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $to_dba
  Arg[3]      : Bio::EnsEMBL::Compara::MethodLinkSpeciesSet $this_mlss

  Description : copies ConservationScores for this MethodLinkSpeciesSet.
  Returns     :
  Exceptions  : throw if argument test fails

=cut

sub copy_conservation_scores {
  my ($from_dba, $to_dba, $mlss_id) = @_;

  my ($gab_mlss_id) = @{$from_dba->get_MetaContainer->list_value_by_key("gerp_$mlss_id")};
  if (!$gab_mlss_id) {
    print " ** ERROR **  Needs a <gerp_$mlss_id> entry in the meta table!\n";
    exit(1);
  }
  exit(1) if !check_table("method_link_species_set", $from_dba, $to_dba, undef,
      "method_link_species_set_id = $gab_mlss_id");

  ## Check min and max of the relevant internal IDs in the FROM database
  my $sth = $from_dba->dbc->prepare("SELECT
        MIN(cs.genomic_align_block_id), MAX(cs.genomic_align_block_id)
      FROM genomic_align_block gab
        LEFT JOIN conservation_score cs using (genomic_align_block_id)
      WHERE
        gab.method_link_species_set_id = ?");

  $sth->execute($gab_mlss_id);
  my ($min_cs, $max_cs) = $sth->fetchrow_array();
  $sth->finish();

  my $lower_limit = $gab_mlss_id * 10**10;
  my $upper_limit = ($gab_mlss_id + 1) * 10**10;
  my $fix;
  if ($max_cs < 10**10) {
    ## Need to add $method_link_species_set_id * 10^10 to the internal_ids
    $fix = $lower_limit;
  } elsif ($max_cs and $min_cs >= $lower_limit) {
    ## Internal IDs are OK.
    $fix = 0;
  } else {
    print " ** ERROR **  Internal IDs are funny. Case not implemented yet!\n";
  }

  my $step = 1000;
  ## Check availability of the internal IDs in the TO database
  $sth = $to_dba->dbc->prepare("SELECT count(*)
      FROM conservation_score
      WHERE genomic_align_block_id >= $lower_limit
          AND genomic_align_block_id < $upper_limit");
  $sth->execute();
  my ($count) = $sth->fetchrow_array();
  if ($count) {
    print " ** ERROR **  There are $count entries in the release database (TO) in the \n",
      " ** ERROR **  conservation_score table with IDs within the range defined by the\n",
      " ** ERROR **  convention!\n";
    exit(1);
  }

  copy_data($from_dba, $to_dba,
      "meta",
      undef, undef, undef,
      "SELECT NULL, species_id, meta_key, meta_value".
        " FROM meta ".
        " WHERE meta_key = \"gerp_$mlss_id\"");

  # Most of the times, you want to copy all the data. Check if this is the case as it will be much faster!
  $sth = $from_dba->dbc->prepare("SELECT count(*)
      FROM conservation_score LEFT JOIN genomic_align_block
      USING (genomic_align_block_id)
      WHERE method_link_species_set_id != $gab_mlss_id limit 1");
  $sth->execute();
  ($count) = $sth->fetchrow_array();

  if ($count) {
    ## Other scores are in the from database.
    print " ** WARNING **\n";
    print " ** WARNING ** Copying only part of the data in the conservation_score table\n";
    print " ** WARNING ** This process might be very slow.\n";
    print " ** WARNING **\n";
    copy_data($from_dba, $to_dba,
        "conservation_score",
         "genomic_align_block_id", $min_cs, $max_cs,
        "SELECT cs.genomic_align_block_id+$fix, window_size, position, expected_score, diff_score".
          " FROM genomic_align_block gab".
          " LEFT JOIN conservation_score cs using (genomic_align_block_id)".
          " WHERE cs.genomic_align_block_id IS NOT NULL AND gab.method_link_species_set_id = $gab_mlss_id");
  } elsif ($fix) {
    ## These are the only scores but need to fix them.
    copy_data($from_dba, $to_dba,
        "conservation_score",
        "genomic_align_block_id", $min_cs, $max_cs,
        "SELECT cs.genomic_align_block_id+$fix, window_size, position, expected_score, diff_score".
          " FROM conservation_score cs" . 
	  " WHERE genomic_align_block_id >= $min_cs AND genomic_align_block_id <= $max_cs",
	 $step);
  } else {
      ## These are the only scores and need no fixing. Copy all as they are
      copy_data($from_dba, $to_dba, "conservation_score");
  }
}

=head2 copy_constrained_elements

  Arg[1]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $from_dba
  Arg[2]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $to_dba
  Arg[3]      : Bio::EnsEMBL::Compara::MethodLinkSpeciesSet $this_mlss

  Description : copies ConstrainedElements for this MethodLinkSpeciesSet.
  Returns     :
  Exceptions  : throw if argument test fails

=cut

sub copy_constrained_elements {
  my ($from_dba, $to_dba, $mlss_id) = @_;

  exit(1) if !check_table("method_link_species_set", $from_dba, $to_dba, undef,
      "method_link_species_set_id = $mlss_id");

  my $lower_limit = $mlss_id * 10**10;
  my $upper_limit = ($mlss_id + 1) * 10**10;

  ## Check min and max of the relevant internal IDs in the FROM database
  my $sql = "SELECT MIN(ce.constrained_element_id), MAX(ce.constrained_element_id) FROM constrained_element ce WHERE "
        . ($trust_ce
            ? " ce.constrained_element_id BETWEEN $lower_limit AND $upper_limit "
            : " ce.method_link_species_set_id = '$mlss_id'"
        );

  my $sth = $from_dba->dbc->prepare( $sql );

  $sth->execute();
  my ($min_ce, $max_ce) = $sth->fetchrow_array();
  $sth->finish();

  my $fix;
  my $step = 10000;

  if ($max_ce < 10**10) {
    ## Need to add $method_link_species_set_id * 10^10 to the internal_ids
    $fix = $lower_limit;
  } elsif ($max_ce and $min_ce >= $lower_limit) {
    ## Internal IDs are OK.
    $fix = 0;
  } else {
    print " ** ERROR **  Internal IDs are funny. Case not implemented yet!\n";
  }

  ## Check availability of the internal IDs in the TO database
  $sth = $to_dba->dbc->prepare("SELECT count(*)
      FROM constrained_element
      WHERE constrained_element_id >= $lower_limit
          AND constrained_element_id < $upper_limit");
  $sth->execute();
  my ($count) = $sth->fetchrow_array();
  if ($count) {
    print " ** ERROR **  There are $count entries in the release database (TO) in the \n",
      " ** ERROR **  constrained_element table with IDs within the range defined by the\n",
      " ** ERROR **  convention!\n";
    exit(1);
  }

  copy_data($from_dba, $to_dba,
      "meta",
      undef, undef, undef,
      "SELECT NULL, species_id, meta_key, meta_value".
        " FROM meta ".
        " WHERE meta_key = \"max_align_$mlss_id\"");

  # Most of the times, you want to copy all the data. Check if this is the case as it will be much faster!
  $sth = $from_dba->dbc->prepare("SELECT count(*)
      FROM constrained_element
      WHERE method_link_species_set_id != $mlss_id limit 1");
  $sth->execute();
  ($count) = $sth->fetchrow_array();
  if ($count) {
    ## Other constrained elements are in the from database.
    print " ** WARNING **\n";
    print " ** WARNING ** Copying only part of the data in the conservation_score table\n";
    print " ** WARNING ** This process might be very slow.\n";
    print " ** WARNING **\n";
    copy_data($from_dba, $to_dba,
        "constrained_element",
        "SELECT constrained_element_id+$fix, dnafrag_id, dnafrag_start, dnafrag_end, dnafrag_strand,
	method_link_species_set_id, p_value, taxonomic_level, score".
        " FROM constrained_element".
        " WHERE method_link_species_set_id = $mlss_id");
  } else {
    ## These is only one set of constrained elements. Copy all of them
      copy_data($from_dba, $to_dba,
		"constrained_element",
		"constrained_element_id",
		$min_ce, $max_ce,
		"SELECT constrained_element_id+$fix, dnafrag_id, dnafrag_start, dnafrag_end, dnafrag_strand,
	method_link_species_set_id, p_value, taxonomic_level, score".
		" FROM constrained_element ".
		" WHERE method_link_species_set_id = $mlss_id",
		$step);
  }
}

=head2 copy_data

  Arg[1]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $from_dba
  Arg[2]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $to_dba
  Arg[3]      : Bio::EnsEMBL::Compara::MethodLinkSpeciesSet $this_mlss
  Arg[4]      : string $table
  Arg[5]      : string $sql_query

  Description : copy data in this table using this SQL query.
  Returns     :
  Exceptions  : throw if argument test fails

=cut

sub copy_data {
  my ($from_dba, $to_dba, $table_name, $index_name, $min_id, $max_id, $query, $step) = @_;

  print "Copying data in table $table_name\n";

  my $sth = $from_dba->dbc->db_handle->column_info($from_dba->dbc->dbname, undef, $table_name, '%');
  $sth->execute;
  my $all_rows = $sth->fetchall_arrayref;
  my $binary_mode = 0;
  foreach my $this_col (@$all_rows) {
    if (($this_col->[5] eq "BINARY") or ($this_col->[5] eq "VARBINARY") or
        ($this_col->[5] eq "BLOB") or ($this_col->[5] eq "BIT")) {
      $binary_mode = 1;
      last;
    }
  }

  #speed up writing of data by disabling keys, write the data, then enable 
  #but takes far too long to ENABLE again
  if (!$merge) {
      $to_dba->dbc->do("ALTER TABLE `$table_name` DISABLE KEYS");
  }
  if ($binary_mode) {
    copy_data_in_binary_mode($from_dba, $to_dba, $table_name, $index_name, $min_id, $max_id, $query, $step);
  } else {
    copy_data_in_text_mode($from_dba, $to_dba, $table_name, $index_name, $min_id, $max_id, $query, $step);
  }
  if (!$merge) {
      $to_dba->dbc->do("ALTER TABLE `$table_name` ENABLE KEYS");
  }
}


=head2 copy_data_in_text_mode

  Arg[1]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $from_dba
  Arg[2]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $to_dba
  Arg[3]      : Bio::EnsEMBL::Compara::MethodLinkSpeciesSet $this_mlss
  Arg[4]      : string $table
  Arg[5]      : string $sql_query

  Description : copy data in this table using this SQL query.
  Returns     :
  Exceptions  : throw if argument test fails

=cut

sub copy_data_in_text_mode {
  my ($from_dba, $to_dba, $table_name, $index_name, $min_id, $max_id,$query, $step) = @_;
   print "start copy_data_in_text_mode\n";

  my $user = $to_dba->dbc->username;
  my $pass = $to_dba->dbc->password;
  my $host = $to_dba->dbc->host;
  my $port = $to_dba->dbc->port;
  my $dbname = $to_dba->dbc->dbname;
  my $use_limit = 0;
  my $start = $min_id;

  #If not using BETWEEN, revert back to LIMIT
  if (!defined $index_name && !defined $min_id && !defined $max_id) {
      $use_limit = 1;
      $start = 0;
  }

  #constrained elements need smaller step than default
  if (!defined $step) {
      $step = 100000;
  }
  while (1) {
    my $start_time = time();
    my $end = $start + $step - 1;
    my $sth;
    #print "start $start end $end\n";
    if (!$use_limit) {
	$sth = $from_dba->dbc->prepare($query." AND $index_name BETWEEN $start AND $end");
    } else {
	$sth = $from_dba->dbc->prepare($query." LIMIT $start, $step");
    }
    $start += $step;
    $sth->execute();
    my $all_rows = $sth->fetchall_arrayref;
    $sth->finish;
    ## EXIT CONDITION
    return if (!@$all_rows);
    my $time=time(); 
    my $filename = "/tmp/$table_name.copy_data.$$.$time.txt";
    open(TEMP, ">$filename") or die "could not open the file '$filename' for writing";
    foreach my $this_row (@$all_rows) {
      print TEMP join("\t", map {defined($_)?$_:'\N'} @$this_row), "\n";
    }
    close(TEMP);
    #print "time " . ($start-$min_id) . " " . (time - $start_time) . "\n";

    system("mysqlimport -h$host -P$port -u$user ".($pass ? "-p$pass" : '')." -L -l -i $dbname $filename");

    unlink("$filename");
    #print "total time " . ($start-$min_id) . " " . (time - $start_time) . "\n";
  }
}

=head2 copy_data_in_binary_mode

  Arg[1]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $from_dba
  Arg[2]      : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor $to_dba
  Arg[3]      : Bio::EnsEMBL::Compara::MethodLinkSpeciesSet $this_mlss
  Arg[4]      : string $table
  Arg[5]      : string $sql_query

  Description : copy data in this table using this SQL query.
  Returns     :
  Exceptions  : throw if argument test fails

=cut

sub copy_data_in_binary_mode {
  my ($from_dba, $to_dba, $table_name, $index_name, $min_id, $max_id, $query, $step) = @_;

  my $from_user = $from_dba->dbc->username;
  my $from_pass = $from_dba->dbc->password;
  my $from_host = $from_dba->dbc->host;
  my $from_port = $from_dba->dbc->port;
  my $from_dbname = $from_dba->dbc->dbname;

  my $to_user = $to_dba->dbc->username;
  my $to_pass = $to_dba->dbc->password;
  my $to_host = $to_dba->dbc->host;
  my $to_port = $to_dba->dbc->port;
  my $to_dbname = $to_dba->dbc->dbname;

  my $use_limit = 0;
  my $start = $min_id;
  my $direct_copy = 0;

  #all the data in the table needs to be copied and does not need fixing
  if (!defined $query) {
    my $start_time  = time();

    system("mysqldump -h$from_host -P$from_port -u$from_user ".($from_pass ? "-p$from_pass" : '')." --insert-ignore -t $from_dbname $table_name ".
           "| mysql   -h$to_host   -P$to_port   -u$to_user   ".($to_pass ? "-p$to_pass" : '')." $to_dbname");

    #print "time " . ($start-$min_id) . " " . (time - $start_time) . "\n";

    return;
  }

  print " ** WARNING ** Copying table $table_name in binary mode, this requires write access.\n";
  print " ** WARNING ** The original table will be temporarily renamed as original_$table_name.\n";
  print " ** WARNING ** An auxiliary table named temp_$table_name will also be created.\n";
  print " ** WARNING ** You may have to undo this manually if the process crashes.\n\n";
 
  #If not using BETWEEN, revert back to LIMIT
  if (!defined $index_name && !defined $min_id && !defined $max_id) {
      $use_limit = 1;
      $start = 0;
  }
  #my $start = 0;
  if (!defined $step) {
      $step = 1000000;
  }
  while (1) {
    my $start_time  = time();
    my $end = $start + $step - 1;
    #print "start $start end $end\n";

    ## Copy data into a aux. table
    my $sth;
    if (!$use_limit) {
	$sth = $from_dba->dbc->prepare("CREATE TABLE temp_$table_name $query AND $index_name BETWEEN $start AND $end");
    } else {
	$sth = $from_dba->dbc->prepare("CREATE TABLE temp_$table_name $query LIMIT $start, $step");
    }
    $sth->execute();

    $start += $step;
    my $count = $from_dba->dbc->db_handle->selectrow_array("SELECT count(*) FROM temp_$table_name");

    ## EXIT CONDITION
    if (!$count) {
      $from_dba->dbc->db_handle->do("DROP TABLE temp_$table_name");
      return;
    }

    ## Change table names (mysqldump will keep the table name, hence we need to do this)
    $from_dba->dbc->db_handle->do("ALTER TABLE $table_name RENAME original_$table_name");
    $from_dba->dbc->db_handle->do("ALTER TABLE temp_$table_name RENAME $table_name");

    ## mysqldump data

    system("mysqldump -h$from_host -P$from_port -u$from_user ".($from_pass ? "-p$from_pass" : '')." --insert-ignore -t $from_dbname $table_name ".
           "| mysql   -h$to_host   -P$to_port   -u$to_user   ".($to_pass ? "-p$to_pass" : '')." $to_dbname");

    #print "time " . ($start-$min_id) . " " . (time - $start_time) . "\n";

    ## Undo table names change
    $from_dba->dbc->db_handle->do("DROP TABLE $table_name");
    $from_dba->dbc->db_handle->do("ALTER TABLE original_$table_name RENAME $table_name");

     #print "total time " . ($start-$min_id) . " " . (time - $start_time) . "\n";
  }
}

#fix the genomic_align table
sub fix_genomic_align_table {
    my ($from_dba, $to_dba, $mlss_id, $temp_genomic_align) = @_;

    print "\n ** WARNING ** Fixing the dnafrag_ids in the genomic_align table requires write access.\n";
    print " ** WARNING ** Two temporary tables are created, temp_dnafrag and temp_genomic_align. The original tables are not altered.\n\n";

    #create new dnafrag table in FROM database
    $from_dba->dbc->db_handle->do("CREATE TABLE temp_dnafrag LIKE dnafrag");

    #copy over only those dnafrags for the genome_db_ids in the mlss.
    my $query = "SELECT dnafrag.* FROM method_link_species_set LEFT JOIN species_set USING (species_set_id) LEFT JOIN dnafrag USING (genome_db_id) WHERE method_link_species_set_id=$mlss_id";
    copy_data_in_text_mode($to_dba, $from_dba, "temp_dnafrag", undef, undef, undef, $query);

    #check that don't have dnafrags in the FROM database that aren't in the
    #TO database - need to exit if there are and reassess the situation!
    my $sth = $from_dba->dbc->prepare("SELECT dnafrag.* FROM method_link_species_set LEFT JOIN species_set USING (species_set_id) LEFT JOIN dnafrag USING (genome_db_id) LEFT JOIN temp_dnafrag USING (genome_db_id, name, length, coord_system_name) WHERE method_link_species_set_id=$mlss_id AND temp_dnafrag.genome_db_id IS NULL;");
    $sth->execute();
    my $rows = $sth->fetchall_arrayref();
    if (@$rows) {
	print "\n** ERROR ** The following dnafrags are present in the production (FROM) dnafrag table and are not present in the release (TO) dnafrag table\n"; 
	foreach my $row (@$rows) {
	    print "@$row\n";
	}
	$from_dba->dbc->db_handle->do("DROP TABLE temp_dnafrag");
	exit(1);
    }
    
    #copy genomic_align table into a temporary table
    $from_dba->dbc->db_handle->do("CREATE TABLE $temp_genomic_align LIKE genomic_align");
      
    #fill the table
    #doing this in 2 steps means we don't have to make assumptions as to the column names in the genomic_align table
    $sth = $from_dba->dbc->prepare("INSERT INTO $temp_genomic_align SELECT * FROM genomic_align WHERE method_link_species_set_id=$mlss_id");
    $sth->execute();
    
    #update the table 
    $sth = $from_dba->dbc->prepare("UPDATE $temp_genomic_align ga, dnafrag df, temp_dnafrag df_temp SET ga.dnafrag_id=df_temp.dnafrag_id WHERE ga.dnafrag_id=df.dnafrag_id AND df.genome_db_id=df_temp.genome_db_id AND df.name=df_temp.name AND df.coord_system_name=df_temp.coord_system_name AND ga.method_link_species_set_id=$mlss_id");      
    $sth->execute();

    #delete the temporary dnafrag table
    $from_dba->dbc->db_handle->do("DROP TABLE temp_dnafrag");
}


