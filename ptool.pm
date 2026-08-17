package IBM::SVCTools;

our $VERSION = '1.09';
use strict;
use warnings;
use Data::Dumper;
use DateTime::Format::Strptime;
 
use Exporter qw(import);
our @EXPORT_OK = qw(parse_lsoutput);

my $CONVERT_TO_KB = 1024;			# 1024
my $CONVERT_TO_MB = 1048576;		# 1024/1024
my $CONVERT_TO_GB = 1073741824;		# 1024/1024/1024
my $CONVERT_TO_TB = 1099511627776;	# 1024/1024/1024/1024


sub parse_lssystem {

	my $self = $_[0];
	my $i = $_[1];
	my $start_indx = $i;
	my @indata = @{$_[2]};
	my $cluster_info = $_[3];
	
	my $end_indx = $start_indx + 100;
	if ($end_indx > @indata) {$end_indx = @indata;}
	
	_log (1,"*++++ Start lssystem start=$start_indx end=$end_indx");
	
	my $dd = trim($indata[$start_indx+1]);
	_log(2,"lssystem:  start=$start_indx / $dd");
	#
	#
	my $cluster_indx = 0;
	my @header_tokens = split(":",$dd);
#	_log(3,"lssystem: data=$dd");
#	$cluster_id = $cluster_idnum{$header_tokens[1]};
	my $cluster_id = $header_tokens[1];
#	_log(2,"lssystem: cluster_id = $cluster_id");
		
		for ($i=$start_indx+2;$i<$end_indx;$i++) {
			my $dd = trim($indata[$i]);
			if ($dd eq "") {last;}
			my @tokens = split(":",$dd);
			$cluster_info->{$cluster_id}{$tokens[0]} = $tokens[1];
#			_log(3,"lssystem: $cluster_id / $tokens[0] / $tokens[1] ")
		}
	
	return $i;
}

sub parse_lscluster {

#	my ($self, $start_indx, $ref_indata, $ref_cluster_info) = @_;
	my $self = $_[0];
	my $i = $_[1];
	my $start_indx = $i;
	my @indata = @{$_[2]};
	my $cluster_info = $_[3];

	my $num_recs = @indata;
	my $end_indx = $start_indx + 80;
	if ($end_indx > $num_recs) {$end_indx = $num_recs;}	
	my $dd = trim($indata[$start_indx+1]);
	_log (1,"*++++ Start lscluster start=$start_indx");
	#
	#  There are two types of lscluster outputs in the svcout file, the list and then one for each cluster.
	#
	my $cluster_indx = 0;
	my @header_tokens = split(":",$dd);
	#
	#  If we have a true header then it must be the list format
	#  else it will be the details version
	#
	if (@header_tokens > 3) {
#		_log(3,"lscluster: summary version header=$dd");

		for ($i=$start_indx+2;$i<$end_indx;$i++) {
			my $dd = trim($indata[$i]);
			if ($dd eq "") {last;}
			my @tokens = split(":",$dd);
			my $cluster_num = $tokens[0];
			my $cluster_id = $cluster_num;
			$cluster_info->{$cluster_id}{"id"} = $cluster_id;
			$cluster_info->{$cluster_id}{"num"} = $tokens[0];

			for (my $ii=1;$ii<@tokens;$ii++) {
				if ($tokens[$ii] ne "") {
					$cluster_info->{$cluster_id}{$header_tokens[$ii]} = $tokens[$ii];
				}
			}
		}
	} else {
#		_log(3,"lscluster: detailed version data=$dd");
		my $cluster_id = $header_tokens[1];
		for ($i=$start_indx+2;$i<$end_indx;$i++) {
			my $dd = trim($indata[$i]);
			if ($dd eq "") {last;}
			my @tokens = split(":",$dd);
			$cluster_info->{$cluster_id}{$tokens[0]} = $tokens[1];
		}
	}
	
	return $i;
}

