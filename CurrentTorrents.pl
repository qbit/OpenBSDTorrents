#!/usr/bin/perl -T
#$RedRiver: CurrentTorrents.pl,v 1.30 2010/02/25 18:03:01 andrew Exp $
use strict;
use warnings;
use diagnostics;

use Time::Local;
use Fcntl ':flock';
use File::Basename;

use Transmission::Client;
use Transmission::Utils;

#use YAML;

use lib 'lib';
use OpenBSDTorrents;
use BT::MetaInfo::Cached;

%ENV = ();

#justme();

my $Name_Filter = shift || '';
if ( $Name_Filter =~ /^(\w*)$/ ) {
    $Name_Filter = $1;
}
else {
    die "Invalid filter: $Name_Filter";
}

my %Possible_Torrents;
Process_Dir( $OBT->{DIR_FTP} );

my %files;
my @delete;
foreach my $DIR ( $OBT->{DIR_NEW_TORRENT}, $OBT->{DIR_TORRENT} ) {
    opendir DIR, $DIR
        or die "Couldn't opendir $DIR: $!";
    foreach ( readdir DIR ) {
        next unless my ($ext) = /\.(torrent|$OBT->{META_EXT})$/;

        if (/^([^\/]+)$/) {
            $_ = $1;
        }
        else {
            die "Invalid character in $_: $!";
        }
        my $epoch = 0;
        my $name = basename( $_, '.torrent' );

        if ( my ( $base, $year, $mon, $mday, $hour, $min )
            = /^(.*)-(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})/ )
        {

            $mon--;
            $epoch = timegm( 0, $min, $hour, $mday, $mon, $year );
            $name = $base;
        }

        #print "Adding $_\n";

        $files{$ext}{$name}{$epoch} = {
            file => $_,
            dir  => $DIR,
            path => "$DIR/$_",
            ext  => $ext,

            #year      => $year,
            #mon       => $mon,
            #mday      => $mday,
            #hour      => $hour,
            #min       => $min,
            name  => $name,
            epoch => $epoch,
        };

        if ( $name =~ m/\A $OBT->{BASENAME} /xms
            && !exists $Possible_Torrents{$name} )
        {
            #print "Would remove $_\n";
            push @delete, $files{$ext}{$name}{$epoch};
        }
    }
    closedir DIR;
}

#print Dump \%files;

my %keep;
my %seen;
foreach my $name ( sort keys %{ $files{torrent} } ) {
    next unless $name =~ /^$Name_Filter/;

    #next if $name !~ /songs/xms;
    #next if $name =~ /_packages_/xms;
    #print "Checking $name\n";

    my $cn = $files{torrent}{$name};

EPOCH: foreach my $epoch ( sort { $b <=> $a } keys %{$cn} ) {
        my $ct = $cn->{$epoch};
        my $cf = $ct->{path};

        #print "\t$epoch - $cf\n";

        my $t;
        eval {
            $t
                = BT::MetaInfo::Cached->new( $cf,
                { cache_root => '/tmp/OBTFileCache' } );
        };

        if ($@) {
            warn "Error reading torrent $cf\n";
            push @delete, $ct;
            next EPOCH;
        }

        $ct->{comment} = $t->{comment};
        my ($path) = $t->{comment} =~ /($OBT->{BASENAME}\/[^\n]+)\n/s;

        if ( !-e $OBT->{DIR_FTP} . "/$path" ) {
            print
                'Deleting ',
                $cn->{$epoch}{file}, ' the path (', $path,
                ") doesn't exist.\n";
            push @delete, $ct;
            next EPOCH;
        }

        my $hash = unpack( "H*", $t->info_hash );
        $ct->{info_hash} = $hash;

        undef $t;

        if ( $seen{$name} && $seen{$name} ne $hash ) {
            print "Removing older [$name] [$hash]\n\t",
                $ct->{path},
                "\n";
            $ct->{reason} = 'older';
            push @delete, $ct;
            next EPOCH;
        }
        elsif ( keys %{$cn} == 1 && $ct->{dir} eq $OBT->{DIR_TORRENT} ) {
            $ct->{reason} = 'only';
        }
        elsif ( $keep{$hash} ) {
            if ( $keep{$hash}{epoch} == $epoch ) {
                next EPOCH;
            }

            print "Removing duplicate [$name] [$hash]\n\t",
                $keep{$hash}{path}, "\n";

            $keep{$hash}{reason} = 'duplicate';
            $ct->{reason} = 'duplicate';

            push @delete, $keep{$hash};
        }
        else {
            $ct->{reason} = 'first';
        }

        $keep{$hash} = $ct;
        $seen{$name} = $hash;
    }
}

