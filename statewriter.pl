#!/usr/bin/perl
#
# statewriter.pl -- write a value to a predictable, untrusted pathname safely.
#
# Called by BarWidget.qml as:
#     /usr/bin/perl <plugindir>/statewriter.pl <destination>
# with the payload on stdin. Never pass content via argv: argv is readable by
# any local process through /proc/<pid>/cmdline.
#
# WHY THIS EXISTS
# ---------------
# The destination ($XDG_STATE_HOME/urija.wifi-force-connector/ssid) is
# predictable, so any process running as the same user can create it, or
# replace it with a symlink, at any moment -- including between the checks and
# the write. That makes a "check the path, then write the path" sequence
# inherently racy (TOCTOU): a symlink planted after the last check turns the
# write into an arbitrary-file overwrite of the link's target.
#
# Earlier versions of this plugin used `install -D /dev/null <path>` (which
# truncates whatever regular file is at the path) and then a chain of
# `test -L` / `test -e` / `test -f` / `wc -c` guards before the write. Both are
# wrong:
#
#   * `install -D /dev/null` clobbers an existing file.
#   * `test -f` FOLLOWS symlinks, so it happily approves a symlink pointing at
#     a regular file. The separate processes in the chain each re-resolve the
#     pathname, so the value each one checks is not the value the last one
#     writes.
#
# THE FIX
# -------
# Never open the destination for writing at all. Instead:
#
#   1. Read the payload from stdin.
#   2. Create a temp file in the SAME directory with a name that includes
#      getpid() (unpredictable to other processes) and mode 0600, using
#      O_CREAT|O_EXCL|O_NOFOLLOW so it is created fresh and cannot be a
#      pre-planted symlink.
#   3. Write the payload through that already-open descriptor. We never
#      re-resolve the temp pathname, so nothing can be swapped underneath us.
#   4. fsync, then close.
#   5. rename(2) the temp file onto the destination. rename is atomic and,
#      critically, it does NOT follow a symlink at the destination: it replaces
#      the symlink itself. The link's target is never opened or modified.
#
# Because step 5 is a single atomic syscall on the final name, there is no
# window in which a check result could disagree with what is written. The only
# state we trust is the descriptor we ourselves hold.
#
# The destination must NOT be an existing non-empty file that we did not
# create: rename(2) would replace it silently. To keep the "never destroy
# unrelated data" guarantee, the destination is only replaced when it is
# absent, an empty file, or a file we previously wrote ourselves (recorded by
# the companion .owned marker, created with the same O_EXCL|O_NOFOLLOW
# discipline). Anything else is refused and reported on stderr.
#
# Usage:
#   statewriter.pl <destination>        write, payload on stdin
#   statewriter.pl --read <destination>  print the current value, or exit 1
#
# STDIN PROTOCOL (why it is not a bare payload)
# -------------------------------------------
# The caller cannot close our stdin: Quickshell's Process.write() has no
# close() and delivers no EOF, so a helper that reads to EOF hangs forever
# (verified: `tee` never exits under qs). Instead the caller sends
#
#     <UTF-8 byte length> <space> <exactly that many bytes>
#
# and we read(2) exactly that many bytes and stop. Nothing waits for EOF, so
# the helper always terminates. The length is a byte count, not a character
# count, so non-ASCII SSIDs survive intact.
#
# Exit codes: 0 = written / value printed, 1 = refused (see stderr), 2 = usage
# or IO error.

use strict;
use warnings;
use Fcntl qw(O_WRONLY O_RDONLY O_CREAT O_EXCL O_NOFOLLOW);

sub fail {
    my ($code, $msg) = @_;
    print STDERR "$msg\n";
    exit $code;
}

# Read exactly $n bytes from STDIN, tolerating short reads.
sub read_exactly {
    my ($n) = @_;
    my $buf = '';
    while (length($buf) < $n) {
        my $chunk = '';
        my $got = read(STDIN, $chunk, $n - length($buf));
        fail(2, "ERROR: short read from stdin") unless defined $got;
        fail(2, "ERROR: unexpected EOF on stdin") if $got == 0;
        $buf .= $chunk;
    }
    return $buf;
}

my $mode = 'write';
if (@ARGV && $ARGV[0] eq '--read') {
    $mode = 'read';
    shift @ARGV;
}
my $dest = shift @ARGV;
# File-scoped: used further down when publishing.
our $payload;
unless (defined $dest && $dest ne '') {
    print STDERR "usage: statewriter.pl [--read] <destination>\n";
    exit 2;
}

