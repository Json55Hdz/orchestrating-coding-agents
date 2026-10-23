#!/usr/bin/perl
# File snapshot for folders without git, so `review` can still say what an agent changed.
#   snap.pl snap <dir> <out>    record "mtime<TAB>size<TAB>path" for every file (skips .git, node_modules, build dirs)
#   snap.pl diff <dir> <out>    print "A|M|D<TAB>path" lines comparing <dir> now with a snapshot
use strict; use warnings;
use File::Find;

my ($mode, $dir, $file) = @ARGV;
die "usage: snap.pl snap|diff <dir> <file>\n" unless $mode && $dir && $file;
my $MAX = 50000;
my %skip = map { $_ => 1 } qw(.git node_modules .venv venv __pycache__ dist build target .next .gradle Library obj bin);

sub scan {
    my %m; my $n = 0;
    File::Find::find({ no_chdir => 1, wanted => sub {
        my $p = $File::Find::name;
        if (-d $p) { my ($b) = $p =~ m{([^/]+)$}; $File::Find::prune = 1 if $b && $p ne $dir && $skip{$b}; return }
        return if -l $p || !-f _ || $n >= $MAX;
        my @s = stat $p or return;
        (my $rel = $p) =~ s{^\Q$dir\E/?}{};
        $m{$rel} = "$s[9]\t$s[7]"; $n++;
    } }, $dir);
    \%m;
}

if ($mode eq 'snap') {
    my $m = scan();
    open my $o, '>', $file or die "cannot write $file: $!";
    print $o "$m->{$_}\t$_\n" for sort keys %$m;
    close $o;
} elsif ($mode eq 'diff') {
    my %old;
    open my $i, '<', $file or die "no snapshot $file\n";
    while (<$i>) { chomp; my ($t, $s, $p) = split /\t/, $_, 3; $old{$p} = "$t\t$s" if defined $p }
    close $i;
    my $new = scan();
    for my $p (sort keys %$new) { if (!exists $old{$p}) { print "A\t$p\n" } elsif ($old{$p} ne $new->{$p}) { print "M\t$p\n" } }
    for my $p (sort keys %old) { print "D\t$p\n" unless exists $new->{$p} }
}
