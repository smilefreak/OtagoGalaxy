#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=pod 

=head1 NAME

Bio::EnsEMBL::Compara::RunnableDB::ncRNAtrees::NCOrthoTree

=cut

=head1 SYNOPSIS

my $db    = Bio::EnsEMBL::Compara::DBAdaptor->new($locator);
my $otree = Bio::EnsEMBL::Compara::RunnableDB::ncRNAtrees::NCOrthoTree->new ( 
                                                    -db      => $db,
                                                    -input_id   => $input_id,
                                                    -analysis   => $analysis );
$otree->fetch_input(); #reads from DB
$otree->run();
$otree->output();
$otree->write_output(); #writes to DB

=cut

=head1 DESCRIPTION

This Analysis/RunnableDB is designed to take NCTree as input

This must already have a rooted tree with duplication/sepeciation tags
on the nodes.

It analyzes that tree structure to pick Orthologues and Paralogs for
each genepair.

input_id/parameters format eg: "{'nc_tree_id'=>1234}"
    nc_tree_id : use 'id' to fetch a cluster from the NCTree

=cut

=head1 CONTACT

  Contact Albert Vilella on module implementation: avilella@ebi.ac.uk
  Contact Ewan Birney on EnsEMBL in general: birney@sanger.ac.uk

=cut

=head1 APPENDIX

The rest of the documentation details each of the object methods. 
Internal methods are usually preceded with a _

=cut

package Bio::EnsEMBL::Compara::RunnableDB::ncRNAtrees::NCOrthoTree;

use strict;
use IO::File;
use File::Basename;
use Time::HiRes qw(time gettimeofday tv_interval);
use Scalar::Util qw(looks_like_number);

use Bio::SimpleAlign;
use Bio::AlignIO;

use Bio::EnsEMBL::Compara::Member;
use Bio::EnsEMBL::Compara::Graph::Link;
use Bio::EnsEMBL::Compara::Graph::Node;
use Bio::EnsEMBL::Compara::Graph::NewickParser;
use Bio::EnsEMBL::Compara::MethodLinkSpeciesSet;
use Bio::EnsEMBL::Compara::Homology;
use Bio::EnsEMBL::Hive::Utils 'stringify';  # import 'stringify()'

use base ('Bio::EnsEMBL::Compara::RunnableDB::BaseRunnable');


=head2 fetch_input

    Title   :   fetch_input
    Usage   :   $self->fetch_input
    Function:   Fetches input data for repeatmasker from the database
    Returns :   none
    Args    :   none

=cut


sub fetch_input {
  my( $self) = @_;

  $self->param('tree_scale', 1);
  $self->param('store_homologies', 1);
  $self->param('no_between', 0.25);

  $self->throw("No input_id") unless defined($self->input_id);

  $self->print_params if($self->debug);

  my $starttime = time();
  $self->param('treeDBA', $self->compara_dba->get_NCTreeAdaptor);
  $self->param('homologyDBA', $self->compara_dba->get_HomologyAdaptor);
  $self->param('nc_tree',  $self->param('treeDBA')->fetch_tree_at_node_id($self->param('nc_tree_id')) );

  if($self->debug) {
    $self->param('nc_tree')->print_tree($self->param('tree_scale'));
    printf("time to fetch tree : %1.3f secs\n" , time()-$starttime);
  }
  unless($self->param('nc_tree')) {
    $self->throw("undefined NCTree as input\n");
  }
  $self->delete_old_homologies;
  $self->delete_old_ncorthotree_tags;
  $self->load_species_tree;

  return 1;
}


=head2 run

    Title   :   run
    Usage   :   $self->run
    Function:   runs NCOrthoTree
    Returns :   none
    Args    :   none

=cut


sub run
{
  my $self = shift;
  $self->run_analysis;
}


=head2 write_output

    Title   :   write_output
    Usage   :   $self->write_output

    Function: parse clustalw output and update homology and
              homology_member tables
    Returns : none 
    Args    : none 

=cut

sub write_output {
  my $self = shift;
  $self->store_homologies;
}


sub DESTROY {
  my $self = shift;

  if($self->param('nc_tree')) {
    printf("NCOrthoTree::DESTROY  releasing nc_tree\n") if($self->debug);
    $self->param('nc_tree')->release_tree;
    $self->param('nc_tree', undef);
  }
  if($self->param('taxon_tree')) {
    printf("NCOrthoTree::DESTROY  releasing taxon_tree\n") if($self->debug);
    $self->param('taxon_tree')->release_tree;
    $self->param('taxon_tree', undef);
  }

  $self->SUPER::DESTROY if $self->can("SUPER::DESTROY");
}


##########################################
#
# internal methods
#
##########################################


sub print_params {
  my $self = shift;

  print("params:\n");
  printf("  tree_id   : %d\n", $self->param('nc_tree_id'));
}


