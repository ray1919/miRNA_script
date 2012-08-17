#!/usr/bin/env perl
print '扫描当前目录及一级子目录中.gpr文件...',"\n";
open SMA, ">median.txt" or die "$!";
use Time::localtime;

my ( @routes, $dn, @sn );
&folder_information;

my ( %mirna, $book, $sheet, $format );
&read_data;

&merge_data;

&slide_median_normalization;

print ctime(),"\n<Finished, press ENTER key to exit>";
<STDIN>;
exit;

sub folder_information {
  @routes = glob "*/*.gpr *.gpr"; # gpr in current dir and sub dir
  @sn = @routes;
  $s = 0;
  map {$t = length($_);$s=$s<$t?$t:$s;} @routes;
  @sn = map {$_ . ' ' x ($s - length($_))} @routes;
  $dn = @sn;
  print ctime(),"\n\tTotal .gpr Count: $dn\n";
  print SMA ctime(),"\nTotal .gpr Count: $dn\n\n";
}

sub read_data {
  my ( $gpr, $flag, @line, $n, $s, %diff );
  $s    = 0;

  foreach $gpr (@routes) {
    open( GPR, $gpr ) || die "gpr file read error!";
    $flag = 0;
  # $mirna{SLIDE_key}{ID}
  # 0 -> name; 1 -> row_number; 2 -> F value; 3 -> F_B value;
  # 4 -> F median; 5 -> F_B median
    while (<GPR>) {
      if ( $flag == 1 ) {
        @line = split( "\t", $_ );
        $line[3] =~ s/^"|"$//g;
        $line[4] =~ s/^"|"$//g;

        $mirna{$s}{$line[4]}[0] = $line[3];
        push( @{ $mirna{$s}{ $line[4] }[3] }, $line[46] );
      }
      if (/^"Block"/) { $flag = 1; }
    }
    bar( ++$s, $dn );
  }
  close GPR;
  print "\n";
}

sub merge_data {
  my $id;

  # $mirna{SLIDE_key}{ID}
  # 0 -> name; 1 -> row_number; 2 -> F value; 3 -> F_B value;
  # 4 -> F median; 5 -> F_B median
  foreach $id (keys %{$mirna{0}}) {
    $flag = 1;
    for ( $slide = 0 ; $slide < $dn ; $slide++ ) {
      if (!defined $mirna{$slide}{$id}[3][0]) {
        print "ID $id 存在批次间差异，忽略计算\n";
        print SMA "ID $id 存在批次间差异，忽略计算\n";
        $flag = 0;
        delete $mirna{$slide}{$id};
        last;
      }
    }
    for ( $slide = 0 ; $slide < $dn ; $slide++ ) {
      if ($flag) {
        $mirna{$slide}{$id}[5] = median( @{ $mirna{$slide}{$id}[3] } ) * 1;
      }
    }
  }
}

sub slide_median_normalization {
  my ( $i, $sn, $id, %valid_median, $flag, $row_number );
  $row_number = 0;
  foreach $id ( keys %{ $mirna{0} } ) {
    $flag = 1;
    foreach $sn ( keys %mirna ) {
      if ( $mirna{$sn}{$id}[0] !~ /let|mir/i || $mirna{$sn}{$id}[5] < 30 ) {
        $flag = 0;
        last;
      }
    }
    if ( $flag == 1 ) {
      $row_number++;
      foreach $sn ( keys %mirna ) {
        push( @{ $valid_median{$sn} }, $mirna{$sn}{$id}[5] );
      }
    }
  }

  print "\n\nRow number is $row_number\n";
  print SMA "Row number is $row_number\n";
  print "\n\nmedian value in median normalization for each sample:\n";
  print SMA "\n\nmedian value in median normalization for each sample:\n";
  for ( $sn = 0 ; $sn < $dn ; $sn++ ) {
    $i = 1;
    print "\t",$sn[$sn], " : ", median( @{ $valid_median{$sn} } ), "\n";
    print SMA "\t",$sn[$sn], " : ", median( @{ $valid_median{$sn} } ), "\n";
  }
}
sub median{
   my @temp = sort {$a <=> $b} @_;
   my $size = scalar @temp;
   if($size%2==0){
     return ($temp[$size/2-1]+$temp[$size/2])/2;
   }
   else{
     return $temp[($size-1)/2];
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
