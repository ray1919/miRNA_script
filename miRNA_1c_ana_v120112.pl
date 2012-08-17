#!/usr/bin/env perl
#         FILE: miRNA_1c_ana_zhao.pl
#
#  DESCRIPTION: automate the analysis of 1-color miRNA microarray analysis,
#               produve results required.
#
# REQUIREMENTS: perl packages (Statistics::Basic, Statistics::Lite,
#               Excel::Writer::XLSX, Statistics::TTest) required
#         BUGS: ---
#        NOTES: prepare compare.txt for comparison pairs setting
#       AUTHOR: zr, zzqr@live.cn
#      COMPANY: KangChen Bio-tech
#      VERSION: 0.5
#      CREATED: 07/27/2011 01:36:39 PM
#     REVISION: 2012-01-12 17:10
#       UPDATE: require same id and name field.

use strict;
use warnings;
use Statistics::Basic qw/correlation average median/;
use Statistics::Lite qw/stddev/;
use File::Copy;
use Excel::Writer::XLSX;
use Statistics::ANOVA;
use Time::localtime;
use 5.010;

mkdir "result";
mkdir "temp";
mkdir "Array_Image";

open SMA, ">result/summary.txt" or die "$!";
print SMA "Code version: v2012-01-12\n";
print SMA ctime(),"\n";

my ( @routes, $dn, @sn );    # $dn -> data number # @sn -> sample names
&folder_information;

my ( @pairs, @pairn, %groups, $is_paired );
&pair_input;

my ( @raw, $rn, $book, $sheet, $format );
&read_data;

my (%mirna);
&merge_data;

&slide_median_normalization;

my ( @gpairn, %sn, @expression, %expre_col, %gn, %pv, %fold, $pc );
&expression;

&R_boxplot;

&differential;

&get_spike;

&micv;

close SMA;
say '<Finished, press ENTER key to exit>';
say '<运行完毕，按回车键退出>';
<STDIN>;
exit;

sub folder_information {
  @routes = glob "*/*.gpr";
  foreach (@routes) {
    if (/(.+?)\/(.+?)\.gpr$/) {
      push( @sn, $2 );
    }
    if ( -e "$1/$2_W2.jpg" && !-e "Array_Image/$2.jpg" ) {
      copy( "$1/$2_W2.jpg", "Array_Image/$2.jpg" );
      print "$1/$2_W2.jpg", " is copied\n";
      print SMA "$1/$2_W2.jpg", " is copied\n";
    }
  }
  $dn = @sn;
  print "FOLD_INFORMATION done\nTotal Sample Count: $dn\n";
  print "Reading .gpr files from sub-directories.\n";
  print SMA "FOLD_INFORMATION done\nTotal Sample Count: $dn\n\n";
}

sub read_data {
  my ( $gpr, $flag, @line, $n, $s, %diff, $note, %lotNum, $lotNum );
  $s    = 0;
  $note = "";

  # lot Number checking
  foreach $gpr (@routes) {
    $s++;
    open( GPR, $gpr ) || die "gpr file read error!";
    while (<GPR>) {
      if (/^"LotNumberRange=\d+-(\d+)"/) {
        $lotNum{$s} = $1;
        $lotNum = $s == 1 ? $1 : $lotNum < $1 ? $1 : $lotNum;
        if ( $lotNum ne $1 ) {
          print "LotNumber difference FOUND!批号不一致，进行ID，Name校验\n";
          print SMA "LotNumber difference FOUND!批号不一致，进行ID，Name校验\n";
        }
        last;
      }
    }
  }
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
        elsif ( $line[3] ne $raw[$n][3]
          && $line[4] eq $raw[$n][4]
          && $lotNum{$s} == $lotNum )
        {
          $raw[$n][3] = $line[3];
        }
        elsif ( $line[4] ne $raw[$n][4] ) {
          $diff{$n} =
            "Block $line[0], Col $line[1], Row $line[2] ID不一致，已删除\n";
        }
        $raw[$n][ 4 + $s ] = $line[20];
        $raw[$n][ 4 + $s + $dn ] = $line[46];
        $n++;
      }
      if (/^"Block"/) { $flag = 1; }
    }
    bar( $s, $dn );
  }
  foreach $s ( sort { $b <=> $a } keys %diff ) {
    splice( @raw, $s, 1 );
    print SMA $diff{$s};
  }
  close GPR;
  $rn = $#raw + 1;

  # 输出 raw data的报告xls
  my $notetext =
qq~# This page contains raw intensities for all $dn slides.\n# Column "Block": block number of each probe.\n# Column "Column": column number of each probe.\n# Column "Row": row number of each probe.\n# Column "Name": the name of each miRNA/probe.\n# Column "ID": array ID of the probes, each miRNA always has its unique probe, but some miRNAs may have two different probes.\n# Column "ForeGround": the foreground intensity of each probe.\n# Column "ForeGround-BackGround": the signal of the probe after background correction.~;
  $book   = Excel::Writer::XLSX->new('Raw Intensity File.xlsx');
  $sheet  = $book->add_worksheet("Raw Intensity File");
  $format = $book->add_format();

  # note
  $format->set_font('Verdana');
  $format->set_size(10);
  $format->set_bg_color(26);
  $format->set_text_wrap();
  $format->set_align("top");
  $sheet->set_row( 0, 150 );
  $sheet->merge_range( "A1:I1", $notetext, $format );

  # title
  $format = $book->add_format();
  $format->set_font("Arial");
  $format->set_bold();
  $format->set_align("center");
  $format->set_size(11);
  $format->set_bg_color(61);
  $sheet->merge_range( 2, 5, 2, 4 + $dn, "ForeGround", $format );
  $format = $book->add_format();
  $format->set_font("Arial");
  $format->set_bold();
  $format->set_align("center");
  $format->set_size(11);
  $format->set_bg_color(13);
  $sheet->merge_range( 2, 5 + $dn, 2, 4 + 2 * $dn,
    "ForeGround-BackGround", $format );

  $format = $book->add_format();
  $format->set_font("Arial");
  $format->set_bold();
  my @row = ( "Block", "Column", "Row", "Name", "ID" );
  foreach $s (@sn) { push( @row, $s . "_f" ); }
  foreach $s (@sn) { push( @row, $s . "_f_b" ); }
  $sheet->write_row( "A4", \@row, $format );

  # value
  $format = $book->add_format();
  $format->set_font("Arial");
  $format->set_align("left");
  $sheet->set_column( "A:C", 8 );
  $sheet->set_column( "D:D", 18 );
  print "\nSaving <Raw Intensity File.xlsx>\n";
  $sheet->write_col( 4, 0, \@raw, $format );
  $book->close() or die "\nError closing file: $!";
  print SMA "<Raw Intensity File.xlsx> saved.\n";
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
      $mirna{$slide}{$id}[6] =
          average( @{ $mirna{$slide}{$id}[3] } ) != 0
        ? stddev( @{ $mirna{$slide}{$id}[3] } ) /
        average( @{ $mirna{$slide}{$id}[3] } )
        : "N/A";
    }
  }

}

