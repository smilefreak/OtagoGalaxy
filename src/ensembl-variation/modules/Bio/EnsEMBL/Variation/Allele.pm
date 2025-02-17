=head1 LICENSE

 Copyright (c) 1999-2011 The European Bioinformatics Institute and
 Genome Research Limited.  All rights reserved.

 This software is distributed under a modified Apache license.
 For license details, please see

   http://www.ensembl.org/info/about/code_licence.html

=head1 CONTACT

 Please email comments or questions to the public Ensembl
 developers list at <dev@ensembl.org>.

 Questions may also be sent to the Ensembl help desk at
 <helpdesk@ensembl.org>.

=cut

# Ensembl module for Bio::EnsEMBL::Variation::Allele
#
# Copyright (c) 2004 Ensembl
#


=head1 NAME

Bio::EnsEMBL::Variation::Allele - A single allele of a nucleotide variation.

=head1 SYNOPSIS

    $allele = Bio::EnsEMBL::Variation::Allele->new
       (-allele => 'A',
        -frequency => 0.85,
        -population => $population);

    $delete = Bio::EnsEMBL::Variation::Allele->new
       (-allele => '-',
        -frequency => 0.15,
        -population => $population);

    ...

    $astr = $a->allele();
    $pop  = $a->population();
    $freq = $a->frequency();

    print $a->allele();
    if($a->populaton) {
       print " found in population ", $allele->population->name();
    }
    if(defined($a->frequency())) {
      print " with frequency ", $a->frequency();
    }
    print "\n";



=head1 DESCRIPTION

This is a class representing a single allele of a variation.  In addition to
the nucleotide(s) (or absence of) that representing the allele frequency
and population information may be present.

=head1 METHODS

=cut

use strict;
use warnings;

package Bio::EnsEMBL::Variation::Allele;

use Bio::EnsEMBL::Storable;
use Bio::EnsEMBL::Utils::Argument qw(rearrange);
use Bio::EnsEMBL::Utils::Exception qw(throw deprecate warning);
use Bio::EnsEMBL::Utils::Scalar qw(assert_ref check_ref);
use Scalar::Util qw(weaken);

our @ISA = ('Bio::EnsEMBL::Storable');


=head2 new

  Arg [-dbID]: int - unique internal identifier for the Allele
  Arg [-ADAPTOR]: Bio::EnsEMBL::Variation::DBSQL::AlleleAdaptor
  Arg [-ALLELE]: string - the nucleotide string representing the allele
  Arg [-FREQUENCY]: float - the frequency of the allele
  Arg [-POPULATION]: Bio::EnsEMBL::Variation::Population - the population
                     in which the allele was recorded
  Example    :     $allele = Bio::EnsEMBL::Variation::Allele->new
                      (-allele => 'A',
                       -frequency => 0.85,
                       -population => $pop);

  Description: Constructor.  Instantiates a new Allele object.
  Returntype : Bio::EnsEMBL::Variation::Allele
  Exceptions : none
  Caller     : general
  Status     : At Risk

=cut


sub new {
  my $caller = shift;
  my $class = ref($caller) || $caller;

  my ($dbID, $adaptor, $allele, $freq, $count, $pop, $ss_id, $variation_id, $population_id) =
    rearrange(['dbID', 'ADAPTOR', 'ALLELE', 'FREQUENCY', 'COUNT', 'POPULATION', 'SUBSNP', 'VARIATION_ID', 'POPULATION_ID'], @_);
  
  # set subsnp_id to undefined if it's 0 in the DB
  #$ss_id = undef if (defined $ss_id && $ss_id == 0);
  
  # add ss to the subsnp_id
  $ss_id = 'ss'.$ss_id if defined $ss_id && $ss_id !~ /^ss/;

  # Check that we at least get a BaseAdaptor
  assert_ref($adaptor,'Bio::EnsEMBL::Variation::DBSQL::BaseAdaptor');
  # If the adaptor is not an AlleleAdaptor, try to get it via the passed adaptor
  unless (check_ref($adaptor,'Bio::EnsEMBL::Variation::DBSQL::AlleleAdaptor')) {
      $adaptor = $adaptor->db->get_AlleleAdaptor();
      # Verify that we could get the AlleleAdaptor
        assert_ref($adaptor,'Bio::EnsEMBL::Variation::DBSQL::AlleleAdaptor');
  }
  
  my $self = bless {}, $class;
  
  $self->dbID($dbID);
  $self->adaptor($adaptor);
  $self->allele($allele);
  $self->frequency($freq);
  $self->count($count);
  $self->subsnp($ss_id);
  $self->{'_variation_id'} = $variation_id;
  $self->{'_population_id'} = $population_id;
  $self->population($pop) if (defined($pop));
  
  return $self;
}