sub run_analysis {
  my $self = shift;

  my $starttime = time()*1000;
  my $tmp_time = time();
  my $tree = $self->param('nc_tree');

  print "Getting all leaves\n";
  my @all_nc_leaves = @{$tree->get_all_leaves};
  my $tree_node_id = $tree->node_id;

  #precalculate the ancestor species_hash (caches into the metadata of
  #nodes) also augments the Duplication tagging
  printf("Calculating ancestor species hash\n") if ($self->debug);
  $self->get_ancestor_species_hash($tree);

  if($self->debug) {
    $self->param('nc_tree')->print_tree($self->param('tree_scale'));
    printf("%d ncs in tree\n", scalar(@all_nc_leaves));
  }

  #compare every gene in the tree with every other each gene/gene
  #pairing is a potential ortholog/paralog and thus we need to analyze
  #every possibility
  #Accomplish by creating a fully connected graph between all the
  #genes under the tree (hybrid graph structure) and then analyze each
  #gene/gene link
  $tmp_time = time();
  printf("build fully linked graph\n") if($self->debug);
  my @genepairlinks;
  my $graphcount = 0;
  while (my $nc1 = shift @all_nc_leaves) {
    foreach my $nc2 (@all_nc_leaves) {
      my $ancestor = $nc1->find_first_shared_ancestor($nc2);
      # Line below will is a speed-up of the find_first_shared_ancestor, but relies on root_id/clusterset_id schema
      # my $ancestor = $self->param('treeDBA')->fetch_first_shared_ancestor_indexed($nc1,$nc2);
      my $taxon_level = $self->get_ancestor_taxon_level($ancestor);
      my $distance = $nc1->distance_to_ancestor($ancestor) +
                     $nc2->distance_to_ancestor($ancestor);
      my $genepairlink = new Bio::EnsEMBL::Compara::Graph::Link
        (
         $nc1, $nc2, $distance
        );
      $genepairlink->add_tag("hops", 0);
      $genepairlink->add_tag("ancestor", $ancestor);
      $genepairlink->add_tag("taxon_name", $taxon_level->name);
      $genepairlink->add_tag("tree_node_id", $tree_node_id);
      push @genepairlinks, $genepairlink;
    }
    print STDERR "build graph $graphcount\n" if ($graphcount++ % 10 == 0);
  }
  printf("%1.3f secs build links and features\n", time()-$tmp_time) 
    if($self->debug>1);

  $self->param('nc_tree')->print_tree($self->param('tree_scale')) 
    if($self->debug);

  #sort the gene/gene links by distance
  #   makes debug display easier to read, not required by algorithm
  $tmp_time = time();
  printf("sort links\n") if($self->debug);
  my @sorted_genepairlinks = 
    sort {$a->distance_between <=> $b->distance_between} @genepairlinks;
  printf("%1.3f secs to sort links\n", time()-$tmp_time) if($self->debug > 1);

  #analyze every gene pair (genepairlink) to get its classification
  printf("analyze links\n") if($self->debug);
  printf("%d links\n", scalar(@genepairlinks)) if ($self->debug);
  $tmp_time = time();
  $self->param('old_homology_count', 0);
  $self->param('ncorthotree_homology_counts', {});
  foreach my $genepairlink (@sorted_genepairlinks) {
    $self->analyze_genepairlink($genepairlink);
  }
  printf("%1.3f secs to analyze genepair links\n", time()-$tmp_time) 
    if($self->debug > 1);
  
  #display summary stats of analysis 
  my $runtime = time()*1000-$starttime;  
  $self->param('nc_tree')->store_tag('NCOrthoTree_runtime_msec', $runtime) 
    unless ($self->param('_readonly'));
  if($self->debug) {
    printf("%d ncs in tree\n", scalar(@{$tree->get_all_leaves}));
    printf("%d pairings\n", scalar(@genepairlinks));
    printf("%d old homologies\n", $self->param('old_homology_count'));
    printf("ncorthotree homologies\n");
    foreach my $type (keys(%{$self->param('ncorthotree_homology_counts')})) {
      printf ( "  %13s : %d\n", $type, $self->param('ncorthotree_homology_counts')->{$type});
    }
  }
  $self->param('homology_links', \@sorted_genepairlinks);

  return undef;
}


sub analyze_genepairlink
{
  my $self = shift;
  my $genepairlink = shift;

  my ($nc1, $nc2) = $genepairlink->get_nodes;

  #run feature detectors: precalcs and caches into metadata
  $self->genepairlink_check_dups($genepairlink);
  $self->genepairlink_fetch_homology($genepairlink) if($self->debug);

  #do classification analysis : as filter stack
  if($self->inspecies_paralog_test($genepairlink)) { }
  elsif($self->direct_ortholog_test($genepairlink)) { } 
  elsif($self->ancient_residual_test($genepairlink)) { } 
  elsif($self->one2many_ortholog_test($genepairlink)) { } 
  elsif($self->outspecies_test($genepairlink)) { }
  else {
    printf
      (
       "OOPS!!!! %s - %s\n",
       $nc1->gene_member->stable_id,
       $nc2->gene_member->stable_id
      );
  }

  $self->param('old_homology_count', $self->param('old_homology_count')+1 )
    if($genepairlink->get_tagvalue('old_homology'));

  my $type = $genepairlink->get_tagvalue('ncorthotree_type');
  if($type) {
    if(!defined($self->param('ncorthotree_homology_counts')->{$type})) {
      $self->param('ncorthotree_homology_counts')->{$type} = 1;
    } else {
      $self->param('ncorthotree_homology_counts')->{$type}++;
    }
  }

  #display results
  $self->display_link_analysis($genepairlink) if($self->debug >1);

  return undef;
}


sub display_link_analysis
{
  my $self = shift;
  my $genepairlink = shift;

  #display raw feature analysis
  my ($nc1, $nc2) = $genepairlink->get_nodes;
  my $ancestor = $genepairlink->get_tagvalue('ancestor');
  printf("%21s(%7d) - %21s(%7d) : %10.3f dist : %3d hops : ", 
    $nc1->gene_member->stable_id, $nc1->gene_member->member_id,
    $nc2->gene_member->stable_id, $nc2->gene_member->member_id,
    $genepairlink->distance_between, $genepairlink->get_tagvalue('hops'));

  if($genepairlink->get_tagvalue('has_dups')) { printf("%5s ", 'DUP');
  } else { printf("%5s ", ""); }

  my $homology = $genepairlink->get_tagvalue('old_homology');
  if($homology) { printf("%5s ", $homology->description);
  } else { printf("%5s ", ""); }

  print("ancestor:(");
  my $dup_value = $ancestor->get_tagvalue("Duplication");
#  my $sis_value = $ancestor->get_tagvalue("species_intersection_score");
  my $sis_value = $ancestor->get_tagvalue("duplication_confidence_score");
  if($dup_value eq '1' || $dup_value eq '2'){
    if ($sis_value eq '0') {
      print("DD  ");
    } else {
      print("DUP ");
    }
  }
  else{print"    ";}
  printf("%9s)", $ancestor->node_id);

  my $taxon_level = $ancestor->get_tagvalue('taxon_level');
  printf(" %s %s %s\n", 
         $genepairlink->get_tagvalue('ncorthotree_type'), 
         $genepairlink->get_tagvalue('ncorthotree_subtype'),
         $taxon_level->name
        );

  return undef;
}

sub load_species_tree {
  my $self = shift @_;

  my $starttime = time();

  # FIXME -- this species_tree_string entry in nc_tree_tag is to
  # avoid using lustre filesystem on cluster nodes but right now needs
  # a bit of a cleanup because it's shared with NJTREE_PHYML -- we
  # should have a single method for both, potentially in NestedSet

  # Defining a species_tree: Option 1 is species_tree_string in
  # nc_tree_tag, which then doesn't require tracking files
  # around.  Option 2 is species_tree_file as defined in the config
  # file, which should still work for compatibility
  my $sql1 = "select value from nc_tree_tag where tag='species_tree_string'";
  my $sth1 = $self->dbc->prepare($sql1);
  $sth1->execute;
  my $species_tree_string = $sth1->fetchrow_hashref;
  $sth1->finish;
  my $eval_species_tree;
  eval {
    $eval_species_tree = Bio::EnsEMBL::Compara::Graph::NewickParser::parse_newick_into_tree($species_tree_string->{value});
    my @leaves = @{$eval_species_tree->get_all_leaves};
  };
  if($@) {
    unless(-e $self->param('species_tree_file')) {
      $self->throw("can't find species_tree\n");
    }
  } else {
    $self->param('species_tree_string', $species_tree_string->{value});
    my $spfilename = $self->worker_temp_directory . "spec_tax.nh";
    open SPECIESTREE, ">$spfilename" or die "$!";
    print SPECIESTREE $self->param('species_tree_string');
    close SPECIESTREE;
    $self->param('species_tree_file', $spfilename);
  }

  my $tree = $self->param('species_tree_file')
    ? $self->load_species_tree_from_file
      : $self->load_species_tree_from_tax
	;
  $self->param('taxon_tree', $tree);

  if($self->debug) {
    $tree->print_tree(1);
    printf("%1.3f secs for load species tree\n", time()-$starttime);
  }
}