sub parse_lseventlog {
	my $i = $_[1];
	my $start_indx = $i;
	my @indata = @{$_[2]};
#	my $process_date = $_[3];
	my $event_info = $_[4];
	my $num_recs = @indata;
	
	my $end_indx = $num_recs;
	my $dd = trim($indata[$start_indx+1]);
	_log (1,"*++++ Start lseventlog start=$start_indx");
	
	
	my $dt_parser = DateTime::Format::Strptime->new(
			pattern => '%y%m%d%H%M%S', 
			on_error => 'croak');

	my $dt_parser2 = DateTime::Format::Strptime->new(
			pattern => '%Y-%m-%d', 
			on_error => 'croak');
#  			on_error => \&dt_error,
	my $process_dt = $dt_parser2->parse_datetime($_[3]);

	my $delim = ($dd =~ /\|/)?'|':':';
	my @header_tokens = split(/\Q$delim/,$dd);

	for ($i=$start_indx+2;$i<$end_indx;$i++) {
		my $dd = trim($indata[$i]);
		if ($dd eq "") {last;}
		if ($dd =~ /^#### </) {last;}
		my @tokens = split(/\Q$delim/,$dd);
		my $event_date = $dt_parser->parse_datetime($tokens[1]);
		my $delta_hrs = int($process_dt->subtract_datetime_absolute($event_date)->delta_seconds / (60*60));
		if ($delta_hrs < 48) {
			$dd =~ s/:/,/g;
			my $d = $event_date->ymd;
			my $t = $event_date->hms;
			$tokens[1] = $d.' '.$t;
			my $id = sprintf("%04d",$tokens[0]);
			my %row_hash = ();
			@row_hash{@header_tokens} = @tokens;
			$event_info->{$id} = \%row_hash;
		}
	}
	return $i;
}

sub parse_lspartnership($) {
	my $self = $_[0];
	my $i = $_[1];
	my $start_indx = $i;
	my @indata = @{$_[2]};
	my $cluster_info = $_[3];
	my $num_recs = @indata;
	
	my $end_indx = $start_indx + 80;
	if ($end_indx > $num_recs) {$end_indx = $num_recs;}
	my $dd = trim($indata[$start_indx+1]);
	_log (1,"*++++ Start lspartner start=$start_indx");
	#
	#  There are two types of lspartnership outputs in the svcout file, the list and then one for each cluster.
	#
	my $cluster_indx = 0;
	my @header_tokens = split(":",$dd);
	#
	#  If we have a true header then it must be the list format
	#  else it will be the details version
	#
	if (@header_tokens > 3) {
#		_log(3,"lspartner: header=$dd");
		for ($i=$start_indx+2;$i<$end_indx;$i++) {
			my $dd = trim($indata[$i]);

			if ($dd eq "") {last;}
			my @tokens = split(":",$dd);
			my $cluster_num = $tokens[0];
			my $cluster_id = $tokens[0];
#			_log(3,"lspartner1: $i indx=$cluster_indx cluster=$cluster_num data=$dd");
#			if (exists $cluster_idnum{$cluster_num}) {
#				$cluster_id = $cluster_idnum{$cluster_num};
#				_log(3,"lspartner2: $cluster_num / $cluster_id /");
#				if ($cluster_indx <= $cluster_id) {
#					$clusterid_indx = $cluster_id + 1;
#					_log(3,"lspartner2b: $cluster_num / $cluster_id / $clusterid_indx");
#				}
#			} else {
#				$cluster_id = sprintf("%02d",$clusterid_indx++);
#				$cluster_idnum{$tokens[0]} = $cluster_id;
#				_log(3,"lspartner3: $tokens[0] / $cluster_id /");
#			}
			$cluster_info->{$cluster_id}{"id"} = $cluster_id;
			$cluster_info->{$cluster_id}{"num"} = $tokens[0];

			for (my $ii=1;$ii<@tokens;$ii++) {
				if ($tokens[$ii] ne "") {
					$cluster_info->{$cluster_id}{$header_tokens[$ii]} = $tokens[$ii];
				}
			}
		}
	} else {
#		_log(3,"lspartner: data=$dd");
#		$cluster_id = $cluster_idnum{$header_tokens[1]};
		for ($i=$start_indx+2;$i<$end_indx;$i++) {
			my $dd = trim($indata[$i]);
			if ($dd eq "") {last;}
			my @tokens = split(":",$dd);
			my $cluster_id = $tokens[0];
			$cluster_info->{$cluster_id}{$tokens[0]} = $tokens[1];
#			_log(3,"lspartner: $cluster_id / $tokens[0] / $tokens[1] ")
		}
	}
	return $i;
}

sub parse_lsnodevpd($) {
	my $self = $_[0];
	my $i = $_[1];
	my $start_indx = $i;
	my @indata = @{$_[2]};
	my $node_info = $_[3];
	my $num_recs = @indata;
	my $end_indx = @indata;

	_log (1,"*++++ Start lsnodevpd start=$start_indx / $end_indx");
	my $dd = trim($indata[$start_indx+1]);
	if ($dd =~ /command not found/i) {return ++$i;};
	
	my $delim = ($dd =~ /\|/)?'|':':';
	print "==> $dd\n";
	my @header_tokens = split(/\Q$delim/,$dd);
	if (@header_tokens > 3)	{
		for ($i=$start_indx+2;$i<$end_indx;$i++) {
			my $dd = trim($indata[$i]);
			if ($dd eq "") {last;}
			if ($dd =~ /^#### </) {last;}
			if ($dd =~ /svcinfo /i) {$i--;last;}
			my @tokens = split(/\Q$delim/,$dd);
			my $id = sprintf("%04d",$tokens[0]);
			my %row_hash = ();
			@row_hash{@header_tokens} = @tokens;
			$node_info->{$id} = \%row_hash;
		}
	}
	return $i;
}

sub parse_lshost($) {
	my $self = $_[0];
	my $i = $_[1];
	my $start_indx = $i;
	my @indata = @{$_[2]};
	my $host_info = $_[3];
	
	my $end_indx = $start_indx + 8192;
	if ($end_indx > @indata) {$end_indx = @indata;}
#	_log (1,"*++++ Start lshost start=$start_indx end=$end_indx");
	
	my $dd = trim($indata[$start_indx+1]);
	my @header_tokens = split(":",$dd);
#	_log (1,"lshost: header i=$i dd=$dd");
	if (@header_tokens > 3)	{
		for ($i=$start_indx+2;$i<$end_indx;$i++) {
			my $dd = trim($indata[$i]);
			if ($dd eq "") {last;}
			if ($dd =~ /^#### </) {last;}
			if ($dd =~ /^svcinfo /i) {$i--;last;}
			my @tokens = split(":",$dd);
			my $host_id = sprintf("%04d",$tokens[0]);
			my %row_hash = ();
			@row_hash{@header_tokens} = @tokens;
			$host_info->{$host_id} = \%row_hash;
		}
	} else {
		my $host_id = -1;
		my $fc_num = 0;
		for ($i=$start_indx+1;$i<$end_indx;$i++) {
			my $dd = trim($indata[$i]);
			if ($dd eq "") {next;}
			if ($dd =~ /^#### </) {last;}
			if ($dd =~ /^svcinfo /i) {$i--;last;}
			my ($keyword,$value) = split(':',$dd,2);
			if ($keyword eq 'id') {				
				$host_id = sprintf("%04d",$value);
				$fc_num = 0;
			}			
			if ($keyword eq "WWPN") {
				$host_info->{$host_id}{'WWPN'}{$fc_num} = $value;
#				_log(1,"lshost3a: $host_id / $fc_num / $keyword / $value / $dd");
				my $dd = trim($indata[++$i]);
				my @toks = split(":",$dd);
				my $keyw = $toks[0];
				my $v = $toks[1];
				$host_info->{$host_id}{'nodes'}{$fc_num} = $toks[1];
#				_log(2,"lshost3b: $host_id / $fc_num / $keyw / $v / $dd");
				$dd = trim($indata[++$i]);
				@toks = split(":",$dd);
				$keyw = $toks[0];
				$v = $toks[1];
				$host_info->{$host_id}{'state'}{$fc_num++} = $toks[1];
#				_log(2,"lshost3c: $host_id / $fc_num / $keyw / $v / $dd");
			} else {
#				_log(2,"lshost: $host_id / $keyword / $value / $dd");
				$host_info->{$host_id}{$keyword} = $value;
			}
		}
	
	}
	return $i;
}

sub parse_lsoutput($) {
	my $self = $_[0];
	my $i = $_[1];
	my $start_indx = $i;
	my @indata = @{$_[2]};
	my $command_info = $_[3];
	my $num_recs = @indata;
	
	my $end_indx = @indata;
	my $dd = trim($indata[$start_indx+1]);
#	_log (2,"*++++ Start lsoutput start=$start_indx end=$end_indx");
	if ($dd =~ /command not found/i) {return ++$i;};	
	my $delim = ($dd =~ /\|/)?'|':':';
	#  There are 2 version of ls commands the list version or the detail version
	my @header_tokens = split(/\Q$delim/,$dd);
#	_log(1,"lsout: delim=$delim header=@header_tokens\n");
	if (@header_tokens > 4)	{
		for ($i=$start_indx+2;$i<$end_indx;$i++) {
			my $dd = trim($indata[$i]);
			if ($dd eq "") {last;}
			if ($dd =~ /^#### </) {last;}
			if ($dd =~ /^svcinfo /i) {$i--;last;}
			my @tokens = split(/\Q$delim/,$dd);
			my $id = (length($tokens[0]) < 4)?sprintf("%04d",$tokens[0]):$tokens[0];
			my %row_hash = ();
			@row_hash{@header_tokens} = @tokens;
			$command_info->{$id} = \%row_hash;
		}
	} else {									# no header, so must be the detail version	
		my $id = "****";		
		for ($i=$start_indx+1;$i<$end_indx;$i++) {
			my $dd = trim($indata[$i]);
			if ($dd eq "") {next;}
			if ($dd =~ /^#### </) {last;}
			if ($dd =~ /^svcinfo /i) {$i--;last;}
			my ($keyword, $value) = split(/\Q$delim/,$dd);		
			
			if ($keyword eq 'id') {
				$id = (length($value) < 4)?sprintf("%04d",$value):$value;
			}
			$command_info->{$id}{$keyword} = $value;
		}
	}
	return $i;
}

sub parse_lshostvdiskmap($) {
	my $self = $_[0];
	my $i = $_[1];
	my $start_indx = $i;
	my @indata = @{$_[2]};
	my $vdiskmap_info = $_[3];
	my $num_recs = @indata;
	my $end_indx = $start_indx + 18068;
	if ($end_indx > $num_recs) {$end_indx = $num_recs;}
	my $dd = trim($indata[$start_indx+1]);
	my @header_tokens = split(":",$dd);

	for ($i=$start_indx+2;$i<$end_indx;$i++) {
		my $dd = trim($indata[$i]);
		if ($dd eq "") {last;}
		if ($dd =~ /^#### </) {last;}
		my @tokens = split(":",$dd);
		my $vdiskmap_id = sprintf("%03d-%04d",$tokens[0],$tokens[3]);
		$vdiskmap_info->{$vdiskmap_id}{'host_id'} = $tokens[0];
		for (my $ii=1;$ii<@tokens;$ii++) {
			if ($tokens[$ii] ne "") {
				$vdiskmap_info->{$vdiskmap_id}{$header_tokens[$ii]} = $tokens[$ii];
			}
		}
	}
	return $i;
}

sub parse_lscontroller($) {
	my $self = $_[0];
	my $i = $_[1];
	my $start_indx = $i;
	my @indata = @{$_[2]};
	my $data_info = $_[3];
	my $num_recs = @indata;
	
#	_log (1,"*++++ Start lscontroller start=$start_indx");
	if ($indata[$start_indx] =~ /^#### <\//) {return ++$i;}
	if ($indata[$start_indx] =~ /command not found/i) {return ++$i;};
	
	my $dd = trim($indata[$start_indx+1]);
	if ($dd =~ /^#### </) {return ++$i;}
	if ($dd =~ /command not found/i) {return ++$i;};
#	_log (1,"lscntrl: header ==> $dd");
	#  There are 2 version of lscontroller the list version or the detail version
	my @header_tokens = split(":",$dd);

	if (@header_tokens > 3)	{
		my $end_indx = $start_indx + 64;
		if ($end_indx > @indata) {$end_indx = @indata;}
		for ($i=$start_indx+2;$i<$end_indx;$i++) {
			my $dd = trim($indata[$i]);
			$dd =~ s/\s+/ /g;
			if ($dd eq "") {last;}
			if ($dd =~ /^#### <\//) {last;}
			if ($dd =~ /^svcinfo /i) {$i--;last;}
			my @tokens = split(/:/,$dd);
			my $id = sprintf("%04d",$tokens[0]);
#			_log(1,"lscntrl: List version id=$id dd=$dd");
			my %row_hash = ();
			@row_hash{@header_tokens} = @tokens;
			$data_info->{$id} = \%row_hash;
		}
	} else {									# no header, so must be the detail version
		my $end_indx = $start_indx + 1024;
		if ($end_indx > @indata) {$end_indx = @indata;}
		my $id = sprintf("%04d",$header_tokens[1]);
		my $port_num = 0;
#		_log(1,"lscntrl: Detailed version id=$id start=$start_indx end=$end_indx dd=$dd");
		for ($i=$start_indx+1;$i<$end_indx;$i++) {			
			my $dd = trim($indata[$i]);
#			_log(1,"lscntrl: Detailed version id=$id i=$i dd=$dd");
			if ($dd eq "") {next;}
			if ($dd =~ /^#### </) {last;}
			if ($dd =~ /^svcinfo /) {--$i;last;}			
			my ($keyword, $value) = split(":",$dd,2);
			if ($keyword eq 'id') {
				$id = sprintf("%04d",$value);
				$port_num = 0;
			}
#			_log(1,"lscntrl: ID=$id Keyword=$keyword value=$value");
			if ($keyword eq 'WWPN') {
				$data_info->{$id}{$keyword}{$port_num} = $value;
			} elsif ($keyword eq 'path_count') {
				$data_info->{$id}{$keyword}{$port_num} = $value;
			} elsif ($keyword eq 'max_path_count') {
				$data_info->{$id}{$keyword}{$port_num++} = $value;
			} else {
				$data_info->{$id}{$keyword} = $value;
			}
		}
	}
	return $i;
}

sub parse_lsvdisk($) {
	my $self = $_[0];
	my $i = $_[1];
	my $start_indx = $i;
	my @indata = @{$_[2]};
	my $command_info = $_[3];
	my $num_recs = @indata;
	my $end_indx = @indata;
	
	
	my $dd = trim($indata[$start_indx+1]);
	_log (2,"*++++ Start lsvdisk start=$start_indx end=$end_indx");
	if ($dd =~ /command not found/i) {return ++$i;};	
	my $delim = ($dd =~ /\|/)?'|':':';
	#  There are 2 version of ls commands the list version or the detail version
	my @header_tokens = split(/\Q$delim/,$dd);
#	_log(3,"lsvdisk: delim=$delim header=@header_tokens\n");
	if (@header_tokens > 3)	{					# header found so must be summary version
		for ($i=$start_indx+2;$i<$end_indx;$i++) {
			my $dd = trim($indata[$i]);
			if ($dd eq "") {last;}
			if ($dd =~ /^#### </) {last;}
			if ($dd =~ /^svcinfo /) {--$i;last;}
			my @tokens = split(/\Q$delim/,$dd);
			my $id = sprintf("%04dP",$tokens[0]);
			my %row_hash = ();
			@row_hash{@header_tokens} = @tokens;
			$command_info->{$id} = \%row_hash;
		}
	} else {									# no header, so must be the detail version	
		my $id = '****';
		my $v_id = '';
		my $tier_level = '';
		for ($i=$start_indx+1;$i<$end_indx;$i++) {
			my $dd = trim($indata[$i]);
			if ($dd eq '') {next;}
			if ($dd =~ /^#### </) {last;}
			if ($dd =~ /^svcinfo /i) {--$i;last;}
			my ($keyword, $value) = split(/\Q$delim/,$dd);
			if ($keyword eq 'id') {
				$id = $value;
				$v_id = sprintf("%04dP",$value);
			}
			if ($keyword eq 'copy_id') {		# scan next 5 lines to see if this is the primary copy or not
				for (my $k=$i;$k<$i+6;$k++) {
					if ($indata[$k] =~ /primary:no/){		# for the non primary volume copy some info from the primary
#						my $ov_id = $v_id;
						$v_id = sprintf("%04dS",$id);
						my $ov_id = sprintf("%04dP",$id);
						$command_info->{$v_id}{'id'} = $id;
						$command_info->{$v_id}{'copy_count'} = $command_info->{$ov_id}{'copy_count'};
						$command_info->{$v_id}{'capacity'} 	= $command_info->{$ov_id}{'capacity'};
						$command_info->{$v_id}{'name'} 		= $command_info->{$ov_id}{'name'};
					}
					if ($indata[$k] =~ /primary:yes/){
						$v_id = sprintf("%04dP",$id);
					}
				}
			}
			if ($keyword eq 'tier') {						# there are 3 tier keywords so need to tag which tier is which
				$tier_level = 'cap_'.$value;
			} elsif ($keyword eq 'tier_capacity') {
				$command_info->{$v_id}{$tier_level} = $value;
			} else {
				$command_info->{$v_id}{$keyword} = $value;
			}
		}
	}
	return $i;
}

sub parse_output {

	my $self = $_[0];
	my $i = $_[1];
	my $start_indx = $i;
	my @indata = @{$_[2]};
	my $hash_data = $_[3];
	my $delim = $_[4];
	
	my $end_indx = @indata;
	
	_log(2,"*++++ Start Output start=$start_indx end=$end_indx");
	for ($i=$start_indx+1;$i<$end_indx;$i++) {
		my $dd = trim($indata[$i]);
		if ($dd eq "") {next;}
		if ($dd =~ /^#### </) {last;}
		if ($dd =~ /^svcinfo /i) {$i--;last;}
		my ($keyword, $value) = split(/\Q$delim/,$dd);
		$hash_data->{$keyword} = $value;
	}

	return $i;
}

sub disp_to_GB($) {
	my $self = $_[0];
	my $size = $_[1];
	if ($size =~ /KB/) {$size = substr($size,0,length($size)-2) / 1024 / 1024;}
	if ($size =~ /MB/) {$size = substr($size,0,length($size)-2) / 1024;}
	if ($size =~ /GB/) {$size = substr($size,0,length($size)-2) }
	if ($size =~ /TB/) {$size = substr($size,0,length($size)-2) * 1024;}
	if ($size =~ /PB/) {$size = substr($size,0,length($size)-2) * 1024 * 1024;}	
	return $size;
}

sub size_to_disp ($) {
	my $self = $_[0];
	my $size = $_[1];	
	if ($size > $CONVERT_TO_TB) {$size = sprintf("%.1f TB",$size/$CONVERT_TO_TB)}
	elsif ($size > $CONVERT_TO_GB) {$size = sprintf("%.1f GB",$size/$CONVERT_TO_GB)}
	elsif ($size > $CONVERT_TO_MB) {$size = sprintf("%.1f MB",$size/$CONVERT_TO_MB)}
	return $size;
}

sub size_to_GB ($) {
	my $self = $_[0];
	my $size = $_[1];	
	$size = $size / 1024 / 1024;
	return $size;
}

sub trim($) {
	my $string = shift;
	$string =~ s/^\s+|\s+$//g;
	return $string;
}

sub _log {
	my ($level, $msg) = @_;
	chomp $msg;
	print "$msg\n" if ($level eq 1);
}

1;