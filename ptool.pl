#! /usr/bin/perl

use English;
use Archive::Tar;
use DateTime::Format::Strptime;
use Excel::Writer::XLSX;
use File::Basename qw(basename dirname);
use POSIX qw(strftime);
use Time::Piece;
# use Storable 'dclone';
use Getopt::Long;
use Data::Dumper;
use XML::Parser;
use Cwd;

my $CONVERT_TO_KB = 1024;			# 1024
my $CONVERT_TO_MB = 1048576;		# 1024/1024
my $CONVERT_TO_GB = 1073741824;		# 1024/1024/1024
my $CONVERT_TO_TB = 1099511627776;	# 1024/1024/1024/1024

use constant { true => 1, false => 0};

my $VERSION = 'v4.2';
my $VERDATE = '2017-01-19';
my $verbose = 0;
my $auto_find = true;
my $process_1920 = false;
my $program_dir = dirname(__FILE__);
my $current_dir = getcwd();

my $package_fn = 'ptool.pm';
eval {	require "$program_dir/$package_fn"};
if ($@) {
	print "Failed to load $package_fn from $program_dir\n";
	eval {require "IBM/$package_fn"};
	if ($@) {
		print "Failed to load $package_fn, because:\n $@"
	} else {
		print "Loaded package $package_fn from perl library\n";
	}
} else {
	print "Loaded package $package_fn from $this_dir\n";
}

#   Setup the default date time parser
my $dt_strptime_version = DateTime::Format::Strptime->VERSION;

our %timezones = (AST => '-0400',ADT => '-0300',
				BST => '+0100',
				CST => '-0600',CDT => '-0500',
				EST => '-0500',EDT => '-0400',
				PST => '-0800',PDT => '-0700',
				MSK => '+0300',
				SAMT => '+0400',
				Localtime => '-0000');

my ($cfgxml_fn, $lsfabric_fn, $audit_fn, $errlof_fn, $svcout_fn);

GetOptions( 'config|xml=s' => \$cfgxml_fn,
			'lsfabric=s' => \$lsfabric_fn, 
			'audit=s' => \$audit_fn, 
			'errlog=s' => \$errlog_fn, 
			'svcout=s' => \$svcout_fn, 
			'outdir=s' => \$output_dir,
			'1920+' => \$process_1920,
			'snap=s' => \$snap_file,
			'auto!' => \$auto_find,
			'help' => \$show_help ) or die "Invalid option specified";

# if auto find is enabled scan current directory to see if we can find the required files
if ($auto_find) {
	print "Checking $current_dir for svc files\n";
	opendir(DIR, $current_dir) || die "Can't open directory $current_dir\n $!";
	my @files = grep {!/^\./} readdir(DIR);
	closedir DIR;
	
	foreach my $fn (sort @files) {
		if (($audit_fn eq '') and ($fn =~ /^auditlog\./)) {$audit_fn=$fn;};
		if (($errlog_fn eq '') and ($fn =~ /^errlog\_/)) {$errlog_fn=$fn;};
		if (($svcout_fn eq '') and ($fn =~ /^svcout\./)) {$svcout_fn=$fn;};
		if (($cfgxml_fn eq '') and ($fn =~ /^svc.config/)) {$cfgxml_fn=$fn;};
	}
}



if ((! -e $cfgxml_fn) and (! -e $svcout_fn)) {
	die "\n** Error **\nNo input file(s) specified, the config xml file or the svcout file or both is required\n  use --xml <config_filename> and/or --svcout <svcout_filename>\n";
}

#	Open log file to track progress/issues
open (my $LOGFILE,'>','svcqtool.log') or warn "Problem creating log file svcqtool.log\n$!";

my %cluster_info = ();
my %cntrl_info = ();
my %etherport_info = ();
my %fcport_info = ();
my %fcgrp_info  = ();
my %host_info = ();
my %mdisk_info = ();
my %mdiskgrp_info = ();
my %node_info = ();
my %partner_info = ();
my %rc_info  = ();
my %rcgrp_info = ();
my %rcmap_info = ();
my %vdisk_info = ();
my %vdiskmap_info = ();
my @errlog;

#  read in the ini file to get the required definitions and control information
our %ini_info = ();
my $ini_fn = 'svcqtool_v4.ini';
my $ini_fqn = "$program_dir/$ini_fn";
open (my $INFILE,'<',$ini_fqn) or die "Problem opening definition file $ini_fqn\n$!\n";
my @ini_recs = <$INFILE>;
close $INFILE;

foreach my $ini_rec (@ini_recs) {
	$ini_rec = trim($ini_rec);
	if ($ini_rec eq '') {next;}
	my ($prod,$file_type,$func,$data) = split(';',$ini_rec,4);	
	$ini_info{$prod}{$file_type}{$func} = $data;
#	$ini_info{'v7k'}{$file_type}{$func} = $data if ($prod eq 'svc');
}

#  Parse the XML config file.
logger(1,"Parse config XML file");
my $xml_parser = new XML::Parser(ErrorContext => 2);
$xml_parser->setHandlers(Start => \&xmlparser_start_handler,
						 End => \&xmlparser_end_handler);
						
if (-e $cfgxml_fn) {$xml_parser->parsefile($cfgxml_fn)};

#
#  Process optional lsfabric, audit and errlog files.
#
if (-e $svcout_fn) {&scan_svcout($svcout_fn);}
#if ($lsfabric_filename ne "") {&process_lsfabric($lsfabric_filename);}
if (-e $errlog_fn) {@errlog = &process_errlog($errlog_fn);}
if (-e $audit_fn) {@auditlog = &process_audit($audit_fn);}

my $lcluster = $cluster_info{'name'};
# loop through the storage pools and add any value add info
@size_metrics = qw(real_capacity virtual_capacity used_capacity free_capacity capacity compression_virtual_capacity compression_compressed_capacity compression_uncompressed_capacity uncompressed_used_capacity);
foreach $id (sort keys %mdiskgrp_info) {
	# convert the mdisk group sizes to real sizes
	foreach $metric (@size_metrics) {
		if ($mdiskgrp_info{$id}{$metric} =~ /B/i) {	
			$mdiskgrp_info{$id}{$metric.'_raw'} = disp_to_GB($mdiskgrp_info{$id}{$metric});
		} else {						
			$mdiskgrp_info{$id}{$metric.'_raw'} = size_to_GB($mdiskgrp_info{$id}{$metric});
			$mdiskgrp_info{$id}{$metric} = size_to_disp($mdiskgrp_info{$id}{$metric});
		}
	}
	
#	calculate the percentage free and used
	if ($mdiskgrp_info{$id}{'capacity_raw'} >0) {
		$mdiskgrp_info{$id}{'pct_free'} = ($mdiskgrp_info{$id}{'free_capacity_raw'}/$mdiskgrp_info{$id}{'capacity_raw'})*100;
		$mdiskgrp_info{$id}{'pct_used'} = ($mdiskgrp_info{$id}{'real_capacity_raw'}/$mdiskgrp_info{$id}{'capacity_raw'})*100;
	} else {
		$mdiskgrp_info{$id}{'pct_free'} = 0;
		$mdiskgrp_info{$id}{'pct_used'} = 0;
	}
	
	# special code to identify the storage pool tier  (only works need to fix this)
	if ($mdiskgrp_info{$id}{'name'} =~ /\_(T[012345])\_/i) {$mdiskgrp_info{$id}{'tier'} = $1;}
}


# loop through the vdisk host mappings and add info to the vdisk_info hash
foreach my $id (keys %vdiskmap_info) {
	my $host_name = $vdiskmap_info{$id}{'name'};
	my $host_id = sprintf("%04d",$vdiskmap_info{$id}{'host_id'});
	my $vdisk_id = sprintf("%04dP",$vdiskmap_info{$id}{'vdisk_id'});
	
#	add the host name and count of hosts to the vdisk info
	if (!defined($vdisk_info{$vdisk_id}{'hostlist'})) {
	
		$vdisk_info{$vdisk_id}{'hostlist'} = $host_name;
	} elsif (';'.$vdisk_info{$vdisk_id}{'hostlist'}.';' !~ ';'.$host_name.';') {
		$vdisk_info{$vdisk_id}{'hostlist'} .= ";$host_name";
	}
	$vdisk_info{$vdisk_id}{'hosts'}++;
	$host_info{$host_id}{'vdisks'}++;

}

