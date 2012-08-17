#!/usr/bin/env perl
#         FILE: miR_1c_median.pl
#
#  DESCRIPTION: calculate gpr median, choose appropriate gpr file
#
# REQUIREMENTS: perl packages (Statistics::Basic)
#         BUGS: ---
#        NOTES: 
#       AUTHOR: zr, zzqr@live.cn
#      COMPANY: KangChen Bio-tech
#      VERSION: 0.1
#      CREATED: 10/08/2011 11:47:11 AM
#     REVISION: 

#use strict;
use warnings;
use 5.010;
use Statistics::Basic qw/median/;
use File::Copy;

open SMA, ">median.log" or die "$!";

my ( @routes, $dn, %sn, @sn );    # $dn -> data number # %sn -> sample names
&folder_information;

my ( @raw, $rn, $book, $sheet, $format );
&read_data;

my (%mirna);
&merge_data;

my (@me);
&slide_median_normalization;

close SMA;
print "\n<Finished, press ENTER key to exit>";
print "<运行完毕，按回车键退出>";
<STDIN>;
exit;

sub folder_information {
  $dn = 0;
  @routes = glob "*/*.gpr";
  foreach (@routes) {
    if (/(.+?)\/(.+?)\.gpr$/) {
      push( @{$sn{$1}}, $dn++ );
      push( @sn, $2);
    }
    #if ( -e "$1/$2_W2.jpg" ) {
    #  print "$1/$2_W2.jpg", " is copied\n";
    #  print SMA "$1/$2_W2.jpg", " is copied\n";
    #}
  }
  print "FOLD_INFORMATION done\nTotal Sample Count: $dn\n";
  print "Reading .gpr files from sub-directories.\n";
  print SMA "FOLD_INFORMATION done\nTotal Sample Count: $dn\n\n";
}