sub slide_median_normalization {
  my ( $i, $sn, $id, %valid_median, $flag );
  foreach $id ( keys %{ $mirna{0} } ) {
    $flag = 1;
    foreach $sn ( keys %mirna ) {
      if ( $mirna{$sn}{$id}[0] !~ /let|mir/i || $mirna{$sn}{$id}[5] < 50 ) {
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
  for ( $sn = 0 ; $sn < $dn ; $sn++ ) {
    $i = 1;
    print $sn[$sn], " :\t", median( @{ $valid_median{$sn} } ), "\n";
    print SMA $sn[$sn], " :\t", median( @{ $valid_median{$sn} } ), "\n";
    foreach $id ( keys %{ $mirna{0} } ) {
      $mirna{$sn}{$id}[7] = $mirna{$sn}{$id}[5] > 0
        ? $mirna{$sn}{$id}[5] / median( @{ $valid_median{$sn} } )
        : 'N/A';
    }
  }

}

sub pair_input {
  print "\n-------
Please indicate fold-change comparison pair(s) in compare.txt.
type one comparison per line:
compare.txt 输入模板，每行写一对比较
\texample:
B vs A
C vs A
C vs B

CAUTION: sample names are case-sensitive, mis-input will make no sense!\n
请注意区分大小写和错误拼写！
If the comparison pair(s) is between groups, use ',' between names in
one group, and include name of the group in '()' to indicate different
groups like this:
如遇分组比较情况，请按如下格式一次逐行输入
（组名写在英文括号中，同组内不同样品名按顺序用英文逗号隔开）
\ttreat1,treat2,treat3(treat) vs control1,control2,control3(control)\n\n";
  my $pair = "";
  my ( $flag, @sa, @sb, $ga, $gb, $n, $i, $name, $k );
  $i = 1;
  $n = 0;
  $is_paired = 1;
  if ( -e "compare.txt" ) {
    open( IN, "compare.txt" ) or die "File read error!";
  }
  else {
    print "Make sure the compare.txt file in the home directory is ready.\n";
    print "<error found, press ENTER key to exit>";
    <STDIN>;
    exit;
  }
  while ( $pair = <IN> ) {
    print "pair $i: $pair";
    if ( $pair =~ /(\S+)\((\S+)\)\s+vs\s+(\S+)\((\S+)\)/ ) {
      @sa   = split( ",", $1 );
      $ga   = $2;
      @sb   = split( ",", $3 );
      $gb   = $4;
      $flag = 1;
      foreach $name (@sa,@sb) {
        $flag = check_sample($name);
        last if ($flag == 0);
      }
      if ( $flag == 1 ) {
        print "Pair $ga vs $gb was added to the list.\n";
        print SMA "Pair $ga vs $gb was added to the list.\n";
        $pairs[$n][0] = [@sa];
        $pairs[$n][1] = [@sb];
        if ( $#sa >= 0 ) { $groups{$ga} = [@sa]; }
        if ( $#sb >= 0 ) { $groups{$gb} = [@sb]; }
        chomp($pair);
        push( @pairn, "$ga vs $gb" );
        $n++;
        $is_paired = 0 if ($#sa != $#sb);
      }
    }
    elsif ( $pair =~ /(\S+)\s+vs\s+(\S+)/ ) {
      @sa    = ();
      $sa[0] = $1;
      @sb    = ();
      $sb[0] = $2;
      if ( check_sample($sa[0]) == 1 && check_sample($sb[0]) == 1 ) {
        print "Pair $sa[0] vs $sb[0] was added to the list.\n";
        print SMA "Pair $sa[0] vs $sb[0] was added to the list.\n";
        $pairs[$n][0] = [@sa];
        $pairs[$n][1] = [@sb];
        chomp($pair);
        push( @pairn, "$sa[0] vs $sb[0]" );
        $n++;
      }
    }
    $i++;
  }
  if ( $n == 0 ) {
    print "There is no compare setting found. Check your compare.txt\n";
    print "<error found, press ENTER key to exit>";
    <STDIN>;
    exit;
  }
  else {
    print "$n pair(s) will be added to the result.\n-------\n";
    print SMA "$n pair(s) will be added to the result.\n-------\n";
  }

  # 调整样品出现顺序
  my %sn;
  foreach $k (sort keys %groups ) {
    foreach $i ( @{ $groups{$k} } ) {
      next if (exists $sn{$i});
      $n = scalar keys %sn;
      &swap( \@sn,     $i, $n );
      &swap( \@routes, $i, $n );
      $sn{$i} = 1;
    }
  }

  # 询问是否进行配对样品处理
  if ($is_paired == 1 && scalar keys %groups > 1) {
    print "是否作为 配对样品 进行计算p value (y/N):";
    $n = <STDIN>;
    chomp $n;
    if ( defined $n && ( $n eq 'y' || $n eq 'Y' ) ) {
      print "进行配对样品计算。\n";
      print SMA "进行配对样品计算。\n";
    }
    else{
      $is_paired = 0;
      print "进行非配对样品计算。\n";
      print SMA "进行非配对样品计算。\n";
    }
  }

}

sub check_sample{
  my $f = shift;
  my @r = glob '*/'.$f.'.gpr';
  return (defined $r[0] ? 1 : 0);
}

sub swap {
  my ( $i, $k, $a, $n, $t1, $t2 );
  ( $a, $k, $n ) = @_;
  $k =~ s/\+/\\\+/g;
  $k =~ s/\//\\\//g;
  if ( $$a[$n] =~ m/$k$|$k\.gpr$/ ) {
    return 1;
  }
  else {
    $t1 = $$a[$n];
    for ( $i = 0 ; $i < @$a ; $i++ ) {
      if ( $$a[$i] =~ m/$k$|$k\.gpr$/ ) {
        $t2 = $$a[$i];
        $$a[$i] = $t1;
        last;
      }
    }
    $$a[$n] = $t2;
    return 2;
  }
}

sub expression {
  my ( $gn, $i, $j, $mean0, $mean1, @mean0, @mean1, $id, @line, $n );
  my ( $ttest, %cv, @title, $line_pv, $line_cv, $line_tt);

  # 先计算fold-change 和 p-value
  for ( $i = 0 ; $i < $dn ; $i++ ) { $sn{ $sn[$i] } = $i; }
  foreach $id ( keys %{ $mirna{0} } ) {
    for ( $i = 0 ; $i < @pairs ; $i++ ) {
      @mean0 = ();
      for ( $j = 0 ; $j < @{ $pairs[$i][0] } ; $j++ ) {
        if ( $mirna{ $sn{ $pairs[$i][0][$j] } }{$id}[7] ne 'N/A' ) {
          push( @mean0, $mirna{ $sn{ $pairs[$i][0][$j] } }{$id}[7] );
        }
      }
      @mean1 = ();
      for ( $j = 0 ; $j < @{ $pairs[$i][1] } ; $j++ ) {
        if ( $mirna{ $sn{ $pairs[$i][1][$j] } }{$id}[7] ne 'N/A' ) {
          push( @mean1, $mirna{ $sn{ $pairs[$i][1][$j] } }{$id}[7] );
        }
      }
      if ( defined $mean0[0] && defined $mean1[0] ) {
        $mean0         = average(@mean0);
        $mean1         = average(@mean1);
        $fold{$id}[$i] = $mean0 / $mean1;
      }
      else {
        $fold{$id}[$i] = 'N/A';
      }

      if ( $is_paired == 0 ){
        # p-value of t-test between none-paired groups
        if (  scalar @{ $pairs[$i][0] } > 1
          and scalar @{ $pairs[$i][1] } > 1 )
        {
          if ( scalar @mean0 >= 2 && scalar @mean1 >= 2 ) {
            $ttest = Statistics::ANOVA->new();
            $ttest->load_data( { 1 => \@mean0, 2 => \@mean1 } );
            $ttest->anova( independent => 1, parametric => 1, ordinal => 0 );
            $ttest->string() =~ /p = (.+)$/;
            $pv{$id}[$i] = $1;
          }
          else {
            $pv{$id}[$i] = 'N/A';
          }
        }
      }
      elsif( $is_paired == 1 ){
        # p-value of t-test between paired groups
        if (  scalar @{ $pairs[$i][0] } > 1
          and scalar @{ $pairs[$i][1] } > 1
          and scalar @{ $pairs[$i][1] } == scalar @{ $pairs[$i][0] } )
        {
        @mean0 = ();
        @mean1 = ();
        for ( $j = 0 ; $j < @{ $pairs[$i][0] } ; $j++ ) {
          if ( $mirna{ $sn{ $pairs[$i][0][$j] } }{$id}[7] ne 'N/A'
            and $mirna{ $sn{ $pairs[$i][1][$j] } }{$id}[7] ne 'N/A' ) {
            push( @mean0, $mirna{ $sn{ $pairs[$i][0][$j] } }{$id}[7] );
            push( @mean1, $mirna{ $sn{ $pairs[$i][1][$j] } }{$id}[7] );
          }
        }
          if ( scalar @mean0 >= 2 && scalar @mean1 >= 2 ) {
            $ttest = Statistics::ANOVA->new();
            $ttest->load_data( { 1 => \@mean0, 2 => \@mean1 } );
            $ttest->anova( independent => 0, parametric => 1, ordinal => 0 );
            $ttest->string() =~ /p = (.+)$/;
            $pv{$id}[$i] = $1;
          }
          else {
            $pv{$id}[$i] = 'N/A';
          }
        }
      }

      if ( scalar @{ $pairs[$i][0] } > 1 and scalar @{ $pairs[$i][1] } > 1 ) {
        $pc = 0.05;
      }

    }
    # CV-value calculation
    if ( scalar( keys %groups ) > 0 ) {
      foreach $gn ( keys %groups ) {
        @mean0 = ();
        foreach $j ( @{ $groups{$gn} } ) {
          if ( $mirna{ $sn{$j} }{$id}[7] ne 'N/A' ) {
            push( @mean0, $mirna{ $sn{$j} }{$id}[7] );
          }
        }
        if ( defined $mean0[1] ) {
          $cv{$id}{$gn} = stddev(@mean0) / average(@mean0);
        }
        else {
          $cv{$id}{$gn} = 'N/A';
        }
      }
    }
  }
  for ( $i = 0 ; $i < @pairs ; $i++ ) {
    if ( scalar @{ $pairs[$i][0] } > 1 && scalar @{ $pairs[$i][1] } > 1 ) {
      push( @gpairn, $pairn[$i] );
    }
  }

  my ( $fold_n, $pv_n, $g_n, $cv_n );    # 记录结果中每一项有多少列
  my ( @f, @f_b, @nor );
  $fold_n = 0;
  $pv_n   = 0;

  # title line
  $id                = $raw[0][4];
  @title             = ( "ID", "Name" );
  $expre_col{'Name'} = 0;
  $expre_col{'ID'}   = 1;

  if ( defined $fold{$id}[0] ) {
    push( @title, @pairn );
    $fold_n = @pairn;
    push( @{ $expre_col{'fold'} }, ( 2 .. 1 + $fold_n ) );
  }

  if ( defined $pc ) {
    push( @title, @gpairn );
    $pv_n = scalar @gpairn;
    $n    = 0;
    for ( $i = 0 ; $i < @pairs ; $i++ ) {
      if ( scalar @{ $pairs[$i][0] } > 1 and scalar @{ $pairs[$i][1] } > 1 ) {
        $expre_col{'pv'}[$i] = 2 + $fold_n + $n;
        $n++;
      }
    }
  }
  $g_n = scalar( keys %groups );
  my @gn = sort keys %groups;
  for ( $i = 0 ; $i < $dn ; $i++ ) {
    push( @f,   $sn[$i] );
    push( @f_b, $sn[$i] );
    push( @nor, $sn[$i] );
    $expre_col{'f'}{ $sn[$i] }   = 2 + $fold_n + $pv_n + $i;
    $expre_col{'f_b'}{ $sn[$i] } = 2 + $fold_n + $pv_n + $dn + $i;
    $expre_col{'nor'}{ $sn[$i] } = 2 + $fold_n + $pv_n + 2 * $dn + $g_n + $i;
  }
  if ( $g_n > 0 ) {

    # foreach $gn ( keys %groups ) {
    for ( $i = 0 ; $i < @gn ; $i++ ) {
      push( @f_b, "Mean of " . $gn[$i] . " group" );
      push( @nor, "Mean of " . $gn[$i] . " group" );
      $expre_col{'f_b_mean'}{ $gn[$i] } = 2 + $fold_n + $pv_n + 2 * $dn + $i;
      $expre_col{'nor_mean'}{ $gn[$i] } =
        2 + $fold_n + $pv_n + 3 * $dn + $g_n + $i;
    }
  }
  push( @title, @f, @f_b, @nor );
  $cv_n = $g_n;
  if ( $cv_n > 0 ) {
    my @gn_t = map( $_ . " group", @gn );

    push( @title, @gn_t );
    for ( $i = 0 ; $i < @gn ; $i++ ) {
      $expre_col{'cv'}{ $gn[$i] } =
        2 + $fold_n + $pv_n + 3 * $dn + 2 * $g_n + $i;
    }
  }
  $expression[0] = [@title];

  # 输出 miRNA Expression Profiling Data.xlsx
  $book   = Excel::Writer::XLSX->new('miRNA Expression Profiling Data.xlsx');
  $sheet  = $book->add_worksheet("Expression Matrix");
  $format = $book->add_format();

  # 输出 Expression 的报告xls
  print "\nSaving <miRNA Expression Profiling Data.xlsx>\n";
  print "\n<miRNA Expression Profiling Data.xlsx> saved.\n";
  $line_tt = $is_paired == 1 ? 'Paired' : '';
  $line_pv = defined $pc ? "\n# Column \"P value\": $line_tt T-test result between samples in different groups."
                         : "";
  $line_cv = defined $pc ? "\n# Column \"CV-value\": coefficient of variation between samples in different groups."
                         : "";
  my $notetext =
    qq~# This page contains an expression matrix for all $dn slides. 
# Column "Name": the name of each miRNA.
# Column "ID": array ID of the probes, each miRNA always has its unique probe, but some miRNAs may have two different probes.
# Column "Fold change": the ratio of normalized intensities between two conditions (use normalized data, ratio scale).$line_pv
# Column "ForeGround": the foreground intensity of each probe.
# Column "ForeGround-BackGround": the signal of the probe after background correction.
# Column "Normalized": means the normalized ratio of the microRNA. Median Normalization Method was adopted.
          Normalized Data=(Foreground-Background)/median*$line_cv

NOTE:1. median value of valid probe intensity (background corrected intensity >= 50 in all samples).
     2. Each kind of probe has four repeat spots on the microarray, the values in this table are MEDIAN data of the four repeat spots.~;

  # note
  $format->set_font('Verdana');
  $format->set_size(10);
  $format->set_bg_color(26);
  $format->set_text_wrap();
  $format->set_align("top");
  $sheet->set_row( 0, 240 );
  $sheet->merge_range( "A1:I1", $notetext, $format );

  # title
  &write_title( $book, $sheet, \@title, 2, $fold_n, $pv_n, $dn, $g_n, $cv_n );

  # value
  $format = $book->add_format();
  $format->set_font("Arial");
  $format->set_align("left");

  my $row = 4;
  $n = 1;
  foreach $id (
    sort { $mirna{0}{$a}[1][0] <=> $mirna{0}{$b}[1][0] }
    keys %{ $mirna{0} }
    )
  {
    @line = ( $id, $mirna{0}{$id}[0] );
    if ( defined $fold{$id}[0] ) {
      push( @line, @{ $fold{$id} } );
    }
    if ( defined $pc ) {
      foreach $i ( @{ $pv{$id} } ) {
        if ( defined $i ) { push( @line, $i ); }
      }
    }
    @f   = ();
    @f_b = ();
    @nor = ();
    for ( $i = 0 ; $i < $dn ; $i++ ) {
      push( @f,   $mirna{$i}{$id}[4] );
      push( @f_b, $mirna{$i}{$id}[5] );
      push( @nor, $mirna{$i}{$id}[7] );
    }

    # 加入组内平均值
    if ( scalar( keys %groups ) > 0 ) {
      foreach $gn ( @gn ) {
        @mean0 = ();
        @mean1 = ();
        foreach $j ( @{ $groups{$gn} } ) {
          push( @mean0, $mirna{ $sn{$j} }{$id}[5] );
          if ( $mirna{ $sn{$j} }{$id}[7] ne 'N/A' ) {
            push( @mean1, $mirna{ $sn{$j} }{$id}[7] );
          }
        }
        push( @f_b, average(@mean0) * 1 );
        if ( defined $mean1[0] ) {
          push( @nor, average(@mean1) * 1 );
        }
        else {
          push( @nor, 'N/A' );
        }
      }
    }
    push( @line, @f, @f_b, @nor );
    if ( defined $cv{$id} ) {
      push( @line, @{ $cv{$id} }{@gn} );
    }
    $expression[$n] = [@line];
    $n++;

    $sheet->write_row( $row, 0, \@line, $format );
    &bar( $row++, ( scalar keys %{ $mirna{0} } ) + 3 );
  }

  $sheet = $book->add_worksheet("Correlation & Scatter Plot");
  $notetext =
qq~# The table "Correlation coefficient matrix" list the correlation matrix of replicate samples in the project.
# The R is calculated after array normalization using the Median method.
# When two samples are different, the correlation coefficient R of them does not mean the reproducibility of the slides but the difference of your RNA samples.
# When two samples are the same, the correlation coefficient R of them reflects the reproducibility of the slides.~;

  # note
  $format = $book->add_format();
  $format->set_font('Verdana');
  $format->set_size(10);
  $format->set_bg_color(26);
  $format->set_text_wrap();
  $format->set_align("top");
  $sheet->set_row( 0, 100 );
  $sheet->merge_range( "A1:I1", $notetext, $format );

  # title
  $format = $book->add_format();
  $format->set_font("Arial");
  $format->set_bold();
  $sheet->write( "A3", "Correlation coefficient matrix", $format );

  # correlarion
  $format = $book->add_format();
  $format->set_font("Arial");
  @line = &cor_cal;
  $sheet->write_col( "A4", \@line, $format );
  $sheet->insert_image( 4 + scalar @line, 0, "temp/scatterplot.png" );

  # sheet Hierarchical Clustering
  $sheet    = $book->add_worksheet("Hierarchical Clustering");
  $notetext = qq~Heat Map and Hierarchical Clustering\n
  The heat map diagram shows the result of the two-way hierarchical clustering of miRNAs and samples. Each row represents a miRNA and each column represents a sample. The miRNA clustering tree is shown on the left, and the sample clustering tree appears at the top. The color scale shown at the top illustrates the relative expression level of a miRNA in the certain slide: red color represents a high relative expression level ; green color represents a low relative expression levels.\n
The actual normalized data of the miRNAs are shown in the expression matrix sheet in miRNA Expression Profiling Data.xls file.\n
Reference:
Eisen MB, Spellman PT, Brown PO and Botstein D. Cluster Analysis and Display of Genome-Wide Expression Patterns. Proc Natl Acad Sci USA 1998; 95: 14863-14868.~;

  # note
  $format = $book->add_format();
  $format->set_font('Verdana');
  $format->set_size(10);
  $format->set_bg_color(26);
  $format->set_text_wrap();
  $format->set_align("top");
  $sheet->set_row( 0, 160 );
  $sheet->merge_range( "A1:O1", $notetext, $format );

  &cluster;
  $book->close() or die "\nError closing file: $!";
}

sub R_boxplot {
  my ( $id, $i, $flag, @arraya, @arrayb, $names );
  open R_data_after,  ">temp/boxplota.txt";
  open R_data_before, ">temp/boxplotb.txt";
  print R_data_after "'",  join( "'\t'", @sn ), "'";
  print R_data_before "'", join( "'\t'", @sn ), "'";
  foreach $id ( keys %{ $mirna{0} } ) {
    $flag = 0;
    if ( $mirna{0}{$id}[0] =~ /let|mir/i ) {
      for ( $i = 0 ; $i < $dn ; $i++ ) {
        if ( $mirna{$i}{$id}[5] >= 50 ) {
          $flag++;
        }
      }
    }
    if ( $flag == $dn ) {
      @arraya = ();
      @arrayb = ();
      for ( my $i = 0 ; $i < $dn ; $i++ ) {
        push( @arraya, $mirna{$i}{$id}[7] * 1 );
        push( @arrayb, $mirna{$i}{$id}[5] * 1 );
      }
      print R_data_after "\n",  join( "\t", @arraya );
      print R_data_before "\n", join( "\t", @arrayb );
    }
  }

  open R_script, ">temp/R_boxplot.R" or die "File written error!";
  $names = "c('" . join( "', '", @sn ) . "')";
  print R_script qq~setwd("temp")
after = read.table("boxplota.txt", header = TRUE)
before = read.table("boxplotb.txt", header = TRUE)
png("boxplot.png", width = 1200, height = 600)
layout(matrix(c(1, 2), 1, 2))
boxplot(log2(before), cex.main = 2, ylab = 'log2(Ratio)',
    border = rainbow(dim(before)[2]), main = "Before Normalization",
    names = F, outline = F, cex.lab = 1.5, cex.asix = 1.3)
abline(h = mean(apply(log2(before),2,median,na.rm = T)))
text(1:$dn, par("usr")[3] - 0.3, srt = 60, adj = 1,
    labels = $names, xpd = T, font = 2)
boxplot(log2(after), cex.main = 2, ylab = 'log2(Ratio)',
    border = rainbow(dim(after)[2]), main = "After Normalization",
    names = F, outline = F, cex.lab = 1.5, cex.asix = 1.3)
abline(0, 0, col = "black")
text(1:$dn, par("usr")[3] - 0.3, srt = 60, adj = 1,
    labels = $names, xpd = T, font = 2)
dev.off()~;
  system("R <temp/R_boxplot.R --vanilla -q >> temp/R.log");
  copy( "./temp/boxplot.png", "./boxplot.png" );
}

sub differential {
  my ( %gi, $gn, $p, $i, $cf, @t, $pn, @up, @down, $n1, $n2 );
  my ( $s1, $s2, $id, $flag50, @titledi, $dn_p );
  my ( $notetext, @pvup, @pvdown, @pv_cluster );
  my ( $bookpv, $sheetpv, $n3, $n4, $line_pv, $line_cv, $line_tt );
  my @labxy; # [0] file name; [1] xlab; [2] ylab
  if ( defined $pc ) {
    $bookpv = Excel::Writer::XLSX->new(
      'Differentially Expressed miRNAs(Pass Volcano Plot).xlsx');
  }
  $book = Excel::Writer::XLSX->new('All Differentially Expressed miRNAs.xlsx');
  $cf   = 1.5;
  print "\nCalculating differentially expressed miRNA.\n";
  print "\n------  请输入Fold Change比较阈值：（默认1.5）  ------\n";
  print "\nPlease input fold change cut-off (default 1.5):";
  $i = <STDIN>;
  if ( $i =~ /(\d\.*\d*)/ and $1 > 1 and $1 < 10 ) { $cf = $1; }
  print "\nSetting fold change cut-off to $cf.\n";
  print SMA "\nSetting fold change cut-off to $cf.\n";
  $pn = @pairs;
  @t  = ( 0 .. $#{ $expression[0] } );

  # %gi 给每个样品赋一个组号，不分组则赋原样品名
  for ( $i = 0 ; $i < $dn ; $i++ ) { $gi{ $sn[$i] } = $sn[$i]; }

  foreach $gn (%groups) {
    foreach $i ( @{ $groups{$gn} } ) {
      $gi{$i} = $gn;
    }
  }

  for ( $p = 0 ; $p < @pairs ; $p++ ) {
    $n1     = 0;
    $n2     = 0;
    $n3     = 0;
    $n4     = 0;
    @up     = ();
    @down   = ();
    @pvup   = ();
    @pvdown = ();
    $pairn[$p] =~ /(\S+) vs (\S+)/;
    $s1         = $1;
    $s2         = $2;
    @pv_cluster = ();

    if (  scalar @{ $pairs[$p][0] } > 1
      and scalar @{ $pairs[$p][1] } > 1 )
    {
      push(@labxy, ["'volcano$p.txt'","'$s1'","'$s2'"]);
      open( OUT, ">temp/volcano$p.txt" ) or die $!;
      print OUT "$s1\t$s2\n";

      # 输出pair_cluster.txt
      open( OUTC, ">temp/pair" . ( $p + 1 ) . "_cluster.txt" );
      $pv_cluster[0] = \@{ &pushex_cluster( $expression[0], $s1, $s2 ) };
    }
    if ( exists $groups{$s1} ) {
      $dn_p = scalar @{ $groups{$s1} } + scalar @{ $groups{$s2} };
    }
    else {
      $dn_p = 0;
    }
    @titledi = @{ &pushex( $expression[0], $s1, $s2, $p ) };
    for ( $i = 1 ; $i < @expression ; $i++ ) {
      if (  $expression[$i][1] =~ /mir|let/i
        and $expression[$i][ 2 + $p ] ne 'N/A' )
      {
        $id = $expression[$i][0];
        if (
          exists $gi{$s1}    # 两样品比较
          and $mirna{ $sn{$s1} }{$id}[5] < 50
          and $mirna{ $sn{$s2} }{$id}[5] < 50
          )
        {
          next;
        }
        elsif ( exists $groups{$s1} ) {    # 两组进行比较
          $flag50 = 0;
          if ( defined $pv{$id}[$p] and $pv{$id}[$p] eq 'N/A' ) { next; }
          foreach $gn ( @{ $groups{$s1} }, @{ $groups{$s2} } ) {
            if ( $mirna{ $sn{$gn} }{$id}[5] >= 50 ) {
              $flag50 = 1;
              last;
            }
          }
          if ( $flag50 == 0 ) {
            next;
          }
        }

        if ( $expression[$i][ 2 + $p ] >= $cf ) {
          $up[ $n1++ ] = \@{ &pushex( $expression[$i], $s1, $s2, $p ) };

          # 挑选组间p-value小于0.05的进行筛选
          if (  defined $pv{$id}[$p]
            and $pv{$id}[$p] ne 'N/A'
            and $pv{$id}[$p] <= $pc )
          {
            $pvup[ $n3++ ] = \@{ &pushex( $expression[$i], $s1, $s2, $p ) };
            $pv_cluster[ $n3 + $n4 ] =
              \@{ &pushex_cluster( $expression[$i], $s1, $s2 ) };
          }
        }
        elsif ( $expression[$i][ 2 + $p ] <= 1 / $cf ) {
          $down[ $n2++ ] = \@{ &pushex( $expression[$i], $s1, $s2, $p ) };

          # 挑选组间p-value小于0.05的进行筛选
          if (  defined $pv{$id}[$p]
            and $pv{$id}[$p] ne 'N/A'
            and $pv{$id}[$p] <= $pc )
          {
            $pvdown[ $n4++ ] = \@{ &pushex( $expression[$i], $s1, $s2, $p ) };
            $pv_cluster[ $n3 + $n4 ] =
              \@{ &pushex_cluster( $expression[$i], $s1, $s2 ) };
          }
        }
        if ( defined $pv{$id}[$p] and $pv{$id}[$p] ne 'N/A' ) {
          print OUT $fold{$id}[$p], "\t", $pv{$id}[$p], "\n";
        }
      }
    }
    $sheet = $book->add_worksheet( $pairn[$p] );

    # note
    $line_tt = $is_paired == 1 ? 'Paired' : '';
    $line_pv = defined $pc ? "\n# Column \"P value\": $line_tt T-test result between samples in different groups."
                           : "";
    $line_cv = defined $pc ? "\n# Column \"CV-value\": coefficient of variation between samples in different groups."
                           : "";
    $notetext = qq~# Condition pairs: $pairn[$p]
# Fold Change cut-off: $cf\n
# Column "ID" contains the miRNA ID number constituted by Exiqon.
# Column "Name" contains the name of miRNA.
# Column "Fold change" contains the ratio of normalized intensities between two conditions.$line_pv
# Column "ForeGround" means the foreground intensity of the miRNA.
# Column "ForeGround-BackGround" means the signal of the miRNA after background correction.
# Column "Normalized" means the normalized signal of the miRNA.We use Median Normalization Method to do array normalization.$line_cv\n
NOTE: The low intensity differentially expressed  miRNAs are filtered in the following list (miRNAs that ForeGround-BackGround intensities < 50 in two samples are filtered). If you are interested in these miRNAs, you can find them in sheet "Expression Matrix" of miRNA Expression Profiling Data.xls file.~;
    $format = $book->add_format();
    $format->set_font('Verdana');
    $format->set_size(10);
    $format->set_bg_color(26);
    $format->set_text_wrap();
    $format->set_align("top");
    $sheet->set_row( 0, 180 );
    $sheet->merge_range( "A1:N1", $notetext, $format );

    # up
    $format = $book->add_format();
    $format->set_font('Arial');
    $format->set_align("center");
    $format->set_bold();
    $format->set_bg_color('red');
    $sheet->merge_range( 2, 0, 2, $#titledi,
      "$pairn[$p] $cf fold up regulated miRNAs", $format );
    if ( exists $groups{$s1} and defined $pc ) {
      &write_title( $book, $sheet, \@titledi, 3, 1, 1, $dn_p, 2, 2 );
    }
    elsif ( exists $groups{$s1} and !defined $pc ) {
      &write_title( $book, $sheet, \@titledi, 3, 1, 0, $dn_p, 2, 2 );
    }
    else {
      &write_title( $book, $sheet, \@titledi, 3, 1, 0, 2, 0, 0 );
    }
    $format = $book->add_format();
    $format->set_font('Arial');
    $format->set_align("left");
    $sheet->write_col( 5, 0, \@up, $format );

    # down
    $format = $book->add_format();
    $format->set_font('Arial');
    $format->set_align("center");
    $format->set_bold();
    $format->set_bg_color(50);
    $sheet->merge_range(
      6 + scalar @up,
      0, 6 + scalar @up,
      $#titledi, "$pairn[$p] $cf fold down regulated miRNAs", $format
    );
    if ( exists $groups{$s1} and defined $pc ) {
      &write_title( $book, $sheet, \@titledi, 7 + scalar @up,
        1, 1, $dn_p, 2, 2 );
    }
    elsif ( exists $groups{$s1} and !defined $pc ) {
      &write_title( $book, $sheet, \@titledi, 7 + scalar @up,
        1, 0, $dn_p, 2, 2 );
    }
    else {
      &write_title( $book, $sheet, \@titledi, 7 + scalar @up, 1, 0, 2, 0, 0 );
    }
    $format = $book->add_format();
    $format->set_font('Arial');
    $format->set_align("left");
    $sheet->write_col( 5 + $#up + 5, 0, \@down, $format );

    if ( defined $pv{$id}[$p] ) {
      $sheetpv = $bookpv->add_worksheet( $pairn[$p] );

      # note
      $notetext = qq~# Condition pairs: $pairn[$p]
# Fold Change cut-off: $cf
# P-value cut-off: $pc\n\n
# Column "ID": array ID of the probes, each miRNA always has its unique probe, but some miRNAs may have two different probes.
# Column "Name": the name of each miRNA.
# Column "Fold change": the ratio of normalized intensities between two conditions (use normalized data, ratio scale). 
# Column "P value": $line_tt T-test result between samples in different groups.
# Column "ForeGround": the foreground intensity of each probe.
# Column "ForeGround-BackGround": the signal of the probe after background correction.
# Column "Normalized": means the normalized ratio of the microRNA. Median Normalization Method was adopted.
          Normalized Data=(Foreground-Background)/median*
# Column "CV-value": coefficient of variation between samples in different groups.\n
NOTE: The low intensity differentially expressed  miRNAs are filtered in the following list (miRNAs that ForeGround-BackGround intensities<50 in two samples are filtered). If you are interested in these miRNAs, you can find them in sheet "Expression Matrix" of miRNA Expression Profiling Data.xls file.~;
      $format = $bookpv->add_format();
      $format->set_font('Verdana');
      $format->set_size(10);
      $format->set_bg_color(26);
      $format->set_text_wrap();
      $format->set_align("top");
      $sheetpv->set_row( 0, 240 );
      $sheetpv->merge_range( "A1:N1", $notetext, $format );

      # up
      $format = $bookpv->add_format();
      $format->set_font('Arial');
      $format->set_align("center");
      $format->set_bold();
      $format->set_bg_color('red');
      $sheetpv->merge_range( 2, 0, 2, $#titledi,
        "$pairn[$p] $cf fold up regulated miRNAs", $format );
      if ( exists $groups{$s1} ) {
        &write_title( $bookpv, $sheetpv, \@titledi, 3, 1, 1, $dn_p, 2, 2 );
      }
      else {
        &write_title( $bookpv, $sheetpv, \@titledi, 3, 1, 0, 2, 0, 0 );
      }
      $format = $bookpv->add_format();
      $format->set_font('Arial');
      $sheetpv->write_col( 5, 0, \@pvup, $format );

      # down
      $format = $bookpv->add_format();
      $format->set_font('Arial');
      $format->set_align("center");
      $format->set_bold();
      $format->set_bg_color(50);
      $sheetpv->merge_range(
        6 + scalar @pvup,
        0, 6 + scalar @pvup,
        $#titledi, "$pairn[$p] $cf fold down regulated miRNAs", $format
      );
      if ( exists $groups{$s1} ) {
        &write_title( $bookpv, $sheetpv, \@titledi, 7 + scalar @pvup,
          1, 1, $dn_p, 2, 2 );
      }
      else {
        &write_title( $bookpv, $sheetpv, \@titledi, 7 + scalar @pvup,
          1, 0, 2, 0, 0 );
      }
      $format = $bookpv->add_format();
      $format->set_font('Arial');
      $sheetpv->write_col( 5 + $#pvup + 5, 0, \@pvdown, $format );

      # 输出pair_cluster.txt
      foreach $i (@pv_cluster) {
        print OUTC join( "\t", @{$i} ), "\n";
      }
    }
  }
  $book->close() or die "\nError closing file: $!";
  if ( defined $pc ) {
    open( OUT, ">temp/volcano.R" ) or die $!;
    print OUT qq~setwd("temp")
fl <- list.files(pattern = "^volcano[0-9]+.txt")
r <- ceiling(sqrt(length(fl)))
c <- ceiling(length(fl)/ceiling(sqrt(length(fl))))
png(file = "volcanoplot.png", width = 600 * r, 500 *
    c)
par(mfrow = c(c, r))~;
  foreach $i (0 .. $#labxy) {
    print OUT qq~
    a <- read.table($labxy[$i][0], header = TRUE)
    plot(log2(a[, 1]), -log10(a[, 2]), pch = 19, xlab = expression(log[2]^Foldchange),
      ylab = expression(-log[10]^(p-value)), main = paste("Volcano Plot (",
        $labxy[$i][1], "vs", $labxy[$i][2], ")"), xlim = c(-5,
        5), cex.main = 1.5, cex.lab = 1.3, mgp = c(2.5, 1, 0))
    points(log2(a[a[, 1] >= $cf & a[, 2] <= $pc, 1]), -log10(a[a[,
        1] >= $cf & a[, 2] <= $pc, 2]), col = 2, pch = 19)
    points(log2(a[a[, 1] <= 1/$cf & a[, 2] <= $pc, 1]), -log10(a[a[,
        1] <= 1/$cf & a[, 2] <= $pc, 2]), col = 2, pch = 19)
    abline(v = log2(c($cf, 1/$cf)), lty = "dashed", col = "darkgreen",
        lwd = 2)
    abline(h = -log10($pc), lty = "dashed", col = "darkgreen", lwd = 2)
~;
  }
  print OUT 'dev.off()';
    system("R <temp/volcano.R --vanilla -q >> temp/R.log");
    $sheetpv = $bookpv->add_worksheet("Volcano Plot");

    # note
    $notetext = qq~Volcano Plots\n
      Volcano Plots are useful tool for visualizing differential expression between two different conditions. They are constructed using fold-change values and p-values, and thus allow you to visulaize  the relationship between fold-change (magnitude of change) and statistical significance (which takes both magnitude of change and variability into consideration). They also allow subsets of genes to be isolated, based on those values.\n
      The vertical lines correspond to $cf-fold up and down, respectively, and the horizontal line represents a p-value of $pc. So the red point in the plot represents the differentially expressed miRNAs with statistical significance.\n
      Press ctrl and rolling button of your mouse to zoom in.~;
    $format = $bookpv->add_format();
    $format->set_font('Verdana');
    $format->set_size(10);
    $format->set_bg_color(26);
    $format->set_text_wrap();
    $format->set_align("top");
    $sheetpv->set_row( 0, 140 );
    $sheetpv->merge_range( "A1:N1", $notetext, $format );

    # volcano
    $sheetpv->insert_image( "A3", "temp/volcanoplot.png" );

    $bookpv->close() or die "\nError closing file: $!";
  }
}

sub cluster {
  my ( $id, $i, $flag, @array );
  open( OUT, ">temp/cluster.txt" ) or die $!;
  print OUT "Name\t", join( "\t", @sn ), "\n";
  foreach $id ( keys %{ $mirna{0} } ) {
    if ( $mirna{0}{$id}[0] =~ /mir|let/i ) {
      $flag  = 0;
      @array = ( $mirna{0}{$id}[0] );
      for ( $i = 0 ; $i < $dn ; $i++ ) {
        push( @array,
          $mirna{$i}{$id}[7] eq 'N/A'
          ? 'N/A'
          : log( $mirna{$i}{$id}[7] ) / log(2) );
        if ( $mirna{$i}{$id}[5] >= 50 ) {
          $flag = 1;
        }
      }
      if ( $flag == 1 ) {
        print OUT join( "\t", @array ), "\n";
      }
    }
  }
  close OUT;
  print "\ncluster.txt for clustering is placed in temp dir.\n";
}

sub pushex_cluster {

  # 把对应比较对的相关样品结果提取,输出pair_cluster.txt
  my ( $sn, @a );
  my ( $b, $s1, $s2 ) = @_;
  push( @a, $$b[1] );
  foreach $sn ( @{ $groups{$s2} }, @{ $groups{$s1} } ) {
    if ( $$b[ $expre_col{'nor'}{$sn} ] ne 'N/A' && $$b[1] ne 'Name' ) {
      push( @a, log( $$b[ $expre_col{'nor'}{$sn} ] ) / log(2) );
    }
    else {
      push( @a, $$b[ $expre_col{'nor'}{$sn} ] );
    }
  }
  return \@a;
}

sub pushex {

  # 把对应比较对的相关样品结果提取
  my ( $sn, @a );
  my ( $b, $s1, $s2, $p ) = @_;
  push( @a, $$b[0], $$b[1] );
  if ( !defined $gn{$s1} ) {
    push( @a, $$b[ $expre_col{'fold'}[$p] ] );
    if ( defined $expre_col{'pv'}[$p] ) {
      push( @a, $$b[ $expre_col{'pv'}[$p] ] );
    }
    foreach $sn ( @{ $groups{$s2} }, @{ $groups{$s1} } ) {
      push( @a, $$b[ $expre_col{'f'}{$sn} ] );
    }
    foreach $sn ( @{ $groups{$s2} }, @{ $groups{$s1} } ) {
      push( @a, $$b[ $expre_col{'f_b'}{$sn} ] );
    }
    push( @a, $$b[ $expre_col{'f_b_mean'}{$s2} ] );
    push( @a, $$b[ $expre_col{'f_b_mean'}{$s1} ] );
    foreach $sn ( @{ $groups{$s2} }, @{ $groups{$s1} } ) {
      push( @a, $$b[ $expre_col{'nor'}{$sn} ] );
    }
    push( @a, $$b[ $expre_col{'nor_mean'}{$s2} ] );
    push( @a, $$b[ $expre_col{'nor_mean'}{$s1} ] );
    push( @a, $$b[ $expre_col{'cv'}{$s2} ] );
    push( @a, $$b[ $expre_col{'cv'}{$s1} ] );
    return \@a;
  }
  else {
    push( @a,
      $$b[ $expre_col{'fold'}[$p] ],
      $$b[ $expre_col{'f'}{$s2} ],
      $$b[ $expre_col{'f'}{$s1} ],
      $$b[ $expre_col{'f_b'}{$s2} ],
      $$b[ $expre_col{'f_b'}{$s1} ],
      $$b[ $expre_col{'nor'}{$s2} ],
      $$b[ $expre_col{'nor'}{$s1} ] );
    return \@a;
  }
}

sub cor_cal {
  my ( @cor, $i, $j, @array1, @array2, $id, $sn, $gn, $n, $k, $flag );
  my @labxy; # [0] file name; [1] xlab; [2] ylab
  $n = 101;

  # 给每个sample编个组号，不同组号的比较不输出scatter plot
  foreach $sn (@sn) {
    $gn{$sn} = '0';
  }
  $gn = scalar keys %groups;
    foreach $gn ( keys %groups ) {
      foreach $sn ( @{ $groups{$gn} } ) {
        $gn{$sn} = $gn;
      }
    }
  for ( $i = 0 ; $i < $dn ; $i++ ) {
    for ( $j = 0 ; $j < $dn ; $j++ ) {
      $flag = 0;
      # 多组芯片则输出组内两两比较散点图
      # 多个比一个情况，无p value 有分组
      if ( $gn > 1 && $gn{ $sn[$i] } eq $gn{ $sn[$j] } && $i > $j
          && !("$sn[$i] vs $sn[$j]" ~~ @pairn)
          && !("$sn[$j] vs $sn[$i]" ~~ @pairn) ) {
        $flag = 1;
      }

      # 非多组芯片则至输出定义的比较散点图
      if ( "$sn[$i] vs $sn[$j]" ~~ @pairn ) {
        $flag = 1;
      }

      # calculate correlation between two sample
      @array1 = ();
      @array2 = ();
      foreach $id ( keys %{ $mirna{$i} } ) {
        if (  $mirna{$i}{$id}[0] =~ /mir|let/i
          and $mirna{$i}{$id}[7] ne 'N/A'
          and $mirna{$j}{$id}[7] ne 'N/A'
          and $mirna{$i}{$id}[5] > 0
          and $mirna{$j}{$id}[5] > 0
          and ( $mirna{$i}{$id}[5] >= 50 or $mirna{$j}{$id}[5] >= 50 ) )
        {
          push( @array1, $mirna{$i}{$id}[7] );
          push( @array2, $mirna{$j}{$id}[7] );
        }
      }
      $cor[ $i + 1 ][ $j + 1 ] = correlation( \@array1, \@array2 ) * 1;
      if ( $flag == 1 ) {
        open( OUT, ">temp/scatter$n.txt" ) or die $!;
        $labxy[$n-101] = ["scatter$n.txt","'$sn[$j]'","'$sn[$i]'"];
        print OUT "'$sn[$j]'\t'$sn[$i]'\n";
        for ( $k = 0 ; $k < @array1 ; $k++ ) {
          print OUT "$array2[$k]\t$array1[$k]\n";
        }
        $n++;
      }
    }
    for ( $j = $i ; $j >= 0 ; $j-- ) {
      $cor[0][ $j + 1 ] = $sn[$j];
    }
    $cor[ $i + 1 ][0] = $sn[$i];
  }
  $cor[0][0] = '';

  # group correlation
  #  if ( scalar keys %groups > 1 ) {
  if ( defined $pc ) {
    my ( @corg, $flag, $flag1, $flag2, @array3, @array4, @gn );
    push( @cor, "" );
    @gn = sort keys %groups;
    for ( $i = 0 ; $i < $gn ; $i++ ) {
      for ( $j = $i + 1 ; $j < $gn ; $j++ ) {
        @array1 = ();
        @array2 = ();
        foreach $id ( keys %{ $mirna{0} } ) {
          $flag  = 1;
          $flag1 = 0;

          # 2组内数值检查
          if ( $mirna{0}{$id}[0] !~ /mir|let/i ) {
            next;
          }

          # 至少一个大于等于50
          foreach $sn ( @{ $groups{ $gn[$i] } }, @{ $groups{ $gn[$j] } } ) {
            if ( $mirna{ $sn{$sn} }{$id}[5] < 50 ) {
              $flag1++;
            }
          }

          # 组内至少两个有效值
          $flag2 = 0;
          foreach $sn ( @{ $groups{ $gn[$i] } } ) {
            if ( $mirna{ $sn{$sn} }{$id}[5] > 0 ) { $flag2++; }
          }
          if ( $flag2 < 2 ) { next; }
          $flag2 = 0;
          foreach $sn ( @{ $groups{ $gn[$j] } } ) {
            if ( $mirna{ $sn{$sn} }{$id}[5] > 0 ) { $flag2++; }
          }
          if ( $flag2 < 2 ) { next; }
          if ( $flag == 0
            or $flag1 ==
            scalar @{ $groups{ $gn[$i] } } + scalar @{ $groups{ $gn[$j] } } )
          {
            next;
          }

          # 符合条件
          @array3 = ();
          @array4 = ();
          foreach $sn ( @{ $groups{ $gn[$i] } } ) {
            if ( $mirna{ $sn{$sn} }{$id}[7] ne 'N/A' ) {
              push( @array3, $mirna{ $sn{$sn} }{$id}[7] );
            }
          }
          push( @array1, average(@array3) * 1 );
          foreach $sn ( @{ $groups{ $gn[$j] } } ) {
            if ( $mirna{ $sn{$sn} }{$id}[7] ne 'N/A' ) {
              push( @array4, $mirna{ $sn{$sn} }{$id}[7] );
            }
          }
          push( @array2, average(@array4) * 1 );
        }
        $corg[ $i + 1 ][ $j + 1 ] = correlation( \@array1, \@array2 );

        # write data for scatter plot
        if ( "$gn[$i] vs $gn[$j]" ~~ @pairn ) {
          open( OUT, ">temp/scatter$n.txt" ) or die $!;
          $labxy[$n-101] = ["scatter$n.txt","'$gn[$j]'","'$gn[$i]'"];
          print OUT "'$gn[$j]'\t'$gn[$i]'\n";
          for ( $k = 0 ; $k < @array1 ; $k++ ) {
            print OUT "$array2[$k]\t$array1[$k]\n";
          }
          $n++;
        }
        elsif ( "$gn[$j] vs $gn[$i]" ~~ @pairn ) {
          open( OUT, ">temp/scatter$n.txt" ) or die $!;
          $labxy[$n-101] = ["scatter$n.txt","'$gn[$i]'","'$gn[$j]'"];
          print OUT "'$gn[$i]'\t'$gn[$j]'\n";
          for ( $k = 0 ; $k < @array1 ; $k++ ) {
            print OUT "$array1[$k]\t$array2[$k]\n";
          }
          $n++;
        }
      }
      for ( $j = $i ; $j >= 0 ; $j-- ) {
        $corg[0][ $j + 1 ] = $gn[$j];
        $corg[ $i + 1 ][ $j + 1 ] = $i == $j ? 1 : $corg[ $j + 1 ][ $i + 1 ];
      }
      $corg[ $i + 1 ][0] = $gn[$i];
    }
    $corg[0][0] = '';
    push( @cor, @corg );
  }
  # remove obsoleted files
  while (-e "temp/scatter$n.txt") {
    unlink("temp/scatter$n.txt");
    $n++;
  }

  # scatter plot
  open( OUT, ">temp/scatter.R" ) or die $!;
  print OUT qq~
setwd("temp")
fl <- list.files(pattern="^scatter[0-9]+.txt")
r <- ceiling(sqrt(length(fl)))
c <- ceiling(length(fl)/ceiling(sqrt(length(fl))))
png(file="scatterplot.png",width=400*r,400*c)
par(mfrow=c(c,r))~;
  foreach $i (0 .. $#labxy) {
    print OUT qq~
  data <- read.table("$labxy[$i][0]",header=TRUE)
  plot(data,pch=19,xlim=c(0.01,100),ylim=c(0.01,100),
       xlab=$labxy[$i][1], ylab=$labxy[$i][2],
       log="xy",cex.axis=1.2,cex.lab=1.5,font.lab=2)
  abline(0,1,col=4)
~;
  }
print OUT 'dev.off()';
  close OUT;
  system("R <temp/scatter.R --vanilla -q > temp/R.log");
  return @cor;
}

sub write_title {
  my ( $tbook, $tsheet, $title, $row, $fold_n, $pv_n, $dn_n, $g_n, $cv_n ) = @_;

  # title
  $tsheet->set_column( 'B:B', 18 );
  if ( $fold_n > 0 ) {
    $format = $tbook->add_format();
    $format->set_font("Arial");
    $format->set_bold();
    $format->set_align("center");
    $format->set_size(11);
    $format->set_bg_color(50);
    if ( $fold_n > 1 ) {
      $tsheet->merge_range( $row, 2, $row, 2 + $fold_n - 1,
        "Fold change", $format );
    }
    else {
      $tsheet->write( $row, 2, "Fold change", $format );
    }
  }
  if ( $pv_n > 0 ) {
    $format = $tbook->add_format();
    $format->set_font("Arial");
    $format->set_bold();
    $format->set_align("center");
    $format->set_size(11);
    $format->set_bg_color(46);
    if ( $pv_n > 1 ) {
      $tsheet->merge_range(
        $row, 2 + $fold_n,
        $row, 2 + $fold_n + $pv_n - 1,
        "P-value", $format
      );
    }
    else {
      $tsheet->write( $row, 2 + $fold_n, "P-value", $format );
    }
  }
  $format = $tbook->add_format();
  $format->set_font("Arial");
  $format->set_bold();
  $format->set_align("center");
  $format->set_size(11);
  $format->set_bg_color(61);
  $tsheet->merge_range(
    $row, 2 + $fold_n + $pv_n,
    $row, 2 + $fold_n + $pv_n + $dn_n - 1,
    "ForeGround", $format
  );

  $format = $tbook->add_format();
  $format->set_font("Arial");
  $format->set_bold();
  $format->set_align("center");
  $format->set_size(11);
  $format->set_bg_color(13);
  $tsheet->merge_range(
    $row, 2 + $dn_n + $fold_n + $pv_n,
    $row, 2 + $fold_n + $pv_n + 2 * $dn_n + $g_n - 1,
    "ForeGround-BackGround", $format
  );

  $format = $tbook->add_format();
  $format->set_font("Arial");
  $format->set_bold();
  $format->set_align("center");
  $format->set_size(11);
  $format->set_bg_color(44);
  $tsheet->merge_range(
    $row, 2 + 2 * $dn_n + $g_n + $fold_n + $pv_n,
    $row, 2 + $fold_n + $pv_n + 3 * $dn_n + 2 * $g_n - 1,
    "Normalized", $format
  );

  if ( $cv_n > 0 ) {
    $format = $tbook->add_format();
    $format->set_font("Arial");
    $format->set_bold();
    $format->set_align("center");
    $format->set_size(11);
    $format->set_bg_color(28);
    if ( $cv_n > 1 ) {
      $tsheet->merge_range(
        $row, 2 + $fold_n + $pv_n + 3 * $dn_n + 2 * $g_n,
        $row, 2 + $fold_n + $pv_n + 3 * $dn_n + 2 * $g_n + $cv_n - 1,
        "CV-value", $format
      );
    }
    else {
      $tsheet->write( $row, 2 + $fold_n + $pv_n + 3 * $dn_n + 2 * $g_n,
        "CV-value", $format );
    }
  }

  $format = $tbook->add_format();
  $format->set_font("Arial");
  $format->set_bold();
  $format->set_bg_color(30);
  $format->set_text_wrap();
  $format->set_align("center");
  $tsheet->write_row( $row + 1, 0, $title, $format );
}

sub get_spike {
  my ( %spike, %sp_array, %cv_array, @corr, $id, $i, $flag, $k, $j, @spike_mean,
    $v );
  foreach $id ( keys %{ $mirna{0} } ) {
    if ( $mirna{0}{$id}[0] =~ /spike_control_v(\d)/ ) {
      $v = $1;
      for ( $i = 0 ; $i < $dn ; $i++ ) {
        if ( $mirna{$i}{$id}[5] >= 50 ) {    # 单芯片CV median值
          push( @{ $cv_array{$v}{$i} }, $mirna{$i}{$id}[6] );
        }
        $spike{$id}[0]     = $mirna{$i}{$id}[0];
        $spike{$id}[1][$i] = $mirna{$i}{$id}[5];
        $spike{$id}[2][$i] = $mirna{$i}{$id}[6];
        $flag              = 1;
        for ( $k = $i + 1 ; $k < $dn ; $k++ ) {
          if ( $mirna{$i}{$id}[5] < 50 && $mirna{$k}{$id}[5] < 50 ) {
            $flag = 0;
          }
          if ( $mirna{$i}{$id}[5] < 0 || $mirna{$k}{$id}[5] < 0 ) {
            $flag = 0;
          }
          if ( $flag == 1 ) {    # spike 相关性
            push( @{ $sp_array{$v}{$i}{$k}{$i} }, $mirna{$i}{$id}[5] );
            push( @{ $sp_array{$v}{$i}{$k}{$k} }, $mirna{$k}{$id}[5] );
          }
        }
      }
    }
  }
  foreach $j ( 1 .. 2 ) {
    for ( $i = 0 ; $i < $dn ; $i++ ) {
      if ( defined $cv_array{$j}{$i}[1] ) {
        $spike_mean[$j][$i] = median( @{ $cv_array{$j}{$i} } );
      }
      else {
        $spike_mean[$j][$i] = 'N/A';
      }
    }
  }
  foreach $i ( 1 .. 2 ) {
    $corr[$i][0][0] = "\\";
    push( @{ $corr[$i][0] }, @sn );
    for ( $j = 0 ; $j < $dn ; $j++ ) {
      $corr[$i][ $j + 1 ][0] = $sn[$j];
      for ( $k = $j + 1 ; $k < $dn ; $k++ ) {
        if ( defined $sp_array{$i}{$j}{$k}{$j}[1] ) {
          $corr[$i][ $j + 1 ][ $k + 1 ] =
            correlation( $sp_array{$i}{$j}{$k}{$j}, $sp_array{$i}{$j}{$k}{$k} );
        }
        else {
          $corr[$i][ $j + 1 ][ $k + 1 ] = 'N/A';
        }
      }
    }
  }
  $book   = Excel::Writer::XLSX->new('temp/spike_control.xlsx');
  $format = $book->add_format();
  $format->set_font('Arial');
  $format->set_align("left");
  $sheet = $book->add_worksheet("spike_control");
  $sheet->set_column( "A:A", 18 );
  $sheet->write( 0, 0, "Spike v1 median for each slide", $format );

  $sheet->write_row( 1, 0, \@sn,           $format );
  $sheet->write_row( 2, 0, $spike_mean[1], $format );
  $sheet->write( 3, 0, "Spike v2 median for each slide", $format );

  $sheet->write_row( 4, 0, \@sn,           $format );
  $sheet->write_row( 5, 0, $spike_mean[2], $format );
  $sheet->write( 7, 0, "Sample correlation using spike v1 F_B median",
    $format );
  $sheet->write_col( 8, 0, $corr[1], $format );
  $sheet->write( $dn + 10, 0, "Sample correlation using spike v2 F_B median",
    $format );
  $sheet->write_col( $dn + 11, 0, $corr[2], $format );
  $k = 15;
  $sheet->merge_range(
    2 * $dn + 13,
    1, 2 * $dn + 13,
    $dn, "F_B median", $format
  );
  $sheet->merge_range(
    2 * $dn + 13,
    1 + $dn, 2 * $dn + 13,
    2 * $dn, "spike CV", $format
  );
  $sheet->write_row( 2 * $dn + 14, 1,       \@sn, $format );
  $sheet->write_row( 2 * $dn + 14, 1 + $dn, \@sn, $format );

  foreach $id ( sort { $spike{$a}[0] cmp $spike{$b}[0] } keys %spike ) {
    $sheet->write( 2 * $dn + $k, 0, $spike{$id}[0], $format );
    $sheet->write_row( 2 * $dn + $k, 1,       $spike{$id}[1], $format );
    $sheet->write_row( 2 * $dn + $k, 1 + $dn, $spike{$id}[2], $format );
    $k++;
  }
  $book->close() or die "\nError closing file: $!";
  print "Spike control CV calculation done.\n";
  print SMA "<temp/spike_control.xlsx> saved.\n";
}

sub micv {
  my ( $i, $n, $id, @cv_array, @slide_cv, @cv_mean );
  $n = 0;
  foreach $id ( keys %{ $mirna{0} } ) {
    if ( $mirna{0}{$id}[0] =~ /mir|let/i ) {
      push( @{ $cv_array[$n] }, $mirna{0}{$id}[0] );
      for ( $i = 0 ; $i < $dn ; $i++ ) {
        push( @{ $cv_array[$n] }, $mirna{$i}{$id}[5] );

        # 单张slide的cv值
        if ( $mirna{$i}{$id}[5] >= 50 ) {
          push( @{ $slide_cv[$i] }, $mirna{$i}{$id}[6] );
        }
      }
      for ( $i = 0 ; $i < $dn ; $i++ ) {
        push( @{ $cv_array[$n] }, $mirna{$i}{$id}[6] );
      }
      $n++;
    }
  }
  for ( $i = 0 ; $i < $dn ; $i++ ) {
    $cv_mean[$i] = median( @{ $slide_cv[$i] } );
  }
  $book   = Excel::Writer::XLSX->new('temp/miRNA_cv.xlsx');
  $format = $book->add_format();
  $format->set_font('Arial');
  $format->set_align("left");
  $sheet = $book->add_worksheet("miRNA_CV");
  $sheet->set_column( "A:A", 18 );
  $sheet->write( "A1", "median CV for each slide (F_B >= 50)", $format );
  $sheet->write_row( "A2", \@sn,      $format );
  $sheet->write_row( "A3", \@cv_mean, $format );

  $sheet->merge_range( 4, 1,       4, $dn,     "F_B median", $format );
  $sheet->merge_range( 4, 1 + $dn, 4, 2 * $dn, "CV value",   $format );
  $sheet->write_row( 5, 1,       \@sn, $format );
  $sheet->write_row( 5, 1 + $dn, \@sn, $format );
  $sheet->write_col( 6, 0, \@cv_array, $format );
  $book->close() or die "\nError closing file: $!";
  print "miRNA CV calculation done.\n";
  print SMA "<temp/miRNA_cv.xlsx> saved.\n";
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
