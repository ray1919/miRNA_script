#!/usr/bin/env perl
# Author: Zhao
# Date: 2012-07-18
# Purpose: list mirna name and dir name in sequence

use 5.010;

@gprs = glob "*/*.gpr";

say "\t\tImage\t\tSample\t\tGroup";
for $i ( 0 .. $#gprs ) {
  $gprs[$i] =~ /(\S+)\/(\S+)\.gpr/i;
  print "\t",$i+1, "\t$1\t$2";
  $name = $2;
  if ($name =~ s/\d+$//) {
    say "\t$name";
  }
  else {
    say '';
  }
}
