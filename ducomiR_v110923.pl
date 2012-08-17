#!/usr/bin/perl -w
# Created: 7.6.2011
# Author: zr, zzqr@live.cn
# Purpose: dual-color microRNA analysis
# Revision: 09/21/2011 02:20:51 PM
# Notes: detailed in document
# Version: 0.4

use File::Copy;
use Time::localtime;
use Excel::Writer::XLSX;

mkdir "./result";
mkdir "./temp";
mkdir "./image";

print "运行日志保存到<result/summary.txt>\n";
print "------ " . ctime() . " ------\n\n";
open SMR, ">>result/summary.txt" or die "$!";
print SMR "Job start: " . ctime() . "\n";

# scan directory
my ( @sn, $dn, @routes );
&folder_information;

# filter .gpr files
my @files;
&filtergpr;

# read setting.txt
my ( @pairs, %groups, @pairn );
my ( $rmean, $rfold, $rcv, $rpv, $rdiff );
my ( $pvn, $groupn, %dnp, %gnp );
&pair_input;

# data analysis and chart
my ( $cf, $pc );
&Rroutine;

# generate report
my ( @raw, %mirna );
&report;
&spike_cv;

print "\n------ " . ctime() . " ------\n";
print "<Finished, press ENTER key to exit>\n";
print "<运行完毕，按回车键退出>";
print SMR "Job finished: " . ctime() . "\n\n";
close SMR;
<STDIN>;
exit;

sub spike_cv {
  my ( @file, $l);

  # -------------spike_control.xlsx--------------------------------
  print "Saving <temp/spike_control.xlsx> ...\n";
  print SMR "<temp/spike_control.xlsx> saved.\n";
  $book  = Excel::Writer::XLSX->new('temp/spike_control.xlsx');
  $sheet = $book->add_worksheet("spike_control");
  &setformat;
  open( IN, "temp/spike_control.txt" ) || die "spike_control.txt NOT ready!";
  $l = 0;
  while(<IN>){
    chomp($_);
    @{$file[$l++]} = split("\t",$_);
  }
  $sheet->write_col("A1",\@file,$format4);
  $sheet->set_column("A:A",18);

  # -------------miRNA_CV.xlsx-------------------------------------
  print "Saving <temp/miRNA_CV.xlsx> ...\n";
  print SMR "<temp/miRNA_CV.xlsx> saved.\n";
  $book  = Excel::Writer::XLSX->new('temp/miRNA_CV.xlsx');
  $sheet = $book->add_worksheet("miRNA_CV");
  &setformat;
  open( IN, "temp/miRNA_CV.txt" ) || die "miRNA_CV.txt NOT ready!";
  $l = 0;
  while(<IN>){
    chomp($_);
    @{$file[$l++]} = split("\t",$_);
  }
  $sheet->write_col("A1",\@file,$format4);
  $sheet->set_column("A:A",18);
  $book->close() or die "\nError closing file: $!";
}

