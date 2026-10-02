#!/usr/bin/perl
use strict;
use warnings;

use Fcntl qw(O_CREAT O_EXCL O_RDWR O_WRONLY LOCK_EX LOCK_UN);
use POSIX ();

my ($lock_path, $relay_role) = @ARGV;
die "usage: swift-test-output-relay.pl <lock-path> <relay-role>\n"
  unless defined $lock_path && defined $relay_role;

sysopen(my $lock_file, $lock_path, O_CREAT | O_RDWR, 0666)
  or die "cannot open output lock $lock_path: $!\n";

binmode STDIN;
binmode STDOUT;
POSIX::close(94) if $relay_role ne "dispatcher";
record_relay_start($relay_role);

while (defined(my $line = <STDIN>)) {
  flock($lock_file, LOCK_EX) or die "cannot acquire output lock $lock_path: $!\n";
  write_complete_line($line);
  flock($lock_file, LOCK_UN) or die "cannot release output lock $lock_path: $!\n";
}

sub write_complete_line {
  my ($line) = @_;
  my $offset = 0;
  my $line_length = length $line;

  while ($offset < $line_length) {
    my $chunk = substr($line, $offset, 512);
    my $written = syswrite(STDOUT, $chunk);
    die "cannot write relayed output: $!\n" unless defined $written;
    die "output relay wrote zero bytes\n" if $written == 0;
    $offset += $written;
  }
}

sub record_relay_start {
  my ($relay_role) = @_;
  my $directory = $ENV{SWIFT_TEST_OUTPUT_RELAY_START_DIRECTORY} // "";
  return if $directory eq "";

  my $marker_path = "$directory/$relay_role-$$";
  sysopen(my $marker_file, $marker_path, O_CREAT | O_EXCL | O_WRONLY, 0600)
    or die "cannot create output relay marker $marker_path: $!\n";
  print {$marker_file} "$$\n" or die "cannot write output relay marker $marker_path: $!\n";
  close $marker_file or die "cannot close output relay marker $marker_path: $!\n";
}
