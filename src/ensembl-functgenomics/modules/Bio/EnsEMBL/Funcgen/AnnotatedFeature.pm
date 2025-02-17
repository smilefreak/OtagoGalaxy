#
# Ensembl module for Bio::EnsEMBL::Funcgen::AnnotatedFeature
#
# You may distribute this module under the same terms as Perl itself

=head1 LICENSE

  Copyright (c) 1999-2011 The European Bioinformatics Institute and
  Genome Research Limited.  All rights reserved.

  This software is distributed under a modified Apache license.
  For license details, please see

    http://www.ensembl.org/info/about/code_licence.html

=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <ensembl-dev@ebi.ac.uk>.

  Questions may also be sent to the Ensembl help desk at
  <helpdesk@ensembl.org>.


=head1 NAME

Bio::EnsEMBL::AnnotatedFeature - A module to represent a feature mapping as 
predicted by the eFG pipeline.

=head1 SYNOPSIS

use Bio::EnsEMBL::Funcgen::AnnotatedFeature;

my $feature = Bio::EnsEMBL::Funcgen::AnnotatedFeature->new(
	-SLICE         => $chr_1_slice,
	-START         => 1_000_000,
        -SUMMIT        => 1_000_019,
	-END           => 1_000_024,
	-STRAND        => -1,
        -DISPLAY_LABEL => $text,
        -SCORE         => $score,
        -FEATURE_SET   => $fset,
); 



=head1 DESCRIPTION

An AnnotatedFeature object represents the genomic placement of a prediction
generated by the eFG analysis pipeline. This normally represents the 
output of a peak calling analysis. It can have a score and/or a summit, the 
meaning of which depend on the specific Analysis used to infer the feature.
For example, in the case of a feature derived from a peak call over a ChIP-seq
experiment, the score is the peak caller score, and summit is the point in the
feature where more reads align with the genome.

=head1 SEE ALSO

Bio::EnsEMBL::Funcgen::DBSQL::AnnotatedFeatureAdaptor

=cut

use strict;
use warnings;

package Bio::EnsEMBL::Funcgen::AnnotatedFeature;

use Bio::EnsEMBL::Utils::Argument qw( rearrange );
use Bio::EnsEMBL::Utils::Exception qw( throw );
use Bio::EnsEMBL::Funcgen::SetFeature;
use Bio::EnsEMBL::Funcgen::FeatureType;

use vars qw(@ISA);
@ISA = qw(Bio::EnsEMBL::Funcgen::SetFeature);


=head2 new

 
  Arg [-SCORE]        : (optional) int - Score assigned by analysis pipeline
  Arg [-ANALYSIS]     : Bio::EnsEMBL::Analysis 
  Arg [-SLICE]        : Bio::EnsEMBL::Slice - The slice on which this feature is.
  Arg [-START]        : int - The start coordinate of this feature relative to the start of the slice
		                it is sitting on. Coordinates start at 1 and are inclusive.
  Arg [-END]          : int -The end coordinate of this feature relative to the start of the slice
	                    it is sitting on. Coordinates start at 1 and are inclusive.
  Arg [-SUMMIT]       : (optional) int - seq_region peak summit position
  Arg [-DISPLAY_LABEL]: string - Display label for this feature
  Arg [-STRAND]       : int - The orientation of this feature. Valid values are 1, -1 and 0.
  Arg [-dbID]         : (optional) int - Internal database ID.
  Arg [-ADAPTOR]      : (optional) Bio::EnsEMBL::DBSQL::BaseAdaptor - Database adaptor.
  Example    : my $feature = Bio::EnsEMBL::Funcgen::AnnotatedFeature->new(
									  -SLICE         => $chr_1_slice,
									  -START         => 1_000_000,
									  -END           => 1_000_024,
                                                                          -SUMMIT        => 1_000_019,
									  -STRAND        => -1,
									  -DISPLAY_LABEL => $text,
									  -SCORE         => $score,
                                                                          -FEATURE_SET   => $fset,
                                                                         );


  Description: Constructor for AnnotatedFeature objects.
  Returntype : Bio::EnsEMBL::Funcgen::AnnotatedFeature
  Exceptions : None
  Caller     : General
  Status     : Medium Risk

=cut