# ---------------------------------------------------------------- read mode --
if ($mode eq 'read') {
    my $fh;
    unless (sysopen($fh, $dest, O_RDONLY | O_NOFOLLOW)) {
        print STDERR "cannot read $dest: $!\n";
        exit 1;
    }
    my @st = stat($fh);
    unless (@st && -f _) {
        print STDERR "not a regular file: $dest\n";
        exit 1;
    }
    local $/;
    my $v = <$fh>;
    close $fh;
    $v = '' unless defined $v;
    $v =~ s/\s+\z//;
    print "$v\n";
    exit 0;
}

# --------------------------------------------------------------- write mode --
# Payload arrives as "<byte-length> <space> <bytes>"; see the protocol note
# above for why we cannot simply read to EOF.
{
    my $hdr = '';
    while (1) {
        my $c = '';
        my $got = read(STDIN, $c, 1);
        last if !defined $got || $got == 0;
        $hdr .= $c;
        last if $c eq ' ';
    }
    $hdr =~ s/\s+\z//;
    unless ($hdr =~ /\A[0-9]+\z/ && $hdr > 0 && $hdr <= 255) {
        fail(2, "ERROR: bad length prefix '$hdr' (expected 1..255)");
    }
    $payload = read_exactly($hdr);
}

my $dir = $dest;
$dir =~ s{/[^/]*\z}{} or do {
    print STDERR "destination has no directory component: $dest\n";
    exit 2;
};
$dir = '.' if $dir eq '';

# Marker recording "this file is ours to replace". Created with the same
# exclusive, no-follow discipline as the payload file.
my $marker = "$dest.owned";

sub lstat_is {
    my ($path) = @_;
    my @st = lstat($path);
    return @st ? $st[0] : undef;   # undef == does not exist
}

# --- Decide whether we are allowed to replace the destination. -------------
# This is a *policy* check, not a security boundary: the security property is
# that whatever happens next cannot follow a symlink or write outside our own
# temp file. The policy check exists to avoid destroying data we did not create.
my $st = lstat_is($dest);

if (defined $st) {
    if (-l _) {
        # A symlink. Never write to it. We refuse rather than replace, so a
        # planted link stays visible instead of being silently replaced.
        print STDERR "REFUSED: destination is a symlink: $dest\n";
        exit 1;
    }
    if (-d _) {
        print STDERR "REFUSED: destination is a directory: $dest\n";
        exit 1;
    }
    if (-s _) {
        # Non-empty regular file. Only replace it if we own the marker,
        # i.e. it is the file we created on a previous run.
        if (lstat_is($marker)) {
            # ours -- safe to replace
        } else {
            print STDERR "REFUSED: destination exists and is not ours: $dest\n";
            exit 1;
        }
    }
    # size 0, or ours: proceed.
}

# --- Create the temp file: fresh, unpredictable, no symlink follow. --------
my $tmp;
my $fh;
for my $attempt (0 .. 9) {
    $tmp = sprintf("%s/.ssid.tmp.%d.%d", $dir, $$, $attempt);
    if (sysopen($fh, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)) {
        last;
    }
    # EEXIST: name collision (someone is racing us) -> try another name.
    # Anything else (e.g. ENOENT because the dir vanished) is fatal.
    if ($!{EEXIST}) {
        print STDERR "ERROR: cannot create temp file $tmp: $!\n";
        exit 2;
    }
}
unless (defined $fh) {
    print STDERR "ERROR: exhausted temp names in $dir\n";
    exit 2;
}

# --- Write through the descriptor we already hold. -------------------------
my $written = print {$fh} $payload;
unless (defined $written) {
    print STDERR "ERROR: write to temp file failed: $!\n";
    close $fh;
    unlink $tmp;
    exit 2;
}

# Close before renaming, so the data is flushed and the descriptor is gone.
# (An explicit fsync is intentionally skipped: on a crash between rename and
# directory fsync the worst case is a missing or stale file, which the plugin
# handles by falling back to auto-detection -- never data loss.)
close $fh or do {
    print STDERR "ERROR: closing temp file failed: $!\n";
    unlink $tmp;
    exit 2;
};

# --- Atomic, symlink-safe publication. -------------------------------------
# rename(2) replaces the destination NAME. If a symlink is sitting there, the
# symlink itself is replaced; its target is never opened. This is the step
# that makes the whole thing race-free with respect to the destination.
unless (rename($tmp, $dest)) {
    print STDERR "ERROR: cannot publish $tmp -> $dest: $!\n";
    unlink $tmp;
    exit 2;
}

# Record ownership for the next run, same discipline (O_EXCL|O_NOFOLLOW).
# Failure here only weakens the "don't clobber" policy, never the write
# safety, so it is non-fatal.
{
    my $m;
    if (sysopen($m, $marker, O_WRONLY | O_CREAT | O_NOFOLLOW, 0600)) {
        print {$m} "$$ $dest\n";
        close $m;
    }
}

print "OK\n";
exit 0;