# An internal method for getting a unique hash key identifier, used by the Variation module 
sub _hash_key {
    my $self = shift;
    
    # By default, return the dbID
    my $dbID = $self->dbID();
    return $dbID if (defined($dbID));
     
    # If no dbID is specified, e.g. if we are creating a 'custom' object, return a fake dbID. This is necessary since e.g. Variation stores
    # its alleles in a hash with dbID as key. To create fake dbIDs, use the string representing the memory address.
    ($dbID) = sprintf('%s',$self) =~ m/\(([0-9a-fx]+)\)/i;
    return $dbID;
}

=head2 allele

  Arg [1]    : string $newval (optional) 
               The new value to set the allele attribute to
  Example    : print $a->allele();
               $a1->allele('A');
               $a2->allele('-');
  Description: Getter/Setter for the allele attribute.  The allele is a string
               of nucleotide sequence, or a '-' representing the absence of
               sequence (deletion).
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : At Risk

=cut

sub allele{
  my $self = shift;
  return $self->{'allele'} = shift if(@_);
  return $self->{'allele'};
}




=head2 frequency

  Arg [1]    : float $newval (optional) 
               The new value to set the frequency attribute to
  Example    : $frequency = $a->frequency();
  Description: Getter/Setter for the frequency attribute. The frequency is
               the frequency of the occurance of the allele. If the population
               attribute it is the frequency of the allele within that
               population.
  Returntype : float
  Exceptions : none
  Caller     : general
  Status     : At Risk

=cut

sub frequency{
  my $self = shift;
  return $self->{'frequency'} = shift if(@_);
  return $self->{'frequency'};
}

=head2 count

  Arg [1]    : int $count (optional)
               The new value to set the count attribute to
  Example    : $frequency = $allele->count()
  Description: Getter/Setter for the observed count of this allele
               within its associated population.
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : At Risk

=cut

sub count{
  my $self = shift;
  return $self->{'count'} = shift if(@_);
  return $self->{'count'};
}



=head2 population

  Arg [1]    : Bio::EnsEMBL::Variation::Population $newval (optional)
               The new value to set the population attribute to
  Example    : $population = $a->population();
  Description: Getter/Setter for the population attribute
  Returntype : Bio::EnsEMBL::Variation::Population
  Exceptions : throw on incorrect argument
  Caller     : general
  Status     : At Risk

=cut

sub population{
    my $self = shift;

    if(@_) {
        assert_ref($_[0],'Bio::EnsEMBL::Variation::Population');
        $self->{'population'} = shift;
        $self->{'_population_id'} = $self->{'population'}->dbID();
    }

    # Population can be lazy-loaded, so get it from the database if we have a sample_id but no cached object
    if (!defined($self->{'population'}) && defined($self->{'_population_id'})) {
        
        # Check that an adaptor is attached
        assert_ref($self->adaptor(),'Bio::EnsEMBL::Variation::DBSQL::AlleleAdaptor');
        
        # Get a population object
        my $population = $self->adaptor->db->get_PopulationAdaptor()->fetch_by_dbID($self->{'_population_id'});
        
        # Set the population
				$self->{'population'} = $population;
    }
    
    return $self->{'population'};
}


=head2 subsnp

  Arg [1]    : string $newval (optional) 
               The new value to set the subsnp attribute to
  Example    : print $a->subsnp();
  Description: Getter/Setter for the subsnp attribute.
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : At Risk

=cut

sub subsnp{
  my $self = shift;
  return $self->{'subsnp'} = shift if(@_);
  return $self->{'subsnp'};
}


=head2 variation

  Arg [1]    : Bio::EnsEMBL::Variation::Variation $newval (optional) 
               The new value to set the variation attribute to
  Example    : print $a->variation->name();
  Description: Getter/Setter for the variation attribute.
  Returntype : Bio::EnsEMBL::Variation::Variation
  Exceptions : throw on incorrect argument
  Caller     : general

=cut