# loop through the vdisks and add any value add info
foreach my $vdisk_id (keys %vdisk_info) {
	print "==>$vdisk_id<== \n" if ($vdisk_id !~ /[PS]/);

	my $pool_id 	= sprintf("%04d",$vdisk_info{$vdisk_id}{'mdisk_grp_id'});

	#  convert display values to raw bytes or raw bytes to display values as required
	foreach $metric (@size_metrics) {
		if ($vdisk_info{$vdisk_id}{$metric} =~ /B/i) {
			$vdisk_info{$vdisk_id}{$metric.'_raw'} = IBM::SVCTools->disp_to_GB($vdisk_info{$vdisk_id}{$metric});
		} elsif ($vdisk_info{$vdisk_id}{$metric} > 0) {
			$vdisk_info{$vdisk_id}{$metric.'_raw'} = IBM::SVCTools->size_to_GB($vdisk_info{$vdisk_id}{$metric});
			$vdisk_info{$vdisk_id}{$metric} = IBM::SVCTools->size_to_disp($vdisk_info{$vdisk_id}{$metric});
		}
	}
	
	# Set a common vdisk type n=normal, c=compressed t=thin provisioned
	if ($vdisk_info{$vdisk_id}{'se_copy'} eq 'yes') {
		$vdisk_info{$vdisk_id}{'vdisk_type'} = 'T';
		$mdiskgrp_info{$pool_id}{'vdisks_thin'}++;
#		$mdiskgrp_info{$pool_id}{'used_thin'} += $vdisk_info{$vdisk_id}{'used_capacity_raw'};
	} elsif ($vdisk_info{$vdisk_id}{'compressed_copy'} eq 'yes') {
		$vdisk_info{$vdisk_id}{'vdisk_type'} = 'C';
		$mdiskgrp_info{$pool_id}{'vdisks_comp'}++;
#		$mdiskgrp_info{$pool_id}{'used_comp'} += $vdisk_info{$vdisk_id}{'used_capacity_raw'};
#		$vdisk_info{$vdisk_id}{'comp_saved_raw'} = $vdisk_info{$vdisk_id}{'uncompressed_used_capacity_raw'} - $vdisk_info{$vdisk_id}{'used_capacity_raw'};
	} else {
		$vdisk_info{$vdisk_id}{'vdisk_type'} = 'N';
	};
	
	if ($vdisk_id =~ /P/) {
		my $node_id 	= sprintf("%04d",$vdisk_info{$vdisk_id}{'preferred_node_id'});
# 		identify if the vdisk in a rc relationship is a Source or Target
		if (defined($vdisk_info{$vdisk_id}{'RC_id'}) and ($vdisk_info{$vdisk_id}{'RC_id'} ne '')) {
			my $rc_id = sprintf("%04d",$vdisk_info{$vdisk_id}{'RC_id'});
			$vdisk_info{$vdisk_id}{'RC_state'} = $rcmap_info{$rc_id}{'state'};
			$vdisk_info{$vdisk_id}{'RC_type'} = 'S' if ($lcluster eq $rcmap_info{$rc_id}{'master_cluster_name'});
			$vdisk_info{$vdisk_id}{'RC_type'} = 'T' if ($lcluster eq $rcmap_info{$rc_id}{'aux_cluster_name'});
			$vdisk_info{$vdisk_id}{'RC_GRP'} = $rcmap_info{$rc_id}{'consistency_group_id'};
			$vdisk_info{$vdisk_id}{'RC_GRP_name'} = $rcmap_info{$rc_id}{'consistency_group_name'};
		}
	
#		check if this vdisk is part of a FC relationship
		if (defined($vdisk_info{$vdisk_id}{'FC_id'}) and ($vdisk_info{$vdisk_id}{'FC_id'} ne '')) {
			if ($vdisk_info{$vdisk_id}{'FC_id'} ne 'many') {
				my $tmp_vdisk_id = substr($vdisk_id,0,4);
				my $fc_id = sprintf("%04d",$vdisk_info{$vdisk_id}{'FC_id'});
				my $svdisk_id = sprintf("%04d",$fcmap_info{$fc_id}{'source_vdisk_id'});
				my $tvdisk_id = sprintf("%04d",$fcmap_info{$fc_id}{'target_vdisk_id'});
				$vdisk_info{$vdisk_id}{'FC_type'} = 'S' if ($tmp_vdisk_id eq $svdisk_id);
				$vdisk_info{$vdisk_id}{'FC_type'} = 'T' if ($tmp_vdisk_id eq $tvdisk_id);
			}
		}
#		add site info
		$vdisk_info{$vdisk_id}{'site_name'} = $node_info{$node_id}{'site_name'} if (exists $vdisk_info{$vdisk_id}{'preferred_node_id'});
	}
}

#
#  Create report workbook
#

my $now = localtime;
my $now_date = $now->ymd;
my $now_time = $now->hms;
my ($t1,$t2);
if (exists $cluster_info{'xml_date'}) {
	$t1 = $cluster_info{'xml_date'}->ymd('');
	$t2 = substr($cluster_info{'xml_date'}->hms(''),0,4);
} elsif (exists $cluster_info{'svcout_date'}) {
	$t1 = $cluster_info{'svcout_date'}->ymd('');
	$t2 = substr($cluster_info{'svcout_date'}->hms(''),0,4);
} else {
	$t1 = $now->ymd('');
	$t2 = substr($now->hms(''),0,4);
}



my $wb_fn = "svcqtool.$lcluster.$t1\_$t2.xlsx";
logger(1,"****> Creating workbook $wb_fn");
my $wb_fqn =  "$wb_fn";
our $workbook  = Excel::Writer::XLSX->new($wb_fqn) or die "Problem creating new workbook $wb_fqn\n$!";
our $fmt_int = $workbook->add_format();
$fmt_int->set_num_format( '#,##0' );
our $fmt_pct = $workbook->add_format( num_format => '#0.0');
our $fmt_size = $workbook->add_format( num_format => '#,0.0');
our $markFormat = $workbook->add_format( bold => 1);				#first row and col setup
our $infoFormat = $workbook->add_format(bg_color => 'yellow');
our $warningFormat = $workbook->add_format(bg_color => 'orange');
our $errorFormat = $workbook->add_format(bg_color => 'red');
our $toc_ws = $workbook->add_worksheet("TOC");
	$toc_ws->set_column( 'A:A', 18);
	$toc_ws->set_column( 'B:B', 45);
	our $url_format = $workbook->add_format(
				color     => 'blue',
				underline => 1,
	);
	
	$toc_ws->write_string( 0,0,'SVCQtool Version:');
	$toc_ws->write_string( 0,1,$VERSION);
	$toc_ws->write_string( 1,0,'Config XLM Date:');
	if (exists $cluster_info{'xml_date'}) {
		my $xml_date = $cluster_info{'xml_date'}->ymd;
		my $xml_time = $cluster_info{'xml_date'}->hms;
		$toc_ws->write_string( 1,1,"$xml_date $xml_time");
	}
	$toc_ws->write_string( 2,0,'SVCOUT Date:');
	if (exists $cluster_info{'svcout_date'}) {
		my $svcout_date = $cluster_info{'svcout_date'}->ymd;
		my $svcout_time = $cluster_info{'svcout_date'}->hms;
		$toc_ws->write_string( 2,1,"$svcout_date $svcout_time");
	}
	$toc_ws->write_string( 3,0,'Workbook created:');
	$toc_ws->write_string( 3,1,"$now_date $now_time");
	$toc_ws->write_string( 4,0,'Cluster Name:');
	$toc_ws->write_string( 4,1,$lcluster);
	
	my $toc_row=6;
	my $cluster_name = $cluster_info{'name'};
	&create_main_ws($workbook,\%cluster_info,\%partner_info);
	$toc_ws->write_url( $toc_row,0,"internal:\'$cluster_name\'!A1", $url_format,$cluster_name);
	$toc_ws->write_string( $toc_row++,1,'Cluster summary information');

	my $tt = $ini_info{'svc'}{'sheets'}{'names'};
#	$tt = 'fcgrp,fcmap';

	my @t = split(',',$tt);
	foreach my $rpt_type (@t) {	
		if ($rpt_type eq 'nodes') {$stg_info = \%node_info if (%node_info);}
		elsif ($rpt_type eq 'mdiskgrp') {$stg_info = \%mdiskgrp_info if (%mdiskgrp_info);}
		elsif ($rpt_type eq 'mdisks') {$stg_info = \%mdisk_info if (%mdisk_info);}
		elsif ($rpt_type eq 'fcports') {$stg_info = \%fcport_info if (%fcport_info);}
		elsif ($rpt_type eq 'hosts') {$stg_info = \%host_info if (%host_info);}
		elsif ($rpt_type eq 'cntrl') {$stg_info = \%cntrl_info if (%cntrl_info);}
		elsif ($rpt_type eq 'vdisks') {$stg_info = \%vdisk_info if (%vdisk_info);}
		elsif ($rpt_type eq 'vdiskmap') {$stg_info = \%vdiskmap_info if (%vdiskmap_info);}		
		elsif ($rpt_type eq 'rcgrp') {$stg_info = \%rcgrp_info if (%rcgrp_info);}
		elsif ($rpt_type eq 'rcmap') {$stg_info = \%rcmap_info if (%rcmap_info);}
		elsif ($rpt_type eq 'fcgrp') {$stg_info = \%fcgrp_info if (%fcgrp_info);}
		elsif ($rpt_type eq 'fcmap') {$stg_info = \%fcmap_info if (%fcmap_info);}
		elsif ($rpt_type eq 'eports') {$stg_info = \%etherport_info if (%etherport_info);}
		else {warn "***** Hash for report type $rpt_type not found";next;}	
		&create_worksheet($workbook,$rpt_type,$stg_info);
		my ($sheet,$title,$desc,$junk) = split(';',$ini_info{'svc'}{$rpt_type}{'toc'},4);
		$toc_ws->write_url( $toc_row,0,"internal:$rpt_type!A1", $url_format,$rpt_type);
		$toc_ws->write_string( $toc_row++,1,$desc);
	}
	
	if (@errlog > 2) {
		$toc_ws->write_url( $toc_row,0,"internal:errlog!A1", $url_format,'errlog');
		$toc_ws->write_string( $toc_row++,1,'SVC Event Log');
		&create_errlog_ws($workbook,\@errlog,\@auditlog);
	}
	$workbook->close;

exit;

# end of line

