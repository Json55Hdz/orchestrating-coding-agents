#!/usr/bin/perl
# Runs ONE backend process with a watchdog. Internal: launched by dispatch.sh / viewer.sh. (macOS/Linux twin of worker.ps1.)
# Streams the child's output to this console (if visible) and to out.log.
#   opencode: `run --attach` one-shot; ends when the process ends.
#   agy:      ONE long-lived `--print` process in stream-json mode with stdin open. The first message is the brief;
#             later messages arrive via <RunDir>/inbox (say.pl). After each turn it writes done.json and waits idle
#             (up to IdleMin, or until another job is queued) for follow-ups.
# done.json status: DONE | FAILED | STALLED | TIMEOUT  (AGY: rewritten at the end of every turn).
use strict; use warnings;
use FindBin; require "$FindBin::Bin/lib.pl";
use JSON::PP; use Getopt::Long; use IO::Select; use IO::Handle; use POSIX qw(:sys_wait_h);
use Time::HiRes qw(time);

my ($RunDir, $Backend, $Dir, $Prompt, $Model, $Url, $SessionId, $Title, $Resume, $QueueDir) = ('', '', '', '', '', '', '', 'task', 0, '');
my ($TimeoutMin, $StallMin, $IdleMin) = (30, 10, 15);
Getopt::Long::Configure('ignore_case');
GetOptions('RunDir=s' => \$RunDir, 'Backend=s' => \$Backend, 'Dir=s' => \$Dir, 'Prompt=s' => \$Prompt, 'Model=s' => \$Model,
           'Url=s' => \$Url, 'SessionId=s' => \$SessionId, 'Title=s' => \$Title, 'Resume!' => \$Resume,
           'TimeoutMin=f' => \$TimeoutMin, 'StallMin=f' => \$StallMin, 'IdleMin=f' => \$IdleMin, 'QueueDir=s' => \$QueueDir)
    or die "bad arguments\n";
die "RunDir, Backend, Dir and Prompt are required\n" unless $RunDir && $Backend && $Dir && length $Prompt;

$SIG{PIPE} = 'IGNORE'; $| = 1;
my $isAgy = $Backend eq 'agy';
my $out = "$RunDir/out.log"; my $done = "$RunDir/done.json"; my $inbox = "$RunDir/inbox";
my $json = JSON::PP->new->canonical;          # one line per message (stdin of agy)
my $pretty = JSON::PP->new->canonical->pretty; # done.json
my $tty = -t STDOUT;
sub col { my ($c, $t) = @_; $tty ? "\e[${c}m$t\e[0m" : $t }
print "\e]0;[$Backend] $Title\a" if $tty;
spit("$RunDir/worker.pid", "$$\n");

my ($exe, @args);
if (!$isAgy) {
    @args = ('run', '--attach', $Url, '--dir', $Dir, '--auto', '--format', 'json', '--title', $Title);
    push @args, '-m', $Model if $Model;
    if ($SessionId) { push @args, '-s', $SessionId } elsif ($Resume) { push @args, '-c' }
    push @args, $Prompt;
    $exe = 'opencode';
} else {
    mkdir $inbox;
    @args = ('--dangerously-skip-permissions', '--add-dir', $Dir, '--add-dir', $RunDir, '--project', $Title);
    if ($Resume) { unshift @args, '-c' } else { push @args, '--new-project' }
    push @args, '--model', $Model if $Model;
    push @args, '--input-format', 'stream-json', '--output-format', 'stream-json', '--print', '';
    $exe = resolve_agy();
}

my $start = time;
my ($turnStart, $lastOut, $idleSince) = ($start, $start, undef);
my ($sent, $results, $turnTokens, $convId) = (0, 0, 0, '');
my $inW;