sub read_data {
  my ( $gpr, $flag, @line, $n, $s );
  $s = 0;
  foreach $gpr (@routes) {
    $n = 0;
    $s++;
    open( GPR, $gpr ) || die "gpr file read error!";
    $flag = 0;
    while (<GPR>) {
      if ( $flag == 1 ) {
        @line = split( "\t", $_ );
        $line[3] =~ s/^"|"$//g;
        $line[4] =~ s/^"|"$//g;

        # Block Column Row Name ID
        if ( !exists $raw[$n] ) {
          push(
            @{ $raw[$n] },
            ( $line[0], $line[1], $line[2], $line[3], $line[4] )
          );
        }
        $raw[$n][ 4 + $s ] = $line[20];
        $raw[$n][ 4 + $s + $dn ] = $line[46];
        $n++;
      }
      if (/^"Block"/) { $flag = 1; }
      if (/^"ImageFiles=.*\\(\S+\\\S+)\.tif \d/) { $image_file = $1; }
      if (/^"JpegImage=.*\\(\S+\\\S+)\.jpg"/) { $jpeg_iamge = $1; }
    }
    if ($image_file ne $jpeg_iamge) {
      say "\n",$gpr;
      say $image_file;
      say $jpeg_iamge;
      <STDIN>;
    }
    bar( $s, $dn );
  }
  $rn = $#raw + 1;
  close GPR;
}

sub merge_data {
  my $id;

  # $mirna{SLIDE_key}{ID}
  # 0 -> name; 1 -> row_number; 2 -> F value; 3 -> F_B value;
  # 4 -> F median; 5 -> F_B median; 6 -> F_B cv; 7 -> nor_value
  for ( my $slide = 0 ; $slide < $dn ; $slide++ ) {
    for ( my $i = 0 ; $i < $rn ; $i++ ) {
      if ( !defined $mirna{$slide}{ $raw[$i][4] }[0] ) {
        $mirna{$slide}{ $raw[$i][4] }[0] = $raw[$i][3];
      }
      if ( !defined $mirna{$slide}{ $raw[$i][4] }[1] ) {
        push( @{ $mirna{$slide}{ $raw[$i][4] }[1] }, $i );
      }
      push( @{ $mirna{$slide}{ $raw[$i][4] }[2] }, $raw[$i][ 5 + $slide ] );
      push(
        @{ $mirna{$slide}{ $raw[$i][4] }[3] },
        $raw[$i][ 5 + $dn + $slide ]
      );
    }
    foreach $id ( sort { $a <=> $b } keys %{ $mirna{0} } ) {
      $mirna{$slide}{$id}[4] = median( @{ $mirna{$slide}{$id}[2] } ) * 1;
      $mirna{$slide}{$id}[5] = median( @{ $mirna{$slide}{$id}[3] } ) * 1;
    }
  }

}

sub slide_median_normalization {
  my ( $i, $sn, $id, %valid_median, $flag, %pick, $j, $sum, @sum );
  foreach $id ( keys %{ $mirna{0} } ) {
    $flag = 1;
    foreach $sn ( keys %mirna ) {
      if ( $mirna{$sn}{$id}[0] !~ /let|mir/i || $mirna{$sn}{$id}[5] < 30 ) {
        $flag = 0;
        last;
      }
    }
    if ( $flag == 1 ) {
      foreach $sn ( keys %mirna ) {
        push( @{ $valid_median{$sn} }, $mirna{$sn}{$id}[5] );
      }
    }
  }

  print "\n\nmedian value in median normalization for each sample:\n";
  print SMA "\n\nmedian value in median normalization for each sample:\n";
  # for ( $sn = 0 ; $sn < $dn ; $sn++ ) {
  foreach $i (sort {$sn{$a}[0] <=> $sn{$b}[0]} keys %sn){
    foreach $sn (@{$sn{$i}}){
      $me[$sn] = median( @{ $valid_median{$sn} } );
    }
  }
  for($j=int(min(@me));$j<int(max(@me));$j++){
    $sum = 0;
    foreach $i (sort {$sn{$a}[0] <=> $sn{$b}[0]} keys %sn){
      @tmp = ();
      foreach $sn (@{$sn{$i}}){
        push(@tmp,abs($me[$sn] - $j));
      }
      $sum += min(@tmp);
    }
    push(@sum,$sum);
  }
  for($j=int(min(@me));$j<int(max(@me));$j++){
    $sum = 0;
    foreach $i (sort {$sn{$a}[0] <=> $sn{$b}[0]} keys %sn){
      @tmp = ();
      foreach $sn (@{$sn{$i}}){
        push(@tmp,abs($me[$sn] - $j));
      }
      $sum += min(@tmp);
    }
    if($sum == min(@sum)){
      $choose = $j;
      last;
    }
  }
  print "choose => $choose\n"; # 最佳median值，所有gpr median离它最近
  print SMA "median => $choose\n";
  foreach $i (sort {$sn{$a}[0] <=> $sn{$b}[0]} keys %sn){
    foreach $sn (@{$sn{$i}}){
      push(@{$pick{$i}}, abs($me[$sn] - $choose));
    }
  }
  foreach $i (sort {$sn{$a}[0] <=> $sn{$b}[0]} keys %sn){
    print "  < $i >\n";
    print SMA "  < $i >\n";
    foreach $sn (@{$sn{$i}}){
      print "$sn[$sn]\t->\t$me[$sn]";
      print SMA "$sn[$sn]\t->\t$me[$sn]";
      if(min(@{$pick{$i}}) == abs($me[$sn] - $choose)){
        print "\t**\n";
        # 改名
        print "Name for this slide:";
        $name = <STDIN>;
        chomp($name);
        unless ($name eq '') {
          move("$i/$sn[$sn].gpr","$i/$name.gpr");
          move("$i/$sn[$sn]_W2.jpg","$i/$name"."_W2.jpg");
          move("$i/$sn[$sn]_R1.jpg","$i/$name"."_R1.jpg");
          print SMA "\t**\t$name\n";
        }
      }else{
        print "\n";
        print SMA "\n";
        # 分离文件
        mkdir "$i/obsoleted";
        @tmp = glob "$i/$sn[$sn]*";
        foreach $file (@tmp){
          move($file,"$i/obsoleted");
        }
      }
    }
  }

}

sub bar {
  local $| = 1;
  my $i = $_[0] || return 0;
  my $n = $_[1] || return 0;
  print "\r["
    . ( "#" x int( ( $i / $n ) * 50 ) )
    . ( " " x ( 50 - int( ( $i / $n ) * 50 ) ) ) . "]";
  printf( "%2.1f%%", $i / $n * 100 );
  local $| = 0;
}

sub max {
my $max = $_[0];
for ( @_[ 1..$#_ ] ) {
$max = $_ if $_ > $max;
}
return $max;
}

sub min {
my $min = $_[0];
for ( @_[ 1..$#_ ] ) {
$min = $_ if $_ < $min;
}
return $min;
}