sub create_main_ws ($) {

	my $wb = $_[0];
	my $hash_data = $_[1];
	my $partner_data = $_[2];
	logger(1,"****> Creating svc cluster worksheet for $hash_data->{'name'}");
	my $ws = $wb->add_worksheet($hash_data->{'name'});
	$ws->set_column( 0,0, 23);
	$ws->set_column( 1,1, 30);
	$ws->set_column( 3,3, 35);
	$ws->set_column( 4,5, 12);
	$ws->set_column( 7,7, 30);
	
	$ws->write_string(1,0,'Name');
	$ws->write_string(1,1,$hash_data->{'name'});
	$ws->write_string(2,0,'ID');
	$ws->write_string(2,1,$hash_data->{'id'});
	$ws->write_string(3,0,'Location');
	$ws->write_string(3,1,$hash_data->{'location'});
	$ws->write_string(4,0,'Code Level');
	$ws->write_string(4,1,$hash_data->{'code_level'});
	$ws->write_string(5,0,'Product Name');
	$ws->write_string(5,1,$hash_data->{'product_name'});
	$ws->write_string(6,0,'Time Zone');
	$ws->write_string(6,1,$hash_data->{'time_zone'});	
	
	$ws->write_string(9,0,'console_IP');
	$ws->write_string(9,1,$hash_data->{'console_IP'});
	$ws->write_string(10,0,'cluster_ntp_IP_address');
	$ws->write_string(10,1,$hash_data->{'cluster_ntp_IP_address'}) if (exists $hash_data->{'cluster_ntp_IP_address'});
	$ws->write_string(11,0,'cluster_isns_IP_address');
	$ws->write_string(11,1,$hash_data->{'cluster_isns_IP_address'}) if (exists $hash_data->{'cluster_isns_IP_address'});
	$ws->write_string(12,0,'iscsi_auth_method');
	$ws->write_string(12,1,$hash_data->{'iscsi_auth_method'}) if (exists $hash_data->{'iscsi_auth_method'});
	$ws->write_string(13,0,'iscsi_chap_secret');
	$ws->write_string(13,1,$hash_data->{'iscsi_chap_secret'}) if (exists $hash_data->{'iscsi_chap_secret'});
	
	$ws->write_string(15,0,'inventory_mail_interval');
	$ws->write_string(15,1,$hash_data->{'inventory_mail_interval'});
	$ws->write_string(16,0,'email_reply');
	$ws->write_string(16,1,$hash_data->{'email_reply'});
	$ws->write_string(17,0,'email_contact');
	$ws->write_string(17,1,$hash_data->{'email_contact'});
	$ws->write_string(18,0,'email_contact_primary');
	$ws->write_string(18,1,$hash_data->{'email_contact_primary'});
	$ws->write_string(19,0,'email_contact_location');
	$ws->write_string(19,1,$hash_data->{'email_contact_location'});
	$ws->write_string(20,0,'email_state');
	$ws->write_string(20,1,$hash_data->{'email_state'});
	$ws->write_string(21,0,'email_organization');
	$ws->write_string(21,1,$hash_data->{'email_organization'});	
	
	$ws->write_string(23,0,'Local FC Mask');
	$ws->write_string(23,1,$hash_data->{'local_fc_port_mask'});
	$ws->write_string(24,0,'Remote FC Mask');
	$ws->write_string(24,1,$hash_data->{'partner_fc_port_mask'});

	$ws->write_string(0,5,'   GB');
	$ws->write_string(1,3,'total_mdisk_capacity');
	$ws->write_string(1,4,$hash_data->{'total_mdisk_capacity'});
	$ws->write_number(1,5,disp_to_GB($hash_data->{'total_mdisk_capacity'}),$fmt_size);
	$ws->write_string(2,3,'space_in_mdisk_grps');
	$ws->write_string(2,4,$hash_data->{'space_in_mdisk_grps'});
	$ws->write_number(2,5,disp_to_GB($hash_data->{'space_in_mdisk_grps'}),$fmt_size);
	$ws->write_string(3,3,'total_used_capacity');
	$ws->write_string(3,4,$hash_data->{'total_used_capacity'});
	$ws->write_number(3,5,disp_to_GB($hash_data->{'total_used_capacity'}),$fmt_size);
	$ws->write_string(4,3,'total_free_space');
	$ws->write_string(4,4,$hash_data->{'total_free_space'});
	$ws->write_number(4,5,disp_to_GB($hash_data->{'total_free_space'}),$fmt_size);
	
	$ws->write_string(6,3,'total_vdisk_capacity');
	$ws->write_string(6,4,$hash_data->{'total_vdisk_capacity'});
	$ws->write_number(6,5,disp_to_GB($hash_data->{'total_vdisk_capacity'}),$fmt_size);
	$ws->write_string(7,3,'total_vdiskcopy_capacity');
	$ws->write_string(7,4,$hash_data->{'total_vdiskcopy_capacity'});
	$ws->write_number(7,5,disp_to_GB($hash_data->{'total_vdiskcopy_capacity'}),$fmt_size);
	$ws->write_string(8,3,'space_allocated_to_vdisks');
	$ws->write_string(8,4,$hash_data->{'space_allocated_to_vdisks'});
	$ws->write_number(8,5,disp_to_GB($hash_data->{'space_allocated_to_vdisks'}),$fmt_size);
	
	$ws->write_string(10,3,'compression_virtual_capacity');
	$ws->write_string(10,4,$hash_data->{'compression_virtual_capacity'});
	$ws->write_number(10,5,disp_to_GB($hash_data->{'compression_virtual_capacity'}),$fmt_size);
	$ws->write_string(11,3,'compression_uncompressed_capacity');
	$ws->write_string(11,4,$hash_data->{'compression_uncompressed_capacity'});
	$ws->write_number(11,5,disp_to_GB($hash_data->{'compression_uncompressed_capacity'}),$fmt_size);
	$ws->write_string(12,3,'compression_compressed_capacity');
	$ws->write_string(12,4,$hash_data->{'compression_compressed_capacity'});
	$ws->write_number(12,5,disp_to_GB($hash_data->{'compression_compressed_capacity'}),$fmt_size);

	if ($hash_data->{'total_drive_raw_capacity'} > 0) {
		$ws->write_string(13,3,'total_drive_raw_capacity');
		$ws->write_string(13,4,$hash_data->{'total_drive_raw_capacity'});
		$ws->write_number(13,5,disp_to_GB($hash_data->{'total_drive_raw_capacity'}),$fmt_size);
	}
	
	$ws->write_string(15,3,'layer');
	$ws->write_string(15,4,$hash_data->{'layer'});
	$ws->write_string(16,3,'cache_prefetch');
	$ws->write_string(16,4,$hash_data->{'cache_prefetch'});	
	$ws->write_string(17,3,'vdisk_protection_enabled');
	$ws->write_string(17,4,$hash_data->{'vdisk_protection_enabled'});
	$ws->write_string(18,3,'vdisk_protection_time');
	$ws->write_string(18,4,$hash_data->{'vdisk_protection_time'});
	$ws->write_string(19,3,'statistics_status');
	$ws->write_string(19,4,$hash_data->{'statistics_status'});
	$ws->write_string(20,3,'statistics_frequency');
	$ws->write_string(20,4,$hash_data->{'statistics_frequency'});
	
	
	$ws->write_string(1,7,'topology');
	$ws->write_string(1,8,$hash_data->{'topology'}) if (exists $hash_data->{'topology'});
	$ws->write_string(2,7,'topology_status');
	$ws->write_string(2,8,$hash_data->{'topology_status'}) if (exists $hash_data->{'topology_status'});
	
	$ws->write_string(4,7,'gm_link_tolerance');
	$ws->write_string(4,8,$hash_data->{'gm_link_tolerance'});
	$ws->write_string(5,7,'gm_max_host_delay');
	$ws->write_string(5,8,$hash_data->{'gm_max_host_delay'});
	$ws->write_string(6,7,'rc_buffer_size');
	$ws->write_string(6,8,$hash_data->{'rc_buffer_size'});
	$ws->write_string(7,7,'relationship_bandwidth_limit');
	$ws->write_string(7,8,$hash_data->{'relationship_bandwidth_limit'});
	
	$ws->write_string(9,7,'link_bandwidth_mbits');
	$ws->write_string(9,8,$hash_data->{'link_bandwidth_mbits'}) if (exists $hash_data->{'link_bandwidth_mbits'});
 	$ws->write_string(10,7,'background_copy_rate');
	$ws->write_string(10,8,$hash_data->{'background_copy_rate'}) if (exists $hash_data->{'background_copy_rate'});

	
	my $outr = 28;
	$ws->write_string($outr,0,'Remote SVC');
	$ws->write_string($outr,1,'partnership');
	$ws->write_string($outr,2,'type');
	$ws->write_string($outr,3,'code_level');
	$ws->write_string($outr,4,'host_delay');
	$ws->write_string($outr,5,'link_tolerance');
	$ws->write_string($outr,7,'relationship_bandwidth');
	$ws->write_string($outr,6,'link_bw');
	$ws->write_string($outr,8,'bg_copy_rate');
	$ws->write_string($outr,9,'console_IP');
	foreach my $cluster_id (keys %{$partner_data}) {
		if ($partner_data->{$cluster_id}{'location'} eq 'remote') {
			$outr++;
			$ws->write_string($outr,0,$partner_data->{$cluster_id}{'name'});
			$ws->write_string($outr,1,$partner_data->{$cluster_id}{'partnership'});
			$ws->write_string($outr,2,$partner_data->{$cluster_id}{'type'});
			$ws->write_string($outr,3,$partner_data->{$cluster_id}{'code_level'});
			$ws->write_string($outr,4,$partner_data->{$cluster_id}{'gm_max_host_delay'});
			$ws->write_string($outr,5,$partner_data->{$cluster_id}{'gm_link_tolerance'});
			$ws->write_string($outr,7,$partner_data->{$cluster_id}{'relationship_bandwidth_limit'});
			$ws->write_string($outr,6,$partner_data->{$cluster_id}{'link_bandwidth_mbits'});
			$ws->write_string($outr,8,$partner_data->{$cluster_id}{'background_copy_rate'});
			$ws->write_string($outr,9,$partner_data->{$cluster_id}{'console_IP'});
		} elsif ($partner_data->{$cluster_id}{'location'} eq 'local') {
			$ws->write_string(9,8,$partner_data->{$cluster_id}{'link_bandwidth_mbits'});
			$ws->write_string(10,8,$partner_data->{$cluster_id}{'background_copy_rate'});
		}
	}
	
}