sub load_species_tree_from_tax
{
  my $self = shift;

  printf("load_species_tree_from_tax\n") if($self->debug);
  my $starttime = time();
  my $taxonDBA = $self->compara_dba->get_NCBITaxonAdaptor;

  my $gdb_list = $self->compara_dba->get_GenomeDBAdaptor->fetch_all;
  my $root=undef;
  foreach my $gdb (@$gdb_list) {
    next if ($gdb->name =~ /ancestral/);
    my $taxon = $taxonDBA->fetch_node_by_taxon_id($gdb->taxon_id);
    $taxon->no_autoload_children;
    # $taxon->add_tag("taxon_id") = $taxon->taxon_id; # homogenize with load_species_tree_from_file
    $taxon->{_tags}{taxon_id} = $taxon->taxon_id; # line above seems to fail somehow
    $root = $taxon->root unless($root);
    $root->merge_node_via_shared_ancestor($taxon);
  }
  $root = $root->minimize_tree;
  return $root;
}

sub load_species_tree_from_file {
  my $self = shift @_;

  my $taxonDBA = $self->compara_dba->get_NCBITaxonAdaptor;
  print "load_species_tree_from_file\n" if $self->debug;
  my $newick = $self->_slurp($self->param('species_tree_file'));
  my $tree = Bio::EnsEMBL::Compara::Graph::NewickParser::parse_newick_into_tree($newick);
  foreach my $node (@{$tree->all_nodes_in_graph}) {
    my ($id) = split('-',$node->name);
    $id =~ s/\*//; # internal nodes have asterisk
    if (looks_like_number($id)) {
      $node->node_id($id);
      my $ncbi_node = $taxonDBA->fetch_node_by_taxon_id($id);
      $node->name($ncbi_node->name) if (defined $ncbi_node);
    } else { # doesnt look like number
      $node->name($id);
    }
    $node->add_tag('taxon_id', $id);
  }
  return $tree;
}

sub _slurp {
  my ($self, $file_name) = @_;
  my $slurped;
  {
    local $/ = undef;
    open(my $fh, '<', $file_name);
    $slurped = <$fh>;
    close($fh);
  }
  return $slurped;
}

sub get_ancestor_species_hash
{
  my $self = shift;
  my $node = shift;

  my $species_hash = $node->get_tagvalue('species_hash');
  return $species_hash if($species_hash);

  $species_hash = {};
  my $duplication_hash = {};
  my $is_dup=0;

  if($node->isa('Bio::EnsEMBL::Compara::GeneTreeMember')) {
    my $node_genome_db_id = $node->genome_db_id;
    $species_hash->{$node_genome_db_id} = 1;
    $node->add_tag('species_hash', $species_hash);
    return $species_hash;
  }

  foreach my $child (@{$node->children}) {
    my $t_species_hash = $self->get_ancestor_species_hash($child);
    next unless(defined($t_species_hash)); #shouldn't happen
    foreach my $genome_db_id (keys(%$t_species_hash)) {
      unless(defined($species_hash->{$genome_db_id})) {
        $species_hash->{$genome_db_id} = $t_species_hash->{$genome_db_id};
      } else {
        #this species already existed in one of the other children
        #this means this species was duplicated at this point between
        #the species
        $is_dup=1;
        $duplication_hash->{$genome_db_id} = 1;
        $species_hash->{$genome_db_id} += $t_species_hash->{$genome_db_id};
      }
    }
  }
  
  #printf("\ncalc_ancestor_species_hash : %s\n", stringify($species_hash));
  #$node->print_tree(20);
  
  $node->add_tag("species_hash", $species_hash);
  if($is_dup && !($self->param('_treefam'))) {
    my $original_duplication_value = $node->get_tagvalue("Duplication");
    $original_duplication_value = 0 
      unless (defined $original_duplication_value && $original_duplication_value ne '');

    if ($original_duplication_value == 0) {
      # RAP did not predict a duplication here
      $node->add_tag("duplication_hash", $duplication_hash);
      $node->store_tag("Duplication", 1)  unless ($self->param('_readonly'));
      $node->store_tag("Duplication_alg", 'species_count') 
        unless ($self->param('_readonly'));

    } elsif ($original_duplication_value == 1) {
      my $dup_alg = $node->get_tagvalue("Duplication_alg");
      if (defined $dup_alg and $dup_alg ne 'species_count') {
        # RAP did predict a duplication here but not species_count
        $node->add_tag("duplication_hash", $duplication_hash);
        $node->store_tag("Duplication", 2) unless ($self->param('_readonly'));
        $node->store_tag("Duplication_alg", 'species_count') 
          unless ($self->param('_readonly'));
      }
    }
  }
  return $species_hash;
}


sub get_ancestor_taxon_level
{
  my $self = shift;
  my $ancestor = shift;

  my $taxon_level = $ancestor->get_tagvalue('taxon_level');
  return $taxon_level if($taxon_level);

  #printf("\ncalculate ancestor taxon level\n");
  my $taxon_tree = $self->param('taxon_tree');
  my $species_hash = $self->get_ancestor_species_hash($ancestor);

  foreach my $gdbID (keys(%$species_hash)) {
    my $gdb = 
      $self->compara_dba->get_GenomeDBAdaptor->fetch_by_dbID($gdbID);
    my $taxon = $taxon_tree->find_node_by_node_id($gdb->taxon_id);

    unless($taxon) {
      $self->throw("oops missing taxon " . $gdb->taxon_id ."\n");
    }

    if($taxon_level) {
      $taxon_level = $taxon_level->find_first_shared_ancestor($taxon);
    } else {
      $taxon_level = $taxon;
    }
  }
  my $taxon_id = $taxon_level->get_tagvalue("taxon_id");
  $ancestor->add_tag("taxon_level", $taxon_level);
  $ancestor->store_tag("taxon_id", $taxon_id) 
    unless ($self->param('_readonly'));
  $ancestor->store_tag("taxon_name", $taxon_level->name) 
    unless ($self->param('_readonly'));

  #$ancestor->print_tree($self->param('tree_scale'));
  #$taxon_level->print_tree(10);

  return $taxon_level;
}