sub new {
  my $caller = shift;
	
  my $class = ref($caller) || $caller;
  my $self = $class->SUPER::new(@_);
  my ($score, $summit) = rearrange(['SCORE', 'SUMMIT'], @_);
    
  $self->score($score)   if $score;
  $self->summit($summit) if $summit;
	
  return $self;
}


=head2 score

  Arg [1]    : (optional) int - score
  Example    : my $score = $feature->score();
  Description: Getter and setter for the score attribute for this feature. 
  Returntype : int
  Exceptions : None
  Caller     : General
  Status     : Low Risk

=cut

sub score {
    my $self = shift;
	
    $self->{'score'} = shift if @_;
		
    return $self->{'score'};
}

=head2 summit

  Arg [1]    : (optional) int - summit postition
  Example    : my $peak_summit = $feature->summit;
  Description: Getter and setter for the summit attribute for this feature. 
  Returntype : int
  Exceptions : None
  Caller     : General
  Status     : At Risk

=cut

sub summit {
  my $self = shift;
  
  $self->{'summit'} = shift if @_;
  
  return $self->{'summit'};
}


=head2 display_label

  Arg [1]    : string - display label
  Example    : my $label = $feature->display_label();
  Description: Getter and setter for the display label of this feature.
  Returntype : str
  Exceptions : None
  Caller     : General
  Status     : Medium Risk

=cut

#Can This be mirrored in AnnotatedFeatureSet?
#this will over ride individual display_label for annotated features.
#set label could be used as track name and feature label used in zmenu?
#These should therefore be called track_label and display_label


sub display_label {
    my $self = shift;
	
    $self->{'display_label'} = shift if @_;


    #auto generate here if not set in table
    #need to go with one or other, or can we have both, split into diplay_name and display_label?
    
    if(! $self->{'display_label'}  && $self->adaptor()){
      $self->{'display_label'} = $self->feature_type->name()." -";
      $self->{'display_label'} .= " ".$self->cell_type->name();# if $self->cell_type->display_name();
      $self->{'display_label'} .= " Enriched Site";
    }
	
    return $self->{'display_label'};
}


=head2 is_focus_feature

  Args       : None
  Example    : if($feat->is_focus_feature){ ... }
  Description: Returns true if AnnotatedFeature is part of a focus
               set used in the RegulatoryBuild
  Returntype : Boolean
  Exceptions : None
  Caller     : General
  Status     : At Risk

=cut

sub is_focus_feature{
  my $self = shift;

  #Do we need to test for FeatureSet here?
  
  return $self->feature_set->is_focus_set;
}


=head2 get_underlying_structure

  Example    : my @loci = @{ $af->get_underlying_structure() };
  Description: Returns and array of loci consisting of:
                  (start, (motif_feature_start, motif_feature_end)*, end)
  Returntype : ARRAYREF
  Exceptions : None
  Caller     : General
  Status     : At Risk - This is TFBS specific and could move to TranscriptionFactorFeature

=cut

#This should really be precomputed and stored in the DB to avoid the MF attr fetch
#Need to be aware of projecting here, as these will expire if we project after this method is called

sub get_underlying_structure{
  my $self = shift;

  if(! defined $self->{underlying_structure}){
	my @loci = ($self->start);
	
	foreach my $mf(@{$self->get_associated_MotifFeatures}){
	  push @loci, ($mf->start, $mf->end);
	}

	push @loci, $self->end;
	
	$self->{underlying_structure} = \@loci;
  }

  return $self->{underlying_structure};
}

=head2 get_associated_MotifFeatures

  Example    : my @assoc_mfs = @{ $af->get_associated_MotifFeatures };
  Description: Returns and array associated MotifFeature i.e. MotifFeatures
               representing a relevanting PWM/BindingMatrix
  Returntype : ARRAYREF
  Exceptions : None
  Caller     : General
  Status     : At Risk - This is TFBS specific and could move to TranscriptionFactorFeature

=cut

sub get_associated_MotifFeatures{
  my ($self) = @_;

  if(! defined $self->{'assoc_motif_features'}){
	my $mf_adaptor = $self->adaptor->db->get_MotifFeatureAdaptor;
	
	#These need reslicing!
	
	$self->{'assoc_motif_features'} = $mf_adaptor->fetch_all_by_AnnotatedFeature($self, $self->slice);
  }

  return $self->{'assoc_motif_features'};
}


1;