sub create_worksheet ($) {
	
	my $wb = $_[0];
	my $rpt_name = $_[1];;
	my $hash_data = $_[2];
	
	logger(1,"****> Creating $rpt_name worksheet");
	my $ws = $wb->add_worksheet($rpt_name);
		
	my @cols = split(',',$ini_info{'svc'}{$rpt_name}{'cols'});
	my @col_fmt = split(';',rmblank($ini_info{'svc'}{$rpt_name}{'fmt'}));
	my @header = split(',',$ini_info{'svc'}{$rpt_name}{'header'});
	
	my $row = 0;
	my $col_num = 0;
	for (my $i=0;$i<@header;$i++) {
		my ($col_type,$col_width) = split(':',$col_fmt[$i],2);
		if ($col_type eq 'L4') {
			for (my $k=0;$k<4;$k++) {
				my @list_cols = split(':',$header[$i]);
				foreach my $col (@list_cols) {
					$ws->write_string($row,$col_num++,"$col-$k");
				}
			}
		} else {		
			$ws->set_column( $col_num,$col_num, $col_width);
			$ws->write_string($row,$col_num++,$header[$i]);
		}
	}
	$row++;	
	foreach my $id (sort keys %{$hash_data}) {
		my $col_num = 0;
		for (my $i=0;$i<@header;$i++) {
#			print "++1: $rpt_name / $row / $col_num / $col_fmt[$i] / $cols[$i] / $hash_data->{$id}{$cols[$i]} \n";
			if ($col_fmt[$i] =~ /^S/) {
				$ws->write_string($row,$col_num,$hash_data->{$id}{$cols[$i]}) if ((exists $hash_data->{$id}{$cols[$i]}) and ($hash_data->{$id}{$cols[$i]} ne ''));
				$col_num++;
			} elsif ($col_fmt[$i] =~ /^N/) {
				$ws->write_number($row,$col_num,$hash_data->{$id}{$cols[$i]}) if ((exists $hash_data->{$id}{$cols[$i]}) and ($hash_data->{$id}{$cols[$i]} ne '') );
				$col_num++;
			} elsif ($col_fmt[$col_num] =~ /^P/) {			
				$ws->write_number($row,$col_num,$hash_data->{$id}{$cols[$i]},$fmt_pct) if (exists $hash_data->{$id}{$cols[$i]});
				$col_num++;
			} elsif ($col_fmt[$col_num] =~ /^n/) {
				$ws->write_number($row,$col_num,$hash_data->{$id}{$cols[$i]},$fmt_size) if (exists $hash_data->{$id}{$cols[$i]});
				$col_num++;	
			} elsif ($col_fmt[$col_num] =~ /^L4/) {
				my @list_cols = split(':',$cols[$col_num]);
				my $sub_col = 0;
				for (my $indx=0;$indx<4;$indx++) {
					foreach my $col (@list_cols) {
						$ws->write_string($row,$col_num+$sub_col,$hash_data->{$id}{$col}{$indx}) if (exists $hash_data->{$id}{$col}{$indx});
						$sub_col++;
					}
				}
				$col_num += $sub_col;
			} else {
				$ws->write($row,$col_num++,$hash_data->{$id}{$cols[$i]});
			}
		}
#		sleep 1;
		$row++;
	}
	
	$ws->freeze_panes( 1, 1 );    # Freeze the first row
	#$ws->autofilter( 0, 0, $row, $col-1 );
	$ws->autofilter( 0, 0, 0, $#header );
}

sub create_errlog_ws ($) {

	my $wb = $_[0];
	my @errout = @{$_[1]};
	my @auditlog = @{$_[2]};
		
	logger(1,"****> Creating errlog worksheet");
	my $ws = $wb->add_worksheet('errlog');

	$ws->set_column( 0,0, 6);
	$ws->set_column( 2,5, 10);
	$ws->set_column( 6,6, 6);
	$ws->set_column( 13,13, 50);
	$ws->set_column( 14,14, 30);
	$ws->set_column( 16,16, 17);

	my $header = shift @errout;
#	my $audit_header = shift @auditlog;
	
	push (@errout,@auditlog);

	#
	#  before putting the data on the worksheet want to sort it
	#
	my @tokens = split(';',$header);
	my $col = 0;
	
	my $junk = shift @tokens;
	foreach my $item (@tokens) {		
		$ws->write_string(0,$col++,$item);
	}
	
	my $row = 1;
	foreach my $rec (sort @errout) {
		my @items = split(';',$rec);
		$junk = shift @items;
		my $col = 0;
		foreach my $item (@items){
			$ws->write_string($row,$col,$item) if ($item ne '');
			$col++;
		}
		$row++;
	}

	$ws->conditional_formatting('M:M',
		{
			type => 'text',
			criteria => 'containing',
			value => '985003',
			format => $infoFormat
		}
	);
	$ws->conditional_formatting('M:M',
		{
			type => 'text',
			criteria => 'containing',
			value => '10029',
			format => $warningFormat
		}
	);
	$ws->freeze_panes( 1, 1 );    # Freeze the first row
	#$ws->autofilter( 0, 0, $row, $col-1 );
	$ws->autofilter( 'A:S');
}

sub scan_svcout($) {
	#
	#  Scan svcout file from snap and parse svc commands
	#
	my $svcout_fn = shift;	
	my $t = basename($svcout_fn);
	my (undef,$svcout_ser,$svcout_date,$svcout_time) = split(/\./,basename($svcout_fn),4);
	$dt = "$svcout_date $svcout_time";
	logger(1,"**** Process SVC out file $svcout_fn dt=$dt");
			
	my $dt_parser = DateTime::Format::Strptime->new(
		pattern => '%y%m%d %H%M%S', 
		on_error => \&dt_error,
		zone_map => \%timezones
		);
	$ss_dt = $dt_parser->parse_datetime($dt);
	if (!defined $ss_dt) {
		logger(1,"*** Unable to parse Config XML timestamp, using current date");
		$ss_dt=localtime;
	}
	$cluster_info{'svcout_date'} = $ss_dt;
	$cluster_info{'svcout_ms'} = $svcout_ser;
	
	open (my $INFILE,'<',$svcout_fn) or warn "Problem opening svcout file $svcout_fn\n$!";
	my @indata = <$INFILE>;
	close ($INFILE);
	for (my $i=0;$i<@indata;$i++) {
		my $dd = trim($indata[$i]);
#		logger(1,"scan svcout: $i / $dd") if ($dd =~ /svcinfo/i);
		if ($dd =~ /svcinfo lsnode /i) {
			logger(1,"***+ Parsing lsnode - $i / $dd");
			$i = IBM::SVCTools->parse_lsoutput($i,\@indata,\%node_info);
		}
		if ($dd =~ /svcinfo lssystem /i) {
			logger(1,"***+ Parsing lssystem - $i / $dd");
			my %temp = ();
			$i = IBM::SVCTools->parse_output($i,\@indata,\%cluster_info,':');
		}
		if ($dd =~ /svcinfo lspartnership /i) {
			logger(1,"***+ Parsing lspartnership - $i / $dd");
			$i = IBM::SVCTools->parse_lsoutput($i,\@indata,\%partner_info);
		}
		if ($dd =~ /svcinfo lsvdisk /i) {
			logger(1,"***+ Parsing lsvdisk - $i / $dd") if ($dd =~ /[15]00$/);
			$i = IBM::SVCTools->parse_lsvdisk($i,\@indata,\%vdisk_info);
		}
		if ($dd =~ /svcinfo lshostvdiskmap /i) {
			logger(1,"***+ Parsing lshostvdiskmap - $i / $dd");
			$i = IBM::SVCTools->parse_lshostvdiskmap($i,\@indata,\%vdiskmap_info);
		}
		if ($dd =~ /svcinfo lsmdiskgrp /i) {
			logger(1,"***+ Parsing lsmdiskgrp - $i / $dd");
			$i = IBM::SVCTools->parse_lsoutput($i,\@indata,\%mdiskgrp_info);
		}
		if ($dd =~ /svcinfo lsmdisk /i) {
			logger(1,"***+ Parsing lsmdisk - $i / $dd") if ($dd =~ /10$/);
			$i = IBM::SVCTools->parse_lsoutput($i,\@indata,\%mdisk_info);
		}
		if ($dd =~ /svcinfo lsportfc /i) {
			logger(1,"***+ Parsing fcport - $i / $dd") if ($dd =~ /10$/);
			$i = IBM::SVCTools->parse_lsoutput($i,\@indata,\%fcport_info);
		}
#		if ($dd =~ /svcinfo lsnodevpd /i) {$i = IBM::SVCTools->parse_lsnodevpd($i,\@indata,\%node_info);}
		if ($dd =~ /svcinfo lscontroller /i) {
			logger(1,"***+ Parsing lscontroller - $i / $dd") if ($dd =~ /0$/);
			$i = IBM::SVCTools->parse_lscontroller($i,\@indata,\%cntrl_info);
		}
		if ($dd =~ /^svcinfo lshost /i) {
			logger(1,"***+ Parsing lshost - $i / $dd") if ($dd =~ /10$/);
			$i = IBM::SVCTools->parse_lshost($i,\@indata,\%host_info);
		}
		if ($dd =~ /^svcinfo lsrcrelationship /) {
			logger(1,"***+ Parsing lsrcrelationship - $i / $dd");
			$i = IBM::SVCTools->parse_lsoutput($i,\@indata,\%rcmap_info);
		}
		if ($dd =~ /^svcinfo lsrcconsistgrp /) {
			$i = IBM::SVCTools->parse_lsoutput($i,\@indata,\%rcgrp_info);
		}
	}
}

sub  trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };

sub logger {
	my ($level, $msg) = @_;
	chomp $msg;
	if ($level  < 2) {print "$msg\n";}
	if ($level  <= $verbose) {print $LOGFILE "$msg\n";}
}

sub disp_to_GB($) {
	my $size = $_[0];
	if ($size =~ /KB/) {$size = substr($size,0,length($size)-2) / 1024 / 1024;}
	if ($size =~ /MB/) {$size = substr($size,0,length($size)-2) / 1024;}
	if ($size =~ /GB/) {$size = substr($size,0,length($size)-2) }
	if ($size =~ /TB/) {$size = substr($size,0,length($size)-2) * 1024;}
	if ($size =~ /PB/) {$size = substr($size,0,length($size)-2) * 1024 * 1024;}	
	return $size;
}

