
=pod 

=head1 NAME

  Bio::EnsEMBL::Compara::PipeConfig::AncestralMerge_conf

=head1 SYNOPSIS

    init_pipeline.pl Bio::EnsEMBL::Compara::PipeConfig::AncestralMerge_conf -password <your_password>

=head1 DESCRIPTION  

    A pipeline to create the EnsEMBL core database with ancestral sequences merged from different sources.

    In rel.64 it took ~30min to run.

=head1 CONTACT

  Please contact ehive-users@ebi.ac.uk mailing list with questions/suggestions.

=cut

package Bio::EnsEMBL::Compara::PipeConfig::AncestralMerge_conf;

use strict;
use warnings;

use base ('Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf');   # instead of Compara tables we actually want Core tables


sub default_options {
    my ($self) = @_;
    return {
        'ensembl_cvs_root_dir' => $ENV{'ENSEMBL_CVS_ROOT_DIR'},

        'rel'               => 64,                                                  # current release number
        'rel_suffix'        => '',                                                  # empty string by default
        'rel_with_suffix'   => $self->o('rel').$self->o('rel_suffix'),              # for convenience

        'pipeline_name' => 'ensembl_ancestral_'.$self->o('rel_with_suffix'),        # name used by the beekeeper to prefix job names on the farm

        'merge_script'  => $self->o('ensembl_cvs_root_dir').'/ensembl-compara/scripts/pipeline/copy_ancestral_core.pl',

        'pipeline_db' => {
            -host   => 'compara1',
            -port   => 3306,
            -user   => 'ensadmin',
            -pass   => $self->o('password'),
            -dbname => $ENV{'USER'}.'_'.$self->o('pipeline_name'),
        },

        'prev_ancestral_db' => {
            -driver => 'mysql',
            -host   => 'compara1',
            -port   => 3306,
            -user   => 'ensadmin',
            -pass   => $self->o('password'),
            -dbname => 'lg4_ensembl_ancestral_63',
        },

    };
}


sub pipeline_create_commands {
    my ($self) = @_;
    return [
        @{$self->SUPER::pipeline_create_commands},                                                              # inherit database and Hive tables' creation

        $self->db_connect_command('pipeline_db').' <'.$self->o('ensembl_cvs_root_dir').'/ensembl/sql/table.sql',     # add Core tables
    ];
}


sub resource_classes {
    my ($self) = @_;
    return {
         0 => { -desc => 'default',          'LSF' => '' },
         1 => { -desc => 'urgent',           'LSF' => '-q yesterday' },
         2 => { -desc => 'more_mem',         'LSF' => '-M5000000 -R "select[mem>5000] rusage[mem=5000]"' },
    };
}


sub pipeline_analyses {
    my ($self) = @_;
    return [
        {   -logic_name => 'copy_coord_system',
            -module     => 'Bio::EnsEMBL::Hive::RunnableDB::MySQLTransfer',
            -parameters => {
                'src_db_conn'   => $self->o('prev_ancestral_db'),
                'table'         => 'coord_system',
                'mode'          => 'insertignore',
            },
            -input_ids  => [ {} ],
            -flow_into  => {
                1 => [ 'generate_merge_jobs' ],
            },
            -rc_id => 1,
        },

        {   -logic_name => 'generate_merge_jobs',
            -module     => 'Bio::EnsEMBL::Hive::RunnableDB::JobFactory',
            -parameters => {
                'inputlist'         => [        # this table needs to be edited prior to running the pipeline:
                        # copying from previous release:
                    [ '505' => $self->dbconn_2_url('prev_ancestral_db'), ],                                                 # 3-way birds
                    [ '528' => $self->dbconn_2_url('prev_ancestral_db'), ],                                                 # 5-way fish

                        # copying from new sources:
                    [ '538' => 'mysql://ensadmin:'.$self->o('password').'@compara3/sf5_compara_6way_64_ancestral_core' ],   # 6-way primates
                    [ '537' => 'mysql://ensadmin:'.$self->o('password').'@compara3/sf5_compara_12way_64_ancestral_core' ],  # 12-way mammals
                ],
                'input_id'          => { 'mlss_id' => '#_0#', 'from_url' => '#_1#' },
                'fan_branch_code'   => 2,
            },
            -flow_into => {
                2 => [ 'merge_an_ancestor' ],
            },
            -rc_id => 1,
        },

        {   -logic_name    => 'merge_an_ancestor',
            -module        => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
            -parameters    => {
                'to_url' => $self->dbconn_2_url('pipeline_db'),
                'cmd'    => $self->o('merge_script').' --from_url #from_url# --to_url #to_url# --mlss_id #mlss_id#',
            },
            -hive_capacity  => 1,   # do them one-by-one
            -rc_id => 2,
        },
    ];
}

1;