sub duplication_confidence_score {
  my $self = shift;
  my $ancestor = shift;
  my $nc_tree_id = $self->param('nc_tree_id');

  # This assumes bifurcation!!! No multifurcations allowed
  my ($child_a, $child_b, $dummy) = @{$ancestor->children};
  $self->throw("tree $nc_tree_id is multifurcated in duplication_confidence_score\n") if (defined($dummy));
  my @child_a_gdbs = keys %{$self->get_ancestor_species_hash($child_a)};
  my @child_b_gdbs = keys %{$self->get_ancestor_species_hash($child_b)};
  my %seen = ();  my @gdb_a = grep { ! $seen{$_} ++ } @child_a_gdbs;
     %seen = ();  my @gdb_b = grep { ! $seen{$_} ++ } @child_b_gdbs;
  my @isect = my @diff = my @union = (); my %count;
  foreach my $e (@gdb_a, @gdb_b) { $count{$e}++ }
  foreach my $e (keys %count) {
    push(@union, $e); push @{ $count{$e} == 2 ? \@isect : \@diff }, $e; 
  }

  my $duplication_confidence_score = 0;
  my $scalar_isect = scalar(@isect);
  my $scalar_union = scalar(@union);
  $duplication_confidence_score = 
    (($scalar_isect)/$scalar_union) unless (0 == $scalar_isect);

  $ancestor->store_tag
    (
     "duplication_confidence_score",
     $duplication_confidence_score
    ) unless ($self->param('_readonly'));
}


sub genepairlink_fetch_homology
{
  my $self = shift;
  my $genepairlink = shift;

  my ($member1, $member2) = $genepairlink->get_nodes;

  my $sql = "select homology.homology_id from homology ".
            "join homology_member hm1 using(homology_id) ".
            "join homology_member hm2 using (homology_id) " .
            "where hm1.peptide_member_id=? and hm2.peptide_member_id=?";

  my $sth = $self->dbc->prepare($sql);
  $sth->execute($member1->member_id, $member2->member_id);
  my $ref = $sth->fetchrow_arrayref();
  return undef unless($ref);
  $sth->finish;
  my ($homology_id) = @$ref;
  return undef unless($homology_id);

  my $homology = 
    $self->compara_dba->get_HomologyAdaptor->fetch_by_dbID($homology_id);
  $genepairlink->add_tag("old_homology", $homology);

  return $homology;
}

sub delete_old_ncorthotree_tags
{
  my $self = shift;

  return undef unless ($self->input_job->retry_count > 0);

  print "deleting old ncorthotree tags\n" if ($self->debug);
  my @node_ids;

#   # Old method -- too slow
#   my $left_index  = $self->param('nc_tree')->left_index;
#   my $right_index = $self->param('nc_tree')->right_index;
#   my $tree_root_node_id = $self->param('nc_tree')->node_id;
#   # Include the root_id as well as the rest of the nodes within the tree
#   push @node_ids, $tree_root_node_id;
#   my $sql = "select ptn.node_id from nc_tree_node ptn where ptn.left_index>$left_index and ptn.right_index<$right_index";
#   my $sth = $self->dbc->prepare($sql);
#   $sth->execute;
#   while (my $aref = $sth->fetchrow_arrayref) {
#     my ($node_id) = @$aref;
#     push @node_ids, $node_id;
#   }

  foreach my $node ($self->param('nc_tree')->get_all_subnodes) {
    push @node_ids, $node->node_id;
  }

  my @list_ids;
  foreach my $id (@node_ids) {
    push @list_ids, $id;
    if (scalar @list_ids == 2000) {
      my $sql = "delete from nc_tree_tag where node_id in (".join(",",@list_ids).") and tag in ('duplication_confidence_score','taxon_id','taxon_name','NCOrthoTree_runtime_msec','NCOrthoTree_types_hashstr')";
      my $sth = $self->dbc->prepare($sql);
      $sth->execute;
      $sth->finish;
      @list_ids = ();
    }
  }

  if (scalar @list_ids) {
    my $sql = "delete from nc_tree_tag where node_id in (".join(",",@list_ids).") and tag in ('duplication_confidence_score','taxon_id','taxon_name','NCOrthoTree_runtime_msec','NCOrthoTree_types_hashstr')";
    my $sth = $self->dbc->prepare($sql);
    $sth->execute;
    $sth->finish;
    @list_ids = ();
  }

  return undef;
}

sub delete_old_homologies
{
  my $self = shift;

  return undef unless ($self->input_job->retry_count > 0);

  print "deleting old homologies\n" if ($self->debug);

  # New method all in one go -- requires key on tree_node_id
  my $delete_time = time();
  my $tree_node_id = $self->param('nc_tree')->node_id;
  my $sql1 = "delete h.*, hm.* from homology h, homology_member hm where h.homology_id=hm.homology_id and h.tree_node_id=$tree_node_id";
  my $sth1 = $self->dbc->prepare($sql1);
  $sth1->execute;
  $sth1->finish;
  printf("%1.3f secs build links and features\n", time()-$delete_time);

  $self->param('old_homologies_deleted', 1);
  return undef;
}

sub delete_old_homologies_old
{
  my $self = shift;
  my $genepairlink = shift;

  return undef unless ($self->input_job->retry_count > 0);

  my ($member1, $member2) = $genepairlink->get_nodes;

  my @homologies = @{$self->compara_dba->get_HomologyAdaptor->fetch_by_Member_Member_method_link_type
                       ($member1->gene_member, $member2->gene_member, 'ENSEMBL_ORTHOLOGUES')};
  push @homologies, @{$self->compara_dba->get_HomologyAdaptor->fetch_by_Member_Member_method_link_type
                        ($member1->gene_member, $member2->gene_member, 'ENSEMBL_PARALOGUES')};

  my $sql1 = "DELETE FROM homology WHERE homology_id=?";
  my $sth1 = $self->dbc->prepare($sql1);
  my $sql2 = "DELETE FROM homology_member WHERE homology_id=?";
  my $sth2 = $self->dbc->prepare($sql2);

  foreach my $homology (@homologies) {
    $sth1->execute($homology->dbID);
    $sth2->execute($homology->dbID);
  }

  $sth1->finish;
  $sth2->finish;

  return undef;
}

sub genepairlink_check_dups
{
  my $self = shift;
  my $genepairlink = shift;

  my ($pep1, $pep2) = $genepairlink->get_nodes;

  my $ancestor = $genepairlink->get_tagvalue('ancestor');
  my $has_dup=0;
  my %nodes_between;
  my $tnode = $pep1;
  do {
    $tnode = $tnode->parent;
    my $dup_value = $tnode->get_tagvalue("Duplication");
#    my $sis_value = $tnode->get_tagvalue("species_intersection_score");
    my $sis_value = $tnode->get_tagvalue("duplication_confidence_score");
    $dup_value = 0 unless (defined($dup_value) && $dup_value ne '');
    $sis_value = 0 unless (defined($sis_value) && $sis_value ne '');
    unless ($sis_value eq '0') {
      if($dup_value > 0) {
        $has_dup = 1;
      }
    }
    $nodes_between{$tnode->node_id} = $tnode;
  } while(!($tnode->equals($ancestor)));

  $tnode = $pep2;
  do {
    $tnode = $tnode->parent;
    my $dup_value = $tnode->get_tagvalue("Duplication");
#    my $sis_value = $tnode->get_tagvalue("species_intersection_score");
    my $sis_value = $tnode->get_tagvalue("duplication_confidence_score");
    $dup_value = 0 unless (defined($dup_value) && $dup_value ne '');
    $sis_value = 0 unless (defined($sis_value) && $sis_value ne '');
    $genepairlink->{duplication_confidence_score} = $sis_value;
    unless ($sis_value eq '0') {
      if($dup_value > 0) {
        $has_dup = 1;
      }
    }
    $nodes_between{$tnode->node_id} = $tnode;
  } while(!($tnode->equals($ancestor)));

  $genepairlink->add_tag("hops", scalar(keys(%nodes_between)));
  $genepairlink->add_tag("has_dups", $has_dup);
  return undef;
}