sub size_to_disp ($) {
	my $size = $_[0];	
	if ($size > $CONVERT_TO_TB) {$size = sprintf("%.1f TB",$size/$CONVERT_TO_TB)}
	elsif ($size > $CONVERT_TO_GB) {$size = sprintf("%.1f GB",$size/$CONVERT_TO_GB)}
	elsif ($size > $CONVERT_TO_MB) {$size = sprintf("%.1f MB",$size/$CONVERT_TO_MB)}
	return $size;
}

sub size_to_GB ($) {
	my $size = $_[0];	
	$size = $size / 1024 / 1024;
	return $size;
}

sub rmblank {
	my $string = shift;
	$string =~ s/\s+//g;
	return $string;
}

sub dt_error($) {
	logger(0,"strptime_error: $_[1]\ndt==>$dt<==\npattern==>$dt_pattern\n");
	true;
}

sub xmlparser_start_handler {
	my( $p, $el, %attrs ) = @_;

	if ( $el eq "xml") {
		$dt = $attrs{"timestamp"};		
		logger(1,"SS Date= $dt");

#			pattern => '%Y/%m/%d %T %Z', 		
		my $dt_parser = DateTime::Format::Strptime->new(
			pattern => '%Y/%m/%d %T',
			on_error => \&dt_error,
			zone_map => \%timezones
			);

		$ss_dt = $dt_parser->parse_datetime($dt);
		if (!defined $ss_dt) {
			logger(1,"*** Unable to parse Config XML timestamp, using current date");
			$ss_dt=localtime;
		}
		$cluster_info{'xml_date'} = $ss_dt;
	}
	if ( $el eq "object") {
		$rectype = $attrs{type};
	}
	if ( $el eq 'property') {
		if ( $attrs{value} ne '' ) {
			if (($rectype eq 'vdiskextent') or ($rectype eq 'sevdiskcopy') or ($rectype eq 'vdiskaccess')) {
#				logger(3,"xml: Junk rec $rectype")
			} elsif ($rectype eq 'vdisk') {
				if ($attrs{'name'} eq 'copy_id') {$vdisk_copyid = $attrs{'value'};}
				if ($vdisk_copyid eq 0) {
					$vdiskdata0{$attrs{'name'}} = $attrs{'value'};
				} elsif ($vdisk_copyid eq 1) {
					$vdiskdata1{$attrs{'name'}} = $attrs{'value'};
				} else {
					$vdiskdata{$attrs{'name'}} = $attrs{'value'};
				}
				
			} elsif ($rectype eq 'mdisk') {
				if ($attrs{name} eq "id") {
					$mdisk_id = sprintf("%04d",$attrs{'value'});
				} else {
					$mdisk_info{$mdisk_id}{$attrs{'name'}} = $attrs{'value'};
				}
			} elsif ($rectype eq 'rcrelationship') {
					$rcmap{$attrs{'name'}} = $attrs{'value'};
			} elsif ($rectype eq 'host') {
				if ($attrs{name} eq 'id') {
					$host_id = sprintf("%04d",$attrs{value});
				} elsif ($attrs{name} eq 'WWPN') {
					$host_info{$host_id}{$attrs{name}}{++$hostport_indx} = $attrs{value};
				} elsif ($attrs{name} eq 'node_logged_in_count') {
					$host_info{$host_id}{$attrs{name}}{$hostport_indx} = $attrs{value};
				} elsif ($attrs{name} eq 'state') {
					$host_info{$host_id}{$attrs{name}}{$hostport_indx} = $attrs{value};
				} else {
					$host_info{$host_id}{$attrs{name}} = $attrs{value};
				}
			} elsif ($rectype eq 'rcconsistgrp') {
					$rcgrp{$attrs{name}} = $attrs{value};
			} elsif ($rectype eq 'fcconsistgrp') {
				$fcgrp{$attrs{name}} = $attrs{value};
			} elsif ($rectype eq 'fcmap') {	
				$fcmap{$attrs{name}} = $attrs{value};
			} elsif ($rectype eq 'vdiskhostmap') {
				if ($attrs{'name'} eq 'name') {$vdiskmap{'vdisk_name'} = $attrs{'value'};}
				elsif ($attrs{'name'} eq 'host_name') {$vdiskmap{'name'} = $attrs{'value'};}
				else {$vdiskmap{$attrs{'name'}} = $attrs{'value'};}
			} elsif ($rectype eq "drive") {	
				if ($attrs{name} eq "id") {
					$drive_id = sprintf("%04d",$attrs{value});
				} else {
					$drive_info{$drive_id}{$attrs{name}} = $attrs{value};
				}
			} elsif ($rectype eq 'mdisk_grp') {
				if ($attrs{name} eq 'id') {
					$mdiskgrp_id = 	sprintf("%04d",$attrs{value});
					$mdiskgrp_info{$mdiskgrp_id}{$attrs{name}} = $attrs{value};
				} elsif ($attrs{name} eq "capacity") {
					$mdiskgrp_info{$mdiskgrp_id}{$attrs{name}} = $attrs{value};
					$mdiskgrp_info{$mdiskgrp_id}{"raw_capacity"} = $attrs{value};
				} elsif ($attrs{name} eq "tier") {
					$mdiskgrp_info{$mdiskgrp_id}{$attrs{name}.++$mdiskgrptier_indx} = $attrs{value};
				} elsif ($attrs{name} eq "tier_mdisk_count") {
					$mdiskgrp_info{$mdiskgrp_id}{$attrs{name}.$mdiskgrptier_indx} = $attrs{value};
				} elsif ($attrs{name} eq "tier_capacity") {
					$mdiskgrp_info{$mdiskgrp_id}{$attrs{name}.$mdiskgrptier_indx} = $attrs{value};
				} elsif ($attrs{name} eq "tier_free_capacity") {
					$mdiskgrp_info{$mdiskgrp_id}{$attrs{name}.$mdiskgrptier_indx} = $attrs{value};
				} else {
					$mdiskgrp_info{$mdiskgrp_id}{$attrs{name}} = $attrs{value};
				}
			} elsif ($rectype eq 'portfc') {
					$portfc{$attrs{name}} = $attrs{value};
			} elsif ($rectype eq 'node') {
				if ($attrs{name} !~ /port_/) {
					$nodedata{$attrs{name}} = $attrs{value};
				}
			} elsif ($rectype eq "cluster") {
				if ($attrs{name} eq "id") {
					$cluster_num = $attrs{value};
#					$cluster_id = sprintf("%02d",++$clusterid_indx);
					$cluster_id = $attrs{value};
					$cluster_info{'id'} = $attrs{value};
#					$cluster_idnum{$cluster_num} = $cluster_id;
				} elsif ($attrs{name} eq "name") {
					$cluster_name = $attrs{value};
					$cluster_info{$attrs{name}} = $attrs{value};
				} elsif ($attrs{name} eq "location") {
					if ($attrs{value} eq "local") {
						$lcluster = $cluster_name;
						logger(1,"Local Cluster is $lcluster");
					} elsif ($attrs{value} eq "remote") {
						$rcluster = $cluster_name;
						logger(1,"Remote Cluster is $rcluster");
					}
					$cluster_info{$attrs{name}} = $attrs{value};
				} elsif ($attrs{name} eq "tier") {
					$cluster_info{$attrs{name}.++$tier_indx} = $attrs{value};
				} elsif ($attrs{name} eq "tier_capacity") {
					$cluster_info{$attrs{name}.$tier_indx} = $attrs{value};
				} elsif ($attrs{name} eq "tier_free_capacity") {
					$cluster_info{$attrs{name}.$tier_indx} = $attrs{value};
				} else {
					$cluster_info{$attrs{name}} = $attrs{value};
				}
			} elsif ($rectype eq "clusterip") {
				if ($attrs{name} eq "cluster_id") {
					$clusterip_id = ++$clusterip_indx;
					$clusterip_info{$clusterip_id}{"cluster_id"}="0x".$attrs{value};
				} else {
					$clusterip_info{$clusterip_id}{$attrs{name}} = $attrs{value};
				}
			} elsif ($rectype eq "controller") {
				if ($attrs{name} eq "id") {
					$cntrl_id = $attrs{value};
				} elsif ($attrs{name} eq "WWPN") {
					$cntrl_info{$cntrl_id}{$attrs{name}.++$cntrlport_indx} = $attrs{value};
				} elsif ($attrs{name} eq "path_count") {
					$cntrl_info{$cntrl_id}{$attrs{name}.$cntrlport_indx} = $attrs{value};
				} elsif ($attrs{name} eq "max_path_count") {
					$cntrl_info{$cntrl_id}{$attrs{name}.$cntrlport_indx} = $attrs{value};
				} else {
					$cntrl_info{$cntrl_id}{$attrs{name}} = $attrs{value};
				}
			} elsif ($rectype eq 'node_ethernet_portip_ip') {
				$etherport{$attrs{name}} = $attrs{value};
			} elsif ($rectype eq "quorum") {
				if ($attrs{name} eq "quorum_index")	{
					$quorum_id = $attrs{value};
				} else {
					$quorum_info{$quorum_id}{$attrs{name}} = $attrs{value};
				}
			} elsif ($rectype eq "emailserver") {
				if ($attrs{name} eq "id") {
					$smtp_id = "S".$attrs{value};
					$email_info{$smtp_id}{id} = $smtp_id;
				} elsif ($attrs{name} eq "IP_address") {
					$email_info{$smtp_id}{"address"} = $attrs{value};
				} elsif ($attrs{name} eq "port") {
					$email_info{$smtp_id}{"user_type"} = $attrs{value};
				} else {
					$email_info{$smtp_id}{$attrs{name}} = $attrs{value};
				}
			} elsif ($rectype eq "emailuser") {
				if ($attrs{name} eq "id") {
					$email_id = sprintf("%02d",$attrs{value});
					$email_info{$email_id}{id} = $attrs{value};
				} else {
					$email_info{$email_id}{$attrs{name}} = $attrs{value};
				}
			} elsif ($rectype eq "user") {
				if ($attrs{name} eq "id") {
					$user_id = sprintf("%02d",$attrs{value});
					$user_info{$user_id}{id} = $attrs{value};
				} else {
					$user_info{$user_id}{$attrs{name}} = $attrs{value};
				}
			} elsif ($rectype eq "io_grp") {
				if ($attrs{name} eq "id") {
					$iog_id = sprintf("%02d",$attrs{value});
					$iog_info{$iog_id}{id} = $attrs{value};
				} else {
					$iog_info{$iog_id}{$attrs{name}} = $attrs{value};
#					logger(1,"xml_iog: $iog_id / $attrs{name} / $attrs{value}");
				}
			} else {
#				logger(1,"xml: unprocess rec type $rectype");
			}
			
		}
	}
}

