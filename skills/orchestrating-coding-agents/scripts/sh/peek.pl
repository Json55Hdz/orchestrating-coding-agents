#!/usr/bin/perl
# Compact progress of a run, so Claude never reads the raw out.log. (macOS/Linux twin of peek.ps1.)
#   peek -RunDir <RUN_DIR> [-Lines 15]
use strict; use warnings;
use FindBin; require "$FindBin::Bin/lib.pl";
use JSON::PP; use Getopt::Long;

my ($RunDir, $Lines) = ('', 15);
Getopt::Long::Configure('ignore_case');
GetOptions('RunDir=s' => \$RunDir, 'Lines=i' => \$Lines) or die "bad arguments\n";
die "-RunDir is required\n" unless $RunDir;
my $log = "$RunDir/out.log"; my $done = "$RunDir/done.json";
my $isAgy = -d "$RunDir/inbox";

sub T {
    my ($s, $n) = @_; $n ||= 140;
    $s = '' unless defined $s;
    $s =~ s/\s+/ /g; $s =~ s/^ | $//g;
    $s =~ s{/(?:[^/ "]+/)+([^/ "]+/[^/ "]+)}{.../$1}g;
    length $s > $n ? substr($s, 0, $n) . '...' : $s;
}

my $head = 'RUNNING';
if (-e $done) {
    my $d = eval { decode_json(slurp($done)) } || {};
    $head = sprintf('%s (turn %s, %ss, tokens %s)', $d->{status} // '?', $d->{turn} // 0, $d->{seconds} // 0, $d->{tokens} // 0);
} elsif (!-e $log) { $head = 'NOT STARTED (no output yet)' }
else { $head = sprintf('RUNNING (last output %ds ago)', time - (stat $log)[9]) }
my $name = (split m{/}, $RunDir)[-1] // $RunDir;
printf "[%s] %s  %s\n", ($isAgy ? 'agy' : 'opencode'), $name, $head;
exit 0 unless -e $log;

my @items; my $say = '';
sub flush_say { if (length $say) { push @items, 'say: ' . T($say, 220); $say = '' } }
open my $fh, '<', $log or exit 0;
my @tail; while (<$fh>) { push @tail, $_; shift @tail if @tail > 600 }
close $fh;
for my $line (@tail) {
    chomp $line;
    my $j = eval { decode_json($line) }; next unless $j && ref $j eq 'HASH';
    if ($isAgy) {
        my $ev = $j->{event} // '';
        if ($ev eq 'step_update') {
            my $s = $j->{step_update} || {}; my $type = $s->{step_type} // '';
            if ($type eq 'tool' && ($s->{state} // '') eq 'ACTIVE') {
                flush_say();
                push @items, "> " . ($s->{tool_name} // '') . ' ' . T(first_param($s->{tool_info}{parameters}), 110);
            } elsif ($type eq 'agent_response' && defined $s->{text_delta}) { $say .= $s->{text_delta} }
        } elsif ($ev eq 'result') {
            flush_say();
            push @items, sprintf('= turn %s %s (%s tokens)', $j->{result}{num_turns} // '?', $j->{result}{status} // '?', $j->{result}{usage}{total_tokens} // 0);
        }
    } else {
        my $type = $j->{type} // '';
        if ($type eq 'tool_use') {
            flush_say();
            my $p = $j->{part} || {};
            push @items, sprintf('> %s %s [%s]', $p->{tool} // '', T(first_param($p->{state}{input}), 110), $p->{state}{status} // '');
        } elsif ($type eq 'text') { push @items, 'say: ' . T($j->{part}{text}, 220) }
        elsif ($type eq 'error')  { push @items, 'ERROR: ' . T(JSON::PP->new->canonical->encode($j->{error}), 200) }
    }
}
flush_say();
my $from = @items > $Lines ? @items - $Lines : 0;
print "$_\n" for @items[$from .. $#items];