########################################################
#
# Classification analysis
#
########################################################


sub direct_ortholog_test
{
  my $self = shift;
  my $genepairlink = shift;

  #strictest ortholog test: 
  #  - genes are from different species
  #  - no ancestral duplication events
  #  - these genes are only copies of the ancestor for their species

  return undef if($genepairlink->get_tagvalue('has_dups'));

  my ($pep1, $pep2) = $genepairlink->get_nodes;
  return undef if($pep1->genome_db_id == $pep2->genome_db_id);

  my $ancestor = $genepairlink->get_tagvalue('ancestor');
  my $species_hash = $self->get_ancestor_species_hash($ancestor);

  #RAP seems to miss some duplication events so check the species 
  #counts for these two species to make sure they are the only
  #representatives of these species under the ancestor
  my $count1 = $species_hash->{$pep1->genome_db_id};
  my $count2 = $species_hash->{$pep2->genome_db_id};

  return undef if($count1>1);
  return undef if($count2>1);

  #passed all the tests -> it's a simple ortholog
#  $self->delete_old_homologies_old($genepairlink) unless ($self->param('_readonly'));
  $genepairlink->add_tag("ncorthotree_type", 'ortholog_one2one');
  my $taxon = $self->get_ancestor_taxon_level($ancestor);
  $genepairlink->add_tag("ncorthotree_subtype", $taxon->name);
  return 1;
}


sub inspecies_paralog_test
{
  my $self = shift;
  my $genepairlink = shift;

  #simplest paralog test: 
  #  - both genes are from the same species
  #  - and just label with taxonomic level

  my ($pep1, $pep2) = $genepairlink->get_nodes;
  return undef unless($pep1->genome_db_id == $pep2->genome_db_id);

  my $ancestor = $genepairlink->get_tagvalue('ancestor');
  my $taxon = $self->get_ancestor_taxon_level($ancestor);

  #my $species_hash = $self->get_ancestor_species_hash($ancestor);
  #foreach my $gdbID (keys(%$species_hash)) {
  #  return undef unless($gdbID == $pep1->genome_db_id);
  #}

  #passed all the tests -> it's an inspecies_paralog
#  $genepairlink->add_tag("ncorthotree_type", 'inspecies_paralog');
#  $self->delete_old_homologies_old($genepairlink) unless ($self->param('_readonly'));
  $genepairlink->add_tag("ncorthotree_type", 'within_species_paralog');
  $genepairlink->add_tag("ncorthotree_subtype", $taxon->name);
  # Duplication_confidence_score
  if ('' eq $ancestor->get_tagvalue("duplication_confidence_score")) {
    $self->duplication_confidence_score($ancestor);
    $genepairlink->{duplication_confidence_score} = $ancestor->get_tagvalue("duplication_confidence_score");
  }
  return 1;
}


sub ancient_residual_test
{
  my $self = shift;
  my $genepairlink = shift;

  #test 3: getting a bit more complex:
  #  - genes are from different species
  #  - there is evidence for duplication events elsewhere in the history
  #  - but these two genes are the only remaining representative of
  #    the ancestor

  my ($pep1, $pep2) = $genepairlink->get_nodes;
  return undef if($pep1->genome_db_id == $pep2->genome_db_id);

  my $ancestor = $genepairlink->get_tagvalue('ancestor');
  my $species_hash = $self->get_ancestor_species_hash($ancestor);

  #check these are the only representatives of the ancestor
  my $count1 = $species_hash->{$pep1->genome_db_id};
  my $count2 = $species_hash->{$pep2->genome_db_id};

  return undef if($count1>1);
  return undef if($count2>1);

  #passed all the tests -> it's a simple ortholog
  # print $ancestor->node_id, " ", $ancestor->name,"\n";

  # little hack to work around some weird treefam trees
  if ($self->param('_treefam')) {
    my $dup_value = $ancestor->get_tagvalue("Duplication");
    if ($dup_value eq '') {
      $dup_value = 0;
      $ancestor->add_tag("Duplication",0) ;
    }
  }

#  my $sis_value = $ancestor->get_tagvalue("species_intersection_score");
  my $sis_value = $ancestor->get_tagvalue("duplication_confidence_score");
  if($ancestor->get_tagvalue("Duplication") > 0 && $sis_value ne '0') {
#    $self->delete_old_homologies_old($genepairlink) unless ($self->param('_readonly'));
    $genepairlink->add_tag("ncorthotree_type", 'apparent_ortholog_one2one');
    my $taxon = $self->get_ancestor_taxon_level($ancestor);
    $genepairlink->add_tag("ncorthotree_subtype", $taxon->name);
    # Duplication_confidence_score
    if ('' eq $ancestor->get_tagvalue("duplication_confidence_score")) {
      $self->duplication_confidence_score($ancestor);
      $genepairlink->{duplication_confidence_score} = $ancestor->get_tagvalue("duplication_confidence_score");
    }
  } else {
#    $self->delete_old_homologies_old($genepairlink) unless ($self->param('_readonly'));
    $genepairlink->add_tag("ncorthotree_type", 'ortholog_one2one');
    my $taxon = $self->get_ancestor_taxon_level($ancestor);
    $genepairlink->add_tag("ncorthotree_subtype", $taxon->name);
  }
  return 1;
}


