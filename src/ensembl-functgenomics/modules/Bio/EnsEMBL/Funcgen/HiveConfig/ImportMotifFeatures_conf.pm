
=pod 

=head1 NAME

    Bio::EnsEMBL::Funcgen::HiveConfig::ImportMotifFeatures_conf;

=head1 SYNOPSIS

   # Example 1: specifying only the mandatory options (initial params are taken from defaults)
init_pipeline.pl Bio::EnsEMBL::Funcgen::HiveConfig::*_conf -password <mypass>

   # Example 2: specifying the mandatory options as well as setting initial params:
init_pipeline.pl Bio::EnsEMBL::Funcgen::HiveConfig::*_conf -password <mypass> -p1name p1value -p2name p2value

   # Example 3: do not re-create the database, just load more tasks into an existing one:
init_pipeline.pl Bio::EnsEMBL::Funcgen::HiveConfig::*_conf -job_topup -password <mypass> -p1name p1value -p2name p2value


=head1 DESCRIPTION

    This is the Config file for the Import Pipeline
    
    Please refer to Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf module to understand the interface implemented here.

    The Import pipeline consists of several "analysis":
        * SetupPipeline is equivalent to the "prepare" in parse_and_import.pl
        * LoadMotifFeatures loads motif features per each slice...
        * WrapUpPipeline finalizes when all partial imports are done...

    Please see the implementation details in LoadMotifFeatures Runnable module

=head1 CONTACT

    Please contact ensembl-dev@ebi.ac.uk mailing list with questions/suggestions.

=cut


package Bio::EnsEMBL::Funcgen::HiveConfig::ImportMotifFeatures_conf;

use strict;
use warnings;
use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor; 
use Bio::EnsEMBL::Utils::Exception qw(throw warning stack_trace_dump);

use base ('Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf');  
# All Hive databases configuration files should inherit from HiveGeneric, directly or indirectly


=head2 default_options

    Description : Implements default_options() interface method of 
    Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf that is used to initialize default options.

=cut

sub default_options {
  my ($self) = @_;
  return {
	  'ensembl_cvs_root_dir' => $ENV{'SRC'},                  # some Compara developers might prefer $ENV{'HOME'}.'/ensembl_main'  
	  
	  'pipeline_db' => {                             
	  		    -host   => $self->o('host'),
	  		    -port   => $self->o('port'),
	  		    -user   => $self->o('user'),
	  		    -pass   => $self->o('pass'),                       
	  		    #-dbname => $ENV{'USER'}.'_motif_feature_import_'.$self->o('dbname'),
			    -dbname => $ENV{'USER'}.'_mf_import_'.$self->o('dbname'),
	  		   },

	  'data_dir'   => '/lustre/scratch103/ensembl/funcgen',
	  'slices'     => '',

	 };
}

=head2 resource_classes

    Description : Implements resource_classes() interface method of 
      Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf that lists the LSF resource classes available

=cut

sub resource_classes {
    my ($self) = @_;
    return {
	    0 => { -desc => 'default',          'LSF' => '' },
	    1 => { -desc => 'urgent',           'LSF' => '-q yesterday' },
	    2 => { -desc => 'normal ens-genomics1',  'LSF' => '-R"select[myens_genomics1<1000] rusage[myens_genomics1=10:duration=10:decay=1]"' },
	    3 => { -desc => 'long ens-genomics1',    'LSF' => '-q long -R"select[myens_genomics1<1000] rusage[myens_genomics1=10:duration=10:decay=1]"' },
	    4 => { -desc => 'long high memory',      'LSF' => '-q long -M4000000 -R"select[mem>4000] rusage[mem=4000]"' },  
	    5 => { -desc => 'long ens-genomics1 high memory',  'LSF' => '-q long -M4000000 -R"select[myens_genomics1<600 && mem>4000] rusage[myens_genomics1=12:duration=5:decay=1:mem=4000]"' },

	   };
}


=head2 pipeline_wide_parameters

    Description : Interface method that should return a hash of pipeline_wide_parameter_name->pipeline_wide_parameter_value pairs.
                  The value doesn't have to be a scalar, can be any Perl structure now (will be stringified and de-stringified automagically).
                  Please see existing PipeConfig modules for examples.

=cut

sub pipeline_wide_parameters {
  my ($self) = @_;
  return {
	  
	  'pipeline_name'   => $self->o('pipeline_db', '-dbname'),  # name used by the beekeeper to prefix job names on the farm
	  'hive_output_dir' => $self->o('data_dir')."/output/".$self->o('dbname')."/motif_features/hive_output",
	  'output_dir' => $self->o('data_dir')."/output/".$self->o('dbname')."/motif_features/results",

	  'host'   => $self->o('host'),
	  'port'   => $self->o('port'),
	  'user'   => $self->o('user'),
	  'pass'   => $self->o('pass'),                       
	  'dbname' => $self->o('dbname'),

	  'dnadbhost'  => $self->o('dnadbhost'),
	  'dnadbport'  => $self->o('dnadbport'),
	  'dnadbuser'  => $self->o('dnadbuser'),
	  'dnadbname'  => $self->o('dnadbname'),

	  'efg_src'    => $self->o('efg_src'),

	  'slices'     => $self->o('slices'),

	 };
}


=head2 pipeline_create_commands

    Description : Implements pipeline_create_commands() interface method of 
      Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf that lists the commands 
      that will create and set up the Hive database.

=cut


sub pipeline_create_commands {
 my ($self) = @_;


  return [

	  #HiveGeneric assumes ensembl-hive folder while if you use the stable version its ensembl-hive_stable!
	  @{$self->SUPER::pipeline_create_commands},  
	  # inheriting database and hive tables creation
	  	 
	  #'mysql '.$self->dbconn_2_mysql('pipeline_db', 0)." -e 'CREATE DATABASE ".$self->o('pipeline_db', '-dbname')."'",

	  # standard eHive tables and procedures:	  
	  #'mysql '.$self->dbconn_2_mysql('pipeline_db', 1).' <'.$self->o('ensembl_cvs_root_dir').'/ensembl-hive/sql/tables.sql',
	  #'mysql '.$self->dbconn_2_mysql('pipeline_db', 1).' <'.$self->o('ensembl_cvs_root_dir').'/ensembl-hive/sql/procedures.mysql',


	  #Create hive output folders as required
	  'mkdir -p '.$self->o('data_dir')."/output/".$self->o('dbname')."/motif_features/hive_output",
	  'mkdir -p '.$self->o('data_dir')."/output/".$self->o('dbname')."/motif_features/results",

	 ];
}


=head2 pipeline_analyses

    Description : Implements pipeline_analyses() interface method of 
      Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf that defines the structure of the pipeline: analyses, jobs, rules, etc.


=cut

sub pipeline_analyses {
  my ($self) = @_;

  return [
	  
	  {   
	   -logic_name    => 'run_import',
	   -module        => 'Bio::EnsEMBL::Funcgen::RunnableDB::ImportMotifFeatures',
	   -parameters    => { },
	   -hive_capacity => 1,   # allow several workers to perform identical tasks in parallel
	   -batch_size    => 1,
	   -input_ids     => [
			      #For the moment it only receives the matrix, and deduces feature_type(s) from there...
			      { 'matrix' => $self->o('matrix'), 'file' => $self->o('file') } 
			     ],
	   -rc_id => 2,
	  },
	  

	 ];
}

1;

