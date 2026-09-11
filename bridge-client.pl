#!/usr/bin/perl
# Container-side bridge client. This is the file you point Jellyfin's
# --ffmpeg flag (or its Playback / Transcoding path setting) at, in place of
# a real ffmpeg binary. Written in Perl because Perl's core IO::Socket and
# IO::Select modules are enough to implement this with no extra packages -
# useful if your Jellyfin image doesn't ship Python and you don't want to
# install one just for this.
#
# Stands in for "ffmpeg" from Jellyfin's point of view: receives argv exactly
# as ffmpeg would, forwards the job to the host bridge daemon, relays
# stdout/stderr live as bytes arrive, forwards a stop request on
# SIGTERM/SIGINT, and exits with the same code the real ffmpeg process on
# the host produced.
#
# STDOUT/STDERR writes here are non-blocking and buffered, decoupled from
# the loop that drains the daemon socket. This matters more than it looks:
# a plain blocking `print STDOUT $payload` can stall forever whenever
# nobody downstream is actually reading that fd - and for a real Jellyfin
# transcode job, nobody is (Jellyfin doesn't redirect/read its ffmpeg
# subprocess's stdout for that case). Once such a write blocks, this script
# stops reading the socket, which backpressures the daemon, which
# backpressures the real ffmpeg process on the host - a full deadlock of
# the entire pipeline triggered by an fd nobody even needed. With a bounded,
# non-blocking buffer instead, a full or absent destination just means the
# buffer holds what it can't flush yet (oldest bytes dropped on overflow),
# and the socket-drain loop keeps moving regardless.
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);

# Must match the daemon's BRIDGE_BIND_ADDR/BRIDGE_PORT - see bridge-daemon.py.
# Set these via the container's environment (or your ffmpeg-path wrapper)
# rather than editing this file. 172.17.0.1 is Docker's default bridge
# network gateway - override if you're using a custom network.
my $DAEMON_HOST = $ENV{BRIDGE_HOST} || "172.17.0.1";
my $DAEMON_PORT = $ENV{BRIDGE_PORT} || 9919;

my $sock = IO::Socket::INET->new(
    PeerAddr => $DAEMON_HOST,
    PeerPort => $DAEMON_PORT,
    Proto    => 'tcp',
) or die "bridge-client: connect to $DAEMON_HOST:$DAEMON_PORT failed: $!\n";
binmode($sock);

sub json_escape {
    my ($s) = @_;
    $s =~ s/([\\"])/\\$1/g;
    $s =~ s/\n/\\n/g;
    return $s;
}
my $json = '{"argv":[' . join(",", map { '"' . json_escape($_) . '"' } @ARGV) . ']}';
print $sock pack("N", length($json));
print $sock $json;

binmode(STDOUT);
binmode(STDERR);

for my $fh (\*STDOUT, \*STDERR) {
    my $flags = fcntl($fh, F_GETFL, 0) or die "bridge-client: fcntl F_GETFL failed: $!\n";
    fcntl($fh, F_SETFL, $flags | O_NONBLOCK) or die "bridge-client: fcntl F_SETFL failed: $!\n";
}

my $want_kill = 0;
$SIG{TERM} = sub { $want_kill = 1; };
$SIG{INT}  = sub { $want_kill = 1; };

my $sel = IO::Select->new($sock);
my $buffer = '';
my $rc = 1;

# Bounded, per-stream output buffers - filled from frames off the socket,
# drained opportunistically via non-blocking syswrite. Never grown without
# limit and never the thing the main loop blocks on.
my %out_fh  = (1 => \*STDOUT, 2 => \*STDERR);
my %out_cap = (1 => 65536, 2 => 8 * 1024 * 1024);
my %out_buf = (1 => '', 2 => '');

sub flush_buffers {
    for my $ftype (1, 2) {
        next if $out_buf{$ftype} eq '';
        my $n = syswrite($out_fh{$ftype}, $out_buf{$ftype});
        if (defined $n && $n > 0) {
            substr($out_buf{$ftype}, 0, $n, '');
        }
        # undef (EAGAIN/EWOULDBLOCK, or a closed/broken reader on the other
        # end) just leaves the buffer as-is for next time - never blocks.
    }
}

sub buffer_payload {
    my ($ftype, $payload) = @_;
    $out_buf{$ftype} .= $payload;
    my $over = length($out_buf{$ftype}) - $out_cap{$ftype};
    if ($over > 0) {
        # Drop the oldest excess rather than block or grow unbounded.
        substr($out_buf{$ftype}, 0, $over, '');
    }
}

MAIN: while (1) {
    if ($want_kill) {
        print $sock "KILL";
        $want_kill = 0;
    }
    flush_buffers();
    my @ready = $sel->can_read(1);
    unless (@ready) {
        next MAIN;
    }
    my $chunk;
    my $n = sysread($sock, $chunk, 65536);
    last MAIN if !defined($n) || $n == 0;
    $buffer .= $chunk;
    while (1) {
        last if length($buffer) < 5;
        my ($ftype, $flen) = unpack("CN", substr($buffer, 0, 5));
        last if length($buffer) < 5 + $flen;
        my $payload = substr($buffer, 5, $flen);
        $buffer = substr($buffer, 5 + $flen);
        if ($ftype == 1 || $ftype == 2) {
            buffer_payload($ftype, $payload);
        } elsif ($ftype == 3) {
            $rc = unpack("l>", $payload);
            last MAIN;
        }
    }
    flush_buffers();
}
# Best-effort final drain - a slow/absent reader must not delay our own exit.
for (1 .. 5) {
    last if $out_buf{1} eq '' && $out_buf{2} eq '';
    flush_buffers();
}
close($sock);
exit($rc);
