#!/usr/bin/perl -T
#$RedRiver: CurrentTorrents.pl,v 1.26 2009/10/20 19:04:28 andrew Exp $
use strict;
use warnings;
use diagnostics;

use Time::Local;
use Fcntl ':flock';
use File::Basename;

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
            print "Would remove $_\n";
            push @delete, $files{$ext}{$name}{$epoch};
        }
    }
    closedir DIR;
}

#print Dump \%files;

my %keep;
foreach my $name ( sort keys %{ $files{torrent} } ) {
    next unless $name =~ /^$Name_Filter/;

    #print "Checking $name\n";

    foreach my $epoch ( sort { $b <=> $a } keys %{ $files{torrent}{$name} } )
    {

        #print "\t$epoch\n";
        my $torrent = $files{torrent}{$name}{$epoch}{path};

        if ( keys %{ $files{torrent}{$name} } == 1
            && $files{torrent}{$name}{$epoch}{dir} eq $OBT->{DIR_TORRENT} )
        {

            #print "Skipping torrent for $name there is only one.\n";
            next;
        }

        my $t;
        eval {
            $t = BT::MetaInfo::Cached->new(
                $torrent,
                {   cache_root => '/tmp/OBTFileCache'

                        #$OBT->{DIR_HOME} . '/FileCache'
                }
            );
        };

        if ($@) {
            warn "Error reading torrent $torrent\n";
            push @delete, $files{torrent}{$name}{$epoch};
            delete $files{torrent}{$name}{$epoch};
            next;
        }

        $files{torrent}{$name}{$epoch}{comment} = $t->{comment};
        my ($path) = $t->{comment} =~ /($OBT->{BASENAME}\/[^\n]+)\n/s;

        unless ( -e $OBT->{DIR_FTP} . "/$path" ) {
            print
                "Deleting $files{torrent}{$name}{$epoch}{file} the path ($path) doesn't exist.\n";
            push @delete, $files{torrent}{$name}{$epoch};
            delete $files{torrent}{$name}{$epoch};
            next;
        }

        my $hash = $t->info_hash;
        $hash = unpack( "H*", $hash );

        undef $t;

        $files{torrent}{$name}{$epoch}{info_hash} = $hash;

        if ( exists $keep{$hash} ) {
            if ( $keep{$hash}{epoch} == $epoch ) {
                next;
            }
            print "Removing [$name] [$hash]\n\t", $keep{$hash}{path}, "\n";
            push @delete, $keep{$hash};
            delete $files{torrent}{ $keep{$hash}{name} }
                { $keep{$hash}{epoch} };
            $keep{$hash} = $files{torrent}{$name}{$epoch};
            print "Keeping additional instance of  [$name] [$hash]\n\t",
                $keep{$hash}{path},
                "\n";
        }
        else {
            print "Removing old [$name] [$hash]\n";
            if ( $keep{$hash}{path} ) {
                print "\t", $keep{$hash}{path}, "\n";
            }
            push @delete, $files{torrent}{$name}{$epoch};
            delete $files{torrent}{$name}{$epoch};
        }
        else {
            print "Keeping first instance of $name [$hash]\n\t",
                $files{torrent}{$name}{$epoch}{path},
                "\n";
            $keep{$hash} = $files{torrent}{$name}{$epoch};

        }
    }
}

#print Dump \%files, \%keep, \@delete;
#exit;

foreach (@delete) {
    print "Deleting '$_->{path}'\n";
    unlink $_->{path} or die "Couldn't unlink $_->{path}";
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

#print Dump \%keep;
foreach my $hash ( keys %keep ) {
    my $file = $keep{$hash}{file} || q{};
    my $dir  = $keep{$hash}{dir}  || q{};
    if ( $dir eq $OBT->{DIR_NEW_TORRENT} ) {
        print "Moving $file to current torrents\n";
        rename( "$dir/$file", $OBT->{DIR_TORRENT} . "/" . $file )
            or die "Couldn't rename '$file': $!";

        my $name  = $keep{$hash}{name};
        my $epoch = $keep{$hash}{epoch};

        if ( exists $files{txt}{$name}{$epoch} ) {
            my $m_file = $files{txt}{$name}{$epoch}{file};
            my $m_dir  = $files{txt}{$name}{$epoch}{dir};
            rename( "$m_dir/$m_file", $OBT->{DIR_TORRENT} . "/" . $m_file )
                or die "Couldn't rename '$m_file': $!";
        }
    }
}

sub Process_Dir {
    my $basedir = shift;

    my ( $dirs, $files ) = Get_Files_and_Dirs($basedir);
    if (@$files) {
        my $dir = $basedir;
        $dir =~ s/^$OBT->{DIR_FTP}\///;
        my $torrent = Name_Torrent($dir);
        $torrent =~ s/-.*$//;
        $Possible_Torrents{$torrent} = 1;
        foreach my $file (@$files) {
            if ( $file =~ /$INSTALL_ISO_REGEX/ ) {
                $torrent = Name_Torrent("$dir/$file");
                $torrent =~ s/-.*$//;
                $Possible_Torrents{$torrent} = 1;
            }
        }
    }

    foreach my $subdir (@$dirs) {
        next if $subdir eq '.';
        next if $subdir eq '..';
        Process_Dir("$basedir/$subdir");
    }
}