sub xmlparser_end_handler {
	my( $p, $el ) = @_;
	if ( $el eq "object") {
		if ($rectype eq 'node') {
			my $node_id = sprintf("%04d",$nodedata{'id'});
			$node_info{$node_id} = {%nodedata};
#			if (!exists $node_iog{$node_id}) {
#				my $iog = $node_info{$node_id}{"IO_group_id"};
#				my $pnode_id = $node_info{$node_id}{"partner_node_id"};
#				$node_iog{$node_id} = $iog."a";
#				$node_iog{$pnode_id} = $iog."b";
#			}
			$port_indx = -1;
			$port_nindx++;
			%nodedata = ();
		}
		if ($rectype eq "clusterip") {
			$clusterip_info{$clusterip_id}{"id"} = $clusterip_id;
			$clusterip_id = "";
		} elsif ($rectype eq "vdisk") {			
			my $vdisk_id = sprintf("%04dP",$vdiskdata{'id'});
			if (exists $vdiskdata0{'copy_id'}) {
				if ($vdiskdata0{'primary'} eq 'yes') {
					$vdisk_info{$vdisk_id} = {%vdiskdata, %vdiskdata0};
				} else {
					my $vdisk_id2 = sprintf("%04dS",$vdiskdata{'id'});
					$vdisk_info{$vdisk_id2} = {%vdiskdata0};
					$vdisk_info{$vdisk_id2}{'id'} = $vdiskdata{'id'};
					$vdisk_info{$vdisk_id2}{'name'} = $vdiskdata{'name'};
					$vdisk_info{$vdisk_id2}{'copy_count'} = $vdiskdata{'copy_count'};
				}
			}
			if (exists $vdiskdata1{'copy_id'}) {
				if ($vdiskdata1{'primary'} eq 'yes') {
					$vdisk_info{$vdisk_id} = {%vdiskdata, %vdiskdata1};
				} else {
					my $vdisk_id2 = sprintf("%04dS",$vdiskdata{'id'});
					$vdisk_info{$vdisk_id2} = {%vdiskdata1};
					$vdisk_info{$vdisk_id2}{'id'} = $vdiskdata{'id'};
					$vdisk_info{$vdisk_id2}{'name'} = $vdiskdata{'name'};
					$vdisk_info{$vdisk_id2}{'copy_count'} = $vdiskdata{'copy_count'};
				}
			}
			%vdiskdata = ();
			%vdiskdata0 = ();
			%vdiskdata1 = ();
			$vdisk_copyid = '';
		} elsif ($rectype eq "rcrelationship") {
			my $rc_id = sprintf("%04d",$rcmap{'id'});
			$rcmap_info{$rc_id} = {%rcmap};
			%rcmap = ();
			my $rc_vdisk_id = sprintf("%04d",$rc_info{$rc_id}{'master_vdisk_id'});
#			$vdisk_info{$rc_vdisk_id}{'rc_id'} = $rc_id;
#			$vdisk_info{$rc_vdisk_id}{'rc_name'} = $rc_info{$rc_id}{'name'};
#			$vdisk_info{$rc_vdisk_id}{'cg_id'} = $rc_info{$rc_id}{'consistency_group_id'};
#			$vdisk_info{$rc_vdisk_id}{'cg_name'} = $rc_info{$rc_id}{'consistency_group_name'};
		} elsif ($rectype eq 'rcconsistgrp') {
			my $id = sprintf("%04d",$rcgrp{'id'});
			$rcgrp_info{$id} = {%rcgrp};
			%rcgrp = ();
		} elsif ($rectype eq 'fcconsistgrp') {
			my $fc_id = sprintf("%04d",$fcgrp{'id'});
			$fcgrp_info{$fc_id}= {%fcgrp};
			%fcgrp = ();
		} elsif ($rectype eq 'fcmap') {
			my $fcmap_id =  sprintf("%04d",$fcmap{'id'});
			$fcmap_info{$fcmap_id}= {%fcmap};
			%fcmap = ();
		} elsif ($rectype eq 'portfc') {
			my $id =  sprintf("%04d",$portfc{'id'});
			$fcport_info{$id}= {%portfc};
			%portfc = ();
		} elsif ($rectype eq "quorum") {
			$quorum_info{$quorum_id}{"id"} = $quorum_id;
			$quorum_id = "";
		} elsif ($rectype eq 'vdiskhostmap') {
		
			my $map_id = "$vdiskmap{'host_id'}-$vdiskmap{'vdisk_id'}";
			$vdiskmap_info{$map_id} = {%vdiskmap};
			$vdiskmap = ();
		
#			$vdiskmap_info{$vdiskmap_id}{"id"}=$vdiskmap_id;
#			$vdisk_id = $vdiskmap_info{$vdiskmap_id}{"vdisk_id"};
#			$mdisk_id = $vdisk_info{$vdisk_id}{"mdisk_grp_id"};
#			$pref_node = $vdisk_info{$vdisk_id}{"preferred_node_id"};
#			$iogrp = $node_info{$pref_node}{"IO_group_id"};
#			$iogrp_indx = $node_iog{$pref_node};
#			my $host_id = $vdiskmap_info{$vdiskmap_id}{"host_id"};
#			$vdiskmap_info{$vdiskmap_id}{"capacity"} = $vdisk_info{$vdisk_id}{"capacity"};
#			$vdiskmap_info{$vdiskmap_id}{"mdisk_grp_name"} = $vdisk_info{$vdisk_id}{"mdisk_grp_name"};
#			$vdiskmap_info{$vdiskmap_id}{"mdisk_grp_id"} = $mdisk_id;
#			$vdiskmap_info{$vdiskmap_id}{"preferred_node_id"} = $pref_node;
#			$vdiskmap_info{$vdiskmap_id}{"IO_group_id"} = $iogrp;
#			$host_info{$host_id}{$iogrp_indx}++;


#			$vdiskmap_list{$vdiskmap_info{$vdiskmap_id}{name}} = $vdiskmap_id;
#			$vdiskmap_id = "";
		} elsif ($rectype eq "mdisk") {
			$mdisk_info{$mdisk_id}{"id"} = $mdisk_id;
			$mdisk_id = "";
		} elsif ($rectype eq "drive") {
			$drive_info{$drive_id}{"id"} = $drive_id;
			$drive_id = "";
		} elsif ($rectype eq "mdisk_grp") {
			$mdiskgrp_info{$mdiskgrp_id}{"id"} = $mdiskgrp_id;
			my $real_size = $mdiskgrp_info{$mdiskgrp_id}{"capacity"};
			my $ext_size = $mdiskgrp_info{$mdiskgrp_id}{"extent_size"}*1024*1024;
			my $num_extents = 0;
			if ($ext_size > 0) {
				$num_extents = $real_size / $ext_size;
			}
			$mdiskgrp_info{$mdiskgrp_id}{"cap_extents"} = $num_extents;
			$mdiskgrp_id = "";
			$mdiskgrptier_indx = -1;
		} elsif ($rectype eq "host") {
			$host_info{$host_id}{"id"} = $host_id;
#			$host_info{$host_id}{"0a"} = 0;
#			$host_info{$host_id}{"0b"} = 0;
#			$host_info{$host_id}{"1a"} = 0;
#			$host_info{$host_id}{"1b"} = 0;
#			$host_info{$host_id}{"2a"} = 0;
#			$host_info{$host_id}{"2b"} = 0;
#			$host_info{$host_id}{"3a"} = 0;
#			$host_info{$host_id}{"3b"} = 0;
			$host_id = "";
			$hostport_indx = -1;
		} elsif ($rectype eq "controller") {
			$cntrl_info{$cntrl_id}{"id"} = $cntrl_id;
			$cntrl_id = "";
			$cntrlport_indx = -1;
		} elsif ($rectype eq "node_ethernet_portip_ip") {
			my $id = sprintf("%02d-%01d-%01d",$etherport{'node_id'},$etherport{'adapter_location'},$etherport{'adapter_port_id'});
			$etherport_info{$id} = {%etherport};
			%etherport = ();
		} elsif ($rectype eq "emailserver") {
			$smtp_id = "";
		} elsif ($rectype eq "emailuser") {
			$email_id = "";
		} elsif ($rectype eq "user") {
			$user_id = "";
		} elsif ($rectype eq "iog") {
			$iog_id = "";
		}
	}
}

sub process_audit($) {

	my $audit_fn = shift;
	my @audit_data;
	logger(1,"Process audit log $audit_fn");
	
	open (my $INFILE,'<',$audit_fn) or warn "Problem opening Audit file $audit_fn\n$!";;
	my @indata = <$INFILE>;
	close ($INFILE);

	my $date_parser = DateTime::Format::Strptime->new(
		pattern => "%y%m%d%H%M%S",
		on_error => \&dt_error,
	);
	
	my $junk = shift @indata;
	my $header = shift @indata;
	foreach my $rec (@indata) {
		my $dd = trim($rec);
		if ($dd eq ''){next;};
		my @tokens = split(":",$dd,7);
		$dt = $tokens[1];
		my $t = $date_parser->parse_datetime($dt);
		$outl = sprintf("%s;A;%s;%s;%s;;;",$t,$tokens[0],$t->ymd,$t->hms);
		for (my $j=2; $j<6; $j++) {
				$outl .= ";$tokens[$j]";
		}
		$outl .= ";;;$tokens[6]";
		push @audit_data,$outl;
	}
	return @audit_data;
}