sub one2many_ortholog_test
{
  my $self = shift;
  my $genepairlink = shift;

  #test 4: getting a bit more complex yet again:
  #  - genes are from different species
  #  - but there is evidence for duplication events in the history
  #  - one of the genes is the only remaining representative of the
  #  ancestor in its species
  #  - but the other gene has multiple copies in it's species 
  #  (first level of orthogroup analysis)

  my ($pep1, $pep2) = $genepairlink->get_nodes;
  return undef if($pep1->genome_db_id == $pep2->genome_db_id);

  my $ancestor = $genepairlink->get_tagvalue('ancestor');
  my $species_hash = $self->get_ancestor_species_hash($ancestor);

  my $count1 = $species_hash->{$pep1->genome_db_id};
  my $count2 = $species_hash->{$pep2->genome_db_id};

  #one of the genes must be the only copy of the gene
  #and the other must appear more than once in the ancestry
  return undef unless 
    (
     ($count1==1 and $count2>1) or ($count1>1 and $count2==1)
    );

  my $dup_value = $ancestor->get_tagvalue("Duplication");
#  my $sis_value = $ancestor->get_tagvalue("species_intersection_score");
  my $sis_value = $ancestor->get_tagvalue("duplication_confidence_score");
  if($dup_value > 0 && $sis_value ne '0') {
    return undef;
  }

  #passed all the tests -> it's a one2many ortholog
#  $self->delete_old_homologies_old($genepairlink) unless ($self->param('_readonly'));
  $genepairlink->add_tag("ncorthotree_type", 'ortholog_one2many');
  my $taxon = $self->get_ancestor_taxon_level($ancestor);
  $genepairlink->add_tag("ncorthotree_subtype", $taxon->name);
  return 1;
}


sub outspecies_test
{
  my $self = shift;
  my $genepairlink = shift;

  #last test: left over pairs:
  #  - genes are from different species
  #  - if ancestor is 'DUP' -> paralog else 'ortholog'

  my ($pep1, $pep2) = $genepairlink->get_nodes;
  return undef if($pep1->genome_db_id == $pep2->genome_db_id);

  my $ancestor = $genepairlink->get_tagvalue('ancestor');
  my $taxon = $self->get_ancestor_taxon_level($ancestor);

  #ultra simple ortho/paralog classification
  my $dup_value = $ancestor->get_tagvalue("Duplication");
#  my $sis_value = $ancestor->get_tagvalue("species_intersection_score");
  my $sis_value = $ancestor->get_tagvalue("duplication_confidence_score");
  unless ($dup_value eq '') {
    if($dup_value > 0 && $sis_value ne '0') {
#      $self->delete_old_homologies_old($genepairlink) unless ($self->param('_readonly'));
      $genepairlink->add_tag("ncorthotree_type", 'possible_ortholog');
      $genepairlink->add_tag("ncorthotree_subtype", $taxon->name);
      # Duplication_confidence_score
      if ('' eq $ancestor->get_tagvalue("duplication_confidence_score")) {
        $self->duplication_confidence_score($ancestor);
       $genepairlink->{duplication_confidence_score} = $ancestor->get_tagvalue("duplication_confidence_score");
      }
    } else {
#      $self->delete_old_homologies_old($genepairlink) unless ($self->param('_readonly'));
      $genepairlink->add_tag("ncorthotree_type", 'ortholog_many2many');
      $genepairlink->add_tag("ncorthotree_subtype", $taxon->name);
    }
  }
  return 1;
}


########################################################
#
# NCTree input/output section
#
########################################################

sub store_homologies
{
  my $self = shift;
  my $a=1;
  my $hlinkscount = 0;
  foreach my $genepairlink (@{$self->param('homology_links')}) {
    $self->display_link_analysis($genepairlink) if($self->debug>2);
    my $type = $genepairlink->get_tagvalue("ncorthotree_type");
    my $dcs = $genepairlink->{duplication_confidence_score};

    next if ($type eq 'possible_ortholog' && $dcs > $self->param('no_between'));
    $self->store_gene_link_as_homology($genepairlink);
    print STDERR "homology links $hlinkscount\n" if ($hlinkscount++ % 500 == 0);
  }

  my $counts_str = stringify($self->param('ncorthotree_homology_counts'));
  printf("$counts_str\n");

  $self->check_homology_consistency;

  $self->param('nc_tree')->store_tag(
      'NCOrthoTree_types_hashstr', 
      stringify($self->param('ncorthotree_homology_counts'))) unless ($self->param('_readonly'));

  return undef;
}


sub store_gene_link_as_homology
{
  my $self = shift;
  my $genepairlink  = shift;

  my $type = $genepairlink->get_tagvalue('ncorthotree_type');
  return unless($type);
  my $subtype = $genepairlink->get_tagvalue('taxon_name');
  my $ancestor = $genepairlink->get_tagvalue('ancestor');
  my $tree_node_id = $genepairlink->get_tagvalue('tree_node_id');
  warn("Tag tree_node_id undefined\n") unless(defined($tree_node_id) && $tree_node_id ne '');

  my ($nc1, $nc2) = $genepairlink->get_nodes;

  #
  # create method_link_species_set
  #
  my $mlss = new Bio::EnsEMBL::Compara::MethodLinkSpeciesSet;
  $mlss->method_link_type("ENSEMBL_ORTHOLOGUES") 
    unless ($type eq 'possible_ortholog' || $type eq 'within_species_paralog');
  $mlss->method_link_type("ENSEMBL_PARALOGUES") if ($type eq 'possible_ortholog' || $type eq 'within_species_paralog');
  if ($nc1->genome_db->dbID == $nc2->genome_db->dbID) {
    $mlss->species_set([$nc1->genome_db]);
  } else {
    $mlss->species_set([$nc1->genome_db, $nc2->genome_db]);
  }
  $self->compara_dba->get_MethodLinkSpeciesSetAdaptor->store($mlss) unless ($self->param('_readonly'));

  # create an Homology object
  my $homology = new Bio::EnsEMBL::Compara::Homology;
  $homology->description($type);
  $homology->subtype($subtype);
  # $homology->node_id($ancestor->node_id);
  $homology->ancestor_node_id($ancestor->node_id);
  $homology->tree_node_id($tree_node_id);
  $homology->method_link_type($mlss->method_link_type);
  $homology->method_link_species_set($mlss);

  my $key = $mlss->dbID . "_" . $nc1->dbID;

      # manual vivification needed:
  unless($self->param('_homology_consistency')) {
        $self->param('_homology_consistency', {});
  }

  $self->param('_homology_consistency')->{$key}{$type} = 1;
  #$homology->dbID(-1);

  # NEED TO BUILD THE Attributes (ie homology_members)
  my ($cigar_line1, $perc_id1, $perc_pos1,
      $cigar_line2, $perc_id2, $perc_pos2) = 
        $self->generate_attribute_arguments($nc1, $nc2,$type);

  # QUERY member
  #
  my $attribute;
  $attribute = new Bio::EnsEMBL::Compara::Attribute;
  $attribute->peptide_member_id($nc1->dbID);
  $attribute->cigar_line($cigar_line1);
  $attribute->perc_cov(100);
  $attribute->perc_id(int($perc_id1));
  $attribute->perc_pos(int($perc_pos1));

  $homology->add_Member_Attribute([$nc1->gene_member, $attribute]);

  #
  # HIT member
  #
  $attribute = new Bio::EnsEMBL::Compara::Attribute;
  $attribute->peptide_member_id($nc2->dbID);
  $attribute->cigar_line($cigar_line2);
  $attribute->perc_cov(100);
  $attribute->perc_id(int($perc_id2));
  $attribute->perc_pos(int($perc_pos2));

  $homology->add_Member_Attribute([$nc2->gene_member, $attribute]);

  ## Check if it has already been stored, in which case we dont need to store again
  my $matching_homology = 0;
  if ($self->input_job->retry_count > 0 && !defined($self->param('old_homologies_deleted'))) {
    my $member_id1 = $nc1->gene_member->member_id;
    my $member_id2 = $nc2->gene_member->member_id;
    if ($member_id1 == $member_id2) {
      my $tree_id = $self->param('nc_tree')->node_id;
      my $pmember_id1 = $nc1->member_id; my $pstable_id1 = $nc1->stable_id;
      my $pmember_id2 = $nc2->member_id; my $pstable_id2 = $nc2->stable_id;
      $self->throw("$member_id1 ($pmember_id1 - $pstable_id1) and $member_id2 ($pmember_id2 - $pstable_id2) shouldn't be the same");
    }
    my $stored_homology = @{$self->param('homologyDBA')->fetch_by_Member_id_Member_id($member_id1,$member_id2)}[0];
    if (defined($stored_homology)) {
      $matching_homology = 1;
      $matching_homology = 0 if ($stored_homology->description ne $homology->description);
      $matching_homology = 0 if ($stored_homology->subtype ne $homology->subtype);
      $matching_homology = 0 if ($stored_homology->ancestor_node_id ne $homology->ancestor_node_id);
      $matching_homology = 0 if ($stored_homology->tree_node_id ne $homology->tree_node_id);
      $matching_homology = 0 if ($stored_homology->method_link_type ne $homology->method_link_type);
      $matching_homology = 0 if ($stored_homology->method_link_species_set->dbID ne $homology->method_link_species_set->dbID);
    }

    # Delete old one, then proceed to store new one
    if (defined($stored_homology) && (0 == $matching_homology)) {
      my $homology_id = $stored_homology->dbID;
      my $sql1 = "delete from homology where homology_id=$homology_id";
      my $sql2 = "delete from homology_member where homology_id=$homology_id";
      my $sth1 = $self->dbc->prepare($sql1);
      my $sth2 = $self->dbc->prepare($sql2);
      $sth1->execute;
      $sth2->execute;
      $sth1->finish;
      $sth2->finish;
    }
  }
  if($self->param('store_homologies') && 0 == $matching_homology) {
    $self->param('homologyDBA')->store($homology);
  }

  my $stable_id;
  if($nc1->taxon_id < $nc2->taxon_id) {
    $stable_id = $nc1->taxon_id . "_" . $nc2->taxon_id . "_";
  } else {
    $stable_id = $nc2->taxon_id . "_" . $nc1->taxon_id . "_";
  }
  $stable_id .= sprintf ("%011.0d",$homology->dbID) if($homology->dbID);
  $homology->stable_id($stable_id);
  #TODO: update the stable_id of the homology

#   if($self->debug) {
#     print("store: ");
#     $homology->print_homology;
#   }

  return undef;
}