sub variation {
    my $self = shift;
    my $variation = shift;
  
    # Set the dbID of the variation object on this allele
    if(defined($variation)) {
        assert_ref($variation,'Bio::EnsEMBL::Variation::Variation');
        $self->{'_variation_id'} = $variation->dbID();
        return $variation;
    }

    # Load the variation from the database if we have a variation_id
    if (defined($self->{'_variation_id'})) {
        
        # Check that an adaptor is attached
        assert_ref($self->adaptor(),'Bio::EnsEMBL::Variation::DBSQL::BaseAdaptor');
        
        # Get a variation object
        $variation = $self->adaptor->db->get_VariationAdaptor()->fetch_by_dbID($self->{'_variation_id'});
        
    }
    
    # Return the variation object
    return $variation;
}

=head2 is_failed

  Example    : print $a->is_failed();
  Description: Gets the failed attribute.
  Returntype : int
  Exceptions : none
  Caller     : general
  Status     : At Risk

=cut

sub is_failed {
    my $self = shift;
  
    return (length($self->failed_description()) > 0);
}


=head2 failed_description

  Arg [1]    : $failed_description (optional)
	           The new value to set the failed_description attribute to. Should 
	           be a reference to a list of strings, alternatively a string can
	           be passed. If multiple failed descriptions are specified, they should
	           be separated with semi-colons.  
  Example    : $failed_str = $allele->failed_description();
  Description: Get/Sets the failed attribute for this allele. The failed
	       descriptions are lazy-loaded from the database.
  Returntype : Semi-colon separated string 
  Exceptions : Thrown on illegal argument.
  Caller     : general
  Status     : At risk

=cut

sub failed_description {
    my $self = shift;
    my $description = shift;
  
    # Update the description if necessary
    if (defined($description)) {
        
        # If the description is a string, split it by semi-colon and take the reference
        if (check_ref($description,'STRING')) {
            my @pcs = split(/;/,$description);
            $description = \@pcs;
        }
        # Throw an error if the description is not an arrayref
        assert_ref($description.'ARRAY');
        
        # Update the cached failed_description
        $self->{'failed_description'} = $description;
    }
    # Else, fetch it from the db if it's not cached
    elsif (!defined($self->{'failed_description'})) {
        $self->{'failed_description'} = $self->get_all_failed_descriptions();
    }
    
    # Return a semi-colon separated string of descriptions
    return join(";",@{$self->{'failed_description'}});
}

=head2 get_all_failed_descriptions

  Example    :  
                if ($allele->is_failed()) {
                    my $descriptions = $allele->get_all_failed_descriptions();
                    print "Allele " . $allele->allele() . " has been flagged as failed because '";
                    print join("' and '",@{$descriptions}) . "'\n";
                }
                
  Description: Gets all failed descriptions associated with this allele.
  Returntype : Reference to a list of strings 
  Exceptions : Thrown if an adaptor is not attached to this object.
  Caller     : general
  Status     : At risk

=cut

sub get_all_failed_descriptions {
    my $self = shift;
    
    # If the failed descriptions haven't been cached yet, load them from db
    unless (defined($self->{'failed_description'})) {
        
        # Check that this allele has an adaptor attached
        assert_ref($self->adaptor(),'Bio::EnsEMBL::Variation::DBSQL::AlleleAdaptor');
    
        $self->{'failed_description'} = $self->adaptor->get_all_failed_descriptions($self);
    }
    
    return $self->{'failed_description'};
}

=head2 subsnp_handle

  Arg [1]    : string $newval (optional) 
               The new value to set the subsnp_handle attribute to
  Example    : print $a->subsnp_handle();
  Description: Getter/Setter for the subsnp_handle attribute.
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : At Risk

=cut

sub subsnp_handle{
    my $self = shift;
    my $handle = shift;
      
    # if changing handle
    if(defined($handle)) {
        $self->{'subsnp_handle'} = $handle;
    }
    elsif (!defined($self->{'subsnp_handle'})) {

        # Check that this allele has an adaptor attached
        assert_ref($self->adaptor(),'Bio::EnsEMBL::Variation::DBSQL::AlleleAdaptor');
        
        $self->{'subsnp_handle'} = $self->adaptor->get_subsnp_handle($self);
    }
    
    return $self->{'subsnp_handle'};
}

sub _weaken {
    my $self = shift;
    
    # If the variation is not defined, do nothing
    return unless (defined($self->variation()));
    
    # Weaken the link to the variation
    weaken($self->{'variation'});
}

1;