sub process_errlog($) {

	my $errlog_fn = shift;
	my $GM1920;
	my @errout;
	my @sense;
	logger(1,"Process errlog file $errlog_fn");
	
	open (INFILE,'<',$errlog_fn) or die "Problem opening errlog file $errlog_fn\n $!";
	@indata = <INFILE>;
	close (INFILE);

	my $date_parser = DateTime::Format::Strptime->new(
		pattern => "%A %B %d %T %Y",
		on_error => 'croak',
	);

	push @errout,'dt;Type;Seq;Date;Time;F Date;F Time;Cnt;Node;Object;Obj ID;Name;Err Code;err ID;Err ID msg;Info;skcq;wwpn;pid;wwnn/sense;err code msg';

	my $rec_cnt = 0;
	for (my $i=1;$i<@indata-1;$i++) {
		my $dd = trim($indata[$i]);
		if ($rec_cnt++ > 10000) {
			print "Processed $i records. \n";
			$rec_cnt = 0;
		}
		if ($dd =~ /^Error Log Entry/) {
			$lognum = trim(substr($dd,17,8));
		}
		if ($dd =~ /^Node Identifier/) {
			$node = trim(substr($dd,index($dd,":")+1));
		}
		if ($dd =~ /^Object Type/) {
			$otype = trim(substr($dd,index($dd,":")+1));
		}
		if ($dd =~ /^Object ID /) {
			$oid = trim(substr($dd,index($dd,":")+1));
		}
		if ($dd =~ /^Status Flag /) {
			my @toks = split(/:/,$dd,2);
			$status = $toks[1];
		}
		if ($dd =~ /^Error Count /) {
			$err_cnt = trim(substr($dd,index($dd,":")+1));
		}
		if ($dd =~ /^Sequence Number/) {
			$seqnum = trim(substr($dd,index($dd,":")+1));
		}
		if ($dd =~ /^Error ID /) {
			$errid_msg = trim(substr($dd,index($dd,":")+1));
			if ($errid_msg =~ /:/) {
				@tokens = split(":",$errid_msg);
				$errid = trim($tokens[0]);
				$errid_msg = $tokens[1];
			} else {
				$errid = "";
			}
		}
		if ($dd =~ /^Error Code /) {
			$errcode_msg = trim(substr($dd,index($dd,":")+1));
			if ($errcode_msg=~ /:/) {
				@tokens = split(":",$errcode_msg);
				$errcode = trim($tokens[0]);
				$errcode_msg = $tokens[1];
			} else {
			$errcode = "";
			}
		}
		if ($dd =~ /^First Error Timestamp /) {
			my $tmp = trim(substr($dd,index($dd,":")+1));
			$first_dt = $date_parser->parse_datetime($tmp);
			$ferrdate = $first_dt->ymd;
			$ferrtime = $first_dt->hms;
		}
		if ($dd =~ /^Last Error Timestamp /) {
			my $tmp = trim(substr($dd,index($dd,":")+1));
			$last_dt = $date_parser->parse_datetime($tmp);
			$errdate = $last_dt->ymd;
			$errtime = $last_dt->hms;
			if ($last_dt eq $first_dt) {
				$ferrdate = "";
				$ferrtime = "";
			}
		}
		if ($dd =~ /^Type Flag /) {
			$errtype = trim(substr($dd,index($dd,":")+1,2));
			for (my $ii=0;$ii<9;$ii++) {
				$sense[$ii] = rmblank($indata[$i+$ii+2])
			}
			@s1 = split(' ',trim($indata[$i+2]));
			@s2 = split(' ',trim($indata[$i+3]));
			@s3 = split(' ',trim($indata[$i+4]));
			@s4 = split(' ',trim($indata[$i+5]));
			@s5 = split(' ',trim($indata[$i+6]));
			@s6 = split(' ',trim($indata[$i+7]));
			@s7 = split(' ',trim($indata[$i+8]));
			@s8 = split(' ',trim($indata[$i+9]));
			$wwnn = "";
			$wwpn = "";
			$add_info = "";
			$skcq="";
			$prt_it = true;
				if ($otype eq "vdisk") {
				my $tmp= sprintf("%04d",$oid);
				$oname = $vdisk_info{$tmp}{"name"};
			} elsif ($otype eq "mdisk") {
				my $tmp= sprintf("%04d",$oid);
				$oname = $mdisk_info{$tmp}{"name"};
			} elsif ($otype eq "node") {
				$oname = $node_info{$oid}{"name"};
			} elsif ($otype eq "host") {
				$oname = $host_info{$oid}{"name"};
			} elsif ($otype eq "rcmap") {
				$oname = $rc_info{$oid}{"name"};
			} elsif ($otype eq "device") {
				$oname = $cntrl_info{$oid}{"controller_name"};
			} elsif ($otype eq "drive") {
				my $tmp= sprintf("%04d",$oid);
				$oname = $drive_info{$tmp}{"enclosure_id"}."/".$drive_info{$tmp}{"slot_id"}."-".$drive_info{$tmp}{"mdisk_name"};
			} else {
				$oname="";
			}
			if ($errid eq "10003") {
				&parse_10003;
			} elsif ($errid eq "10011")	{
				&parse_10011;
			} elsif ($errid eq "10013")	{
				&parse_10013;
			} elsif ($errid eq "10017")	{
				&parse_10017;
			} elsif ($errid eq "10018")	{
				&parse_10018;
			} elsif ($errid eq "10025")	{
				&parse_10025;
			} elsif ($errid eq "10029") {
				&parse_10029;
			} elsif ($errid eq "10030")	{
				&parse_10030;
			} elsif ($errid eq "50010")	{
				&parse_50010;
			} elsif ($errid eq "50030")	{
				&parse_50030;
			} elsif ($errid eq "74002") {
				my $ttt = '';
				for (my $ii=0;$ii<7;$ii++) {
					$ttt .= $sense[$ii];
				}
				$add_info = pack('H*',$ttt);
			} elsif ($errid eq "980440") {
				$errtype = "I2";
			} elsif ($errid eq "981001") {
				$errtype = "I2";
			} elsif ($errid =~ /98100[234]/) {
				&parse_981002 if ($errid eq '981002');
			} elsif ($errid eq "985003") {
				&parse_985003;
			} elsif ($errid eq "987301") {
				&parse_987301;
			}
			if ($prt_it) {
				push @errout,"$last_dt;$errtype;$seqnum;$errdate;$errtime;$ferrdate;$ferrtime;$err_cnt;$node;$otype;$oid;$oname;$errcode;$errid;$errid_msg;$add_info;$skcq;$wwpn;$wwpn_pid{$wwpn};$wwnn;$errcode_msg;$status";
				if ($errid eq "985003")	{
					my @toks = split(" / ",$add_info);
					my @toks2 = split(" / ",$wwpn);
					my $date2 = $errdate." ".$errtime;
#					print $GM1920 "cluster,$node,$toks[1],$date2,$errdate,$errtime,$err_cnt,$oname,$toks[0],$toks2[0],$toks2[1]\n";
				}
				$status="";
				$errcode="";
				$errid="";
				$errid_msg="";
			}
		}
	}
	return @errout;
}

sub parse_10003 {
	$wwpn = $s2[7].$s2[6].$s2[5].$s2[4].$s2[3].$s2[2].$s2[1].$s2[0];
	$wwnn = $s1[15].$s1[14].$s1[13].$s1[12].$s1[11].$s1[10].$s1[9].$s1[8];
}

sub parse_10011 {
	$wwpn = $s2[7].$s2[6].$s2[5].$s2[4].$s2[3].$s2[2].$s2[1].$s2[0];
}

sub parse_10013 {
	$wwpn = $s2[7].$s2[6].$s2[5].$s2[4].$s2[3].$s2[2].$s2[1].$s2[0];
	$pid  = $s2[10].$s2[9].$s2[8];
	$skcq = $s4[1].$s4[2].$s4[3];
	$c1 = $s8[12]." ".$s8[13]." ".$s8[15];
	if ($s4[0] =~ /02/) {
		$add_info = "";
	}
	if ($s4[0] =~ /18/) {
		$add_info = "SCSI Reservation Conflict";
	}
	if ($s1[11] =~ /02/ and $s1[12]=~/28/) {
		$add_info = "Data Underrun";
	}
	if ($skcq eq "000000") {
		if ($s8[8] =~ /46/) {
			$add_info = "SCSI Check - Command drop";
		}
	}
}

sub parse_10017 {
	$wwpn = $s2[7].$s2[6].$s2[5].$s2[4].$s2[3].$s2[2].$s2[1].$s2[0];
}

sub parse_10018 {
	$sk_desc="";
	$wwpn = $s8[7].$s8[6].$s8[5].$s8[4].$s8[3].$s8[2].$s8[1].$s8[0];
	$skcq = $s4[1].$s4[2].$s4[3];
	$cdb = $s1[12].$s1[13].$s1[14].$s1[15];
	$op_code = $s1[12];
	$erp = $s3[0];
	$erp_flag = $s7[12];
	$bytes_req = $s2[14].$s2[15];
	$bytes_rec = $s3[5].$s3[6];

	if ($s1[0] =~ /40/) {
		$lun = $s1[1].$s1[3];
	} else {
		$lun = $s1[0].$s1[1].$s1[2].$s1[3];
	}
	if ($s4[0] =~ /02/) {
		$sk_desc = skcq_desc($skcq);
		if ($skcq =~ /052500/) {$errtype="T2";}
        if ($skcq =~ /062900/) {$errtype="T2";}
        if ($skcq =~ /062A01/) {$errtype="T2";}
        if ($skcq =~ /0B2500/) {$errtype="T2";}
	}

	$wwnn=$sk_desc;
	$add_info = "OP=".$op_code." ERP=".$erp."/".$erp_flag." LUN=".$lun;
}

