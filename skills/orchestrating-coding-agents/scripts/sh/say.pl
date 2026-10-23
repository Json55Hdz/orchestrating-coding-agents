#!/usr/bin/perl
# Talk to a running (or recently finished) agent. (macOS/Linux twin of say.ps1; same flags.)
#   say -RunDir <RUN_DIR> -Text "also add a test for X"     send, return immediately
#   say -RunDir <RUN_DIR> -Text "..." -Wait [-WaitSec 300]  send, wait for the reply, print it
#   say -RunDir <RUN_DIR> -Last                              print the last assistant message
#   say -RunDir <RUN_DIR> -Abort                             interrupt (OpenCode: current turn; AGY: ends the session)
use strict; use warnings;
use FindBin; require "$FindBin::Bin/lib.pl";
use JSON::PP; use Getopt::Long; use HTTP::Tiny; use POSIX qw(strftime setsid);
use Time::HiRes qw(time sleep gettimeofday);

my ($RunDir, $Text, $Model, $Wait, $WaitSec, $Last, $Abort, $Port) = ('', '', '', 0, 300, 0, 0, 0);
Getopt::Long::Configure('ignore_case');
GetOptions('RunDir=s' => \$RunDir, 'Text=s' => \$Text, 'Model=s' => \$Model, 'Wait!' => \$Wait, 'WaitSec=i' => \$WaitSec,
           'Last!' => \$Last, 'Abort!' => \$Abort, 'Port=i' => \$Port) or die "bad arguments\n";
die "-RunDir is required\n" unless $RunDir;
if (!$Port) { my $pf = slurp("$RunDir/port"); $Port = defined $pf && $pf =~ /(\d+)/ ? $1 : 4096 }   # dispatch records the run's server port
die "-Port must be a number between 1 and 65535\n" unless $Port =~ /^\d{1,5}$/ && $Port >= 1 && $Port <= 65535;
$| = 1;
my $json = JSON::PP->new;
my $isAgy = -d "$RunDir/inbox";

if ($isAgy) {
    my $lastFile = "$RunDir/last-response.txt"; my $done = "$RunDir/done.json";
    my $wp = slurp("$RunDir/worker.pid"); my $alive = 0;
    if (defined $wp && $wp =~ /(\d+)/) { $alive = kill(0, $1) ? 1 : 0 }
    if ($Last) { my $t = slurp($lastFile); $t = "(no completed turn yet)" unless defined $t; print $t; print "\n" unless $t =~ /\n$/; exit 0 }
    if ($Abort) {
        my $p = slurp("$RunDir/pid");
        tree_kill($1) if defined $p && $p =~ /(\d+)/;
        print "ABORTED (AGY session ended; continue later with dispatch -Resume)\n"; exit 0;
    }
    die "give -Text, -Last or -Abort\n" unless length $Text;
    if (!$alive) { print "SESSION_ENDED: the AGY worker already exited (idle timeout/closed). Re-dispatch with -Resume and your message in the brief.\n"; exit 3 }
    unlink $done;   # so a waiter sees THIS turn's result, not the old one
    my ($s, $us) = gettimeofday;
    spit(sprintf("%s/inbox/%s%03d.txt", $RunDir, strftime('%Y%m%d%H%M%S', localtime $s), $us / 1000), $Text);
    print "SENT\n";
    if ($Wait) {
        my $deadline = time + $WaitSec;
        while (time < $deadline) {
            sleep 2;
            if (-e $done) {
                my $d = eval { decode_json(slurp($done)) } || {};
                print(($d->{status} // '') . "\n");
                my $t = slurp($lastFile); if (defined $t) { print $t; print "\n" unless $t =~ /\n$/ }
                exit 0;
            }
        }
        print "WAIT_EXPIRED (still working; use -Last later or -Abort)\n";
    }
    exit 0;
}

my $sid = slurp("$RunDir/session"); die "no session file in $RunDir\n" unless defined $sid;
$sid =~ s/\s+//g;
my $base = "http://127.0.0.1:$Port/session/$sid";
my $http = HTTP::Tiny->new(timeout => 20);

sub get_msgs {
    my $r = $http->get("$base/message");
    die "GET message failed: $r->{status} $r->{reason}\n" unless $r->{success};
    decode_json($r->{content});
}
sub last_assistant {
    my ($msgs) = @_;
    my @a = grep { ($_->{info}{role} // '') eq 'assistant' } @$msgs;
    return undef unless @a;
    my $m = $a[-1];
    return { id => $m->{info}{id}, done => ($m->{info}{time}{completed} ? 1 : 0),
             text => join("\n", map { $_->{text} // '' } grep { ($_->{type} // '') eq 'text' } @{ $m->{parts} || [] }) };
}

# OpenCode has no worker after the first turn, so whoever sends a follow-up also records its outcome:
# done.json (status, turn, tokens) and last-response.txt, exactly like the worker does for the first turn.
my $prev = eval { decode_json(slurp("$RunDir/done.json")) } || {};
sub record_done {
    my ($before, $deadline) = @_;
    while (time < $deadline) {
        sleep 2;
        my $msgs = eval { get_msgs() } or next;
        my $l = last_assistant($msgs);
        next unless $l && $l->{done} && (!$before || $l->{id} ne $before->{id});
        my ($tok, $seen) = (0, $before ? 0 : 1);
        for my $m (@$msgs) {
            if (!$seen) { $seen = 1 if ($m->{info}{id} // '') eq $before->{id}; next }
            $tok += $m->{info}{tokens}{total} // 0 if ($m->{info}{role} // '') eq 'assistant';
        }
        spit("$RunDir/last-response.txt", $l->{text});
        spit("$RunDir/done.json", JSON::PP->new->canonical->pretty->encode({
            status => 'DONE', exitCode => 0, backend => 'opencode', title => $prev->{title} // '',
            seconds => $prev->{seconds} // 0, log => "$RunDir/out.log", turn => ($prev->{turn} // 1) + 1, tokens => $tok + 0,
            conversation => $sid, lastResponse => "$RunDir/last-response.txt" }));
        return $l;
    }
    undef;
}

if ($Abort) { $http->post("$base/abort"); print "ABORTED\n"; exit 0 }
if ($Last)  { my $l = last_assistant(get_msgs()); print $l ? "$l->{text}\n" : "(no assistant message yet)\n"; exit 0 }
die "give -Text, -Last or -Abort\n" unless length $Text;

my $before = last_assistant(get_msgs());
my %body = (parts => [ { type => 'text', text => $Text } ]);
if ($Model) { my ($p, $m) = split m{/}, $Model, 2; $body{model} = { providerID => $p, modelID => $m } }
my $r = $http->post("$base/prompt_async", { headers => { 'Content-Type' => 'application/json' }, content => $json->encode(\%body) });
die "prompt_async failed: $r->{status} $r->{reason}\n" unless $r->{success};
unlink "$RunDir/done.json";   # a new turn is running: peek/band must not keep saying DONE
print "SENT\n";
if ($Wait) {
    my $l = record_done($before, time + $WaitSec);
    if ($l) { print "$l->{text}\n" } else { print "WAIT_EXPIRED (still working; use -Last later or -Abort)\n" }
} else {
    my $pid = fork();
    if (defined $pid && $pid == 0) {   # detached watcher: records done.json when the follow-up finishes
        setsid();
        open STDIN, '<', '/dev/null'; open STDOUT, '>', '/dev/null'; open STDERR, '>', '/dev/null';
        record_done($before, time + 3600);
        exit 0;
    }
}