sub write_done {
    my ($status, $code) = @_;
    spit($done, $pretty->encode({ status => $status, exitCode => $code, backend => $Backend, title => $Title,
        seconds => int(time - $start), log => $out, turn => $results + 0, tokens => $turnTokens + 0,
        conversation => $convId, lastResponse => "$RunDir/last-response.txt" }));
}
sub send_user {
    my ($text) = @_;
    print $inW $json->encode({ event => 'user', message => { content => $text } }) . "\n";
    $inW->flush; $sent++;
}
sub show_agy_line {
    my ($line) = @_;
    my $j = eval { decode_json($line) };
    if (!$j || ref $j ne 'HASH') { print "$line\n"; return }
    my $ev = $j->{event} // '';
    if ($ev eq 'init') {
        $convId = $j->{conversation_id} // '';
        print col(36, sprintf("> agy  model=%s  conversation=%s", $j->{init}{model} // '', $convId)) . "\n";
    } elsif ($ev eq 'step_update') {
        my $s = $j->{step_update} || {};
        my $type = $s->{step_type} // '';
        if ($type eq 'tool') {
            if (($s->{state} // '') eq 'ACTIVE') {
                my $sum = first_param($s->{tool_info}{parameters}); $sum = substr($sum, 0, 110) . '...' if length $sum > 110;
                print "\n" . col(33, "  > " . ($s->{tool_name} // '') . " $sum") . "\n";
            } elsif (($s->{state} // '') eq 'DONE') {
                print col(90, sprintf("    done in %.1fs", $s->{duration_seconds} // 0)) . "\n";
            }
        } elsif ($type eq 'agent_response' && defined $s->{text_delta}) {
            print $s->{text_delta};
        }
    } elsif ($ev eq 'result') {
        my $r = $j->{result} || {};
        $results++; $turnTokens = $r->{usage}{total_tokens} // 0;
        spit("$RunDir/last-response.txt", $r->{response} // '');
        write_done((($r->{status} // '') eq 'SUCCESS' ? 'DONE' : 'FAILED'), undef);
        $idleSince = time if $sent <= $results;
        print "\n" . col(32, sprintf("=== turn %d: %s  (%d tokens, %ds) ===", $results, $r->{status} // '', $turnTokens, $r->{duration_seconds} // 0)) . "\n";
    }
}

spit("$RunDir/started", iso_now() . "\n");
pipe(my $outR, my $outW) or die; pipe(my $errR, my $errW) or die;
my ($inR);
pipe($inR, $inW) or die if $isAgy;
my $pid = fork(); die "fork: $!" unless defined $pid;
if ($pid == 0) {
    setpgrp(0, 0);
    chdir $Dir;
    close $outR; close $errR; close $inW if $isAgy;
    open STDOUT, '>&', $outW; open STDERR, '>&', $errW;
    if ($isAgy) { open STDIN, '<&', $inR } else { open STDIN, '<', '/dev/null' }
    exec { $exe } $exe, @args or do { print STDERR "cannot run $exe: $!\n"; exit 127 };
}
close $outW; close $errW; close $inR if $isAgy;
spit("$RunDir/pid", "$pid\n");
if ($isAgy) { $inW->autoflush(1); send_user($Prompt) }

open my $log, '>>', $out or die "cannot write $out: $!";
$log->autoflush(1);
my $sel = IO::Select->new($outR, $errR);
my %buf = (fileno($outR) => '', fileno($errR) => '');
my $status;

sub handle_line {
    my ($line, $isOut) = @_;
    $line =~ s/\r$//;
    print $log "$line\n";
    if ($isAgy && $isOut) { show_agy_line($line) } else { print "$line\n" }
    $lastOut = time;
}

while (1) {
    my $got = 0;
    for my $fh ($sel->can_read(0.1)) {
        my $key = fileno($fh);
        my $n = sysread($fh, my $chunk, 65536);
        next unless defined $n;
        if ($n == 0) {
            handle_line($buf{$key}, $fh == $outR) if length $buf{$key};
            $buf{$key} = ''; $sel->remove($fh); next;
        }
        $buf{$key} .= $chunk; $got = 1;
        while ($buf{$key} =~ s/^([^\n]*)\n//) { handle_line($1, $fh == $outR) }
    }
    last unless $sel->count;

    if ($isAgy && opendir(my $dh, $inbox)) {   # follow-up messages from say.pl
        my @files = sort(grep { /\.txt$/ } readdir $dh);
        for my $f (@files) {
            my $p = "$inbox/$f";
            my $text = slurp($p); unlink $p; unlink $done;
            $text = '' unless defined $text;
            print "\n" . col(35, "[you] $text") . "\n";
            if ($sent <= $results) { $turnStart = time; $lastOut = time; $idleSince = undef }
            send_user($text);
        }
        closedir $dh;
    }
    my $now = time;
    my $busy = !$isAgy || $sent > $results;
    if ($busy) {
        if (($now - $turnStart) / 60 > $TimeoutMin) { $status = 'TIMEOUT'; last }
        if (($now - $lastOut) / 60 > $StallMin)     { $status = 'STALLED'; last }
    } else {
        if (defined $idleSince && ($now - $idleSince) / 60 > $IdleMin) { $status = 'IDLE_EXIT'; last }
        if ($QueueDir && opendir(my $qd, $QueueDir)) { my @j = grep { /\.job$/ } readdir $qd; closedir $qd; if (@j) { $status = 'IDLE_EXIT'; last } }
    }
}

close $inW if $inW;
my $code = -1;
my $deadline = time + 4; my $reaped = 0;
while (time < $deadline) { my $r = waitpid($pid, WNOHANG); if ($r == $pid) { $reaped = 1; $code = ($? & 127) ? -1 : ($? >> 8); last } select(undef, undef, undef, 0.1) }
if (!$reaped) { tree_kill($pid); waitpid($pid, 0); $code = -1 }
else { kill 'KILL', -$pid }   # stragglers in the child's group

if ($isAgy) {
    write_done($status // 'FAILED', $code) if ($status && $status =~ /^(STALLED|TIMEOUT|FAILED)$/) || !-e $done;
} else {
    $status = $code == 0 ? 'DONE' : 'FAILED' unless $status;
    write_done($status, $code);
}
my $final = ($status // '') eq 'IDLE_EXIT' ? 'session closed (idle)' : sprintf('%s (exit %s)', $status // 'DONE', $code);
print "\n" . col(36, "=== $final ===") . "\n";