sub parse_10025 {
	if  ($s1[0] !~ /00/) {
		$wwpn = $s8[7].$s8[6].$s8[5].$s8[4].$s8[3].$s8[2].$s8[1].$s8[0];
		$lba = $s6[11].$s6[10].$s6[9].$s6[8];
		$cdb = $s1[12].$s1[13].$s1[14].$s1[15].$s2[0].$s2[1].$s2[2].$s2[3].$s2[4].$s2[5].$s2[6].$s2[7];
#		$max_count = $s1[10];
#		$port = "P" + substr($port,1,1);
		$add_info = "LBA=".$lba." CDB=".$cdb;
	}
}

sub parse_10029 {
	if  ($s1[0] !~ /00/) {
		$wwpn = $s1[7].$s1[6].$s1[5].$s1[4].$s1[3].$s1[2].$s1[1].$s1[0];
		$port = $s1[8];
		$count = $s1[9];
		$max_count = $s1[10];
		$port = "P" + substr($port,1,1);
		$add_info = "Dropped Frames ".$count." / ".$max_count;
	}
}

sub parse_10030 {
#	$prt_it = false;
	for (my $i=0; $i<4; $i++) {
		if ($i ==0) {@sense = @s1;}
		if ($i ==1) {@sense = @s2;}
		if ($i ==2) {@sense = @s3;}
		if ($i ==3) {@sense = @s4;}
		my $sk_desc="";
		if ($sense[0] =~ /02/ ) {
			$skcq = $sense[1].$sense[2].$sense[3];
			$port = $sense[4];
			$cntrl = $sense[5];
			$cnt  = $sense[7].$sense[6];
			$sk_desc=skcq_desc($skcq);
			$port = "P".substr($port,1,1)."/".$cntrl;
			$wwnn = $sk_desc;
			$add_info = "count=".$cnt." / Port=".$port;
#			if ($skcq ne "000000") {
#				print OUTFILE "$errtype,$seqnum,$errdate,$errtime,$ferrdate,$ferrtime,$err_cnt,$node,$otype,$oid,$oname,$errcode,$errid,\"$errid_msg\",$add_info,$skcq,$wwpn,$wwpn_pid{$wwpn},$wwnn,$errcode_msg\n";
#			}
		}
		$sk_desc="";
		if ($sense[8] =~ /02/ ) {
			$skcq = $sense[9].$sense[10].$sense[11];
			$port = $sense[12];
			$cntrl = $sense[13];
			$cnt  = $sense[15].$sense[14];
			$sk_desc=skcq_desc($skcq);
			$port = "P".substr($port,1,1)."/".$cntrl;
			$wwnn = $sk_desc;
			$add_info = "count=".$cnt." / Port=".$port;
#			if ($skcq ne "000000") {
#				print OUTFILE "$errtype,$seqnum,$errdate,$errtime,$ferrdate,$ferrtime,$err_cnt,$node,$otype,$oid,$oname,$errcode,$errid,\"$errid_msg\",$add_info,$skcq,$wwpn,$wwpn_pid{$wwpn},$wwnn,$errcode_msg\n";
#			}
		}
	}
}

sub parse_10032 {
	$reason = "";
	for (my $i=0; $i<16; $i++) {
		if ($s3[$i] ne "00") {
			$reason = $reason.hex_to_ascii($s3[$i]);
		}
	}
	for (my $i=0; $i<16; $i++) {
		if ($s4[$i] ne "00") {
			$reason = $reason.hex_to_ascii($s4[$i]);
		}
	}
	$add_info = $reason;
	$wwpn = $s2[7].$s2[6].$s2[5].$s2[4].$s2[3].$s2[2].$s2[1].$s2[0];
}

sub parse_50010 {
	$add_info = "GM Threshold exceeded see 985003 for details";
}

sub parse_50020 {
	$add_info = "MM loss of sync see 978301 for details";
}

sub parse_50030 {
	$add_info = "??";
}

sub parse_74002 {
	$reason = "";
	for (my $i=0; $i<16; $i++) {
#	print "+-+-+-+-+\n";
#	print Dumper @s1;
		if ($s1[$i] ne "00") {
			$reason = $reason.hex_to_ascii($s1[$i]);
		}
	}
	for (my $i=0; $i<16; $i++) {
		if ($s2[$i] ne "00") {
			$reason = $reason.hex_to_ascii($s2[$i]);
		}
	}
	for (my $i=0; $i<16; $i++) {
		if ($s3[$i] ne "00") {
			$reason = $reason.hex_to_ascii($s3[$i]);
		}
	}
	for (my $i=0; $i<16; $i++) {
		if ($s4[$i] ne "00") {
			$reason = $reason.hex_to_ascii($s4[$i]);
		}
	}
	for (my $i=0; $i<16; $i++) {
		if ($s5[$i] ne "00") {
			$reason = $reason.hex_to_ascii($s5[$i]);
		}
	}
	$add_info = $reason;	
	print "==> $reason\n";
}

sub parse_985003 {
	my $rcmap_id = sprintf("%04d",$oid);
	my $vdisk_id = sprintf("%04dP",$rcmap_info{$rcmap_id}{'master_vdisk_id'});
	$oname = $rcmap_info{$rcmap_id}{'master_vdisk_name'};
	$skcq = "$vdisk_info{$vdisk_id}{'preferred_node_id'}-$vdisk_info{$vdisk_id}{'IO_group_id'}";
	$add_info = "$rcmap_info{$rcmap_id}{'aux_cluster_name'} / $rcmap_info{$rcmap_id}{'aux_vdisk_name'}";
}

sub parse_981002 {
	$errtype = "I2";
	$n1 = $s2[9].$s2[8];
	$n2 = $s2[11].$s2[10];
	$n3 = $s2[13].$s2[12];
	$n4 = $s2[15].$s2[14];
	$n5 = $s3[1].$s3[0];
	$n6 = $s3[3].$s3[2];
	$n7 = $s3[5].$s3[4];
	$n8 = $s3[7].$s3[6];
	$add_info = $n1." / ".$n2." / ".$n3." / ".$n4." / ".$n5." / ".$n6." / ".$n7." / ".$n8;
}

sub parse_987301 {
	my $cluster_id = $s1[1];
	my $reason_code = $s1[2];
	$wwpn = $cluster_info{$cluster_id}{"name"};
	if ($reason_code eq "03") {
		$add_info = "partial / local cluster only partnered to remote ";
	} elsif ($reason_code eq "05") {
		$add_info = "full / bidirectional partnership and remote is present";
	} elsif ($reason_code eq "06") {
		$add_info = "missing / remote cluster not present ";
	} elsif ($reason_code eq "06") {
		$add_info = "missing / remote cluster not present ";
	} elsif ($reason_code eq "08") {
		$add_info = "partial stopped / local cluster only partnered to remote and local is stopped";
	} elsif ($reason_code eq "0A") {
		$add_info = "lcl stopped / bidirectional partnership, remote is present, local is stopped";
	} elsif ($reason_code eq "0B") {
		$add_info = "rmt stopped / bidirectional partnership, remote is present, remote is stopped";
	} elsif ($reason_code eq "0C") {
		$add_info = "lcl excluded / bidirectional partnership, local cluster excluded link";
	} elsif ($reason_code eq "0D") {
		$add_info = "rmt excluded / bidirectional partnership, remote cluster excluded link";
	} elsif ($reason_code eq "0E") {
		$add_info = "exceeded / partnership not functional due to too many clusters";
	} else {
		$add_info = $reason_code;
	}
}

sub skcq_desc($) {
	my $skcq = shift;
	my $sk_desc = "";
	if ($skcq =~ /020401/) {$sk_desc = "LUN becoming ready";}
	if ($skcq =~ /02040C/) {$sk_desc = "Target Port Unavailable";}
    if ($skcq =~ /03110B/) { $sk_desc = "Read Error";}
	if ($skcq =~ /040800/) {$sk_desc = "LUN Comm error / write protected";}
	if ($skcq =~ /044400/) {$sk_desc = "Internal Target Failure";}
	if ($skcq =~ /052400/) {$sk_desc = "Invalid CDB / Unsupported Mode Page";}
	if ($skcq =~ /052500/) {$sk_desc = "LUN not supported";}
    if ($skcq =~ /062900/) {$sk_desc = "Reset Notification";}
	if ($skcq =~ /062903/) {$sk_desc = "TargetRest";}
    if ($skcq =~ /062904/) {$sk_desc = "Device Internal Reset"};
    if ($skcq =~ /062A01/) {$sk_desc = "Mode Parameters Changed";}
    if ($skcq =~ /062A03/) {$sk_desc = "Reservations pre-empted"};
    if ($skcq =~ /062F01/) {$sk_desc = "Operating Conditions Changed"};
    if ($skcq =~ /063F01/) {$sk_desc = "code change"};
    if ($skcq =~ /063F03/) {$sk_desc = "inquiry parms changed";}
    if ($skcq =~ /063F0E/) {$sk_desc = "Report LUN Changed";}
    if ($skcq =~ /0B2500/) {$sk_desc = "LUN not supported (no lun 00)";}
	if ($skcq =~ /0B4400/) {$sk_desc = "Abort: internal target failure";}
	if ($skcq =~ /0B4F06/) {$sk_desc = "Abort";}
	
	if ($skcq =~ /020500/) {$sk_desc = "LUN does not respond (LUN offline?)";}
	if ($skcq =~ /02040C/) {$sk_desc = "LUN does not respond (LUN offline?)";}
	return $sk_desc;
}

sub hex_to_ascii($) {
	## Convert each two-digit hex number back to an ASCII character.
	(my $str = shift) =~ s/([a-fA-F0-9]{2})/chr(hex $1)/eg;
	return $str;
}

#
# 2017-01-04  4.1  	Initial beta release, this version uses parsing files from ptool.pm package, and creates xlsx output (no more excel)
# 2017-01-18  4.2  	Added support for the error and audit logs.
#					Added auto_find to look for svc files to process in the current directory