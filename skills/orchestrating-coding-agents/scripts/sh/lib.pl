# Shared helpers for the perl scripts (worker.pl, say.pl, peek.pl). Core modules only.
use strict; use warnings;
use POSIX qw(strftime);

# Kill a process and everything below it (shims and child CLIs included).
sub tree_kill {
    my ($pid) = @_;
    my %kids;
    if (open my $ps, '-|', 'ps', '-axo', 'pid=,ppid=') {
        while (<$ps>) { if (/^\s*(\d+)\s+(\d+)/) { push @{ $kids{$2} }, $1 } }
        close $ps;
    }
    my @all = ($pid); my @q = ($pid);
    while (@q) { my $p = shift @q; for my $k (@{ $kids{$p} || [] }) { push @all, $k; push @q, $k } }
    kill 'TERM', -$pid; kill 'TERM', reverse @all;
    select(undef, undef, undef, 0.4);
    kill 'KILL', -$pid; kill 'KILL', reverse @all;
}

sub iso_now { strftime('%Y-%m-%dT%H:%M:%S%z', localtime) }

# AGY_PATH override, then ~/.local/bin/agy, then PATH.
sub resolve_agy {
    for my $c ($ENV{AGY_PATH}, "$ENV{HOME}/.local/bin/agy") { return $c if $c && -x $c }
    for my $d (split /:/, $ENV{PATH} || '') { return "$d/agy" if -x "$d/agy" && !-d "$d/agy" }
    die "agy not found. Install the Antigravity CLI or set AGY_PATH to its full path.\n";
}

# First interesting value of a tool-call parameter hash (hash order is lost, so prefer well-known keys).
sub first_param {
    my ($h) = @_;
    return '' unless ref $h eq 'HASH' && %$h;
    for my $k (qw(command cmd file_path path filePath pattern query url prompt description)) {
        return $h->{$k} if defined $h->{$k} && !ref $h->{$k};
    }
    my ($k) = sort keys %$h;
    my $v = $h->{$k};
    return ref $v ? '' : (defined $v ? $v : '');
}

sub slurp { my ($p) = @_; open my $f, '<', $p or return undef; local $/; my $c = <$f>; close $f; $c }
sub spit  { my ($p, $c) = @_; my $t = "$p.tmp$$"; open my $f, '>', $t or return; print $f $c; close $f; rename $t, $p }

1;
