#!/usr/bin/perl
# Talk to a running (or recently finished) agent. (macOS/Linux twin of say.ps1; same flags.)
#   say -RunDir <RUN_DIR> -Text "also add a test for X"     send, return immediately
#   say -RunDir <RUN_DIR> -Text "..." -Wait [-WaitSec 300]  send, wait for the reply, print it
#   say -RunDir <RUN_DIR> -Last                              print the last assistant message
#   say -RunDir <RUN_DIR> -Abort                             interrupt (OpenCode: current turn; AGY: ends the session)
use strict; use warnings;
use FindBin; require "$FindBin::Bin/lib.pl";
use JSON::PP; use Getopt::Long; use HTTP::Tiny; use POSIX qw(strftime);
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

if ($Abort) { $http->post("$base/abort"); print "ABORTED\n"; exit 0 }
if ($Last)  { my $l = last_assistant(get_msgs()); print $l ? "$l->{text}\n" : "(no assistant message yet)\n"; exit 0 }
die "give -Text, -Last or -Abort\n" unless length $Text;

my $before = last_assistant(get_msgs());
my %body = (parts => [ { type => 'text', text => $Text } ]);
if ($Model) { my ($p, $m) = split m{/}, $Model, 2; $body{model} = { providerID => $p, modelID => $m } }
my $r = $http->post("$base/prompt_async", { headers => { 'Content-Type' => 'application/json' }, content => $json->encode(\%body) });
die "prompt_async failed: $r->{status} $r->{reason}\n" unless $r->{success};
print "SENT\n";
if ($Wait) {
    my $deadline = time + $WaitSec;
    while (time < $deadline) {
        sleep 2;
        my $l = last_assistant(get_msgs());
        if ($l && $l->{done} && (!$before || $l->{id} ne $before->{id})) { print "$l->{text}\n"; exit 0 }
    }
    print "WAIT_EXPIRED (still working; use -Last later or -Abort)\n";
}