sub report {
  my ( $i, $k, $n, @file, @i, $l, $title, $j, $pvnp );
  my ( $filename, $stage );

  # -------------Raw Intensity File.xlsx---------------------------
  print "Saving <Raw Intensity File.xlsx> ...\n";
  print SMR "<Raw Intensity File.xlsx> saved.\n";
  $book  = Excel::Writer::XLSX->new('Raw Intensity File.xlsx');
  $sheet = $book->add_worksheet("Raw Intensity File");
  &setformat;

  # Raw Intensity File.xlsx
  $note = qq~# This page contains raw intensities for all $dn slides.
# Column "Block": the block number of the probes placed on the microarray.
# Column "Column": the column number of the probes placed on the microarray.
# Column "Row": the row number of the probes placed on the microarray.
# Column "ID": the design ID of the probes, one microRNA always has one probe, but some microRNAs maybe have two different probes.
# Column "Name": the name of the microRNA.
# Column "ForeGround-BackGround": the signal of the probe after background correction. We use these values for data analysis.~;
  $sheet->set_row( 0, 130 );
  $sheet->merge_range( "A1:I1", $note, $format1 );

  open( RAW, "temp/raw.txt" ) || die "raw.txt NOT ready!";
  $sheet->merge_range(
    2, 5, 2,
    4 + $dn * 2,
    "ForeGround - BackGround", $format2
  );
  $n = 0;
  while (<RAW>) {
    chomp($_);
    @i = split( "\t", $_ );
    if ( $n == 0 ) {
      $sheet->write_row( 3 + $n++, 0, \@i, $format3 );
      next;
    }
    $sheet->write_row( 3 + $n++, 0, \@i, $format4 );
  }
  $sheet->set_column( 4, 4, 18 );
  $sheet->set_row( 3, 30 );

  # -------------miRNA Expression Profiling Data.xlsx--------------
  print "Saving <miRNA Expression Profiling Data.xlsx> ...\n";
  print SMR "<miRNA Expression Profiling Data.xlsx> saved.\n";
  $book  = Excel::Writer::XLSX->new('miRNA Expression Profiling Data.xlsx');
  $sheet = $book->add_worksheet("Expression Matrix");
  $sheet->set_tab_color("green");
  &setformat;
  $note = qq~# This page contains an expression matrix for all $dn slides.\n
# Lowess normalization for within slide normalization & scale normalization for between slide normalization.
# Column "ID" contains the miRNA ID number constituted by Exiqon.
# Column "Name" contains the name of miRNA.
# Column "Fold change" contains the ratio of normalized intensities between two conditions. 
# Column "Raw Intensity"contains the Raw Intensity of miRNA.
# Column "Normalized value"contains the normalized value of miRNA.~;

  if ( $rpv ne "" ) {
    $note .= "\n# Column \"P-value\" contains P-value calculated from TTest.";
  }
  if ( $rcv ne "" ) {
    $note .=
      "\n# Column \"CV-value\" contains the CV-value of miRNA in each group.";
  }
  $sheet->set_row( 0, 150 );
  $sheet->merge_range( "A1:I1", $note, $format1 );
  open( MIR, "temp/miRNA.txt" ) || die "miRNA.txt NOT ready!";
  $n = 0;
  while (<MIR>) {
    chomp($_);
    @i = split( "\t", $_ );
    if ( $n == 0 ) {
      $sheet->write_row( 4 + $n++, 0, \@i, $format3 );
      next;
    }
    $sheet->write_row( 4 + $n++ , 0, \@i, $format4 );
  }
  $sheet->set_column( 1, 1, 18 );

  # foldchange
  if ( $#pairn == 0 ) {
    $sheet->write( 3, 2, "Foldchange", $format2 );
  }
  else {
    $sheet->merge_range( 3, 2, 3, 2 + $#pairn, "Foldchange", $format2 );
  }

  # P-value
  if ( $pvn == 1 ) {
    $sheet->write( 3, 3 + $#pairn, "P-value", $format5 );
  }
  elsif ( $pvn > 1 ) {
    $sheet->merge_range(
      3, 3 + $#pairn,
      3, 2 + $#pairn + $pvn,
      "P-value", $format5
    );
  }

  # Raw Intensity
  $sheet->merge_range(
    3, 3 + $#pairn + $pvn,
    3,
    2 + $#pairn + $pvn + 2 * $dn,
    "Raw Intensity", $format6
  );

  # Only Lowess Normalization
  # Log2-Ratio Scale
  if ( $dn == 1 ) {
    $sheet->write(
      3,
      3 + $#pairn + $pvn + 2 * $dn,
      "Log2-Ratio Scale", $format7
    );
    $sheet->write( 3, 4 + $#pairn + $pvn + 2 * $dn, "Ratio Scale", $format7 );
    $sheet->merge_range(
      2, 3 + $#pairn + $pvn + 2 * $dn,
      2,
      4 + $#pairn + $pvn + 2 * $dn,
      "Normalized value", $format7
    );
  }
  elsif ( $dn > 1 ) {
    $sheet->merge_range(
      3, 3 + $#pairn + $pvn + 2 * $dn,
      3,
      2 + $#pairn + $pvn + 3 * $dn,
      "Log2-Ratio Scale", $format7
    );
    $sheet->merge_range(
      2, 3 + $#pairn + $pvn + 2 * $dn,
      2,
      2 + $#pairn + $pvn + 3 * $dn,
      "Data after Lowess Normalization", $format8
    );

    $sheet->merge_range(
      3, 3 + $#pairn + $pvn + 3 * $dn,
      3,
      2 + $#pairn + $pvn + 4 * $dn,
      "Log2-Ratio Scale", $format7
    );
    $sheet->merge_range(
      3, 3 + $#pairn + $pvn + 4 * $dn,
      3, 2 + $#pairn + $pvn + 5 * $dn + $groupn,
      "Ratio Scale", $format11
    );
    $sheet->merge_range(
      2, 3 + $#pairn + $pvn + 3 * $dn,
      2,
      2 + $#pairn + $pvn + 5 * $dn + 2 * $groupn,
      "Data After Lowess & Scale Normalization", $format10
    );

    if ( $groupn == 1 ) {
      $sheet->write( 3, 3 + $#pairn + $pvn + 5 * $dn + $groupn,
        "CV-value", $format9 );
    }
    elsif ( $groupn > 1 ) {
      $sheet->merge_range(
        3, 3 + $#pairn + $pvn + 5 * $dn + $groupn,
        3, 2 + $#pairn + $pvn + 5 * $dn + 2 * $groupn,
        "CV-value", $format9
      );
    }
  }

  # boxplot.png
  $sheet->insert_image( "J1", "temp/boxplot.png", 0, 0, .48, .48 );
  $note = "Box plot for Lowess & Scale Normalization
    The box plot shows the miRNA expression profiling before and after normalization.(left: no normalization; right:both within and between slide normalization). The main purpose of lowess and scale normalization is to control within and between slide variability. Y-axis represents the log2Ratio M=log2(Hy5/Hy3).";
  $sheet->merge_range( "R1:W1", $note, $format1 );

  # Hierarchical Clustering
  $sheet = $book->add_worksheet("Hierarchical Clustering");
  $sheet->set_tab_color("blue");
  $note = "Heat Map and Hierarchical Clustering\n
  The heat map diagram shows the result of the two-way hierarchical clustering of miRNAs and samples. Each row represents a miRNA and each column represents a sample. The miRNA clustering tree is shown on the left, and the sample clustering tree appears at the top. The color scale shown at the top illustrates the relative expression level of a miRNA in the certain slide: red color represents a high relative expression level ; green color represents a low relative expression levels.\n
  The log2(Hy5/Hy3) ratios for the miRNAs are listed in the expression matrix sheet within the Data File. Log2(Hy5/Hy3) ratios larger than 1 or smaller than -1 correspond to more than 2-fold up or down regulation.\n\n
  Reference:
  Eisen MB, Spellman PT, Brown PO and Botstein D. Cluster Analysis and Display of Genome-Wide Expression Patterns. Proc Natl Acad Sci USA 1998; 95: 14863-14868.";
  $sheet->set_row( 0, 180 );
  $sheet->merge_range( "A1:L1", $note, $format1 );

  # sample sheet
  $k = 27;
  foreach $i (@sn) {
    $sheet = $book->add_worksheet($i);
    $sheet->set_tab_color( $k++ );
    $note =
qq~# This page shows the $i Lowess normalized data (probe level and miRNA level) and Scatter plot & MA plot\n
# "Normalized Data-Probes"shows Lowess normalized data of all capture probes.
# Column "ID"contains the miRNA ID number constituted by Exiqon.
# Column "Name"contains the name of miRNA.
# Column "LowessNormHy3"contains intensities of Hy3 channel after Lowess normalization. 
# Column "LowessNormHy5"contains intensities of Hy5 channel after Lowess normalization.
# Spots with a high intensity (used in further data analysis) must meet 2 criterions(as follow):
# 1.Hy3 intensity > 0 and Hy5 intensity > 0
# 2.Hy3 SNR>1 and Hy5 SNR > 1, or one of SNR > 2 and another one > 0.
# Low intensity spots(don't meet above criterions) are filtered before lowess normalization.

# "Normalized Data-miRNAs"shows Lowess normalized data - median ratios on 4 capture probe replicates in "Normalized Data-Probes".
# Column "MedianRatios"shows median ratio of 4 replicated miRNA spots. 
# Column "LogMedianRatios"shows log2 value of "MedianRatios".
#  Log2ratio higher than 1 or less than -1 correspond to a more than 2 fold up or down regulation.
# Column "CV" shows the coefficient of variation of 4 replicated miRNA spots.
# If 3 or more of the 4 replicated spots of a certain miRNA are low intensity spots,this miRNA will be filtered in "Normalized Data-miRNAs".~;
    $sheet->set_row( 0, 260 );
    $sheet->merge_range( "A1:I1", $note,                      $format1 );
    $sheet->merge_range( "A3:D3", "Normalized Data - Probes", $format12 );
    $sheet->merge_range( "F3:J3", "Normalized Data - miRNAs", $format12 );
    $n = 0;
    open( IN, "temp/" . $i . "_lowess.txt" )
      || die "temp/" . $i . "_lowess.txt NOT FOUND!";

    while (<IN>) {
      chomp($_);
      @i = split( "\t", $_ );
      if ( $n == 0 ) {
        $sheet->write_row( 3 + $n++, 0, \@i, $format3 );
        next;
      }
      $sheet->write_row( 3 + $n++, 0, \@i, $format4 );
    }
    $sheet->set_column( 1, 1, 18 );
    $n = 0;
    open( IN, "temp/" . $i . "_miRNA.txt" )
      || die "temp/" . $i . "_miRNA.txt NOT FOUND!";
    while (<IN>) {
      chomp($_);
      @i = split( "\t", $_ );
      if ( $n == 0 ) {
        $sheet->write_row( 3 + $n++, 5, \@i, $format3 );
        next;
      }
      $sheet->write_row( 3 + $n++, 5, \@i, $format4 );
    }
    $sheet->set_column( 6, 6, 18 );

    $sheet->insert_image( "K3", "temp/$i.png", 0, 0, 1, 1 );
  }

  # -------------All Differentially Expressed miRNAs.xlsx----------
  print "Saving <All Differentially Expressed miRNAs.xlsx> ...\n";
  print SMR "<All Differentially Expressed miRNAs.xlsx> saved.\n";
  $book = Excel::Writer::XLSX->new('All Differentially Expressed miRNAs.xlsx');
  &setformat;
  foreach $i (@pairn) {
    $sheet = $book->add_worksheet($i);
    $sheet->set_tab_color( $k++ );
    $note = qq~# Condition pairs: $i
# Fold Change cut-off: $cf\n
# Column "ID" contains the miRNA ID number constituted by Exiqon.
# Column "Name" contains the name of miRNA.
# Column "Fold change" contains the ratio of normalized intensities between two conditions.
# Column "Normalized value"contains the normalized value of miRNA.~;
    if ( $gnp{$i} > 0 ) {
      $note .= '
# Column "P-value" contains P-value calculated from T-Test.
# Column "CV-value" contains the CV-value of miRNA in each group.';
    }
    $sheet->set_row( 0, 120 );
    $sheet->merge_range( "A1:I1", $note, $format1 );
    $l = 0;
    foreach $stage ( "up", "down" ) {
      $filename = "temp/" . $i . "_" . $cf . "_$stage.txt";
      if ( -e $filename ) {
        open( IN, $filename ) || die "$filename NOT FOUND!";
        $n     = 0;
        $title = <IN>;
        @file  = <IN>;
        chomp($title);
        @i = split( "\t", $title );
        $sheet->merge_range(
          2 + $l, 0, 2 + $l, $#i,
          "$i $cf-fold $stage-regulated miRNAs",
          $stage eq "up" ? $format13 : $format7
        );
        $sheet->write( 3 + $l, 2, "Foldchange", $format2 );
        $pvnp = 0;

        if ( $i[3] eq $i ) {
          $sheet->write( 3 + $l, 3, "P-value", $format5 );
          $pvnp = 1;
        }
        $sheet->merge_range(
          3 + $l, 3 + $pvnp, 3 + $l,
          2 + $pvnp + 2 * $dnp{$i},
          "Raw Intensity", $format6
        );
        if ( $dnp{$i} == 1 ) {
          $sheet->write(
            3 + $l,
            3 + $pvnp + 2 * $dnp{$i},
            "Log2-Ratio Scale After Lowess Normalization", $format7
          );
          $sheet->write(
            3 + $l,
            4 + $pvnp + 2 * $dnp{$i},
            "Log2-Ratio Scale After Lowess & Scale Normalization", $format14
          );
          $sheet->write(
            3 + $l,
            5 + $pvnp + 2 * $dnp{$i},
            "Ratio Scale After Lowess & Scale Normalization", $format12
          );
        }
        else {
          $sheet->merge_range(
            3 + $l, 3 + $pvnp + 2 * $dnp{$i},
            3 + $l,
            2 + $pvnp + 3 * $dnp{$i},
            "Log2-Ratio Scale After Lowess Normalization", $format7
          );
          $sheet->merge_range(
            3 + $l,
            3 + $pvnp + 3 * $dnp{$i},
            3 + $l,
            2 + $pvnp + 4 * $dnp{$i},
            "Log2-Ratio Scale After Lowess & Scale Normalization",
            $format14
          );
          $sheet->merge_range(
            3 + $l,
            3 + $pvnp + 4 * $dnp{$i},
            3 + $l,
            2 + $pvnp + 5 * $dnp{$i} + $gnp{$i},
            "Ratio Scale After Lowess & Scale Normalization",
            $format12
          );
          if ( $gnp{$i} == 1 ) {
            $sheet->write( 3 + $l, 3 + $pvnp + 5 * $dnp{$i} + $gnp{$i},
              "CV-value", $format8 );
          }
          elsif ( $gnp{$i} > 1 ) {
            $sheet->merge_range(
              3 + $l, 3 + $pvnp + 5 * $dnp{$i} + $gnp{$i},
              3 + $l, 2 + $pvnp + 5 * $dnp{$i} + 2 * $gnp{$i},
              "CV-value", $format8
            );
          }
        }
        $sheet->write_row( 4 + $l + $n++, 0, \@i, $format3 );
        foreach $j (@file) {
          chomp($j);
          @i = split( "\t", $j );
          $sheet->write_row( 4 + $l + $n++, 0, \@i, $format4 );
        }
        $l = @file + 4;
      }
    }
    $sheet->set_column( 1, 1, 18 );
  }

  # -------------Differentially Expressed miRNAs (Pass Volcano Plot).xlsx
  if ( $rpv eq "" ) {
    $book->close() or die "\nError closing file: $!";
    return 0;
  }
  print
    "Saving <Differentially Expressed miRNAs (Pass Volcano Plot).xlsx> ...\n";
  print SMR
    "<Differentially Expressed miRNAs (Pass Volcano Plot).xlsx> saved.\n";
  $book = Excel::Writer::XLSX->new(
    "Differentially Expressed miRNAs (Pass Volcano Plot).xlsx");
  &setformat;
  foreach $i (@pairn) {
    $sheet = $book->add_worksheet($i);
    $sheet->set_tab_color( $k++ );
    $note = qq~# Condition pairs: $i
# Fold Change cut-off: $cf
# P-value cut-off: $pc\n
# Column "ID" contains the miRNA ID number constituted by Exiqon.
# Column "Name" contains the name of miRNA.
# Column "Fold change" contains the ratio of normalized intensities between two conditions. 
# Column "Normalized value"contains the normalized value of miRNA.
# Column "P-value" contains P-value calculated from TTest.
# Column "CV-value" contains the CV-value of miRNA in each group.~;
    $sheet->set_row( 0, 135 );
    $sheet->merge_range( "A1:I1", $note, $format1 );
    $l = 0;
    foreach $stage ( "up", "down" ) {
      $filename = "temp/" . $i . "_" . $cf . "_" . $stage . "pv.txt";
      if ( -e $filename ) {
        open( IN, $filename ) || die "$filename NOT FOUND!";
        $n     = 0;
        $title = <IN>;
        @file  = <IN>;
        chomp($title);
        @i = split( "\t", $title );
        $sheet->merge_range(
          2 + $l, 0, 2 + $l, $#i,
          "$i $cf-fold $stage-regulated miRNAs",
          $stage eq "up" ? $format13 : $format7
        );
        $sheet->write( 3 + $l, 2, "Foldchange", $format2 );
        $pvnp = 0;

        if ( $i[3] eq $i ) {
          $sheet->write( 3 + $l, 3, "P-value", $format5 );
          $pvnp = 1;
        }
        $sheet->merge_range(
          3 + $l, 3 + $pvnp, 3 + $l,
          2 + $pvnp + 2 * $dnp{$i},
          "Raw Intensity", $format6
        );
        if ( $dnp{$i} == 1 ) {
          $sheet->write(
            3 + $l,
            3 + $pvnp + 2 * $dnp{$i},
            "Log2-Ratio Scale After Lowess Normalization", $format7
          );
          $sheet->write(
            3 + $l,
            4 + $pvnp + 2 * $dnp{$i},
            "Log2-Ratio Scale After Lowess & Scale Normalization", $format14
          );
          $sheet->write(
            3 + $l,
            5 + $pvnp + 2 * $dnp{$i},
            "Ratio Scale After Lowess & Scale Normalization", $format12
          );
        }
        else {
          $sheet->merge_range(
            3 + $l, 3 + $pvnp + 2 * $dnp{$i},
            3 + $l,
            2 + $pvnp + 3 * $dnp{$i},
            "Log2-Ratio Scale After Lowess Normalization", $format7
          );
          $sheet->merge_range(
            3 + $l,
            3 + $pvnp + 3 * $dnp{$i},
            3 + $l,
            2 + $pvnp + 4 * $dnp{$i},
            "Log2-Ratio Scale After Lowess & Scale Normalization",
            $format14
          );
          $sheet->merge_range(
            3 + $l,
            3 + $pvnp + 4 * $dnp{$i},
            3 + $l,
            2 + $pvnp + 5 * $dnp{$i} + $gnp{$i},
            "Ratio Scale After Lowess & Scale Normalization",
            $format12
          );
          if ( $gnp{$i} == 1 ) {
            $sheet->write( 3 + $l, 3 + $pvnp + 5 * $dnp{$i} + $gnp{$i},
              "CV-value", $format8 );
          }
          elsif ( $gnp{$i} > 1 ) {
            $sheet->merge_range(
              3 + $l, 3 + $pvnp + 5 * $dnp{$i} + $gnp{$i},
              3 + $l, 2 + $pvnp + 5 * $dnp{$i} + 2 * $gnp{$i},
              "CV-value", $format8
            );
          }
        }
        $sheet->write_row( 4 + $l + $n++, 0, \@i, $format3 );
        foreach $j (@file) {
          chomp($j);
          @i = split( "\t", $j );
          $sheet->write_row( 4 + $l + $n++, 0, \@i, $format4 );
        }
        $l = @file + 4;
      }
    }
    $sheet->set_column( 1, 1, 18 );
  }

  # Volcano Plot
  $sheet = $book->add_worksheet("Volcano Plot");
  $sheet->set_tab_color( $k++ );
  $note = qq~Volcano Plots\n
      Volcano Plots are useful tool for visualizing differential expression between two different conditions. They are constructed using fold-change values and p-values, and thus allow you to visulaize  the relationship between fold-change (magnitude of change) and statistical significance (which takes both magnitude of change and variability into consideration). They also allow subsets of genes to be isolated, based on those values.\n
      The vertical lines correspond to $cf-fold up and down, respectively, and the horizontal line represents a p-value of $pc. So the red point in the plot represents the differentially expressed genes with statistically significance.\n
      Press ctrl and rolling buttion of your mouse to zoom in.~;
  $sheet->set_row( 0, 175 );
  $sheet->merge_range( "A1:J1", $note, $format1 );
  $sheet->insert_image( "A3", "temp/volcanoplot.png", 0, 0, 1, 1 );
  $book->close() or die "\nError closing file: $!";
}

sub pair_input {
  print "\n---- 读取setting.txt设定文件信息 ----\n";
  my $pair = "";
  my ( $flag, @sa, @sb, $ga, $gb, $n, $i, $k, $name );
  my ( @rmean, @rfold, @rcv, @rpv, @rdiff, %pairn );
  $i     = 1;
  $n     = 0;
  $rmean = "";
  $rfold = "";
  $rcv   = "";
  $rpv   = "";
  $pvn   = 0;
  my $sn = join( " ", '', @sn, '' );

  if ( -e "setting.txt" ) {
    open( IN, "setting.txt" ) or die "setting file read error!";
    while ( $pair = <IN> ) {
      print "Pair $i: $pair\n";
      if ( $pair =~ /(\S+)\((\S+)\)\s+vs\s+(\S+)\((\S+)\)/ ) {

        # 多组比较
        @sa = split( ",", $1 );
        $ga = $2;
        @sb = split( ",", $3 );
        $gb = $4;
        if ( &checkname( @sa, @sb ) == 1 ) {
          print "Group $ga vs $gb was added to the list.\n";
          print SMR "Group $ga vs $gb was added to the list.\n";
          $pairs[$n][0] = [@sa];
          $pairs[$n][1] = [@sb];
          if ( $#sa >= 0 ) { $groups{$ga} = [@sa]; }
          if ( $#sb >= 0 ) { $groups{$gb} = [@sb]; }
          push( @pairn, "$ga vs $gb" );
          $dnp{"$ga vs $gb"} = $#sa + $#sb + 2;
          $gnp{"$ga vs $gb"} = 2;

          foreach $k ( @sa, @sb ) {

            # 记录每个样品的分组情况
            $pairn{$k}{"$ga vs $gb"} = 1;
          }
          $n++;

          # 分组处理
          push(
            @rfold,
            "rowMeans(f[,c(\""
              . join( '","', @sa )
              . "\")],na.rm=T)/
rowMeans(f[,c(" . '"' . join( '","', @sb ) . '"' . ")],na.rm=T)"
          );
          if ( $#sa > 0 && $#sb > 0 ) {
            $pvn++;
            push(
              @rpv, "gas <- c(\"" . join( '","', @sa ) . "\")
gbs <- c(\"" . join( '","', @sb ) . "\")
tpv <- array(data=NA,dim=c(nrow(f),1))
colnames(tpv) <- \"$ga vs $gb\"
for (i in 1:nrow(f)){
  if(sum(!is.na(l[i,gas])) >= 2 && sum(!is.na(l[i,gbs])) >= 2){
    tpv[i] <- t.test(l[i,gas],l[i,gbs],var.equal=T)\$p.value
  }
}
if(exists(\"pv\")){
  pv <- cbind(pv,tpv)
}else{
  pv <- tpv
}\n"
            );
          }
        }
      }
      elsif ( $pair =~ /(\S+)\((\S+)\)/ ) {

        # 单组比较
        @sa = split( ",", $1 );
        $ga = $2;
        if ( &checkname(@sa) == 1 ) {
          print "Group $ga was added to the list.\n";
          print SMR "Group $ga was added to the list.\n";
          $pairs[$n][0] = [@sa];
          if ( $#sa >= 0 ) { $groups{$ga} = [@sa]; }
          push( @pairn, $ga );
          $dnp{$ga} = $#sa + 1;
          $gnp{$ga} = 1;
          foreach $k (@sa) {

            # 记录每个样品的分组情况
            $pairn{$k}{$ga} = 1;
          }
          $n++;
          push( @rfold,
            "rowMeans(f[,c(" . '"' . join( '","', @sa ) . '"' . ")],na.rm=T)" );
          if ( $#sa > 0 ) {
            $pvn++;
            push(
              @rpv, "gas <- c(\"" . join( '","', @sa ) . "\")
tpv <- array(data=NA,dim=c(nrow(f),1))
colnames(tpv) <- \"$ga\"
for (i in 1:nrow(f)){
  if(sum(!is.na(l[i,gas])) >= 2){
    tpv[i] <- t.test(l[i,gas],mu=0)\$p.value
  }
}
if(exists(\"pv\")){
  pv <- cbind(pv,tpv)
}else{
  pv <- tpv
}\n"
            );
          }
        }
      }
      elsif ( $pair =~ /(\S+)\s+vs\s+(\S+)/ ) {

        # 样品比较
        @sa = split( ",", $1 );
        @sb = split( ",", $2 );
        if ( &checkname( @sa, @sb ) == 1 ) {
          print "$sa[0] vs $sb[0] was added to the list.\n";
          print SMR "$sa[0] vs $sb[0] was added to the list.\n";
          $pairs[$n][0] = [@sa];
          $pairs[$n][1] = [@sb];
          push( @pairn, "$sa[0] vs $sb[0]" );
          $dnp{"$sa[0] vs $sb[0]"}             = 2;
          $gnp{"$sa[0] vs $sb[0]"}             = 0;
          $pairn{ $sa[0] }{"$sa[0] vs $sb[0]"} = 1;
          $pairn{ $sb[0] }{"$sa[0] vs $sb[0]"} = 1;
          $n++;
          push( @rfold, "f[,\"$sa[0]\"]/f[,\"$sb[0]\"]" );
        }
      }
      $i++;
    }
    if ( $n == 0 ) {
      print "There is no compare setting found. Check your setting.txt\n
CAUTION: sample names are case-sensitive, mis-input will make no sense!\n
请注意区分大小写和错误拼写！
** 具体要求见说明文档\n\n";
      print "<error found, press ENTER key to exit>";
      <STDIN>;
      exit;
    }
    else {
      print "$n pair(s) will be add to the result.\n\n";
      print SMR "$n pair(s) will be add to the result.\n\n";
    }
  }
  else {
    push( @rfold, "f" );
    push( @pairn, @sn );
    foreach $i (@sn) {
      $dnp{$i} = 1;
      $gnp{$i} = 0;
    }
    foreach $k (@sn) {

      # 记录每个样品的分组情况
      $pairn{$k}{$k} = 1;
    }
    print "No setting.txt file found in the home directory.\n";
    print "We will do routine analysis for all sample.\n\n";
    print SMR "No setting.txt file found in the home directory.\n";
    print SMR "We will do routine analysis for all sample.\n\n";
  }

  # 调整样品出现顺序
  $n = 0;
  foreach $k (sort keys %groups ) {
    foreach $i ( @{ $groups{$k} } ) {
      &swap( \@sn,     $i, $n );
      &swap( \@routes, $i, $n );
      &swap( \@files,  $i, $n );
      $n++;
    }
  }
  $groupn = 0;

  # 比较R代码
  foreach $k ( keys %groups ) {
    if ( $#{ $groups{$k} } == 0 ) { next; }
    push( @rmean,
          "rowMeans(f[,c(" . '"'
        . join( '","', @{ $groups{$k} } ) . '"'
        . ")],na.rm=T)" );
    push( @rcv,
          "apply(f[,c(" . '"'
        . join( '","', @{ $groups{$k} } ) . '"'
        . ")],1,sd,na.rm=T)" );
    $groupn++;
  }
  if ( defined $rmean[0] ) {
    $rmean = "avg <- cbind(" . join( ",", @rmean ) . ")
colnames(avg) <- c(\"" . join( '","', keys %groups ) . "\")\n";
    $rcv = "cv <- cbind(" . join( ",", @rcv ) . ")
colnames(cv) <- colnames(avg)\n";
  }
  $rfold = "fold <- cbind(" . join( ",", @rfold ) . ")
colnames(fold) <- c(\"" . join( '","', @pairn ) . "\")\n";
  $rpv = join( "", @rpv );
  $rdiff = "group <- array(dim=c($dn,($#pairn+1)))
colnames(group) <- c(\"" . join( '","', @pairn ) . "\")
rownames(group) <- c(\"" . join( '","', @sn ) . "\")\n";
  if ( $groupn > 0 ) {
    $rdiff .= "
groupname <- array(dim=c(" . ( scalar keys %groups ) . ",($#pairn+1)))
colnames(groupname) <- c(\"" . join( '","', @pairn ) . "\")
rownames(groupname) <- c(\"" . join( '","', keys %groups ) . "\")\n";
  }

  foreach $i (@pairn) {
    foreach $k (@sn) {
      if ( defined $pairn{$k}{$i} ) {
        push( @rdiff, "group['$k','$i'] = '$k'" );
      }
    }
    foreach $k ( keys %groups ) {
      if ( $i eq $k || $i =~ m/^$k / || $i =~ m/ $k$/ ) {
        push( @rdiff, "groupname['$k','$i'] = '$k'" );
      }
    }
  }
  $rdiff .= join( "\n", @rdiff );
}

sub Rroutine {
  my $i;
  open( R, ">temp/script.R" ) || die "File output error:$!";
  $pc = 0.05;
  $cf = 2;
  print "\n------  请输入Fold Change比较阈值：(默认2)  ------\n";
  print "\nPlease input fold change cut-off (default 2):";
  $i = <STDIN>;
  if ( $i =~ /(\d\.*\d*)/ and $1 > 1 and $1 < 10 ) { $cf = $1; }
  print "\nSetting fold change cut-off to $cf.\n";
  print SMR "\nSetting fold change cut-off to $cf.\n";
  my $rscript =
      "library(limma)\nsetwd('temp')\n"
    . "files <- c(\""
    . join( '","', @files ) . "\")\n"
    . "filesraw <- c(\""
    . join( '","', ( map { "../" . $_ } @routes ) ) . "\")\n"
    . 'RG <- read.maimages(files,"genepix.median")
RGraw <- read.maimages(filesraw,"genepix.median")
RGb <- backgroundCorrect(RGraw, method="subtract")
colnames(RGb$R) <- paste(colnames(RG$R),"Hy5")
colnames(RGb$G) <- paste(colnames(RG$G),"Hy3")
write.table(cbind(RGb$genes,RGb$R,RGb$G),file="raw.txt",sep="\t",
    quote=FALSE,row.names=FALSE,col.names=TRUE)
RGb$R[RGb$R<0] <- 0
RGb$G[RGb$G<0] <- 0
MAlowess <- normalizeWithinArrays(RG, method="loess")
names <- colnames(RG$R)
m <- names
a <- names
idname <- colnames(RG$genes[,c("ID","Name")])
raw <- names
l_before <- names
c <- names
MAa <- MAlowess
# 不满3个有效重复的直接归零
for (i in unique(MAa$genes[,"ID"])){
  for (j in colnames(MAa$M)){
    if(!length(MAa$M[MAa$genes[,"ID"]==i&!is.na(MAa$M[,j]),j]) > 2){
      MAa$M[MAa$genes[,"ID"]==i&!is.na(MAa$M[,j]),j] <- NA
      MAa$A[MAa$genes[,"ID"]==i&!is.na(MAa$M[,j]),j] <- NA
    }
  }
}
# 合并同ID
for (i in sort( unique(MAa$genes[,"ID"]) ) ){
  if(length(files) > 1){ # multi-sample
    m <- rbind(m,log2(apply(2^MAa$M[MAa$genes[,"ID"]==i,],2,median,na.rm=T)));
    a <- rbind(a,apply(MAa$A[MAa$genes[,"ID"]==i,],2,median,na.rm=T));
    c <- rbind(c,apply(2^MAa$M[MAa$genes[,"ID"]==i,],2,sd,na.rm=T)/
      colMeans(2^MAa$M[MAa$genes[,"ID"]==i,],na.rm=T));
    tmp <- apply(cbind(RGb$R[RGb$genes[,"ID"]==i,] ,RGb$G[RGb$genes[,"ID"]==i,]),2,median,na.rm=TRUE);
    if(prod(tmp) != 0)
      l_before <- rbind(l_before,apply(
        (RGb$R[RGb$genes[,"ID"]==i,] / RGb$G[RGb$genes[,"ID"]==i,]),
        2,median,na.rm=TRUE));
  }else{ # one sample
    m <- rbind(m,log2(median(2^MAa$M[MAa$genes[,"ID"]==i,],na.rm=TRUE)));
    a <- rbind(a,median(MAa$A[MAa$genes[,"ID"]==i,],na.rm=TRUE));
    c <- rbind(c,sd(2^MAa$M[MAa$genes[,"ID"]==i,],na.rm=T)/
      mean(2^MAa$M[MAa$genes[,"ID"]==i,],na.rm=T));
    tmp <- apply(cbind(RGb$R[RGb$genes[,"ID"]==i,] ,RGb$G[RGb$genes[,"ID"]==i,]),2,median,na.rm=TRUE);
    if(prod(tmp) != 0)
      l_before <- rbind(l_before,median(
        (RGb$R[RGb$genes[,"ID"]==i,] / RGb$G[RGb$genes[,"ID"]==i,]),na.rm=TRUE));
  }
  idname <- rbind(idname,head(MAa$genes[MAa$genes[,"ID"]==i,c("ID","Name")],1));
  raw <- rbind(raw,apply(cbind(
    (RGraw$R[RGraw$genes[,"ID"]==i,] - RGraw$Rb[RGraw$genes[,"ID"]==i,]),
    (RGraw$G[RGraw$genes[,"ID"]==i,] - RGraw$Gb[RGraw$genes[,"ID"]==i,])),
    2,median));
}
m <- array(as.numeric(m[-1,]),dim=dim(m)-c(1,0))
colnames(m) <- names
a <- array(as.numeric(a[-1,]),dim=dim(a)-c(1,0))
colnames(a) <- names
c <- array(as.numeric(c[-1,]),dim=dim(c)-c(1,0))
colnames(c) <- names
l_before <- array(as.numeric(l_before[-1,]),dim=dim(l_before)-c(1,0))
l_before <- log2(l_before)
rawnames <- raw[1,]
raw <- raw[-1,]
raw <- array(as.numeric(raw),dim=dim(raw))
colnames(raw) <- rawnames
# 先合并,后做scale normalization
ma <- list(M=m,A=a)
MA <- normalizeBetweenArrays(ma,method="scale")
idname <- idname[-1,]
n <- length(raw[1,])
tmp <-  rep(1:(n/2),each=2)
tmp[as.logical(!(1:n)%%2)] <- tmp[as.logical(!(1:n)%%2)]+n/2
raw <- raw[,tmp]
colnames(raw) <- paste(colnames(raw),c("Hy5","Hy3"))
colnames(l_before) <- names
lm <- ma$M # log2 ratio before scale normalization
l <- MA$M  # log2 ratio
f <- 2^l   # fold-change ratio
colnames(lm) <- names
colnames(l) <- names
colnames(f) <- names
# miRNA.txt
' 
    . $rfold 
    . $rpv 
    . $rmean 
    . $rcv 
    . 'write.table(cbind('
    . (
      $dn == 1 ? "idname,fold,raw,l,f"
    : $rpv ne "" ? "idname,fold,pv,raw,lm,l,f,avg,cv"
    : $rcv ne "" ? "idname,fold,raw,lm,l,f,avg,cv"
    : "idname,fold,raw,lm,l,f"
    )
    . '),file="miRNA.txt",sep="\t",na="",quote=FALSE,row.names=FALSE,col.names=TRUE)
# alldiff.txt
' . $rdiff . '
cf <- ' . $cf . '
pc <- ' . $pc . '
cn <- ceiling(sqrt(ncol(fold)))
rn <- ceiling(ncol(fold)/cn)
png(file = "volcanoplot.png", width = 600 * cn, 500 * rn)
par(mfrow = c(rn, cn))
pushline <- function(i,j){
  if(exists("pv"))
    c(idname[i,],fold[i,j],pv[i,j],raw[i,paste(group[!is.na(group[,j]),j],"Hy5")],
        raw[i,paste(group[!is.na(group[,j]),j],"Hy3")],
        lm[i,group[!is.na(group[,j]),j]],l[i,group[!is.na(group[,j]),j]],
        f[i,group[!is.na(group[,j]),j]],avg[i,groupname[!is.na(groupname[,j]),j]],
        cv[i,groupname[!is.na(groupname[,j]),j]])
  else if(exists("avg"))
    c(idname[i,],fold[i,j],raw[i,paste(group[!is.na(group[,j]),j],"Hy5")],
        raw[i,paste(group[!is.na(group[,j]),j],"Hy3")],
        lm[i,group[!is.na(group[,j]),j]],l[i,group[!is.na(group[,j]),j]],
        f[i,group[!is.na(group[,j]),j]],avg[i,groupname[!is.na(groupname[,j]),j]],
        cv[i,groupname[!is.na(groupname[,j]),j]])
  else
    c(idname[i,],fold[i,j],raw[i,paste(group[!is.na(group[,j]),j],"Hy5")],
        raw[i,paste(group[!is.na(group[,j]),j],"Hy3")],
        lm[i,group[!is.na(group[,j]),j]],l[i,group[!is.na(group[,j]),j]],
        f[i,group[!is.na(group[,j]),j]])
}
for (j in colnames(fold)){
  for ( i in 1:nrow(f) ){
    if( !is.na(fold[i,j]) && fold[i,j] >= cf ){
      if(exists("up"))
        up <- rbind(up,pushline(i,j))
      else
        up <- rbind(pushline(i,j))
      if(exists("pv") && !is.na(pv[i,j]) && pv[i,j] <= pc){
        if(exists("uppv"))
          uppv <- rbind(uppv,pushline(i,j))
        else
          uppv <- rbind(pushline(i,j))
      }
    }else if(!is.na(fold[i,j]) && fold[i,j] <= 1/cf){
      if(exists("down"))
        down <- rbind(down,pushline(i,j))
      else
        down <- rbind(pushline(i,j))
      if(exists("pv") && !is.na(pv[i,j]) && pv[i,j] <= pc){
        if(exists("downpv"))
          downpv <- rbind(downpv,pushline(i,j))
        else
          downpv <- rbind(pushline(i,j))
      }
    }
  }
  if(exists("up")){
    up[is.na(up)] <- ""
    write.table(up,file=paste(j,cf,"up.txt",sep="_"),sep="\t",
        na="",quote=FALSE,row.names=FALSE,col.names=TRUE)
    rm(up)
  }
  if(exists("down")){
    down[is.na(down)] <- ""
    write.table(down,file=paste(j,cf,"down.txt",sep="_"),
        sep="\t",na="",quote=FALSE,row.names=FALSE,col.names=TRUE)
    rm(down)
  }
  if(exists("pv")){
    if(exists("uppv")){
    uppv[is.na(uppv)] <- ""
      write.table(uppv,file=paste(j,cf,"uppv.txt",sep="_"),sep="\t",
          na="",quote=FALSE,row.names=FALSE,col.names=TRUE)
      rm(uppv)
    }
    if(exists("downpv")){
    downpv[is.na(downpv)] <- ""
      write.table(downpv,file=paste(j,cf,"downpv.txt",sep="_"),sep="\t",
          na="",quote=FALSE,row.names=FALSE,col.names=TRUE)
      rm(downpv)
    }
    plot(log2(fold[!is.na(pv[,j]),j]),-log10(pv[!is.na(pv[,j]),j]),
        pch = 19, xlab = expression(log[2]^Foldchange),
        ylab=expression(-log[10]^(p-value)), main=paste("Volcano Plot", j),
        xlim = c(-max(abs(log2(fold[!is.na(pv[,j]),j]))),
        max(abs(log2(fold[!is.na(pv[,j]),j])))),
        cex.main = 1.5, cex.lab = 1.3, mgp = c(2.5, 1, 0))
    points(log2( fold[ !is.na(pv[,j]) & pv[,j] <= pc & fold[,j] >= cf,j]),
        -log10(pv[ !is.na(pv[,j]) & pv[,j] <= pc & fold[,j] >= cf,j]),
        col = 2, pch = 19)
    points(log2( fold[ !is.na(pv[,j]) & pv[,j] <= pc & fold[,j] <= 1/cf,j]),
        -log10(pv[ !is.na(pv[,j]) & pv[,j] <= pc & fold[,j] <= 1/cf,j]),
        col = 2, pch = 19)
    abline(v = log2(c(cf, 1/cf)), lty = "dashed", col = "darkgreen",
        lwd = 2)
    abline(h = -log10(pc), lty = "dashed", col = "darkgreen", lwd = 2)
  }
}
dev.off()
# boxplot
png(filename="boxplot.png",width=1200,height=500)
par(mfrow = c(1, 2))
dev <- function(x){
  max(range(x,na.rm=T,finite=T))-min(range(x,na.rm=T,finite=T))
}
boxplot(l_before,ylab="Log2Ratio(Hy5/Hy3)",main="Before Normalization",
    pch=4,cex=.5,border=rainbow(length(files)),outline=T,names=F)
text(1:length(files), par("usr")[3] - dev(l_before)*0.03, srt = 60, adj = 1,
    labels = names, xpd = T, font = 1)
boxplot(l,ylab="Log2Ratio(Hy5/Hy3)",main="After LOWESS & scale Normalization",pch=4,cex=.5,border=rainbow(length(files)),outline=T,names=F)
text(1:length(files), par("usr")[3] - dev(l)*0.03, srt = 60, adj = 1,
    labels = names, xpd = T, font = 1)
dev.off()
# miRNA Expression summary
iR <- RG$R-RG$Rb # raw Hy5
iG <- RG$G-RG$Gb # raw Hy5
iG[iG==0] <- NA
iR[iR==0] <- NA
iGn <- sqrt(iR*iG/(2^MAlowess$M)) # lowessed Hy3
iRn <- iGn*(2^MAlowess$M)         # lowessed Hy5
ra <- log2(sqrt(iR*iG))
rm <- log2(iR/iG)
for (i in names){
  lowessdata <- cbind(RG$genes[order(RG$genes[,c("ID")]),c("ID","Name")],
      round(iRn[order(RG$genes[,c("ID")]),i],digits=1),
      round(iGn[order(RG$genes[,c("ID")]),i],digits=1))
  colnames(lowessdata) <- c("ID","Name","LowessNormHy5","LowessNormHy3")
  write.table(lowessdata,file=paste(i,"_lowess.txt",sep=""),sep="\t",
      na="",quote=FALSE,row.names=FALSE,col.names=TRUE)
  mirnadata <- cbind(idname,2^m[,i],m[,i],c[,i])
  colnames(mirnadata) <- c("ID","Name","MedianRatio","logMedianRatio","CV")
  write.table(mirnadata,file=paste(i,"_miRNA.txt",sep=""),sep="\t",
      na="",quote=FALSE,row.names=FALSE,col.names=TRUE)
  png(filename=paste(i,".png",sep=""),width = 800, height =600 )
  par(mfrow = c(2, 2))
  plot(iG[,i],iR[,i],xlim=c(10,100000),ylim=c(10,100000),xlab="Hy3 Intensity",ylab="Hy5 Intensity",
      log="xy",pch=20,cex=.5,main=paste(i,"Scatter plot(no norm)"),
      cex.main=.9,cex.lab=.8,cex.axis=.7,mgp = c(2, .6, 0))
  abline(a=0,b=1,col=2,lwd=.5);
  plot(iGn[,i],iRn[,i],xlim=c(10,100000),ylim=c(10,100000),xlab="Hy3 Intensity",
      ylab="Hy5 Intensity",log="xy",pch=20,cex=.5,main=paste(i,"Scatter plot(lowess)"),
      cex.main=.9,cex.lab=.8,cex.axis=.7,mgp = c(2, .6, 0))
  abline(a=0,b=1,col=2,lwd=.5)
  plot(ra[,i],rm[,i],xlab="A 1/2*(Log2(Hy5)+Log2(Hy3))",ylab="M Log2(Hy5/Hy3)",
      pch=20,cex=.5,main=paste(i,"MA plot(no norm)"),
      ylim=c(-max(abs(rm[,i]),na.rm=T),max(abs(rm[,i]),na.rm=T)),
      cex.main=.9,cex.lab=.8,cex.axis=.7,mgp = c(2, .6, 0))
  abline(h=0,col=2,lwd=.5)
  plot(MAlowess$A[,i],MAlowess$M[,i],xlab="A 1/2*(Log2(Hy5)+Log2(Hy3))",
      ylab="M Log2(Hy5/Hy3)",pch=20,cex=.5,main=paste(i,"MA plot(lowess)"),
      ylim=c(-max(abs(MAlowess$M[,i]),na.rm=T),max(abs(MAlowess$M[,i]),na.rm=T)),
      cex.main=.9,cex.lab=.8,cex.axis=.7,mgp = c(2, .6, 0))
  abline(h=0,col=2,lwd=.5)
}
dev.off()
# miRNA_CV
write("median CV for each slide", file = "miRNA_CV.txt")
write.table(t(round(apply(c,2,median,na.rm=T),2)), file = "miRNA_CV.txt",
    append = T, na = "", quote = F, row.names = F, sep = "\t")
write("", append = T, file = "miRNA_CV.txt")
mircv <- cbind(idname[,"Name"],f,c)
colnames(mircv) <- c("Name",paste(names,"ratio"),paste(names,"CV"))
write.table(mircv, file = "miRNA_CV.txt", append = T, 
    na = "", quote = F, row.names = F, sep = "\t")
dn = length(files)
cv <- function(x) {
    sd(x, na.rm = T)/mean(x, na.rm = T)
}
# get spike_control & miRNA CV
colnames(RGb$R) <- names
sc1 <- c("Name", paste(rep(names, 4),
    rep(c("Hy5","Hy3","Hy5 CV","Hy3 CV"),each=dn)))
sc2 <- sc1
for (i in sort(unique(RGb$genes[grep("spike_control_v1", 
    RGb$genes[, 5]), 5]))) {
  if(dn > 1){
    sc1 <- rbind(sc1, c(i, apply(RGb$R[RGb$genes[, 5] == i, ], 2,
        median, na.rm = T),
        apply(RGb$G[RGb$genes[, 5] == i, ], 2, median, na.rm = T),
        apply(RGb$R[RGb$genes[,5] == i, ], 2, cv),
        apply(RGb$G[RGb$genes[,5] == i, ], 2, cv) ) )
  }else{
    sc1 <- rbind(sc1, c(i, median(RGb$R[RGb$genes[, 5] == i, ], na.rm = T),
        median(RGb$G[RGb$genes[, 5] == i, ], na.rm = T),
        cv(RGb$R[RGb$genes[,5] == i, ]),cv(RGb$G[RGb$genes[,5] == i, ]) ) )
  }
}
for (i in sort(unique(RGb$genes[grep("spike_control_v2", 
    RGb$genes[, 5]), 5]))) {
  if(dn > 1){
    sc2 <- rbind(sc2, c(i, apply(RGb$R[RGb$genes[, 5] == i, ], 2,
        median, na.rm = T),
        apply(RGb$G[RGb$genes[, 5] == i, ], 2, median, na.rm = T),
        apply(RGb$R[RGb$genes[,5] == i, ], 2, cv),
        apply(RGb$G[RGb$genes[,5] == i, ], 2, cv) ) )
  }else{
    sc2 <- rbind(sc2, c(i, median(RGb$R[RGb$genes[, 5] == i, ], na.rm = T),
        median(RGb$G[RGb$genes[, 5] == i, ], na.rm = T),
        cv(RGb$R[RGb$genes[,5] == i, ]),cv(RGb$G[RGb$genes[,5] == i, ]) ) )
  }
}
colnames(sc1) <- sc1[1, ]
rownames(sc1) <- sc1[, 1]
sc1 <- sc1[-1, -1]
sc1 <- array(data = as.numeric(sc1), dim = dim(sc1),
    dimnames = dimnames(sc1))
colnames(sc2) <- sc2[1, ]
rownames(sc2) <- sc2[, 1]
sc2 <- sc2[-1, -1]
sc2 <- array(data = as.numeric(sc2), dim = dim(sc2),
    dimnames = dimnames(sc2))
if( dn > 1){
sc1cor <- array(dim = c(dn, dn))
sc2cor <- array(dim = c(dn, dn))
for (i in 1:dn) {
    for (j in 1:dn) {
        h1 <- cbind(as.numeric(sc1[, (0:1)*dn+i]),
            as.numeric(sc1[, (0:1)*dn+j]))
        h2 <- cbind(as.numeric(sc2[, (0:1)*dn+i]),
            as.numeric(sc2[, (0:1)*dn+j]))
        sc1cor[i, j] <- cor(h1[apply(h1>=50,1,all),1],
            h1[apply(h1>=50,1,all),2])
        sc2cor[i, j] <- cor(h2[apply(h2>=50,1,all),1],
            h2[apply(h2>=50,1,all),2])
    }
}
colnames(sc1cor) <- colnames(sc2cor) <- rownames(sc1cor) <- rownames(sc2cor) <- names
sc1cor = cbind(rownames(sc1cor), sc1cor)
sc2cor = cbind(rownames(sc2cor), sc2cor)
}
sc1cv = array(dim = c(1, 2*dn))
colnames(sc1cv) <- c(paste(names,"Hy5"),paste(names,"Hy3"))
for (i in 1:(2*dn)) {
    sc1cv[i] <- round(median(sc1[sc1[, i]>=50, i + 2*dn], na.rm = T),2)
}
sc2cv = array(dim = c(1, 2*dn))
colnames(sc2cv) <- colnames(sc1cv)
for (i in 1:(2*dn)) {
    sc2cv[i] <- round(median(sc2[sc2[, i]>=50, i + 2*dn], na.rm = T),2)
}
sc1 = cbind(rownames(sc1), sc1)
sc2 = cbind(rownames(sc2), sc2)
# spike_control.txt
write("Spike v1 median for each slide (Hy5/Hy3 >= 50)",
    file = "spike_control.txt")
write.table(sc1cv, file = "spike_control.txt", append = T,
    na = "", quote = F, row.names = F, sep = "\t")
write("Spike v2 median for each slide (Hy5/Hy3 >= 50)",
    append = T, file = "spike_control.txt")
write.table(sc2cv, file = "spike_control.txt", append = T,
    na = "", quote = F, row.names = F, sep = "\t")
if( dn > 1){
write("", append = T, file = "spike_control.txt")
write("Sample correlation using spike v1 Hy5/Hy3 median (Intestity >= 50)",
    append = T, file = "spike_control.txt")
write.table(sc1cor, file = "spike_control.txt", append = T,
    na = "", quote = F, row.names = F, sep = "\t")
write("", append = T, file = "spike_control.txt")
write("Sample correlation using spike v2 Hy5/Hy3 median (Intestity >= 50)",
    append = T, file = "spike_control.txt")
write.table(sc2cor, file = "spike_control.txt", append = T,
    na = "", quote = F, row.names = F, sep = "\t")
}
write("", append = T, file = "spike_control.txt")
write.table(sc1, file = "spike_control.txt", append = T,
    na = "", quote = F, row.names = F, sep = "\t")
write.table(sc2, file = "spike_control.txt", append = T,
    na = "", quote = F, row.names = F, col.names = F, sep = "\t") 
# cluster.txt
if(dn > 1){
write.table(cbind(idname[apply(!is.na(l),1,any),2],
    l[apply(!is.na(l),1,any),]),file="cluster.txt",
    na = "", quote = F, row.names = F, sep = "\t")
}';
  print R $rscript;
  close R;

  if ( system("R <temp/script.R --vanilla -q") == 0 ) {
    print "Data analysis done. 数据预处理完成。\n";
  }
  else {
    print "R code return errors. R代码运行出错。\n";
    print "<运行出错，按回车键退出>";
    print SMR "Exit with error!: " . ctime() . "\n\n";
    <STDIN>;
    exit 1;
  }
}

sub folder_information {
  my @subfiles = glob "*/*.???";    # 二级目录所有文件
  foreach (@subfiles) {
    if ( !/image\/|result\/|temp\// && /\/(.+?)\.gpr$/i ) {
      push @sn,     $1;
      push @routes, $_;
    }
    if ( !/image\/|result\/|temp\// && /\/(.+?)_R2\.jpg$/i ) {
      copy( $_, "./image/$1.jpg" );
    }
  }
  $dn = @sn;
  print "FOLD CONSTRUCTION DONE.\nTotal Sample Count:$dn\n";
  print "Reading .gpr file ...\n";
  print SMR "Total Sample Count:$dn\n";
}

sub filtergpr {
  my ( $flag, @data, $line, $file );
  my $n = @routes;
  my $i = 1;
  foreach $file (@routes) {
    $file =~ m/\/(.+?\.gpr)$/;
    open( IN,  $file )      || die "can't open file:$!";
    open( OUT, ">temp/$1" ) || die "$!";
    $flag = 0;
    while (<IN>) {
      if ( $flag == 1 ) {
        my @array = split( /\t+/, $_ );
        if ( $array[3] =~ /mir|let/i ) {
          if ( $array[45] <= 0
            or $array[46] <= 0
            or $array[51] <= 0
            or $array[52] <= 0
            or ( $array[51] <= 1 and $array[52] <= 2 )
            or ( $array[51] <= 2 and $array[52] <= 1 ) )
          {
            $array[8]  = 0;
            $array[12] = 0;
            $array[13] = 0;
            $array[20] = 0;
            $array[24] = 0;
            $array[25] = 0;
            $array[45] = 0;
            $array[46] = 0;
          }
          print OUT join( "\t", @array );
        }
      }
      else {
        if (/^"Block"\t/i) { $flag = 1; }
        print OUT $_;
      }
    }
    close(IN);
    close(OUT);
    push( @files, $1 );

    if ( $n > 2 ) { &bar( $i++, $n ); }
  }
  print "\nGPR filteration done.\n";
}

sub swap {
  my ( $i, $k, $a, $n, $t1, $t2 );
  ( $a, $k, $n ) = @_;
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

sub checkname {
  my ( $name, $s, $flag );
  my @names = @_;
  return 0 unless defined $names[0];
  foreach $name (@names) {
    $flag = 0;
    foreach $s (@sn) {
      if ( $s eq $name ) { $flag = 1; }
    }
    if ( $flag == 0 ) { return 0; }
  }
  return 1;
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

sub setformat {

  # note format
  $format1 = $book->add_format();
  $format1->set_font('Verdana');
  $format1->set_size(10);
  $format1->set_bg_color(26);
  $format1->set_text_wrap();
  $format1->set_align("top");

  # title F_B
  $format2 = $book->add_format();
  $format2 = $book->add_format();
  $format2->set_font("Arial");
  $format2->set_bold();
  $format2->set_align("center");
  $format2->set_size(11);
  $format2->set_bg_color(34);

  # title
  $format3 = $book->add_format();
  $format3 = $book->add_format();
  $format3->set_text_wrap();
  $format3->set_font("Arial");
  $format3->set_bold();
  $format3->set_bg_color(30);

  # value
  $format4 = $book->add_format();
  $format4 = $book->add_format();
  $format4->set_font("Arial");
  $format4->set_align("left");

  # title p-value
  $format5 = $book->add_format();
  $format5 = $book->add_format();

  # $format5->set_text_wrap();
  $format5->set_font("Arial");
  $format5->set_bold();
  $format5->set_align("center");
  $format5->set_size(11);
  $format5->set_bg_color(47);

  # Raw intensity
  $format6 = $book->add_format();
  $format6 = $book->add_format();
  $format6->set_font("Arial");
  $format6->set_bold();
  $format6->set_align("center");
  $format6->set_size(11);
  $format6->set_bg_color(31);

  # Log2-Ratio Scale 绿色
  $format7 = $book->add_format();
  $format7 = $book->add_format();
  $format7->set_font("Arial");
  $format7->set_bold();
  $format7->set_align("center");
  $format7->set_size(11);
  $format7->set_bg_color(50);

  # Only Lowess Normalization 紫色
  $format8 = $book->add_format();
  $format8 = $book->add_format();
  $format8->set_font("Arial");
  $format8->set_bold();
  $format8->set_align("center");
  $format8->set_size(11);
  $format8->set_bg_color(25);

  # Log2-Ratio Scale 橙色
  $format9 = $book->add_format();
  $format9 = $book->add_format();
  $format9->set_font("Arial");
  $format9->set_bold();
  $format9->set_align("center");
  $format9->set_size(11);
  $format9->set_bg_color(53);

  # Lowess & Scale Normalization 深蓝
  $format10 = $book->add_format();
  $format10 = $book->add_format();
  $format10->set_font("Arial");
  $format10->set_bold();
  $format10->set_align("center");
  $format10->set_size(11);
  $format10->set_bg_color(54);

  # Ratio Scale 橙黄
  $format11 = $book->add_format();
  $format11 = $book->add_format();
  $format11->set_font("Arial");
  $format11->set_bold();
  $format11->set_align("center");
  $format11->set_size(11);
  $format11->set_bg_color(51);

  # Normalized Data 蓝色
  $format12 = $book->add_format();
  $format12 = $book->add_format();
  $format12->set_font("Arial");
  $format12->set_color("white");
  $format12->set_bold();
  $format12->set_align("center");
  $format12->set_size(11);
  $format12->set_bg_color("blue");

  # Ratio Scale 红
  $format13 = $book->add_format();
  $format13 = $book->add_format();
  $format13->set_font("Arial");
  $format13->set_bold();
  $format13->set_align("center");
  $format13->set_size(11);
  $format13->set_bg_color('red');

  # Log2-Ratio Scale 深绿
  $format14 = $book->add_format();
  $format14 = $book->add_format();
  $format14->set_font("Arial");
  $format14->set_bold();
  $format14->set_align("center");
  $format14->set_size(11);
  $format14->set_bg_color(17);

}