sub check_homology_consistency {
  my $self = shift;

  if ($self->debug) {
    print "checking homology consistency\n";
    foreach my $mlss_member_id ( keys %{$self->param('_homology_consistency')} ) {
      my $count = scalar(keys %{$self->param('_homology_consistency')->{$mlss_member_id}});
      if ($count > 1) {
        my ($mlss, $member_id) = split("_",$mlss_member_id);
        print "mlss member_id : $mlss $member_id\n";
      }
    }
  }

  foreach my $mlss_member_id ( keys %{$self->param('_homology_consistency')} ) {
    my $count = scalar(keys %{$self->param('_homology_consistency')->{$mlss_member_id}});
    if ($count > 1) {
      my ($mlss, $member_id) = split("_",$mlss_member_id);
      $self->throw("Inconsistent homologies in mlss $mlss and member_id $member_id");
    }
  }
}


sub generate_attribute_arguments {
  my ($self, $nc1, $nc2, $type) = @_;

  my $new_aln1_cigarline = "";
  my $new_aln2_cigarline = "";

  my $perc_id1 = 0;
  my $perc_pos1 = 0;
  my $perc_id2 = 0;
  my $perc_pos2 = 0;
  # This speeds up the pipeline for this portion of the homology table
  if ($type eq 'possible_ortholog') {
    return ($new_aln1_cigarline, $perc_id1, $perc_pos1, $new_aln2_cigarline, $perc_id2, $perc_pos2);
  }

  my $identical_matches = 0;
  my $positive_matches = 0;
  my $m_hash = $self->get_matrix_hash;

  my ($aln1state, $aln2state);
  my ($aln1count, $aln2count);

  # my @aln1 = split(//, $nc1->alignment_string); # Speed up
  # my @aln2 = split(//, $nc2->alignment_string);

  my $alignment_string = $nc1->alignment_string;
  my @aln1 = unpack("A1" x length($alignment_string), $alignment_string);
  $alignment_string = $nc2->alignment_string;
  my @aln2 = unpack("A1" x length($alignment_string), $alignment_string);

  for (my $i=0; $i <= $#aln1; $i++) {
    next if ($aln1[$i] eq "-" && $aln2[$i] eq "-");
    my ($cur_aln1state, $cur_aln2state) = qw(M M);
    if ($aln1[$i] eq "-") {
      $cur_aln1state = "D";
    }
    if ($aln2[$i] eq "-") {
      $cur_aln2state = "D";
    }
    if ($cur_aln1state eq "M" && $cur_aln2state eq "M" && $aln1[$i] eq $aln2[$i]) {
      $identical_matches++;
      $positive_matches++;
    } elsif ($cur_aln1state eq "M" && $cur_aln2state eq "M" && $m_hash->{uc $aln1[$i]}{uc $aln2[$i]} > 0) {
        $positive_matches++;
    }
    unless (defined $aln1state) {
      $aln1count = 1;
      $aln2count = 1;
      $aln1state = $cur_aln1state;
      $aln2state = $cur_aln2state;
      next;
    }
    if ($cur_aln1state eq $aln1state) {
      $aln1count++;
    } else {
      if ($aln1count == 1) {
        $new_aln1_cigarline .= $aln1state;
      } else {
        $new_aln1_cigarline .= $aln1count.$aln1state;
      }
      $aln1count = 1;
      $aln1state = $cur_aln1state;
    }
    if ($cur_aln2state eq $aln2state) {
      $aln2count++;
    } else {
      if ($aln2count == 1) {
        $new_aln2_cigarline .= $aln2state;
      } else {
        $new_aln2_cigarline .= $aln2count.$aln2state;
      }
      $aln2count = 1;
      $aln2state = $cur_aln2state;
    }
  }
  if ($aln1count == 1) {
    $new_aln1_cigarline .= $aln1state;
  } else {
    $new_aln1_cigarline .= $aln1count.$aln1state;
  }
  if ($aln2count == 1) {
    $new_aln2_cigarline .= $aln2state;
  } else {
    $new_aln2_cigarline .= $aln2count.$aln2state;
  }
  my $seq_length1 = $nc1->seq_length;
  unless (0 == $seq_length1) {
    $perc_id1 = $identical_matches*100.0/$seq_length1;
    $perc_pos1 = $positive_matches*100.0/$seq_length1;
  }
  my $seq_length2 = $nc2->seq_length;
  unless (0 == $seq_length2) {
    $perc_id2 = $identical_matches*100.0/$seq_length2;
    $perc_pos2 = $positive_matches*100.0/$seq_length2;
  }

#   my $perc_id1 = $identical_matches*100.0/$nc1->seq_length;
#   my $perc_pos1 = $positive_matches*100.0/$nc1->seq_length;
#   my $perc_id2 = $identical_matches*100.0/$nc2->seq_length;
#   my $perc_pos2 = $positive_matches*100.0/$nc2->seq_length;

  return ($new_aln1_cigarline, $perc_id1, $perc_pos1, $new_aln2_cigarline, $perc_id2, $perc_pos2);
}