#print Dump \%files, \%keep, \@delete;
#print Dump \%keep, \@delete;
#exit;

my $client = Transmission::Client->new;
my %seeding;
foreach my $torrent ( @{ $client->torrents } ) {

    #my $status = Transmission::Utils::from_numeric_status($torrent->status);
    my $hash = $torrent->hash_string;
    if ( exists $keep{$hash} ) {
        $seeding{$hash} = $torrent;
    }
    else {
        print "No longer seeding [$hash]\n";
        $torrent->stop or warn $torrent->error_string;
        $client->remove( $torrent->id ) or warn $client->error;
    }
}

#print Dump \%keep;
foreach my $hash ( keys %keep ) {
    my $file = $keep{$hash}{file} || q{};
    my $dir  = $keep{$hash}{dir}  || q{};

    my $name  = $keep{$hash}{name};
    my $epoch = $keep{$hash}{epoch};
    my $reason = $keep{$hash}{reason};

    if ($reason && $reason ne 'only') {
        print "Keeping $reason instance of [$name] [$hash]\n",
            "\t", $file, "\n";
    }

    if ( $dir eq $OBT->{DIR_NEW_TORRENT} ) {
        print "Moving $file to current torrents\n";
        rename( "$dir/$file", $OBT->{DIR_TORRENT} . "/" . $file )
            or die "Couldn't rename '$file': $!";

        $dir = $OBT->{DIR_TORRENT};

        if ( exists $files{txt}{$name}{$epoch} ) {
            my $m_file = $files{txt}{$name}{$epoch}{file};
            my $m_dir  = $files{txt}{$name}{$epoch}{dir};
            rename( "$m_dir/$m_file", $OBT->{DIR_TORRENT} . "/" . $m_file )
                or die "Couldn't rename '$m_file': $!";
        }
    }

    if ( !$seeding{$hash} ) {
        print "Starting seed of [$file] [$hash]\n";
        if (!$client->add(
                filename     => "$dir/$file",
                download_dir => $OBT->{DIR_FTP},
            )
            )
        {

            #warn $client->error, ": $dir/$file\n";
            print "Removing invalid torrent\n\t", $keep{$hash}{path}, "\n";
            push @delete, $keep{$hash};
        }
    }
}

foreach (@delete) {
    if ( $_->{path} ) {
        print "Deleting '$_->{path}'\n";
        unlink $_->{path} or die "Couldn't unlink $_->{path}";
        delete $files{torrent}{ $_->{name} }{ $_->{epoch} };
    }
    else {
        use Data::Dumper;
        print Dumper $_;
    }
}

foreach my $name ( keys %{ $files{ $OBT->{META_EXT} } } ) {
    foreach my $epoch ( keys %{ $files{ $OBT->{META_EXT} }{$name} } ) {
        unless ( exists $files{torrent}{$name}{$epoch} ) {
            my $path = $files{ $OBT->{META_EXT} }{$name}{$epoch}{path};
            print "Unlinking '$path'\n";
            unlink $path or die "couldn't unlink '$path': $!";
        }
    }
}

$client->start;

sub Process_Dir {
    my $basedir = shift;

    my ( $dirs, $files ) = Get_Files_and_Dirs($basedir);
    if (@$files) {
        my $dir = $basedir;
        $dir =~ s/^$OBT->{DIR_FTP}\///;
        Make_Possible($dir);
        foreach my $file (@$files) {
            if ( $file =~ /$INSTALL_ISO_REGEX/ ) {
                Make_Possible("$dir/$file");
            }
        }
    }

    foreach my $subdir (@$dirs) {
        next if $subdir eq '.';
        next if $subdir eq '..';
        Process_Dir("$basedir/$subdir");
    }
}

sub Make_Possible {
    my ($path) = @_;

    my $torrent = Name_Torrent($path);
    $torrent =~ s/-.*$//;
    $Possible_Torrents{$torrent} = 1;
   
    return $torrent;
}
