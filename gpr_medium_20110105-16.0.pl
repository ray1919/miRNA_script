#!/usr/bin/perl -w
use strict;
my @dir=glob "*";
my @datapath;
foreach my $dir (@dir){
    if(-d $dir){
      opendir(IN,$dir);
      while (my $name=readdir IN){
        next unless $name=~/\.gpr$/;
        push @datapath,"$dir/$name";
      }
      closedir IN;
    }  
}
#========================================================================================
my @layout;
my @fore_b;
my $index=0;
foreach my $datapath (@datapath){
    my $flag=0;
    my @layout_single;
    my @fore_b_single;
    open (IN,"<$datapath");
    while(my $line=<IN>){
       $flag=1 if($line=~/block/i);
       next if ($line=~/block/i);
       chomp $line; 
        if($flag==1){
            my @temp=split("\t",$line);
            push(@layout_single,join("\t",$temp[3],$temp[4]));
            push(@fore_b_single,$temp[46]);
        }
    }
    @layout=@layout_single;
    $fore_b[$index]=\@fore_b_single;
    $index++;
    close IN;
}
#================================================================================
my @fore_b_combine;
my @median_data;
my @medians;
my $num=@layout/72;
my $h=0;
#open(OUT,">ABC.txt");
for (my $r1=0;$r1<36;$r1++){
 
  for(my $i=$r1*$num ;$i<=$num*($r1+1)-1;$i++){
   #print OUT $i,"\t",$i+$num,"\t",$i+$num*36,"\t",$i+$num*37,"\n";
   next unless ($layout[$i]=~/mir|let/i);
   my @data_temp;
   for (my $j=0;$j<=$#datapath;$j++){
   $fore_b_combine[$j][$i]=median($fore_b[$j][$i],$fore_b[$j][$i+$num],$fore_b[$j][$i+$num*36],$fore_b[$j][$i+$num*37]);
     if($fore_b_combine[$j][$i]<50){
     last;
     }
     else{
       push (@data_temp,$fore_b_combine[$j][$i]);
     }
   }
   if($#data_temp==$#datapath){
      
      for (my $k=0;$k<=$#datapath;$k++){
           $median_data[$k][$h]=$data_temp[$k];
      }
      $h++;
   }
 }

 $r1++;
}




for(my $i=0;$i<=$#datapath;$i++){
  $medians[$i]=median(@{$median_data[$i]});
}
open(OUT,">median.txt");
print OUT "Row number is $h\n";
for(my $i=0;$i<=$#datapath;$i++){
    my @temp=split(/\//,$datapath[$i]);
print OUT "$temp[$#temp-1]\t$medians[$i]\n";
}
close OUT;
#================================================================================ 
sub median{
   my $median;
   my @temp=sort{$a<=>$b}@_;
   my $size=@temp;
   if($size%2==0){
     $median=($temp[$size/2-1]+$temp[$size/2])/2;
   }
   else{
     $median=$temp[($size-1)/2];
   }
   return $median;
}