sub get_matrix_hash {
  my $self = shift;

  return $self->param('matrix_hash') if (defined $self->param('matrix_hash'));

  my $BLOSUM62 = "#  Matrix made by matblas from blosum62.iij
#  * column uses minimum score
#  BLOSUM Clustered Scoring Matrix in 1/2 Bit Units
#  Blocks Database = /data/blocks_5.0/blocks.dat
#  Cluster Percentage: >= 62
#  Entropy =   0.6979, Expected =  -0.5209
   A  R  N  D  C  Q  E  G  H  I  L  K  M  F  P  S  T  W  Y  V  B  Z  X  *
A  4 -1 -2 -2  0 -1 -1  0 -2 -1 -1 -1 -1 -2 -1  1  0 -3 -2  0 -2 -1  0 -4
R -1  5  0 -2 -3  1  0 -2  0 -3 -2  2 -1 -3 -2 -1 -1 -3 -2 -3 -1  0 -1 -4
N -2  0  6  1 -3  0  0  0  1 -3 -3  0 -2 -3 -2  1  0 -4 -2 -3  3  0 -1 -4
D -2 -2  1  6 -3  0  2 -1 -1 -3 -4 -1 -3 -3 -1  0 -1 -4 -3 -3  4  1 -1 -4
C  0 -3 -3 -3  9 -3 -4 -3 -3 -1 -1 -3 -1 -2 -3 -1 -1 -2 -2 -1 -3 -3 -2 -4
Q -1  1  0  0 -3  5  2 -2  0 -3 -2  1  0 -3 -1  0 -1 -2 -1 -2  0  3 -1 -4
E -1  0  0  2 -4  2  5 -2  0 -3 -3  1 -2 -3 -1  0 -1 -3 -2 -2  1  4 -1 -4
G  0 -2  0 -1 -3 -2 -2  6 -2 -4 -4 -2 -3 -3 -2  0 -2 -2 -3 -3 -1 -2 -1 -4
H -2  0  1 -1 -3  0  0 -2  8 -3 -3 -1 -2 -1 -2 -1 -2 -2  2 -3  0  0 -1 -4
I -1 -3 -3 -3 -1 -3 -3 -4 -3  4  2 -3  1  0 -3 -2 -1 -3 -1  3 -3 -3 -1 -4
L -1 -2 -3 -4 -1 -2 -3 -4 -3  2  4 -2  2  0 -3 -2 -1 -2 -1  1 -4 -3 -1 -4
K -1  2  0 -1 -3  1  1 -2 -1 -3 -2  5 -1 -3 -1  0 -1 -3 -2 -2  0  1 -1 -4
M -1 -1 -2 -3 -1  0 -2 -3 -2  1  2 -1  5  0 -2 -1 -1 -1 -1  1 -3 -1 -1 -4
F -2 -3 -3 -3 -2 -3 -3 -3 -1  0  0 -3  0  6 -4 -2 -2  1  3 -1 -3 -3 -1 -4
P -1 -2 -2 -1 -3 -1 -1 -2 -2 -3 -3 -1 -2 -4  7 -1 -1 -4 -3 -2 -2 -1 -2 -4
S  1 -1  1  0 -1  0  0  0 -1 -2 -2  0 -1 -2 -1  4  1 -3 -2 -2  0  0  0 -4
T  0 -1  0 -1 -1 -1 -1 -2 -2 -1 -1 -1 -1 -2 -1  1  5 -2 -2  0 -1 -1  0 -4
W -3 -3 -4 -4 -2 -2 -3 -2 -2 -3 -2 -3 -1  1 -4 -3 -2 11  2 -3 -4 -3 -2 -4
Y -2 -2 -2 -3 -2 -1 -2 -3  2 -1 -1 -2 -1  3 -3 -2 -2  2  7 -1 -3 -2 -1 -4
V  0 -3 -3 -3 -1 -2 -2 -3 -3  3  1 -2  1 -1 -2 -2  0 -3 -1  4 -3 -2 -1 -4
B -2 -1  3  4 -3  0  1 -1  0 -3 -4  0 -3 -3 -2  0 -1 -4 -3 -3  4  1 -1 -4
Z -1  0  0  1 -3  3  4 -2  0 -3 -3  1 -1 -3 -1  0 -1 -3 -2 -2  1  4 -1 -4
X  0 -1 -1 -1 -2 -1 -1 -1 -1 -1 -1 -1 -1 -1 -2  0  0 -2 -1 -1 -1 -1 -1 -4
* -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4  1
";
  my $matrix_string;
  my @lines = split(/\n/,$BLOSUM62);
  foreach my $line (@lines) {
    next if ($line =~ /^\#/);
    if ($line =~ /^[A-Z\*\s]+$/) {
      $matrix_string .= sprintf "$line\n";
    } else {
      my @t = split(/\s+/,$line);
      shift @t;
      #       print scalar @t,"\n";
      $matrix_string .= sprintf(join(" ",@t)."\n");
    }
  }

  my %matrix_hash;
  @lines = ();
  @lines = split /\n/, $matrix_string;
  my $lts = shift @lines;
  $lts =~ s/^\s+//;
  $lts =~ s/\s+$//;
  my @letters = split /\s+/, $lts;

  foreach my $letter (@letters) {
    my $line = shift @lines;
    $line =~ s/^\s+//;
    $line =~ s/\s+$//;
    my @penalties = split /\s+/, $line;
    die "Size of letters array and penalties array are different\n"
      unless (scalar @letters == scalar @penalties);
    for (my $i=0; $i < scalar @letters; $i++) {
      $matrix_hash{uc $letter}{uc $letters[$i]} = $penalties[$i];
    }
  }

  $self->param('matrix_hash', \%matrix_hash);

  return $self->param('matrix_hash');
}

1;
